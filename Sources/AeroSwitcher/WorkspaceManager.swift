import AppKit

// MARK: - Own window manager (Phase 14, B2 to B6)

// This file is AeroSwitcher being its own window manager, the job the
// separate app AeroSpace did before: there are a few named WORKSPACES (Core,
// School, ...), every window belongs to exactly one, the windows of one
// workspace are on screen and the windows of all the others are hidden.
//
// It only does anything when AeroSwitcher is set to manage windows itself
// (`ownWindowManager`, right below). Otherwise AeroSpace does the job and
// nothing in this file runs, apart from the small rescue at launch.
//
// How a window is "hidden". macOS has no way to make another app's window
// invisible, so AeroSpace's trick is used (copied from its hideInCorner and
// unhideFromCorner, tree/MacWindow.swift): the window is PARKED, moved so
// its top left corner sits one point inside the bottom right corner of the
// screen. Everything but one point of it is then off screen. Showing it
// again moves it back to where it was.
//
// Never losing a window is the first rule here, because a bug in this file
// doesn't show a wrong picture, it moves real windows:
//   - Where every parked window was is written to a small file
//     (window-state.json, next to config.json) BEFORE the window is moved.
//   - When AeroSwitcher quits (menu, pkill, Ctrl+C), every parked window is
//     moved back first.
//   - If AeroSwitcher crashes, the next launch reads the file and carries
//     on (or, if it is no longer the window manager, moves them all back).
//   - "Bring Back All Windows" in the menu puts every window on screen in
//     the workspace you are in, including ones this file lost track of.
//   - It refuses to manage windows while AeroSpace is running: two window
//     managers would fight over every window.
//
// Where its facts come from: the window tracker (WindowTracker.swift) keeps
// the live list of real windows and which one has the keyboard focus. After
// each update of that list, trackerRefreshed() below runs: it sorts new
// windows into workspaces by the rules in config.json, follows the focus
// (clicking an app in the Dock whose window is in another workspace
// switches to that workspace, as AeroSpace does), and makes sure every
// window is parked or shown as it should be.
//
// Threads: everything marked "main thread" is only ever touched there.
// Other threads (the Cmd+Tab window list is read in the background) get a
// copy, `snapshot`, guarded by a lock. Moving a window means asking its app,
// which can be slow or frozen, so that always happens on the app's own
// tracker thread (WindowTracker.act) and never makes this file wait.
//
// Copied and adapted from AeroSpace v0.21.3-Beta
// (https://github.com/nikitabobko/AeroSpace, commit
// d56e1637c3a1ed660d0cadd7534e94fb3218d1c3): hiding and showing from
// Sources/AppBundle/tree/MacWindow.swift (hideInCorner, unhideFromCorner),
// focusing a window from tree/MacApp.swift (nativeFocus), following the
// focus from focus.swift and getNativeFocusedWindow.swift, putting windows
// back at quit from terminationHandler / setAxFrameForTermination. MIT
// licence, Copyright (c) 2023 Nikita Bobko, full text in
// LICENSE-AeroSpace.txt. Changes: AeroSpace's tiling tree is gone (a
// workspace here is just a name each window points at), windows are parked
// at their real remembered position instead of a proportional one, and the
// remembered positions are kept in a file so a crash can't lose them.

// true = AeroSwitcher manages windows itself and AeroSpace is not used at
// all. Decided once at launch and never changed while running (switching is
// done in the Setup window, which restarts AeroSwitcher). Stored in
// UserDefaults as "OwnWindowManager". A test copy (one started with
// AEROSWITCHER_CONFIG_DIR) ignores the stored setting, which belongs to the
// real app, and only looks at AEROSWITCHER_OWN_WM=1.
let ownWindowManager: Bool = {
    let environment = ProcessInfo.processInfo.environment
    if environment["AEROSWITCHER_CONFIG_DIR"] != nil {
        return environment["AEROSWITCHER_OWN_WM"] == "1"
    }
    return UserDefaults.standard.bool(forKey: "OwnWindowManager")
}()

let aeroSpaceBundleId = "bobko.aerospace"

// TEST ONLY, and only in a test copy (AEROSWITCHER_CONFIG_DIR set): a list of
// app names, comma separated, in AEROSWITCHER_WM_ONLY_APPS. The manager then
// only knows windows of those apps and never touches any other window. With
// "TextEdit" a test can park and show dummy TextEdit documents while every
// real window on the Mac is left completely alone.
private let testOnlyApps: Set<String>? = {
    let environment = ProcessInfo.processInfo.environment
    guard environment["AEROSWITCHER_CONFIG_DIR"] != nil,
          let list = environment["AEROSWITCHER_WM_ONLY_APPS"], !list.isEmpty else { return nil }
    return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
}()

// What is written to window-state.json. Window numbers only mean something
// until the Mac restarts, so the file also says which start of the Mac it
// belongs to, and a file from an earlier start is ignored.
private struct SavedState: Codable {
    struct Frame: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var needsResize: Bool?
    }
    struct Window: Codable {
        var workspace: String
        var pid: Int32
        // Where the window was before it was parked. Missing = not parked.
        var parked: Frame?
        // The toggle key left it at the smaller size.
        var restored: Bool?
    }
    var bootTime: Double
    var focusedWorkspace: String
    var windows: [String: Window]
}

final class WorkspaceManager: @unchecked Sendable {
    static let shared = WorkspaceManager()

    // Both are called on the main thread. The menu bar icon listens to the
    // first (the workspace name it shows), the recent order (MRUTracker) to
    // the second. Set by MenuBar.swift.
    var onWorkspaceChanged: ((String) -> Void)?
    var onFocusChanged: ((_ windowID: String, _ workspace: String) -> Void)?

