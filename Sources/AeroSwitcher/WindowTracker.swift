import AppKit

// MARK: - Window tracker (Phase 14, B1: watch only)

// AeroSwitcher's own live list of every real window on the Mac, read straight
// from macOS through Accessibility instead of asking AeroSpace. In B1 it only
// WATCHES: Cmd+Tab still shows AeroSpace's list exactly as before, and the
// only thing this list is used for is one log line per Cmd+Tab saying whether
// the two lists agree (checkAgainstAeroSpace, bottom of this file). Nothing
// here moves, resizes, hides or focuses a window. Later steps build on it:
// B2 sorts these windows into workspaces, B6 makes Cmd+Tab read from it.
//
// How it stays up to date (AeroSpace's way, see below for where it's from):
// it does NOT try to follow every change one by one from the notifications.
// Any hint that something might have changed starts a "refresh", which asks
// every watched app again "what windows do you have?". New window numbers
// are added (and sorted into window / dialog / popup, WindowDetection.swift),
// numbers that no longer belong to a window are dropped. The hints are:
//   - from each app: a window was created, the focused window changed
//   - from each window: it was closed, minimized, or un-minimized
//   - from macOS: an app started, quit, came to the front, was hidden
//     (Cmd+H) or shown again, or you switched macOS Spaces
//   - any release of the left mouse button (AeroSpace's comment: "window
//     destroyed" alone is unreliable, a click on a close button is the most
//     reliable sign a window went away)
// After the first contact with an app, asking it again is quick (measured in
// B0: 5 to 11 ms for all normal apps together), so this is cheap.
//
// Every app gets its OWN background thread for this. Asking an app something
// means waiting for its answer, and a frozen app (beach ball) would otherwise
// hold up every other app, or worse, Cmd+Tab. Each question also has a 1
// second limit (axApplication, AccessibilityHelpers.swift).
//
// Which apps are watched (as AeroSpace): every normal app (one with a Dock
// icon), plus a menu-bar-only app once one of its windows comes to the front.
// Menu bar helpers are 4 out of 5 running apps and almost never have a real
// window, so not asking them saves most of the time (B0: 1.1 s vs 0.3 s for
// the first contact). AeroSwitcher never asks itself (Accessibility questions
// to your own app crash) and ignores the lock screen.
//
// Off switch, in case this ever bothers an app: in Terminal
//   defaults write com.aeroswitcher.app WindowTrackerOff -bool true
// and restart AeroSwitcher. `defaults delete com.aeroswitcher.app
// WindowTrackerOff` turns it back on. Temporary, for B1 to B5 only.
//
// Copied and adapted from AeroSpace v0.21.3-Beta
// (https://github.com/nikitabobko/AeroSpace, commit
// d56e1637c3a1ed660d0cadd7534e94fb3218d1c3): the per-app thread and window
// list from Sources/AppBundle/tree/MacApp.swift (getOrRegister,
// refreshAndGetAliveWindowIds, AxWindow.new), the refresh from
// layout/refresh.swift, the macOS events and mouse-release watcher from
// GlobalObserver.swift, the popup re-check from normalizeLayoutReason.swift.
// MIT licence, Copyright (c) 2023 Nikita Bobko, full text in
// LICENSE-AeroSpace.txt. Changes: everything about AeroSpace's tiling tree,
// workspaces and window layout left out; AeroSpace's async tasks and
// cancellation replaced by plain threads, a DispatchGroup and locks; window
// size and position notifications left out until B3 needs them.

// One window as the tracker sees it. Only numbers, names and flags: the
// window's title is never kept or logged.
struct TrackedWindow {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleId: String?
    let kind: AXWindowKind
    let subrole: String
    let minimized: Bool
    let appHidden: Bool

    // AeroSpace's `list-windows` leaves out popups and minimized windows
    // (they sit outside every workspace in AeroSpace), but includes windows
    // of hidden apps and macOS full screen windows. So these are the ones
    // that should match it. (Read in AeroSpace's MacosUnconventional
    // WindowsContainer.swift; the minimized Obsidian window in B0 agrees.)
    var countsLikeAeroSpace: Bool { kind != .popup && !minimized }
}

