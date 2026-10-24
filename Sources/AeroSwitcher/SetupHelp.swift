import Cocoa
import SwiftUI

// MARK: - Setup help (first launch and permissions)
//
// A friendly window that says what is missing for AeroSwitcher to work and
// has a button that goes to the right place. The same check feeds the menu's
// Permissions item, so the window and the menu never disagree.
//
// What is checked, and how far each answer can be trusted:
//   - AeroSpace installed: does the `aerospace` command exist at the usual
//     Homebrew places. Right for a normal install, a guess for odd places.
//   - AeroSpace running: asks `aerospace list-workspaces --focused` and reads
//     the answer (running / "disabled" / "Can't connect"). Reliable. It can't
//     see whether AeroSpace has its own Accessibility permission.
//   - Input Monitoring: macOS's look-only answer AND whether the event tap
//     (the Cmd+Tab hook) really exists.
//   - Screen Recording: macOS's look-only answer.
//   - Recent order: whether AeroSpace's config file has the `on-focus-changed`
//     line that writes the window history. Only the TEXT of the file can be
//     read, not whether AeroSpace has loaded it.
//   - Accessibility (for AeroSpace and the maximize scripts) is NOT checked,
//     it belongs to another app and can't be read. The window only mentions it.
//
// NEVER used here: CGRequestListenEventAccess, CGRequestScreenCaptureAccess,
// AXIsProcessTrustedWithOptions with the prompt option, or any screen capture.
// Those pop up macOS permission dialogs. Everything here only looks.

// MARK: The checks

enum AeroSpaceState: Equatable {
    case notInstalled
    case notRunning
    case disabled
    case running
    case unknown(String)
}

enum RecencyHookState: Equatable {
    case present       // AeroSpace's config has our line
    case conflict      // it has an on-focus-changed of its own, ours is not in it
    case missing       // no on-focus-changed at all
    case noConfig      // couldn't find AeroSpace's config file
    case notChecked    // AeroSpace isn't installed yet, nothing to look at
}

enum RequiredItem: Equatable {
    case aerospaceInstalled, aerospaceRunning, inputMonitoring, screenRecording
}

// The line that makes AeroSpace write down which window you focused. Same
// text as README step 2.
let recencyHookCommand = #"'exec-and-forget /bin/sh -c "mkdir -p /tmp/aerospace-mru && echo $AEROSPACE_WINDOW_ID >> /tmp/aerospace-mru/$(aerospace list-workspaces --focused).log"'"#
let recencyHookLine = "on-focus-changed = [\(recencyHookCommand)]"

struct SetupStatus: Equatable {
    var cliPath: String?
    var appInstalled = false
    var aerospace: AeroSpaceState = .notInstalled
    var subscribeSupported = true
    var inputPreflight = false
    var tapRunning = false
    var screenRecording = false
    var hook: RecencyHookState = .notChecked
    var configPath: String?

    var inputMonitoringOK: Bool { inputPreflight && tapRunning }

    // With `aerospace subscribe` (any recent AeroSpace) AeroSwitcher keeps
    // the recent order itself and nothing needs adding to AeroSpace's
    // config. Only an old AeroSpace without it still needs the hook line.
    var recentOrderNeedsHook: Bool { cliPath != nil && !subscribeSupported }

    // AeroSpace was installed after AeroSwitcher started, somewhere other
    // than where the start-up guess pointed, so all its calls still use the
    // wrong path until a restart.
    var needsRestartForCLI: Bool { cliPath != nil && cliPath != aerospacePath }

    // What stops AeroSwitcher from working at all. Decides the launch popup.
    var requiredMissing: [RequiredItem] {
        var items: [RequiredItem] = []
        if cliPath == nil { items.append(.aerospaceInstalled) }
        else if aerospace == .notRunning { items.append(.aerospaceRunning) }
        if !inputMonitoringOK { items.append(.inputMonitoring) }
        if !screenRecording { items.append(.screenRecording) }
        return items
    }