    // A parked window: where it was (and so where it goes back to).
    private struct Parked {
        let pid: pid_t
        var frame: CGRect
        // It was made "maximized" while parked, where macOS can refuse the
        // new size. So the size is set again when it comes back.
        var needsResize: Bool
    }

    // A window that vanished from the list a moment ago. Kept for 30
    // seconds, because an app that doesn't answer for a moment can make its
    // windows vanish and come back, and they must come back to the SAME
    // workspace instead of being sorted again like new windows.
    private struct Gone {
        let workspace: String
        let parked: Parked?
        let restored: Bool
        let at: Date
    }

    // MARK: State (main thread only)

    private var started = false
    // nil = managing. Otherwise why not, shown in the menu and Setup window.
    private var pauseReason: String? = "Not started yet"
    private var focusedWorkspace = ""
    private var workspaceOf: [CGWindowID: String] = [:]
    private var parked: [CGWindowID: Parked] = [:]
    private var restored: Set<CGWindowID> = []
    // Per workspace, its windows from most to least recently focused. Only
    // used to pick the window to focus after a workspace switch; the
    // Cmd+Tab order has its own history (MRUTracker).
    private var recent: [String: [CGWindowID]] = [:]
    // The focused window the last time the list was updated, to notice when
    // the focus CHANGES (only a change makes the workspace follow).
    private var lastSeenFocus: CGWindowID?
    // After AeroSwitcher itself focused a window (workspace switch, Cmd+Tab)
    // the Mac takes a moment to get there. Until that window is seen as
    // focused (or 2 seconds passed) other focus reports are ignored, or a
    // late report of the OLD window would switch straight back.
    private var pendingFocus: (id: CGWindowID, deadline: Date)?
    private var recentlyGone: [CGWindowID: Gone] = [:]
    // The managed windows as of the last list update.
    private var tracked: [CGWindowID: TrackedWindow] = [:]
    private var firstPass = true
    private var startedAt = Date()
    private var savedAtLaunch: SavedState?
    private var lastWrittenState: Data?
    private var aeroSpaceRunning = false
    private var observers: [NSObjectProtocol] = []
    private var slowTimer: Timer?
    private var commandTimer: Timer?

    // MARK: Snapshot (any thread)

    private struct Snapshot {
        var windows: [AeroWindow] = []
        var names: [String] = []
        var focusedWorkspace: String?
        var focusedWindow: AeroWindow?
        var pauseReason: String? = "Not started yet"
        var parked: [CGWindowID: Parked] = [:]
        var state: SavedState?
    }
    private let lock = NSLock()
    private var snapshot = Snapshot()

