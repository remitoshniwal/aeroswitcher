import Cocoa
import SwiftUI

// MARK: - Setup help (first launch and permissions)
//
// A friendly window that says what is missing for AeroSwitcher to work and
// has a button that goes to the right place. The same check feeds the menu's
// Permissions item, so the window and the menu never disagree.
//
// What is checked:
//   - Window manager: is it managing, or paused and why (no workspaces,
//     AeroSpace running, no Accessibility).
//   - Cmd+Tab (shown as Accessibility): whether the event tap (the Cmd+Tab
//     hook) really exists, plus macOS's look-only answers for Accessibility
//     (AXIsProcessTrusted) and Input Monitoring. The tap swallows keys, which
//     macOS files under Accessibility. The window manager needs
//     Accessibility too, to move other apps' windows.
//   - Screen Recording: macOS's look-only answer.
//
// NEVER used here: CGRequestListenEventAccess, CGRequestScreenCaptureAccess,
// AXIsProcessTrustedWithOptions with the prompt option, or any screen capture.
// Those pop up macOS permission dialogs. Everything here only looks.

// MARK: The checks

enum RequiredItem: Equatable {
    case inputMonitoring, screenRecording, windowManager
}

struct SetupStatus: Equatable {
    var inputPreflight = false
    // Accessibility for AeroSwitcher itself (look-only answer, never prompts).
    // The Cmd+Tab hook is an "active" event tap (it swallows the keys), and
    // macOS files that under Accessibility, not Input Monitoring. Seen on the
    // owner's Mac: AeroSwitcher is in the Accessibility list and not in the
    // Input Monitoring list, and Cmd+Tab works.
    var accessibilityTrusted = false
    var tapRunning = false
    var screenRecording = false
    // Why the window manager is paused, nil while it manages.
    var managerPausedReason: String?

    var inputMonitoringOK: Bool { inputPreflight && tapRunning }

    // What stops AeroSwitcher from working at all. Decides the launch popup.
    var requiredMissing: [RequiredItem] {
        var items: [RequiredItem] = []
        if managerPausedReason != nil { items.append(.windowManager) }
        if !inputMonitoringOK { items.append(.inputMonitoring) }
        if !screenRecording { items.append(.screenRecording) }
        return items
    }

    // Things worth a yellow mark but not worth a launch popup. None right
    // now; kept so the header and the menu have one place to ask.
    var hasWarnings: Bool { false }

    var summary: String {
        "window manager paused=\(managerPausedReason ?? "no") inputPreflight=\(inputPreflight) accessibility=\(accessibilityTrusted) tap=\(tapRunning) screenRecording=\(screenRecording)"
    }
}

// Only look-only questions, but run it off the main thread anyway (the main
// thread runs the Cmd+Tab hook and must never wait). The event tap can only
// be asked on the main thread, so the caller passes that answer in.
func computeSetupStatus(tapRunning: Bool) -> SetupStatus {
    var status = SetupStatus()
    status.inputPreflight = CGPreflightListenEventAccess()
    status.accessibilityTrusted = AXIsProcessTrusted()
    status.tapRunning = tapRunning
    status.screenRecording = CGPreflightScreenCaptureAccess()
    status.managerPausedReason = WorkspaceManager.shared.pausedReason
    return status
}

// MARK: The window's brain

struct SetupButton: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
}

struct SetupRow: Identifiable {
    enum Mark { case good, bad, warning, idle }
    let id: String
    let mark: Mark
    let title: String
    let detail: String
    var hint: String? = nil
    var codeBlock: String? = nil
    var buttons: [SetupButton] = []
}

extension Notification.Name {
    // Posted when the latest check differs from the one before, so the menu
    // can rebuild its Permissions item.
    static let setupStatusChanged = Notification.Name("AeroSwitcherSetupStatusChanged")
}