    // Things worth a yellow mark but not worth a launch popup.
    var hasWarnings: Bool {
        if needsRestartForCLI { return true }
        if case .disabled = aerospace { return true }
        if case .unknown = aerospace { return true }
        if cliPath != nil && !subscribeSupported { return true }
        if recentOrderNeedsHook && hook != .present { return true }
        return false
    }

    var summary: String {
        "installed=\(cliPath != nil) aerospace=\(aerospace) inputPreflight=\(inputPreflight) tap=\(tapRunning) screenRecording=\(screenRecording) hook=\(hook) subscribe=\(subscribeSupported)"
    }
}

// Does the work, including AeroSpace command calls, so call it off the main
// thread. The event tap can only be asked on the main thread, so the caller
// passes that answer in.
func computeSetupStatus(tapRunning: Bool) -> SetupStatus {
    var status = SetupStatus()
    status.inputPreflight = CGPreflightListenEventAccess()
    status.tapRunning = tapRunning
    status.screenRecording = CGPreflightScreenCaptureAccess()
    status.appInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "bobko.aerospace") != nil
    status.cliPath = findAerospaceCLI()
    guard status.cliPath != nil else {
        status.aerospace = .notInstalled
        return status
    }
    if status.needsRestartForCLI {
        status.aerospace = .unknown("AeroSpace was installed after AeroSwitcher started. Restart AeroSwitcher.")
        return status
    }

    let focused = runAerospace(["list-workspaces", "--focused"])
    if focused.ok {
        status.aerospace = .running
    } else if focused.output.contains("disabled") {
        status.aerospace = .disabled
    } else if focused.output.contains("Can't connect") {
        status.aerospace = .notRunning
    } else {
        status.aerospace = .unknown(focused.output.isEmpty ? "no answer" : focused.output)
    }
    status.subscribeSupported = aerospaceSupportsSubscribe()

    let candidates = [getAeroSpaceConfigPath(),
                      NSHomeDirectory() + "/.aerospace.toml",
                      NSHomeDirectory() + "/.config/aerospace/aerospace.toml"]
    if let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }),
       let text = try? String(contentsOfFile: path, encoding: .utf8) {
        status.configPath = path
        status.hook = recencyHookState(inConfigText: text)
    } else {
        status.hook = .noConfig
    }
    return status
}