    // true while it is really managing windows.
    var isManaging: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.pauseReason == nil
    }

    // Why it is not managing ("AeroSpace is running", ...), nil if it is.
    var pausedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.pauseReason
    }

    func workspaceNamesSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.names
    }

    func focusedWorkspaceSnapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.focusedWorkspace
    }

    // Every managed window, in the shape the rest of the app already uses
    // for AeroSpace's answers, so Cmd+Tab, the overview and the menu don't
    // care who the window manager is (see AeroSpaceBridge.swift).
    func windowsSnapshot() -> [AeroWindow] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.windows
    }

    func focusedWindowSnapshot() -> AeroWindow? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.focusedWindow
    }

    // Remembers the choice for the NEXT launch. Restarting is the caller's
    // job (the Setup window does it).
    static func setOwnMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "OwnWindowManager")
        logInfo("WorkspaceManager: own window manager set to \(on ? "on" : "off") for the next launch")
    }

    // MARK: Start

    // Called once at launch from main.swift, BEFORE the window tracker
    // starts (it hooks into the tracker's updates). Main thread. Does
    // nothing unless AeroSwitcher is its own window manager.
    func start() {
        guard ownWindowManager, !started else { return }
        started = true
        startedAt = Date()
        ScreenLayout.shared.start()
        savedAtLaunch = Self.loadState()
        aeroSpaceRunning = Self.isAeroSpaceRunning()

        // AeroSpace starting or quitting changes whether this may manage.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, app?.bundleIdentifier == aeroSpaceBundleId else { return }
                self.aeroSpaceRunning = Self.isAeroSpaceRunning()
                self.reconsider(reason: "AeroSpace started or quit")
            })
        }
        // Another app came to the front (a Dock click, a notification, the
        // system's own app switching): forget which window was focused last,
        // so the next update follows the new app's focused window even when
        // it is the same window as before (it may be parked in another
        // workspace; following it is what shows that workspace).
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.lastSeenFocus = nil
        })
        // New rules or workspaces in config.json apply at once.
        observers.append(NotificationCenter.default.addObserver(forName: .configDidReload, object: nil, queue: .main) { [weak self] _ in
            self?.reconsider(reason: "config reloaded")
        })

        WindowTracker.shared.onRefresh = { [weak self] in self?.trackerRefreshed() }

        // Whatever way the app ends (menu Quit, pkill, Ctrl+C all finish in
        // exit()), parked windows are moved back first. atexit is the one
        // hook that runs for all of them. Not for a crash or `kill -9`:
        // that case is covered by the file, see the top of this file.
        atexit { WorkspaceManager.shared.restoreForTermination() }

        // While paused nothing else may wake this up (no window list without
        // the Accessibility permission), so look again every few seconds:
        // the moment the reason is gone, managing starts by itself.
        slowTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.pauseReason != nil else { return }
            if AXIsProcessTrusted() && !WindowTracker.shared.isRunning { WindowTracker.shared.start() }
            self.reconsider(reason: "paused, checking again")
        }

        startTestCommands()
        logInfo("WorkspaceManager: AeroSwitcher is its own window manager"
            + (testOnlyApps.map { " (TEST: only windows of \($0.sorted().joined(separator: ", ")))" } ?? ""))
        // Not decided yet: the first update of the window list (a moment
        // after launch) decides whether to manage. If the list never comes
        // (no Accessibility permission), the 5 second look above does.
        pauseReason = "Starting"
        publish()
    }

    private static func isAeroSpaceRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: aeroSpaceBundleId).isEmpty
    }

    // Something changed that the window list doesn't know about: look at
    // everything again (through a list update if the tracker runs, so the
    // list is fresh; directly if it doesn't).
    private func reconsider(reason: String) {
        if WindowTracker.shared.isRunning {
            WindowTracker.shared.scheduleRefresh(reason: reason)
        } else {
            _ = updatePause()
            publish()
        }
    }

    // MARK: May it manage?

    private func currentPauseReason() -> String? {
        // Look-only, never a permission prompt.
        if !AXIsProcessTrusted() { return "No Accessibility permission" }
        if !WindowTracker.shared.isRunning { return "The window list is switched off (WindowTrackerOff)" }
        if windowManagerSettings.workspaces.isEmpty { return "No workspaces set up (Settings > Workspaces)" }
        if aeroSpaceRunning && testOnlyApps == nil { return "AeroSpace is running" }
        return nil
    }

    // Works out whether managing is allowed right now and handles the
    // change either way. Returns true when managing.
    private func updatePause() -> Bool {
        let reason = currentPauseReason()
        guard reason != pauseReason else { return reason == nil }
        let wasManaging = pauseReason == nil
        pauseReason = reason
        if let reason {
            logWarn("WorkspaceManager: paused: \(reason)")
            if wasManaging {
                // Don't leave windows parked while nobody is in charge.
                let count = unparkAll()
                logInfo("WorkspaceManager: moved \(count) parked windows back on screen because it is paused")
                if reason == "AeroSpace is running" {
                    // Not from inside the list update: an alert waits for a
                    // click, and the update must finish first.
                    DispatchQueue.main.async {
                        showFailureAlert("AeroSwitcher stopped managing windows",
                            "AeroSpace was started, and two window managers would fight over your windows. All windows are back on screen. Quit AeroSpace to let AeroSwitcher carry on, or go back to AeroSpace in AeroSwitcher's Setup window.")
                    }
                }
            }
        } else {
            logInfo("WorkspaceManager: managing windows, workspaces: \(windowManagerSettings.workspaceNames.joined(separator: ", "))")
        }
        return reason == nil
    }

    // MARK: After every update of the window list

    private func isManaged(_ window: TrackedWindow) -> Bool {
        guard window.kind != .popup else { return false }
        if let only = testOnlyApps, !only.contains(window.appName) { return false }
        return true
    }

    // The workspace the rules give a window, or nil for "no rule". Rules
    // look at where the window's app is on disk, like AeroSpace's
    // %{app-bundle-path} (Steam's window belongs to a helper INSIDE
    // Steam.app, so the path still says Steam). An app the KnownApps files
    // know under another name (Minecraft's game runs as "java") is also
    // tried by that name.
    private func ruleWorkspace(for window: TrackedWindow) -> String? {
        let rules = windowManagerSettings
        if let path = window.appPath, let name = rules.workspace(forBundlePath: path) { return name }
        if let owner = knownApps.owner(ofPID: window.pid)?.name, let name = rules.workspace(forBundlePath: owner) { return name }
        return nil
    }

    // Main thread, called by the tracker after each update.
    private func trackerRefreshed() {
        guard updatePause() else { publish(); return }
        let names = windowManagerSettings.workspaceNames
        let (all, _) = WindowTracker.shared.currentWindows()
        let focusId = WindowTracker.shared.currentFocusedWindowId()
        let managed = all.filter(isManaged)
        tracked = Dictionary(managed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()

        // The very first time: which workspace is showing? The one from the
        // file if AeroSwitcher was managing before (a restart), else the
        // one the rules give the focused window, else the first.
        if firstPass {
            if let saved = savedAtLaunch, names.contains(saved.focusedWorkspace) {
                focusedWorkspace = saved.focusedWorkspace
            } else if let focusId, let window = tracked[focusId], let name = ruleWorkspace(for: window), names.contains(name) {
                focusedWorkspace = name
            } else {
                focusedWorkspace = names[0]
            }
            onWorkspaceChanged?(focusedWorkspace)
        } else if !names.contains(focusedWorkspace) {
            // The workspace that was showing got removed in Settings.
            focusedWorkspace = names[0]
            onWorkspaceChanged?(focusedWorkspace)
        }

        // 1. Windows that are gone.
        for id in Array(workspaceOf.keys) where tracked[id] == nil {
            recentlyGone[id] = Gone(workspace: workspaceOf[id]!, parked: parked[id], restored: restored.contains(id), at: now)
            forget(id)
        }
        recentlyGone = recentlyGone.filter { now.timeIntervalSince($0.value.at) < 30 }

        // 2. New windows get a workspace.
        var newWindows: [TrackedWindow] = []
        for window in managed where workspaceOf[window.id] == nil {
            let id = window.id
            if let back = recentlyGone.removeValue(forKey: id) {
                workspaceOf[id] = names.contains(back.workspace) ? back.workspace : focusedWorkspace
                parked[id] = back.parked
                if back.restored { restored.insert(id) }
                continue
            }
            if let saved = savedAtLaunch?.windows[String(id)], names.contains(saved.workspace) {
                // AeroSwitcher was managing before this launch (or AeroSpace
                // was, see seedFromAeroSpace): the window keeps its
                // workspace, and if it is still parked from then, where it
                // goes back to. Looked at for the first minute, not only the
                // first update: an app that answers slowly at launch shows
                // its windows a few seconds late.
                workspaceOf[id] = saved.workspace
                if let frame = saved.parked {
                    parked[id] = Parked(pid: window.pid,
                                        frame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                                        needsResize: frame.needsResize ?? false)
                }
                if saved.restored == true { restored.insert(id) }
                continue
            }
            let name = ruleWorkspace(for: window).flatMap { names.contains($0) ? $0 : nil } ?? focusedWorkspace
            workspaceOf[id] = name
            // Windows seen in the first 5 seconds were already open before
            // AeroSwitcher started (a slow app shows them late), so they are
            // only sorted, never resized.
            if firstPass || now.timeIntervalSince(startedAt) < 5 {
                // A window that was already open when managing started is
                // only sorted, never resized. If it sits in the parking
                // corner with nothing on file (left there by a crash before
                // the file existed, or by another window manager), treat it
                // as parked so it comes back on screen when its workspace
                // shows.
                if let frame = window.frame, ScreenLayout.shared.looksParked(frame) {
                    parked[id] = Parked(pid: window.pid, frame: fallbackFrame(size: frame.size), needsResize: false)
                }
            } else {
                newWindows.append(window)
            }
        }
        // A workspace removed in Settings: its windows come to this one.
        for (id, name) in workspaceOf where !names.contains(name) {
            workspaceOf[id] = focusedWorkspace
        }

        // 3. Follow the focus.
        if let pending = pendingFocus, focusId == pending.id || now > pending.deadline {
            pendingFocus = nil
        }
        if pendingFocus == nil, let focusId, let name = workspaceOf[focusId], focusId != lastSeenFocus {
            lastSeenFocus = focusId
            noteFocus(focusId, in: name)
            if name != focusedWorkspace {
                let from = focusedWorkspace
                focusedWorkspace = name
                logInfo("WorkspaceManager: \(from) -> \(name) (following the focused window)")
                onWorkspaceChanged?(name)
            }
        }

        // 4. Park and show whatever isn't where it should be.
        applyLayout()

        // 5. New real windows fill the screen.
        if windowManagerSettings.maximizeNewWindows {
            for window in newWindows {
                let id = window.id, pid = window.pid
                WindowSizing.checkNewWindow(pid: pid, windowId: id) { [weak self] in
                    self?.maximizeNew(id)
                }
            }
        }
        if !newWindows.isEmpty {
            // Kind, subrole and size too (never the title): on 2026-11-17 a
            // new Chrome window appeared every 6 to 8 seconds for 11 minutes
            // and the log couldn't say what they were.
            logInfo("WorkspaceManager: new windows: " + newWindows.map { window in
                let size = window.frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
                return "\(window.id) \(window.appName) \(window.kind.rawValue) \(window.subrole) \(size) -> \(workspaceOf[window.id] ?? "?")"
            }.joined(separator: ", "))
        }
        if savedAtLaunch != nil && now.timeIntervalSince(startedAt) > 60 { savedAtLaunch = nil }
        if firstPass {
            firstPass = false
            let counts = names.map { name in "\(name) \(workspaceOf.values.filter { $0 == name }.count)" }.joined(separator: ", ")
            logInfo("WorkspaceManager: started with workspace \(focusedWorkspace); windows per workspace: \(counts); \(parked.count) parked")
        }
        publish()
    }

    private func forget(_ id: CGWindowID) {
        if let name = workspaceOf.removeValue(forKey: id) {
            recent[name]?.removeAll { $0 == id }
        }
        parked[id] = nil
        restored.remove(id)
        if lastSeenFocus == id { lastSeenFocus = nil }
    }

    private func noteFocus(_ id: CGWindowID, in workspace: String) {
        recent[workspace, default: []].removeAll { $0 == id }
        recent[workspace, default: []].insert(id, at: 0)
        onFocusChanged?(String(id), workspace)
    }

    // MARK: Parking and showing

    // Where a parked window's top left corner goes: one point inside the
    // bottom right corner of the usable screen (AeroSpace's
    // hideInCorner(.bottomRightCorner)). macOS may nudge it up a little so
    // the title bar stays reachable; that's fine. With more than one display
    // the right-most one is used. Zoom is the one app that jumps away when a
    // single point shows (AeroSpace issue 527), so it gets no offset.
    private func parkPoint(for window: TrackedWindow) -> CGPoint? {
        guard let screen = ScreenLayout.shared.rightmostScreen() else { return nil }
        let offset: CGFloat = window.bundleId == AeroSpaceKnownBundleId.zoom.rawValue ? 0 : 1
        return CGPoint(x: screen.visible.maxX - offset, y: screen.visible.maxY - offset)
    }

    // Used when where a window was is not known: top left of the usable
    // screen, keeping its size.
    private func fallbackFrame(size: CGSize) -> CGRect {
        let origin = ScreenLayout.shared.screen(for: nil)?.visible.origin ?? .zero
        return CGRect(origin: origin, size: size)
    }

    // A window of a workspace that isn't showing must be parked, unless it
    // is minimized, in macOS full screen (its own Space) or its app is
    // hidden with Cmd+H: those are already out of sight and AeroSpace
    // leaves them alone too.
    private func shouldBeParked(_ window: TrackedWindow) -> Bool {
        guard let name = workspaceOf[window.id] else { return false }
        return name != focusedWorkspace && !window.minimized && !window.fullscreen && !window.appHidden
    }

    // Makes reality match the model. Showing comes first so a workspace
    // switch puts the new windows up before the old ones leave.
    @discardableResult
    private func applyLayout() -> (shown: Int, parked: Int) {
        var shown = 0, hidden = 0
        for (id, window) in tracked where parked[id] != nil && workspaceOf[id] == focusedWorkspace {
            unpark(window)
            shown += 1
        }
        // Debug log only (AEROSWITCHER_DEBUG=1): a window of a hidden
        // workspace that is NOT being parked, and why. Added after the first
        // switch in the 2026-11-17 test parked nothing, for no visible reason.
        for (id, window) in tracked where workspaceOf[id] != focusedWorkspace && parked[id] == nil && !shouldBeParked(window) {
            logDebug("WorkspaceManager: not parking \(id) \(window.appName): minimized=\(window.minimized) fullscreen=\(window.fullscreen) appHidden=\(window.appHidden) workspace=\(workspaceOf[id] ?? "none")")
        }
        for (id, window) in tracked where shouldBeParked(window) {
            if parked[id] == nil {
                if park(window) { hidden += 1 }
            } else if let frame = window.frame, !ScreenLayout.shared.looksParked(frame), let point = parkPoint(for: window) {
                // Parked on paper but back on screen: the app moved its
                // window itself (some do when they wake up). Park it again;
                // where it should come back to stays as remembered.
                WindowTracker.shared.act(pid: window.pid, windowId: id, { element, app in
                    axWithoutAnimations(app: app) { axSetPosition(element, point) }
                })
            }
        }
        return (shown, hidden)
    }

    // Parks one window. The order is the safety rule from the top of this
    // file: remember where it was, write that to the file, only then move.
    private func park(_ window: TrackedWindow) -> Bool {
        let id = window.id
        guard let known = window.frame, let point = parkPoint(for: window) else {
            logDebug("WorkspaceManager: can't park \(id) \(window.appName): frame=\(window.frame.map { "\($0)" } ?? "unknown")")
            return false
        }
        // Never remember the parking corner itself as "where it was".
        let frame = ScreenLayout.shared.looksParked(known) ? fallbackFrame(size: known.size) : known
        parked[id] = Parked(pid: window.pid, frame: frame, needsResize: false)
        saveState()
        WindowTracker.shared.act(pid: window.pid, windowId: id, { [weak self] element, app in
            // The position from the list can be a moment old. Ask the window
            // itself right before moving it, and correct the note if it
            // differs (and is a real on-screen position).
            if let fresh = axFrame(element), !ScreenLayout.shared.looksParked(fresh), !WindowSizing.near(fresh, frame) {
                DispatchQueue.main.async {
                    guard let self, self.parked[id] != nil else { return }
                    self.parked[id]?.frame = fresh
                    self.saveState()
                }
            }
            axWithoutAnimations(app: app) { axSetPosition(element, point) }
        })
        tracked[id]?.frame = CGRect(origin: point, size: frame.size)
        return true
    }

    // Shows one parked window again, where it was. The position is kept
    // inside the screen in case the screen got smaller meanwhile (AeroSpace
    // does the same in unhideFromCorner).
    private func unpark(_ window: TrackedWindow) {
        let id = window.id
        guard let entry = parked.removeValue(forKey: id) else { return }
        var frame = entry.frame
        if let screen = ScreenLayout.shared.screen(for: frame)?.full {
            frame.origin.x = min(max(frame.origin.x, screen.minX), max(screen.minX, screen.maxX - frame.width))
            frame.origin.y = min(max(frame.origin.y, screen.minY), max(screen.minY, screen.maxY - frame.height))
        }
        tracked[id]?.frame = frame
        let resize = entry.needsResize
        WindowTracker.shared.act(pid: entry.pid, windowId: id, { element, app in
            axWithoutAnimations(app: app) {
                if resize {
                    axSetFrame(element, topLeft: frame.origin, size: frame.size)
                } else {
                    axSetPosition(element, frame.origin)
                }
            }
        })
        saveState()
    }

    private func unparkAll() -> Int {
        let ids = Array(parked.keys)
        for id in ids {
            if let window = tracked[id] {
                unpark(window)
            } else {
                parked[id] = nil
            }
        }
        saveState()
        return ids.count
    }

    // MARK: Commands (main thread)

    // Option+key: show another workspace. `focusing` is the window to focus
    // there (Cmd+Tab picked one); without it, the workspace's most recently
    // used window.
    func switchTo(_ name: String, focusing: CGWindowID? = nil) {
        guard pauseReason == nil else { logInfo("WorkspaceManager: not switching to \(name), paused"); return }
        guard windowManagerSettings.workspaceNames.contains(name) else {
            logWarn("WorkspaceManager: there is no workspace called \(name)")
            return
        }
        if name != focusedWorkspace {
            let from = focusedWorkspace
            focusedWorkspace = name
            let counts = applyLayout()
            logInfo("WorkspaceManager: \(from) -> \(name), \(counts.shown) shown, \(counts.parked) parked")
            onWorkspaceChanged?(name)
        }
        let inWorkspace = tracked.keys.filter { workspaceOf[$0] == name }
        let target = focusing
            ?? recent[name]?.first(where: { tracked[$0] != nil })
            ?? inWorkspace.sorted().first
        if let target {
            nativeFocus(target)
        } else {
            focusNothing()
        }
        publish()
    }

    // The workspace you are now in has no window to focus. Without this the
    // app you were in stays in front with its now hidden window, so typing
    // would go into a window you can't see, and clicking that app in the
    // Dock would do nothing (it is already in front, so macOS sends no "app
    // came to the front" news; found in the 2026-11-17 test). So AeroSwitcher
    // itself takes the front for a moment: keys go nowhere, and the next app
    // you click comes to the front for real, which shows its workspace.
    private func focusNothing() {
        pendingFocus = nil
        NSApp.activate(ignoringOtherApps: true)
    }

    // Option+Shift+key: send the focused window to another workspace. You
    // stay where you are (AeroSpace's move-node-to-workspace), and the next
    // most recent window here gets the focus.
    // The window that has the keyboard focus right now: the one AeroSwitcher
    // just focused if the Mac hasn't caught up yet, else the tracker's
    // latest answer.
    private func focusedWindowNow() -> CGWindowID? {
        if let pending = pendingFocus, Date() < pending.deadline { return pending.id }
        return WindowTracker.shared.currentFocusedWindowId() ?? lastSeenFocus
    }

    func moveFocusedWindow(to name: String) {
        guard pauseReason == nil else { return }
        guard windowManagerSettings.workspaceNames.contains(name) else { return }
        guard let id = focusedWindowNow(), let window = tracked[id], let from = workspaceOf[id], from == focusedWorkspace else {
            logInfo("WorkspaceManager: no focused window in this workspace to move")
            return
        }
        guard from != name else { return }
        workspaceOf[id] = name
        recent[from]?.removeAll { $0 == id }
        recent[name, default: []].insert(id, at: 0)
        logInfo("WorkspaceManager: moved window \(id) (\(window.appName)) from \(from) to \(name)")
        applyLayout()
        if let next = recent[from]?.first(where: { tracked[$0] != nil })
            ?? tracked.keys.filter({ workspaceOf[$0] == from }).sorted().first {
            nativeFocus(next)
        } else {
            focusNothing()
        }
        publish()
    }

    // Option+F: the focused window flips between filling the screen and the
    // centered smaller size. Which of the two it is now is simply
    // remembered per window, like the marker files toggle-maximize.sh kept.
    func toggleMaximize() {
        guard pauseReason == nil else { return }
        guard let id = focusedWindowNow(), let window = tracked[id], workspaceOf[id] == focusedWorkspace,
              !window.fullscreen, let screen = ScreenLayout.shared.screen(for: window.frame) else { return }
        let frame: CGRect
        if restored.contains(id) {
            restored.remove(id)
            frame = WindowSizing.maximizedFrame(on: screen)
        } else {
            restored.insert(id)
            frame = WindowSizing.restoredFrame(on: screen)
        }
        tracked[id]?.frame = frame
        WindowSizing.setFrame(pid: window.pid, windowId: id, frame)
        logInfo("WorkspaceManager: window \(id) (\(window.appName)) \(restored.contains(id) ? "made smaller" : "maximized")")
        publish()
    }

    // A new window turned out to be a real one (WindowSizing.checkNewWindow).
    private func maximizeNew(_ id: CGWindowID) {
        guard pauseReason == nil, let window = tracked[id], !restored.contains(id),
              let screen = ScreenLayout.shared.screen(for: parked[id]?.frame ?? window.frame) else { return }
        let frame = WindowSizing.maximizedFrame(on: screen)
        if parked[id] != nil {
            // Parked in another workspace: it comes back maximized.
            parked[id]?.frame = frame
            parked[id]?.needsResize = true
            saveState()
            return
        }
        if let current = window.frame, WindowSizing.near(current, frame) { return }
        tracked[id]?.frame = frame
        WindowSizing.setFrame(pid: window.pid, windowId: id, frame)
        logInfo("WorkspaceManager: made new window \(id) (\(window.appName)) fill the screen")
    }

    // Cmd+Tab (and the overview) picked a window: show its workspace and
    // focus it. The id is text because that is how the rest of the app
    // carries window numbers (they used to come from AeroSpace as text).
    func focus(windowID: String, pid: Int32?) {
        guard pauseReason == nil, let id = CGWindowID(windowID), let name = workspaceOf[id] else {
            // Not managing, or not a window this file knows: at least bring
            // its app to the front.
            if let pid, pid != 0 { NSRunningApplication(processIdentifier: pid_t(pid))?.activate() }
            return
        }
        switchTo(name, focusing: id)
    }

    // The menu's rescue: every window comes to the workspace you are in and
    // on screen, including windows sitting in the parking corner that this
    // file doesn't know about (sorted as popups, or left by a crash).
    func bringBackAllWindows() {
        var count = 0
        for id in Array(workspaceOf.keys) {
            workspaceOf[id] = focusedWorkspace
        }
        let justShown = Set(parked.keys)
        count += unparkAll()
        let (all, _) = WindowTracker.shared.currentWindows()
        // Windows unparked a line above still have their corner position in
        // the tracker's list (it updates a moment later), so they are skipped
        // here or they'd be moved a second time, to the wrong place.
        for window in all where parked[window.id] == nil && !justShown.contains(window.id) {
            if let only = testOnlyApps, !only.contains(window.appName) { continue }
            guard let frame = window.frame, ScreenLayout.shared.looksParked(frame) else { continue }
            let target = fallbackFrame(size: frame.size).origin
            WindowTracker.shared.act(pid: window.pid, windowId: window.id, { element, app in
                axWithoutAnimations(app: app) { axSetPosition(element, target) }
            })
            count += 1
        }
        logInfo("WorkspaceManager: Bring Back All Windows moved \(count) windows on screen, all windows are now in \(focusedWorkspace.isEmpty ? "the current workspace" : focusedWorkspace)")
        WindowTracker.shared.scheduleRefresh(reason: "bring back all windows")
        publish()
    }

    // Gives a window the keyboard focus for real. Copied from AeroSpace's
    // nativeFocus (tree/MacApp.swift): make it the app's main window and
    // raise it FIRST, so it is already on top by the time the app comes to
    // the front, then bring the app to the front. A minimized window is
    // taken out of the Dock first.
    private func nativeFocus(_ id: CGWindowID) {
        guard let window = tracked[id] else { return }
        pendingFocus = (id, Date().addingTimeInterval(2))
        if lastSeenFocus != id, let name = workspaceOf[id] {
            lastSeenFocus = id
            noteFocus(id, in: name)
        }
        let pid = window.pid
        WindowTracker.shared.act(pid: pid, windowId: id, { element, _ in
            if axBool(element, kAXMinimizedAttribute) == true { axSetBool(element, kAXMinimizedAttribute, false) }
            axSetBool(element, kAXMainAttribute, true)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            // "Activate ignoring other apps": AeroSpace uses exactly this
            // option. Apple marked its name as deprecated in macOS 14, which
            // would add a build warning, so it is spelled by its number
            // (1 << 1) here. Without it, an app in the background (which
            // AeroSwitcher is when you press Option+key) is not allowed to
            // bring another app to the front reliably.
            NSRunningApplication(processIdentifier: pid)?.activate(options: NSApplication.ActivationOptions(rawValue: 1 << 1))
        })
        // If the 2 seconds pass without that window getting the focus, look
        // again so a later real focus change isn't ignored forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            WindowTracker.shared.scheduleRefresh(reason: "focus check")
        }
    }

    // MARK: Snapshot and file

    // Copies what other threads may read, and saves the file if it changed.
    private func publish() {
        let names = windowManagerSettings.workspaceNames
        let windows: [AeroWindow] = tracked.values.sorted { $0.id < $1.id }.compactMap { window in
            guard let name = workspaceOf[window.id] else { return nil }
            return AeroWindow(id: String(window.id), appPID: window.pid, workspace: name,
                              appName: shownAppName(pid: window.pid, reported: window.appName), title: window.title)
        }
        let focusedWindow = focusedWindowNow().flatMap { id in windows.first { $0.id == String(id) } }
        let state = currentState()
        lock.lock()
        snapshot.windows = pauseReason == nil ? windows : []
        snapshot.names = names
        snapshot.focusedWorkspace = focusedWorkspace.isEmpty ? names.first : focusedWorkspace
        snapshot.focusedWindow = focusedWindow
        snapshot.pauseReason = pauseReason
        snapshot.parked = parked
        snapshot.state = state
        lock.unlock()
        saveState()
    }

    private static func stateFileURL() -> URL {
        appSupportDirectory().appendingPathComponent("window-state.json")
    }

    // When this Mac was started, in seconds. Window numbers start over at
    // every restart, so a file from before the restart must be ignored.
    private static func bootTime() -> Double {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&name, 2, &time, &size, nil, 0)
        return Double(time.tv_sec)
    }

    private func currentState() -> SavedState {
        var windows: [String: SavedState.Window] = [:]
        for (id, name) in workspaceOf {
            let pid = tracked[id]?.pid ?? parked[id]?.pid ?? 0
            let frame = parked[id].map {
                SavedState.Frame(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height,
                                 needsResize: $0.needsResize ? true : nil)
            }
            windows[String(id)] = SavedState.Window(workspace: name, pid: pid, parked: frame,
                                                    restored: restored.contains(id) ? true : nil)
        }
        return SavedState(bootTime: Self.bootTime(), focusedWorkspace: focusedWorkspace, windows: windows)
    }

    // Writes window-state.json now, on this thread, if anything changed. It
    // is a few hundred bytes, and park() needs it on disk BEFORE it moves a
    // window, so it is not handed to a background queue.
    private func saveState() {
        guard started, !firstPass || !parked.isEmpty else { return }
        Self.write(currentState(), last: &lastWrittenState)
    }

    private static func write(_ state: SavedState, last: inout Data?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state), data != last else { return }
        do {
            try data.write(to: stateFileURL(), options: .atomic)
            last = data
        } catch {
            logError("WorkspaceManager: couldn't write \(stateFileURL().path): \(error.localizedDescription)")
        }
    }

    private static func loadState() -> SavedState? {
        guard let data = try? Data(contentsOf: stateFileURL()),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
        guard abs(state.bootTime - bootTime()) < 2 else {
            logInfo("WorkspaceManager: window-state.json is from before the last restart of the Mac, ignored")
            return nil
        }
        return state
    }

    // MARK: Quitting

    // Runs when the app ends (see atexit in start()), on whatever thread
    // called exit(). Moves every parked window back and waits for that, but
    // never longer than 2 seconds: a frozen app must not stop AeroSwitcher
    // from quitting, and its window is still in the file for next time.
    // (AeroSpace does the same on its way out, setAxFrameForTermination.)
    private func restoreForTermination() {
        lock.lock()
        let parkedNow = snapshot.parked
        var state = snapshot.state
        lock.unlock()
        guard !parkedNow.isEmpty else { return }
        let group = DispatchGroup()
        let doneLock = NSLock()
        var done: Set<CGWindowID> = []
        for (id, entry) in parkedNow {
            group.enter()
            let origin = entry.frame.origin
            WindowTracker.shared.act(pid: entry.pid, windowId: id, { element, app in
                axWithoutAnimations(app: app) { axSetPosition(element, origin) }
                doneLock.lock()
                done.insert(id)
                doneLock.unlock()
                group.leave()
            }, missing: { group.leave() })
        }
        _ = group.wait(timeout: .now() + 2)
        doneLock.lock()
        let moved = done
        doneLock.unlock()
        // The file keeps the workspaces (the next launch parks them again)
        // but only the windows that did NOT make it back stay "parked".
        if state != nil {
            for id in moved { state?.windows[String(id)]?.parked = nil }
            var last: Data?
            Self.write(state!, last: &last)
        }
        logInfo("WorkspaceManager: quitting, moved \(moved.count) of \(parkedNow.count) parked windows back on screen")
        flushLog()
    }

    // MARK: Switching over

    // Called by the Setup window right before AeroSwitcher restarts as its
    // own window manager, with AeroSpace's last answer (which window is in
    // which workspace, and the workspace showing). Written as the window
    // file, so the first launch in the new mode keeps every window in the
    // workspace AeroSpace had it in, instead of sorting all of them again
    // by the rules (a window you moved by hand would otherwise jump back).
    static func seedFromAeroSpace(windows: [AeroWindow], focusedWorkspace: String?) {
        var entries: [String: SavedState.Window] = [:]
        for window in windows where !window.workspace.isEmpty {
            entries[window.id] = SavedState.Window(workspace: window.workspace, pid: window.appPID, parked: nil, restored: nil)
        }
        let state = SavedState(bootTime: bootTime(), focusedWorkspace: focusedWorkspace ?? "", windows: entries)
        var last: Data?
        write(state, last: &last)
        logInfo("WorkspaceManager: took over AeroSpace's workspaces for \(entries.count) windows, showing \(focusedWorkspace ?? "?")")
    }

    // Called by the Setup window before going back to AeroSpace: every parked
    // window back on screen, workspaces kept (AeroSpace sorts them its own
    // way when it starts). Main thread.
    func putAllWindowsOnScreen() {
        let count = unparkAll()
        logInfo("WorkspaceManager: handing over to AeroSpace, moved \(count) parked windows back on screen")
    }

    // MARK: Rescue when AeroSwitcher is NOT the window manager

    // Called at launch from main.swift when AeroSpace is the window manager.
    // If a file is left from a time AeroSwitcher managed windows and it
    // still lists parked windows (AeroSwitcher crashed, then was switched
    // back), they are moved back on screen once the window list is ready,
    // and the file is removed. Normally there is no file and this does
    // nothing.
    static func rescueLeftovers() {
        guard !ownWindowManager else { return }
        guard let state = loadState() else {
            try? FileManager.default.removeItem(at: stateFileURL())
            return
        }
        let leftovers = state.windows.compactMap { key, window -> (CGWindowID, pid_t, CGPoint)? in
            guard let id = CGWindowID(key), let frame = window.parked else { return nil }
            return (id, window.pid, CGPoint(x: frame.x, y: frame.y))
        }
        guard !leftovers.isEmpty else {
            try? FileManager.default.removeItem(at: stateFileURL())
            return
        }
        logWarn("WorkspaceManager: \(leftovers.count) windows were left parked by an earlier run, moving them back on screen")
        ScreenLayout.shared.start()
        WindowTracker.shared.onRefresh = {
            WindowTracker.shared.onRefresh = nil
            for (id, pid, origin) in leftovers {
                WindowTracker.shared.act(pid: pid, windowId: id, { element, app in
                    // Only if it really is still in the corner: AeroSpace
                    // may have taken it over and moved it since.
                    guard let frame = axFrame(element), ScreenLayout.shared.looksParked(frame) else { return }
                    axWithoutAnimations(app: app) { axSetPosition(element, origin) }
                })
            }
            try? FileManager.default.removeItem(at: stateFileURL())
        }
    }

    // MARK: Test commands (test copy only)

    // TEST ONLY. A test copy started with AEROSWITCHER_WM_COMMAND_FILE=<path>
    // (and AEROSWITCHER_CONFIG_DIR) looks at that file a few times a second
    // and runs the commands written into it, one per line, then deletes it:
    //   workspace <name>   like Option+key
    //   move <name>        like Option+Shift+key
    //   toggle             like the maximize toggle key
    //   focus <window id>  like picking a window in Cmd+Tab
    //   bringback          the menu's Bring Back All Windows
    //   state              writes the model to the log (no window titles)
    // This is how the window manager is tested without pressing real keys
    // (simulated Option keys would land in whatever app is in front).
    private func startTestCommands() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AEROSWITCHER_CONFIG_DIR"] != nil,
              let path = environment["AEROSWITCHER_WM_COMMAND_FILE"], !path.isEmpty else { return }
        logInfo("WorkspaceManager: TEST commands are read from \(path)")
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: path)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard let command = parts.first else { continue }
                let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                logInfo("WorkspaceManager: TEST command: \(line)")
                switch command {
                case "workspace": self.switchTo(argument)
                case "move": self.moveFocusedWindow(to: argument)
                case "toggle": self.toggleMaximize()
                case "focus": self.focus(windowID: argument, pid: nil)
                case "bringback": self.bringBackAllWindows()
                case "state": self.logState()
                default: logWarn("WorkspaceManager: unknown TEST command \(command)")
                }
            }
        }
    }

    private func logState() {
        func text(_ rect: CGRect?) -> String {
            rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
        }
        logInfo("WorkspaceManager: STATE workspace=\(focusedWorkspace) paused=\(pauseReason ?? "no") focus=\(lastSeenFocus.map(String.init) ?? "-")")
        for (id, window) in tracked.sorted(by: { $0.key < $1.key }) {
            logInfo("WorkspaceManager: STATE window \(id) \(window.appName) in \(workspaceOf[id] ?? "?") \(window.kind.rawValue)"
                + " frame \(text(window.frame))"
                + (parked[id].map { " PARKED, was at \(text($0.frame))" } ?? "")
                + (restored.contains(id) ? " smaller" : "")
                + (window.minimized ? " minimized" : "") + (window.fullscreen ? " fullscreen" : ""))
        }
    }
}