@MainActor
final class SetupHelp: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = SetupHelp()

    private static let hideKey = "SetupHelpHideAtLaunch"
    private static let inputMonitoringURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    private static let screenRecordingURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    private static let accessibilityURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    @Published private(set) var latest: SetupStatus?
    @Published var welcome = false
    @Published var hideAtLaunch: Bool {
        didSet { UserDefaults.standard.set(hideAtLaunch, forKey: Self.hideKey) }
    }
    // Which "Open System Settings" buttons were clicked, and which of those
    // the user has since come back from. Still a cross after coming back is
    // the sign that macOS wants a restart (see the hints in rows()).
    private var opened: Set<String> = []
    @Published private var returned: Set<String> = []

    private var window: NSWindow?
    private var timer: Timer?
    private var refreshing = false
    private var waiting: [(SetupStatus) -> Void] = []

    override init() {
        hideAtLaunch = UserDefaults.standard.bool(forKey: Self.hideKey)
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.returned.formUnion(self.opened)
                self.refresh()
            }
        }
    }

    // MARK: Checking

    // Asks everything off the main thread (the main thread also runs the
    // Cmd+Tab hook and must never wait). `completion` runs on the main
    // thread with the answer.
    func refresh(completion: ((SetupStatus) -> Void)? = nil) {
        if let completion { waiting.append(completion) }
        // Accessibility (or Input Monitoring) was granted but the Cmd+Tab hook
        // isn't running: try making it now, so no restart is needed if macOS
        // allows it. Only when macOS says "allowed" (both questions are
        // look-only), because trying without permission could pop a macOS
        // dialog every couple of seconds.
        if CGPreflightListenEventAccess() || AXIsProcessTrusted(), let hotkeys, !hotkeys.isRunning {
            hotkeys.start(retry: true)
            if hotkeys.isRunning { logInfo("Setup: Cmd+Tab hook started after the permission was granted, no restart needed.") }
        }
        guard !refreshing else { return }
        refreshing = true
        let tapRunning = hotkeys?.isRunning ?? false
        Task.detached {
            let result = computeSetupStatus(tapRunning: tapRunning)
            await MainActor.run {
                self.refreshing = false
                if result != self.latest {
                    logInfo("Setup check: \(result.summary)")
                    self.latest = result
                    NotificationCenter.default.post(name: .setupStatusChanged, object: nil)
                }
                let done = self.waiting
                self.waiting = []
                for completion in done { completion(result) }
            }
        }
    }

    // The newest check, but with the two look-only permission answers and
    // the tap read again right now (instant), for the menu.
    func statusForMenu() -> SetupStatus? {
        guard var status = latest else { return nil }
        status.inputPreflight = CGPreflightListenEventAccess()
        status.accessibilityTrusted = AXIsProcessTrusted()
        status.tapRunning = hotkeys?.isRunning ?? false
        status.screenRecording = CGPreflightScreenCaptureAccess()
        status.managerPausedReason = WorkspaceManager.shared.pausedReason
        return status
    }

    // MARK: Launch

    // Called once at start-up. Shows the window on a first launch, or when
    // something required is missing (unless "Don't show this at launch" was
    // ticked). The window manager's first look at the windows (paused as
    // "Starting" until then) is given up to 15 seconds first.
    func launchCheck() {
        // TEST ONLY: a test copy started without the Cmd+Tab hook
        // (AEROSWITCHER_NO_HOTKEYS) always looks like "Cmd+Tab missing", so
        // it would pop this window up every time. On 2026-11-17 that window
        // appeared in the middle of a test and its Restart and System
        // Settings buttons got clicked, so such a copy never opens it at
        // launch (Setup... in its menu still works).
        let environment = ProcessInfo.processInfo.environment
        if environment["AEROSWITCHER_CONFIG_DIR"] != nil, environment["AEROSWITCHER_NO_HOTKEYS"] == "1" {
            logInfo("TEST: not opening the Setup window at launch (AEROSWITCHER_NO_HOTKEYS)")
            refresh()
            return
        }
        check(attemptsLeft: 5)
    }

    private func check(attemptsLeft: Int) {
        refresh { [self] status in
            // The window manager still taking its first look: give it a
            // few seconds.
            if status.managerPausedReason == "Starting" && attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.check(attemptsLeft: attemptsLeft - 1) }
                return
            }
            if firstRunThisLaunch {
                logInfo("Setup: first launch, showing the setup window")
                present(welcome: true, activate: false)
            } else if !status.requiredMissing.isEmpty && !hideAtLaunch {
                logInfo("Setup: something required is missing (\(status.requiredMissing)), showing the setup window")
                present(welcome: false, activate: false)
            } else if !status.requiredMissing.isEmpty {
                logInfo("Setup: something required is missing (\(status.requiredMissing)), window hidden by \"Don't show at launch\"")
            }
        }
    }

    // MARK: The window

    func show() { present(welcome: false, activate: true) }

    private func present(welcome: Bool, activate: Bool) {
        self.welcome = welcome
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "AeroSwitcher Setup"
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Floating, so it stays visible above System Settings (which
            // fills the screen) while the user flips a switch there.
            window.level = .floating
            window.contentView = NSHostingView(rootView: SetupView(help: self))
            window.center()
            self.window = window
        }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        refresh()
        timer?.invalidate()
        // While the window is open it keeps checking, so a tick appears by
        // itself once something has been granted.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        logInfo("Setup: window shown")
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        opened = []
        returned = []
        logInfo("Setup: window closed")
    }

    func close() { window?.close() }

    // MARK: Rows

    func rows(for s: SetupStatus) -> [SetupRow] {
        var rows: [SetupRow] = []
        let restartButton = SetupButton(title: "Restart") { [weak self] in self?.restart() }
        let removeAndAdd = "Already on? Remove it with − and add it again with +."
        let accessibilityTitle = "Accessibility"

        // 1. The window manager's own row first: it is what everything else
        // is for.
        if let reason = s.managerPausedReason {
            var buttons: [SetupButton] = []
            if reason.hasPrefix("No workspaces") {
                buttons.append(SetupButton(title: "Open Settings") { SettingsWindow.shared.show() })
            }
            if reason == "AeroSpace is running" {
                // AeroSpace puts every window back on screen when it quits.
                buttons.append(SetupButton(title: "Quit AeroSpace") { [weak self] in
                    logInfo("Setup: quit AeroSpace")
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: aeroSpaceBundleId) { app.terminate() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
                })
            }
            rows.append(SetupRow(id: "manager", mark: reason == "Starting" ? .idle : .bad, title: "Window manager",
                detail: reason == "Starting" ? "Starting…" : "Paused: \(reason)",
                hint: reason == "AeroSpace is running" ? "Also remove it from Login Items." : nil,
                buttons: buttons))
        } else {
            let names = windowManagerSettings.workspaceNames
            rows.append(SetupRow(id: "manager", mark: .good, title: "Window manager",
                detail: names.joined(separator: ", ")))
        }

        // 2. Cmd+Tab (Accessibility). The row id stays "input" because the
        // opened/returned bookkeeping uses it. Accessibility is the page that
        // matters for the hook, Input Monitoring stays as a second button
        // because it can't be ruled out for every Mac.
        if s.inputMonitoringOK {
            rows.append(SetupRow(id: "input", mark: .good, title: accessibilityTitle, detail: "On"))
        } else if s.accessibilityTrusted || s.inputPreflight {
            rows.append(SetupRow(id: "input", mark: .warning, title: accessibilityTitle,
                detail: "Allowed. Restart to apply.",
                buttons: [restartButton]))
        } else {
            var hint = removeAndAdd
            var buttons = [
                openPane("input", "Open Accessibility", Self.accessibilityURL),
                openPane("input", "Open Input Monitoring", Self.inputMonitoringURL),
            ]
            if returned.contains("input") {
                hint = "Still off? Restart, then check Input Monitoring."
                buttons.append(restartButton)
            }
            rows.append(SetupRow(id: "input", mark: .bad, title: accessibilityTitle,
                detail: "Needed for Cmd+Tab and windows.",
                hint: hint, buttons: buttons))
        }

        // 3. Screen Recording
        if s.screenRecording {
            rows.append(SetupRow(id: "screen", mark: .good, title: "Screen Recording", detail: "On"))
        } else {
            var hint = removeAndAdd
            var buttons = [openPane("screen", "Open Screen Recording", Self.screenRecordingURL)]
            if returned.contains("screen") {
                hint = "Still off? Restart."
                buttons.append(restartButton)
            }
            rows.append(SetupRow(id: "screen", mark: .bad, title: "Screen Recording",
                detail: "Needed for window previews.",
                hint: hint, buttons: buttons))
        }

        return rows
    }

    private func openPane(_ key: String, _ title: String, _ url: String) -> SetupButton {
        SetupButton(title: title) { [weak self] in
            self?.opened.insert(key)
            logInfo("Setup: open System Settings page \(url)")
            NSWorkspace.shared.open(URL(string: url)!)
        }
    }

    func openAccessibilitySettings() {
        logInfo("Setup: open System Settings page \(Self.accessibilityURL)")
        NSWorkspace.shared.open(URL(string: Self.accessibilityURL)!)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logInfo("Setup: copied to the clipboard")
    }

    // MARK: Restart

    // A small helper waits for this process to end and then starts the app
    // again (starting it while the old one is still shutting down would just
    // bring the old one to the front). Passes the test variables along so a
    // test copy restarts as a test copy. Retries a few times because `open`
    // once failed right after a quit (error -600, Phase 8).
    func restart() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var envArguments = ""
        for key in ["AEROSWITCHER_CONFIG_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { envArguments += " --env " + quote("\(key)=\(value)") }
        }
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; for i in 1 2 3 4 5; do /usr/bin/open -n\(envArguments) \(quote(path)) && exit 0; sleep 1; done"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        do {
            try helper.run()
            logInfo("Setup: restarting AeroSwitcher")
            NSApp.terminate(nil)
        } catch {
            logError("Setup: couldn't start the restart helper: \(error)")
            showFailureAlert("Couldn't restart AeroSwitcher",
                "Quit and open it again.")
        }
    }
}