// Looks for the top level `on-focus-changed` setting in the TOML text.
// Comment lines don't count. The setting can span several lines, so it
// collects lines until the brackets balance. A guess in one place: brackets
// inside the shell command would confuse the balancing, none of the usual
// commands have any, and it stops after 20 lines anyway.
func recencyHookState(inConfigText text: String) -> RecencyHookState {
    let lines = text.components(separatedBy: "\n")
    var foundSetting = false
    var index = 0
    while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        index += 1
        guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("on-focus-changed") else { continue }
        let afterKey = trimmed.dropFirst("on-focus-changed".count).trimmingCharacters(in: .whitespaces)
        guard afterKey.hasPrefix("=") else { continue }  // some longer key name
        foundSetting = true
        var collected = trimmed
        var depth = trimmed.filter { $0 == "[" }.count - trimmed.filter { $0 == "]" }.count
        var extra = 0
        while depth > 0 && index < lines.count && extra < 20 {
            collected += "\n" + lines[index]
            depth += lines[index].filter { $0 == "[" }.count - lines[index].filter { $0 == "]" }.count
            index += 1
            extra += 1
        }
        if collected.contains("aerospace-mru") { return .present }
    }
    return foundSetting ? .conflict : .missing
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
    private static let aerospaceGuideURL = "https://nikitabobko.github.io/AeroSpace/guide"
    static let installCommand = "brew install --cask nikitabobko/tap/aerospace"

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

    // Asks everything off the main thread (the AeroSpace commands have a
    // time limit, but the main thread also runs the Cmd+Tab hook and must
    // never wait). `completion` runs on the main thread with the answer.
    func refresh(completion: ((SetupStatus) -> Void)? = nil) {
        if let completion { waiting.append(completion) }
        // Input Monitoring was granted but the Cmd+Tab hook isn't running:
        // try making it now, so no restart is needed if macOS allows it.
        // Only when macOS says "allowed", because trying without
        // permission could pop a macOS dialog every couple of seconds.
        if CGPreflightListenEventAccess(), let hotkeys, !hotkeys.isRunning {
            hotkeys.start(retry: true)
            if hotkeys.isRunning { print("Setup: Cmd+Tab hook started after Input Monitoring was granted, no restart needed.") }
        }
        guard !refreshing else { return }
        refreshing = true
        let tapRunning = hotkeys?.isRunning ?? false
        Task.detached {
            let result = computeSetupStatus(tapRunning: tapRunning)
            await MainActor.run {
                self.refreshing = false
                if result != self.latest {
                    print("Setup check: \(result.summary)")
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
        status.tapRunning = hotkeys?.isRunning ?? false
        status.screenRecording = CGPreflightScreenCaptureAccess()
        return status
    }

    // MARK: Launch

    // Called once at start-up. Shows the window on a first launch, or when
    // something required is missing (unless "Don't show this at launch" was
    // ticked). AeroSpace not running yet is given up to 15 seconds first:
    // at login AeroSwitcher can start a few seconds before AeroSpace does,
    // and a popup for that would be wrong every single morning.
    func launchCheck() {
        check(attemptsLeft: 5)
    }

    private func check(attemptsLeft: Int) {
        refresh { [self] status in
            let waitingOnAeroSpace = status.requiredMissing == [.aerospaceRunning]
            if waitingOnAeroSpace && attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.check(attemptsLeft: attemptsLeft - 1) }
                return
            }
            if firstRunThisLaunch {
                print("Setup: first launch, showing the setup window")
                present(welcome: true, activate: false)
            } else if !status.requiredMissing.isEmpty && !hideAtLaunch {
                print("Setup: something required is missing (\(status.requiredMissing)), showing the setup window")
                present(welcome: false, activate: false)
            } else if !status.requiredMissing.isEmpty {
                print("Setup: something required is missing (\(status.requiredMissing)), window hidden by \"Don't show at launch\"")
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
            // AeroSpace may maximize) while the user flips a switch there.
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
        print("Setup: window shown")
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        opened = []
        returned = []
        print("Setup: window closed")
    }

    func close() { window?.close() }

    // MARK: Rows

    func rows(for s: SetupStatus) -> [SetupRow] {
        var rows: [SetupRow] = []
        let restartButton = SetupButton(title: "Restart AeroSwitcher") { [weak self] in self?.restart() }
        let removeAndAdd = "Already switched on but still marked? Select it, remove it with the minus button, then add it again with the plus."

        // 1. AeroSpace installed
        if let path = s.cliPath {
            if s.needsRestartForCLI {
                rows.append(SetupRow(id: "installed", mark: .warning, title: "AeroSpace installed",
                    detail: "Found at \(path) after AeroSwitcher started. Restart to use it.",
                    buttons: [restartButton]))
            } else {
                rows.append(SetupRow(id: "installed", mark: .good, title: "AeroSpace installed", detail: path))
            }
        } else {
            let detail = s.appInstalled
                ? "The app is installed, but its aerospace command wasn't found. Reinstalling with Homebrew links it."
                : "AeroSwitcher needs AeroSpace to see which windows are in each workspace."
            rows.append(SetupRow(id: "installed", mark: .bad, title: "AeroSpace installed", detail: detail,
                codeBlock: Self.installCommand,
                buttons: [
                    SetupButton(title: "Get AeroSpace") {
                        print("Setup: open \(Self.aerospaceGuideURL)")
                        NSWorkspace.shared.open(URL(string: Self.aerospaceGuideURL)!)
                    },
                    SetupButton(title: "Copy install command") { Self.copy(Self.installCommand) },
                ]))
        }

        // 2. AeroSpace running
        switch s.aerospace {
        case .notInstalled:
            rows.append(SetupRow(id: "running", mark: .idle, title: "AeroSpace running", detail: "Checked once AeroSpace is installed."))
        case .running:
            rows.append(SetupRow(id: "running", mark: .good, title: "AeroSpace running", detail: "Responding."))
        case .disabled:
            rows.append(SetupRow(id: "running", mark: .warning, title: "AeroSpace running",
                detail: "Turned off, so workspaces aren't being managed.",
                buttons: [SetupButton(title: "Enable AeroSpace") { [weak self] in
                    Task.detached {
                        let result = setAeroSpaceEnabled(true)
                        print("Setup: aerospace enable on: \(result.ok ? "ok" : "failed") \(result.output)")
                        await MainActor.run { self?.refresh() }
                    }
                }]))
        case .notRunning:
            rows.append(SetupRow(id: "running", mark: .bad, title: "AeroSpace running",
                detail: "Not running. No windows will show until it is.",
                hint: "Starting AeroSpace re-applies its window rules, so windows may move.",
                buttons: [SetupButton(title: "Open AeroSpace") {
                    print("Setup: open AeroSpace")
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "bobko.aerospace") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    } else {
                        NSSound.beep()
                    }
                }]))
        case .unknown(let message):
            rows.append(SetupRow(id: "running", mark: .warning, title: "AeroSpace running",
                detail: "Unexpected answer: \(message)"))
        }

        // 3. Input Monitoring
        if s.inputMonitoringOK {
            rows.append(SetupRow(id: "input", mark: .good, title: "Input Monitoring", detail: "Cmd+Tab is handled by AeroSwitcher."))
        } else if s.inputPreflight {
            rows.append(SetupRow(id: "input", mark: .warning, title: "Input Monitoring",
                detail: "Allowed, but the Cmd+Tab hook hasn't started. Restart AeroSwitcher.",
                buttons: [restartButton]))
        } else {
            var hint = removeAndAdd
            var buttons = [openPane("input", "Open Input Monitoring", Self.inputMonitoringURL)]
            if returned.contains("input") {
                hint = "Still marked after switching it on? Restart AeroSwitcher."
                buttons.append(restartButton)
            }
            rows.append(SetupRow(id: "input", mark: .bad, title: "Input Monitoring",
                detail: "Required for Cmd+Tab. Switch AeroSwitcher on in the list, or add it with the plus button.",
                hint: hint, buttons: buttons))
        }

        // 4. Screen Recording
        if s.screenRecording {
            rows.append(SetupRow(id: "screen", mark: .good, title: "Screen Recording", detail: "Window previews work."))
        } else {
            var hint = removeAndAdd
            var buttons = [openPane("screen", "Open Screen Recording", Self.screenRecordingURL)]
            if returned.contains("screen") {
                hint = "Still marked after switching it on? macOS often applies this only after a restart."
                buttons.append(restartButton)
            }
            rows.append(SetupRow(id: "screen", mark: .bad, title: "Screen Recording",
                detail: "Required for window previews. Without it they appear blank.",
                hint: hint, buttons: buttons))
        }

        // 5. Recent order
        let openConfig = SetupButton(title: "Open config") { [weak self] in
            if let path = self?.latest?.configPath ?? Optional(NSHomeDirectory() + "/.aerospace.toml"),
               FileManager.default.fileExists(atPath: path) {
                print("Setup: open \(path)")
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                print("Setup: no AeroSpace config file to open")
                NSSound.beep()
            }
        }
        if s.cliPath != nil && !s.recentOrderNeedsHook {
            rows.append(SetupRow(id: "hook", mark: .good, title: "Recent order",
                detail: "AeroSwitcher keeps track of the window you used last itself. Nothing to set up."))
        } else {
            switch s.hook {
            case .present:
                rows.append(SetupRow(id: "hook", mark: .good, title: "Recent order", detail: "Windows are listed most recently used first."))
            case .notChecked:
                rows.append(SetupRow(id: "hook", mark: .idle, title: "Recent order", detail: "Checked once AeroSpace is installed."))
            case .missing:
                rows.append(SetupRow(id: "hook", mark: .warning, title: "Recent order",
                    detail: "Optional. Add this line to your AeroSpace config, outside any [section], to list windows most recently used first.",
                    hint: "AeroSwitcher can read the file, but not whether AeroSpace has loaded it. Reload AeroSpace's config after saving.",
                    codeBlock: recencyHookLine,
                    buttons: [SetupButton(title: "Copy line") { Self.copy(recencyHookLine) }, openConfig]))
            case .conflict:
                rows.append(SetupRow(id: "hook", mark: .warning, title: "Recent order",
                    detail: "Optional. Your config already has an on-focus-changed line. Add this command to its list instead of adding a second line, which AeroSpace would reject.",
                    codeBlock: recencyHookCommand,
                    buttons: [SetupButton(title: "Copy command") { Self.copy(recencyHookCommand) }, openConfig]))
            case .noConfig:
                rows.append(SetupRow(id: "hook", mark: .warning, title: "Recent order",
                    detail: "Optional. No AeroSpace config file was found. Create ~/.aerospace.toml with this line.",
                    codeBlock: recencyHookLine,
                    buttons: [SetupButton(title: "Copy line") { Self.copy(recencyHookLine) }]))
            }
        }

        // 6. Old AeroSpace
        if s.cliPath != nil && !s.subscribeSupported {
            rows.append(SetupRow(id: "old", mark: .warning, title: "AeroSpace is out of date",
                detail: "It has no subscribe command, so the menu bar name is checked once a second and the recent order needs the line from the Recent order row. brew upgrade --cask aerospace updates it."))
        }
        return rows
    }

    private func openPane(_ key: String, _ title: String, _ url: String) -> SetupButton {
        SetupButton(title: title) { [weak self] in
            self?.opened.insert(key)
            print("Setup: open System Settings page \(url)")
            NSWorkspace.shared.open(URL(string: url)!)
        }
    }

    func openAccessibilitySettings() {
        print("Setup: open System Settings page \(Self.accessibilityURL)")
        NSWorkspace.shared.open(URL(string: Self.accessibilityURL)!)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("Setup: copied to the clipboard")
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
        for key in ["AEROSWITCHER_CONFIG_DIR", "AEROSWITCHER_AEROSPACE_PATH"] {
            if let value = ProcessInfo.processInfo.environment[key] { envArguments += " --env " + quote("\(key)=\(value)") }
        }
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; for i in 1 2 3 4 5; do /usr/bin/open -n\(envArguments) \(quote(path)) && exit 0; sleep 1; done"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        do {
            try helper.run()
            print("Setup: restarting AeroSwitcher")
            NSApp.terminate(nil)
        } catch {
            print("Setup: couldn't start the restart helper: \(error)")
            NSSound.beep()
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
                            accessibilityNote
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
                Text("Checking...").foregroundStyle(.secondary).padding(24)
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
            : (help.welcome ? "Welcome to AeroSwitcher" : (warnings ? "Almost set" : "You're all set"))
        let subtitle = missing
            ? "Fix the items marked with a cross. They update by themselves."
            : (help.welcome
                ? "It lives in the menu bar. Click the workspace name there for its menu, or press Cmd+Tab to try it."
                : (warnings ? "Nothing required is missing. The items marked with ! are worth a look."
                            : "Everything AeroSwitcher needs is in place."))
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2).bold()
            Text(subtitle).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
    }

    private var accessibilityNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility").font(.headline)
            Text("AeroSpace needs this to move windows. AeroSwitcher can't check it. If windows aren't being managed, look here.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility") { help.openAccessibilitySettings() }.accessibilityLabel("Open Accessibility")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Toggle("Don't show at launch", isOn: $help.hideAtLaunch)
            Spacer()
            Button("Check again") { help.refresh() }.accessibilityLabel("Check again")
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