// Every notification from every app ends here. It has to be a plain function
// (macOS calls it from C), so it can't remember anything itself; it just asks
// the tracker for a refresh. Runs on the app's thread.
private let trackerNotificationCallback: AXObserverCallback = { _, _, notification, _ in
    WindowTracker.shared.scheduleRefresh(reason: notification as String)
}

private let lockScreenBundleId = "com.apple.loginwindow"

// What a refresh needs to know that only the main thread can tell it.
private struct RefreshContext {
    let frontIsLockScreen: Bool
    let mouseDown: Bool
    let appHidden: Bool
    let activationPolicy: NSApplication.ActivationPolicy
}

// MARK: One app

// One watched app: its thread, its notifications, and the windows it has.
// Everything marked "app thread only" is touched only from that app's own
// thread, so it needs no lock.
final class TrackedApp: @unchecked Sendable {
    let nsApp: NSRunningApplication
    let pid: pid_t
    let appName: String
    let bundleId: String?
    private let knownId: AeroSpaceKnownBundleId?

    private var runLoop: CFRunLoop?

    // App thread only.
    private var axApp: AXUIElement?
    private var appSubscription: AXSubscription?
    private struct Entry {
        let element: AXUIElement
        let subscription: AXSubscription  // kept so its notifications keep coming
        var kind: AXWindowKind
        let subrole: String
    }
    private var windows: [CGWindowID: Entry] = [:]

    // "A refresh of this app is still running." Guarded by busyLock. A frozen
    // app gets no new refresh queued until it has answered the last one, so
    // requests can't pile up behind it.
    private let busyLock = NSLock()
    private var busy = false

    init(_ nsApp: NSRunningApplication) {
        self.nsApp = nsApp
        self.pid = nsApp.processIdentifier
        self.appName = nsApp.localizedName ?? "?"
        self.bundleId = nsApp.bundleIdentifier
        self.knownId = nsApp.bundleIdentifier.flatMap { AeroSpaceKnownBundleId(rawValue: $0) }
    }