// MARK: The view

struct SetupView: View {
    @ObservedObject var help: SetupHelp

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = help.latest {
                header(status)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Color.clear.frame(height: 0).id("top")
                            ForEach(help.rows(for: status)) { SetupRowView(row: $0) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                    // The list is taller than the window when several things
                    // are missing. It must start at the top, not wherever
                    // the first layout left it.
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo("top", anchor: .top) } }
                }
            } else {
                Text("Checking…").foregroundStyle(.secondary).padding(24)
                Spacer()
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 600)
    }

    private func header(_ status: SetupStatus) -> some View {
        let missing = !status.requiredMissing.isEmpty
        let warnings = status.hasWarnings
        let title = missing ? "Setup needed"
            : (help.welcome ? "Welcome to AeroSwitcher" : (warnings ? "Almost set" : "All set"))
        let subtitle = missing ? "" : (help.welcome ? "Find it in the menu bar." : "")
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Toggle("Don't show at launch", isOn: $help.hideAtLaunch)
            Spacer()
            Button("Refresh") { help.refresh() }.accessibilityLabel("Refresh")
            Button("Close") { help.close() }.keyboardShortcut(.cancelAction).accessibilityLabel("Close")
        }
        .padding(14)
    }
}

struct SetupRowView: View {
    let row: SetupRow

    private var symbol: (name: String, color: Color) {
        switch row.mark {
        case .good: return ("checkmark.circle.fill", .green)
        case .bad: return ("xmark.circle.fill", .red)
        case .warning: return ("exclamationmark.triangle.fill", .yellow)
        case .idle: return ("circle.dashed", .secondary)
        }
    }

    // Rows that are fine take less room, so the window needs no scrolling
    // when nothing is wrong.
    private var compact: Bool { row.mark == .good || row.mark == .idle }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
                .font(.title3)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: compact ? 2 : 6) {
                Text(row.title).font(.headline)
                Text(row.detail)
                    .font(compact ? .caption : .callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = row.codeBlock {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let hint = row.hint {
                    Text(hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.buttons.isEmpty {
                    HStack {
                        ForEach(row.buttons) { button in
                            Button(button.title, action: button.action).accessibilityLabel(button.title)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