    // Starts the app's thread and waits the moment it takes to be ready.
    // The thread runs a "run loop": it sleeps until there is work (a refresh
    // handed to it, or a notification from the app) and then wakes up.
    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // A run loop with nothing to watch stops at once; this timer that
            // never fires keeps it alive until the app has accepted its
            // notifications.
            let keepAlive = Timer(timeInterval: 1_000_000_000, repeats: true) { _ in }
            RunLoop.current.add(keepAlive, forMode: .default)
            ready.signal()
            CFRunLoopRun()
            // stop() was called: let go of everything, on this same thread
            // (notifications must be removed where they were added).
            keepAlive.invalidate()
            windows = [:]
            appSubscription = nil
            axApp = nil
        }
        thread.name = "AeroSwitcher window tracker: \(appName)"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    func stop() {
        perform { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // Hands a refresh to the app's thread; `done` gets the app's windows.
    // false = the last refresh hasn't finished (frozen app), nothing queued.
    fileprivate func refresh(_ context: RefreshContext, done: @escaping ([TrackedWindow]) -> Void) -> Bool {
        busyLock.lock()
        if busy { busyLock.unlock(); return false }
        busy = true
        busyLock.unlock()
        perform { [self] in
            let result = refreshOnAppThread(context)
            busyLock.lock()
            busy = false
            busyLock.unlock()
            done(result)
        }
        return true
    }

    // The refresh itself (AeroSpace's refreshAndGetAliveWindowIds plus
    // MacWindow.getOrRegister's sorting). App thread only.
    private func refreshOnAppThread(_ context: RefreshContext) -> [TrackedWindow] {
        let axApp = self.axApp ?? axApplication(pid: pid)
        self.axApp = axApp
        // The app has to accept "tell me about new windows" first. An app that
        // is still starting up often refuses; AeroSpace then counts it as
        // having no windows and simply tries again at the next refresh.
        if appSubscription == nil {
            appSubscription = AXSubscription(
                pid: pid, element: axApp,
                names: [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification],
                callback: trackerNotificationCallback)
            if appSubscription == nil { return [] }
        }

        // Drop windows that are gone: a closed window's element no longer
        // gives a window number. Skipped while the lock screen is in front,
        // where macOS answers oddly (AeroSpace's "second line of defence
        // against lock screen").
        //
        // Note this keeps a window that is still alive but missing from the
        // app's current list. AeroSpace does the same, and it's what keeps
        // windows on another macOS Space (a full screen game) known, as long
        // as they were seen once.
        if !context.frontIsLockScreen {
            windows = windows.filter { axWindowId(of: $0.value.element) != nil }
        }

        // Add new windows. Not while the left mouse button is down: dragging
        // a tab out of a browser makes a window that may still turn back
        // into a tab (AeroSpace issue 1001). The mouse release asks again.
        if !context.mouseDown {
            for (id, element) in axWindows(ofApp: axApp) where windows[id] == nil {
                // A window that won't accept notifications isn't counted
                // (AeroSpace's AxWindow.new), tried again next refresh.
                guard let subscription = AXSubscription(
                    pid: pid, element: element,
                    names: [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification],
                    callback: trackerNotificationCallback) else { continue }
                let kind = axWindowKind(element, app: axApp, knownId, context.activationPolicy, windowLevel(for: id))
                windows[id] = Entry(element: element, subscription: subscription, kind: kind,
                                    subrole: axString(element, kAXSubroleAttribute) ?? "-")
            }
        }

        // Something sorted as a popup can grow into a real window (some apps
        // show a window before it has its buttons). AeroSpace re-checks every
        // popup at every refresh (validateStillPopups); so does this.
        for (id, entry) in windows where entry.kind == .popup {
            if axIsWindowHeuristic(entry.element, app: axApp, knownId, context.activationPolicy, windowLevel(for: id)) {
                windows[id]?.kind = axIsDialogHeuristic(entry.element, knownId, windowLevel(for: id)) ? .dialog : .window
            }
        }

        return windows.map { id, entry in
            TrackedWindow(
                id: id, pid: pid, appName: appName, bundleId: bundleId,
                kind: entry.kind, subrole: entry.subrole,
                minimized: axBool(entry.element, kAXMinimizedAttribute) ?? false,
                appHidden: context.appHidden)
        }
    }
}

// MARK: All apps

final class WindowTracker: @unchecked Sendable {
    static let shared = WindowTracker()

    // The latest list, per app. Guarded by `lock`, so any thread can read it
    // at any time without waiting for a refresh.
    private let lock = NSLock()
    private var windowsByPid: [pid_t: [TrackedWindow]] = [:]
    private var lastRefreshDone: Date?

    // Main thread only.
    private var apps: [pid_t: TrackedApp] = [:]
    private(set) var isRunning = false
    private var refreshScheduled = false
    private var refreshRunning = false
    private var refreshAgain = false
    private var lastReason = ""  // for the debug log line only
    private var isFirstRefresh = true
    private var lastSlowWarning: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?

    // Called once at launch (main.swift). Main thread.
    func start() {
        guard !isRunning else { return }
        if UserDefaults.standard.bool(forKey: "WindowTrackerOff") {
            logInfo("WindowTracker: turned off (WindowTrackerOff is set), not watching windows")
            return
        }
        // Look-only check, never a permission prompt.
        guard AXIsProcessTrusted() else {
            logWarn("WindowTracker: no Accessibility permission, not watching windows")
            return
        }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.scheduleRefresh(reason: note.name.rawValue)
            })
        }
        // Sees mouse releases in every app (only that they happened, not
        // where or in what).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.scheduleRefresh(reason: "mouse up")
        }
        scheduleRefresh(reason: "launch")
    }

    // Any thread. Several hints in a row (one click often sends three or
    // four) become one refresh: a refresh already waiting to start takes
    // them all, and one that is already running is followed by exactly one
    // more. (AeroSpace instead cancels the running refresh and starts over.)
    func scheduleRefresh(reason: String) {
        DispatchQueue.main.async { [self] in
            guard isRunning else { return }
            lastReason = reason
            if refreshRunning { refreshAgain = true; return }
            if refreshScheduled { return }
            refreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                refreshScheduled = false
                runRefresh()
            }
        }
    }

    // Main thread. Decides which apps to watch, hands each its refresh, and
    // collects the answers on a background thread so the main thread (which
    // also runs Cmd+Tab) never waits for an app.
    private func runRefresh() {
        refreshRunning = true
        let startedAt = Date()
        let reason = lastReason
        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication
        let frontIsLockScreen = front?.bundleIdentifier == lockScreenBundleId
        let mouseDown = NSEvent.pressedMouseButtons == 1
        let myPid = ProcessInfo.processInfo.processIdentifier

        var wanted: [pid_t: NSRunningApplication] = [:]
        for nsApp in workspace.runningApplications where nsApp.activationPolicy == .regular {
            wanted[nsApp.processIdentifier] = nsApp
        }
        // Menu-bar-only apps stay watched once they're in, like AeroSpace.
        for (pid, app) in apps {
            wanted[pid] = app.nsApp
        }
        if let front {
            wanted[front.processIdentifier] = front
        }
        wanted = wanted.filter { pid, nsApp in
            pid != myPid && nsApp.bundleIdentifier != lockScreenBundleId && !nsApp.isTerminated
        }

        for (pid, app) in apps where wanted[pid] == nil {
            app.stop()
            apps[pid] = nil
        }
        for (pid, nsApp) in wanted where apps[pid] == nil {
            let app = TrackedApp(nsApp)
            app.start()
            apps[pid] = app
        }

        let group = DispatchGroup()
        let answersLock = NSLock()
        var answers: [pid_t: [TrackedWindow]] = [:]
        var stillBusy: [String] = []
        for (pid, app) in apps {
            let context = RefreshContext(
                frontIsLockScreen: frontIsLockScreen, mouseDown: mouseDown,
                appHidden: app.nsApp.isHidden, activationPolicy: app.nsApp.activationPolicy)
            group.enter()
            let queued = app.refresh(context) { windows in
                answersLock.lock()
                answers[pid] = windows
                answersLock.unlock()
                group.leave()
            }
            if !queued {
                stillBusy.append(app.appName)
                group.leave()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // An app that takes longer than this keeps its last known
            // windows for now; its answer still updates its own list and is
            // picked up at the next refresh.
            let allAnswered = group.wait(timeout: .now() + 3) == .success
            answersLock.lock()
            let got = answers
            answersLock.unlock()
            DispatchQueue.main.async { [self] in
                lock.lock()
                // Apps that quit are dropped; apps that answered get their
                // new list; apps that didn't keep their old one.
                windowsByPid = windowsByPid.filter { apps[$0.key] != nil }
                for (pid, windows) in got where apps[pid] != nil {
                    windowsByPid[pid] = windows
                }
                lastRefreshDone = Date()
                let all = windowsByPid.values.joined()
                lock.unlock()

                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                // Only with AEROSWITCHER_DEBUG=1 (or the LogDebug setting):
                // one line per refresh, for finding out what a refresh saw.
                logDebug("WindowTracker: refresh (\(reason)) took \(ms) ms, \(apps.count) apps, \(all.count) windows, \(all.filter(\.countsLikeAeroSpace).count) counted like AeroSpace")
                if isFirstRefresh {
                    isFirstRefresh = false
                    logInfo("WindowTracker: watching \(apps.count) apps, \(all.count) windows (\(all.filter(\.countsLikeAeroSpace).count) of them counted like AeroSpace), first look took \(ms) ms")
                    // One comparison right away, so the log says whether the
                    // lists agree without waiting for the first Cmd+Tab. One
                    // AeroSpace question, in the background.
                    DispatchQueue.global(qos: .utility).async { [self] in
                        if let theirs = getWindowsWithFocus()?.windows {
                            _ = compareAndLog(theirs, label: "at launch: ", isRecheck: false)
                        }
                    }
                } else if !allAnswered || !stillBusy.isEmpty || ms > 1000 {
                    // At most one warning a minute, a frozen app would
                    // otherwise write one at every click.
                    if lastSlowWarning.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                        lastSlowWarning = Date()
                        let late = apps.filter { got[$0.key] == nil }.map(\.value.appName).sorted()
                        logWarn("WindowTracker: refresh took \(ms) ms, no answer yet from: \(late.isEmpty ? "-" : late.joined(separator: ", "))")
                    }
                }
                refreshRunning = false
                if refreshAgain {
                    refreshAgain = false
                    scheduleRefresh(reason: "changed during refresh")
                }
            }
        }
    }

    // Every window the tracker knows right now. Any thread, never waits.
    func currentWindows() -> (windows: [TrackedWindow], refreshedAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        return (Array(windowsByPid.values.joined()), lastRefreshDone)
    }

    // MARK: Comparing with AeroSpace

    // Called by Cmd+Tab (WindowController.swift) with AeroSpace's list of
    // every window from that same press. Main thread; the comparing and
    // logging run in the background, so Cmd+Tab doesn't wait for them.
    //
    // Writes one line: "matches AeroSpace (N windows)", or "differs" with the
    // windows only one side has. Because a window that opened or closed a
    // moment ago can be on one side only for a split second, a difference is
    // checked again 1 second later (asking AeroSpace once more, in the
    // background), which says "matches now" (just timing) or "still differs"
    // (a real difference to look into).
    func checkAgainstAeroSpace(_ aerospaceWindows: [AeroWindow]) {
        guard isRunning else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            guard !compareAndLog(aerospaceWindows, label: "", isRecheck: false) else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                guard let again = getWindowsWithFocus()?.windows else { return }
                _ = compareAndLog(again, label: "1 s later: ", isRecheck: true)
            }
        }
    }

    // true = the lists match.
    private func compareAndLog(_ aerospaceWindows: [AeroWindow], label: String, isRecheck: Bool) -> Bool {
        let (all, refreshedAt) = currentWindows()
        let allById = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ours = Set(all.filter(\.countsLikeAeroSpace).map(\.id))
        var theirs: [CGWindowID: AeroWindow] = [:]
        for window in aerospaceWindows {
            if let id = CGWindowID(window.id) { theirs[id] = window }
        }
        let onlyAeroSpace = Set(theirs.keys).subtracting(ours).sorted()
        let onlyTracker = ours.subtracting(theirs.keys).sorted()
        if onlyAeroSpace.isEmpty && onlyTracker.isEmpty {
            logInfo("WindowTracker: \(label)\(isRecheck ? "matches now" : "matches") AeroSpace (\(ours.count) windows)")
            return true
        }
        // For a window AeroSpace has, say what the tracker thinks of it if it
        // knows it at all (popup? minimized?), which usually explains it.
        let aeroText = onlyAeroSpace.map { id -> String in
            let w = theirs[id]!
            let ourView = allById[id].map { " (tracker: \($0.kind.rawValue)\($0.minimized ? ", minimized" : ""))" } ?? ""
            return "\(id) \(w.appName) in \(w.workspace)\(ourView)"
        }
        let trackerText = onlyTracker.map { id -> String in
            let w = allById[id]!
            return "\(id) \(w.appName) \(w.kind.rawValue) \(w.subrole)\(w.appHidden ? " app hidden" : "")"
        }
        let age = refreshedAt.map { "\(Int(Date().timeIntervalSince($0) * 1000)) ms old" } ?? "never refreshed"
        logInfo("WindowTracker: \(label)\(isRecheck ? "still differs from" : "differs from") AeroSpace (\(theirs.count) vs \(ours.count) windows, tracker list \(age)); only AeroSpace: \(aeroText.isEmpty ? "-" : aeroText.joined(separator: ", ")); only tracker: \(trackerText.isEmpty ? "-" : trackerText.joined(separator: ", "))")
        return false
    }
}
