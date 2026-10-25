import Cocoa

// Where the aerospace CLI actually lives. Homebrew installs it in a
// different place depending on the Mac's chip (Apple Silicon vs Intel),
// and a GUI app like this one — launched by double-clicking, not from a
// Terminal — doesn't inherit your shell's PATH the way a command-line tool
// would, so just running "aerospace" wouldn't reliably find it. Checked
// once at launch, against every common install location, so this same
// build works on Remi's Mac, an Apple Silicon friend's Mac, or an Intel
// one, without anyone having to edit this file.
let aerospacePath: String = {
    if let path = findAerospaceCLI() { return path }
    if let override = testAerospaceOverride() {
        logWarn("Test setup: the fake aerospace at \(override) doesn't exist, so AeroSpace counts as not installed.")
        return override
    }
    logError("Couldn't find the aerospace CLI at any of the usual locations (\(aerospaceCandidatePaths.joined(separator: ", "))). AeroSwitcher needs AeroSpace (https://github.com/nikitabobko/AeroSpace) installed to do anything at all.")
    return aerospaceCandidatePaths[0]  // fall back to the most common one so every aerospace call below fails the same obvious way, instead of crashing differently depending on which one ran first
}()

let aerospaceCandidatePaths = [
    "/opt/homebrew/bin/aerospace",  // Homebrew on Apple Silicon
    "/usr/local/bin/aerospace",     // Homebrew on Intel
]

// TEST ONLY. Pointing this at a fake `aerospace` script lets the setup help
// window be tested for "AeroSpace not installed / not running / disabled"
// without touching the real AeroSpace. It is ignored unless
// AEROSWITCHER_CONFIG_DIR is set too (that variable already means "this is a
// test copy"), so it can never change a normal run.
func testAerospaceOverride() -> String? {
    let environment = ProcessInfo.processInfo.environment
    guard environment["AEROSWITCHER_CONFIG_DIR"] != nil,
          let path = environment["AEROSWITCHER_AEROSPACE_PATH"], !path.isEmpty else { return nil }
    return path
}

// The aerospace command line tool if it exists, nil if it doesn't. Unlike
// `aerospacePath` it never falls back to a guess, so "installed or not" can
// be told apart. Looked at again on every call, which is what lets the
// setup window notice AeroSpace being installed while AeroSwitcher is
// already running.
func findAerospaceCLI() -> String? {
    if let override = testAerospaceOverride() {
        return FileManager.default.fileExists(atPath: override) ? override : nil
    }
    return aerospaceCandidatePaths.first { FileManager.default.fileExists(atPath: $0) }
}

// MARK: - AeroSpace bridge

struct AeroWindow {
    let id: String
    let appPID: Int32   // the owning app's process ID — needed to force real OS focus later
    let workspace: String  // which AeroSpace workspace this window is actually in
    let appName: String
    let title: String

    // "Finder" alone isn't useful with two Finder windows open, show the
    // folder name too for Finder specifically. Every other app just shows
    // its plain name, no title suffix.
    var displayName: String {
        guard appName == "Finder" else { return appName }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == appName {
            return appName
        }
        return "\(appName) - \(trimmed)"
    }
}

// scope "focused" is the normal Cmd+Tab switcher (current workspace only).
// scope "all" is for the separate all-workspaces overview (Cmd+`).
func getWindows(scope: String) -> [AeroWindow] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    var args = ["list-windows"]
    args += scope == "all" ? ["--all"] : ["--workspace", "focused"]
    args += ["--format", "%{window-id}|%{app-pid}|%{workspace}|%{app-name}|%{window-title}"]
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        logWarn("Failed to run aerospace: \(error)")
        return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    var windows: [AeroWindow] = []
    // AeroSwitcher's own windows (the config problems window, About, the
    // "Hide AeroSpace's icon" dialog) are normal windows to AeroSpace, so it
    // lists them too. They'd show up as an "AeroSwitcher" card in Cmd+Tab
    // and the overview, which is never useful, so they're left out here.
    let ownPID = ProcessInfo.processInfo.processIdentifier
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            .map(String.init)
        if parts.count >= 4 {
            let title = parts.count >= 5 ? parts[4] : ""
            let window = AeroWindow(id: parts[0], appPID: Int32(parts[1]) ?? 0, workspace: parts[2], appName: parts[3], title: title)
            if window.appPID == ownPID { continue }
            windows.append(window)
        }
    }
    return windows
}

func focusWindow(id: String, pid: Int32? = nil) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = ["focus", "--window-id", id]
    do {
        try process.run()
    } catch {
        logWarn("Couldn't run aerospace focus: \(error.localizedDescription)")
    }

    // `aerospace focus` updates AeroSpace's own idea of which window is
    // focused, but that alone doesn't reliably hand back real OS-level
    // "active app" status — especially right after our own panel just
    // forcibly activated itself so it could receive keyboard input at
    // all. Without this, the window can look focused but its traffic-light
    // buttons stay greyed out, because macOS still considers AeroSwitcher
    // itself the active app. Explicitly activating the target app's own
    // process is what actually flips that over.
    if let pid = pid, pid != 0, let target = NSRunningApplication(processIdentifier: pid_t(pid)) {
        target.activate()
    }
}

// Name of the AeroSpace workspace currently focused (e.g. "Creative"). Used
// to figure out which launcher apps belong on this particular Cmd+Tab
// screen — see LauncherApp below.
func getCurrentWorkspaceName() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = ["list-workspaces", "--focused"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// Every workspace AeroSpace knows about, whether or not anything's open in
// it right now — this is what lets the overview panel show an empty
// workspace as an empty section instead of just leaving it out entirely.
func getAllWorkspaceNames() -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = ["list-workspaces", "--all"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

// The one specific window that's focused right now (not every window in
// the focused workspace — just the single one). Used to remember what to
// hand focus back to when the read-only overview panel closes, since that
// panel never focuses anything itself the way the normal switcher does.
func getFocusedWindow() -> AeroWindow? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = ["list-windows", "--focused",
                          "--format", "%{window-id}|%{app-pid}|%{workspace}|%{app-name}|%{window-title}"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard let line = output.split(separator: "\n").first else { return nil }
    let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 4 else { return nil }
    let title = parts.count >= 5 ? parts[4] : ""
    return AeroWindow(id: parts[0], appPID: Int32(parts[1]) ?? 0, workspace: parts[2], appName: parts[3], title: title)
}

// Groups every open window by workspace, then by app within each workspace,
// counting windows per app and fetching each app's own icon (cheap —
// straight from the running process, no screen capture). allWorkspaceNames
// controls both which workspaces show up AND the order they show up in, so
// a workspace with nothing open still gets its own (empty) section.
// extraApps optionally tacks on more entries per workspace after the real
// windows — used for homeless apps AppWorkspaceTracker remembers as
// belonging to that workspace, so they show up right alongside its real
// windows instead of only in a separate catch-all section.
func buildWorkspaceSummaries(allWorkspaceNames: [String], windows: [AeroWindow], extraApps: [String: [WorkspaceAppSummary]] = [:]) -> [WorkspaceSummary] {
    var byWorkspace: [String: [AeroWindow]] = [:]
    for w in windows {
        byWorkspace[w.workspace, default: []].append(w)
    }

    // Cached per PID so two windows of the same app (e.g. two Finder
    // windows) only ever resolve that app's icon once per call to this
    // function, not once per window.
    //
    // Bundle-on-disk lookup rather than running.icon directly — same
    // reasoning as resolvedAppIcon and homelessRunningApps below: .icon
    // can hand back a generic placeholder the first time it's asked about
    // a process, this is synchronous and always correct.
    var iconCache: [Int32: NSImage?] = [:]
    func icon(forPID pid: Int32) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let running = NSRunningApplication(processIdentifier: pid_t(pid))
        let image = running?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? running?.icon
        iconCache[pid] = image
        return image
    }

    return allWorkspaceNames.map { name in
        let wsWindows = byWorkspace[name] ?? []
        var order: [String] = []          // app names, in first-seen order
        var counts: [String: Int] = [:]
        var pids: [String: Int32] = [:]
        for w in wsWindows {
            if counts[w.appName] == nil {
                order.append(w.appName)
                pids[w.appName] = w.appPID
            }
            counts[w.appName, default: 0] += 1
        }
        // customIcon(forAppName:) checked first — a real open window's app
        // CAN also have a config.json entry with a custom icon set (unlike
        // a homeless app, see homelessAppSummary), so this is what makes a
        // custom Calendar icon show up here too, not just on the greyed
        // launcher row.
        var apps = order.map { appName in
            WorkspaceAppSummary(appName: appName, icon: customIcon(forAppName: appName) ?? icon(forPID: pids[appName] ?? 0), windowCount: counts[appName] ?? 0)
        }
        apps += extraApps[name] ?? []
        return WorkspaceSummary(name: name, apps: apps)
    }
}

// What `aerospace reload-config` said, for the "reload both together"
// report (see SettingsStore.reloadTogether in Config.swift).
struct AeroSpaceReloadResult {
    let ok: Bool
    let output: String
}

// Asks AeroSpace to reload ~/.aerospace.toml. --no-gui stops AeroSpace
// from opening its own error window, since AeroSwitcher shows AeroSpace's
// problems in its own window next to its own. Exit code 0 means the config
// had no errors; anything else, the reason is in the output. This also
// catches AeroSpace not running at all (the CLI then can't connect).
// Waits for the command, so only call it off the main thread.
func reloadAeroSpaceConfig() -> AeroSpaceReloadResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = ["reload-config", "--no-gui"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return AeroSpaceReloadResult(ok: false, output: "Couldn't run \(aerospacePath): \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    logInfo("aerospace reload-config: exit \(process.terminationStatus)\(output.isEmpty ? "" : ", \(output)")")
    return AeroSpaceReloadResult(ok: process.terminationStatus == 0, output: output)
}

// MARK: - Menu bar support (Phase 8)
//
// Everything below is what the menu bar icon (MenuBar.swift) needs from
// AeroSpace. Same rule as the rest of this file: AeroSpace is only ever
// talked to through its command line.

// Runs one aerospace command and waits for it, but never longer than
// `timeout` seconds. The older helpers above wait forever, which is fine
// for them, but the menu is built on the main thread, the same thread that
// answers Cmd+Tab. If AeroSpace ever hangs, waiting forever there would
// freeze Cmd+Tab for the whole Mac (macOS switches an event tap off when it
// is too slow). A command that takes too long is killed and counts as
// failed instead.
func runAerospace(_ arguments: [String], timeout: TimeInterval = 2) -> (ok: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        return (false, "Couldn't run \(aerospacePath): \(error.localizedDescription)")
    }
    // The output is read on the side so a command that prints a lot can
    // never fill the pipe and get stuck waiting for us to read it.
    var collected = Data()
    let finishedReading = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        collected = pipe.fileHandleForReading.readDataToEndOfFile()
        finishedReading.signal()
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        logWarn("aerospace \(arguments.joined(separator: " ")) took longer than \(timeout)s and was stopped.")
        return (false, "timed out")
    }
    _ = finishedReading.wait(timeout: .now() + 1)
    let output = (String(data: collected, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return (process.terminationStatus == 0, output)
}

// Which apps have windows in each workspace, for the menu's workspace rows
// ("Core    Chrome, Notion"). Names only, sorted and without repeats, like
// AeroSpace's own menu. A workspace with nothing open is just missing from
// the result.
func getAppNamesByWorkspace() -> [String: [String]] {
    let result = runAerospace(["list-windows", "--all", "--format", "%{workspace}|%{app-name}"])
    guard result.ok else { return [:] }
    var names: [String: Set<String>] = [:]
    for line in result.output.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { continue }
        names[parts[0], default: []].insert(parts[1])
    }
    return names.mapValues { $0.sorted() }
}

// The real path of AeroSpace's config file, asked of AeroSpace itself
// (it knows whether it found ~/.aerospace.toml or the XDG folder one).
func getAeroSpaceConfigPath() -> String? {
    let result = runAerospace(["config", "--config-path"])
    return result.ok && !result.output.isEmpty ? result.output : nil
}

// Both lines of `aerospace --version`: the command line tool's version and
// the running app's. Shown in the About window.
func getAeroSpaceVersionText() -> String {
    let result = runAerospace(["--version"])
    return result.ok ? result.output : "AeroSpace isn't reachable"
}

func switchToWorkspace(_ name: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = ["workspace", name]
    do {
        try process.run()
    } catch {
        logWarn("Couldn't run aerospace workspace \(name): \(error.localizedDescription)")
    }
}

// `aerospace enable on` / `off`. AeroSpace can't be asked whether it is
// enabled right now (there is no command for that), but it announces every
// change on the event stream, see AeroSpaceEventStream.onMode.
func setAeroSpaceEnabled(_ enabled: Bool) -> (ok: Bool, output: String) {
    runAerospace(["enable", enabled ? "on" : "off"], timeout: 5)
}

// Only AeroSpace versions from a while back have `aerospace subscribe`.
// `--help` is answered by the command line tool itself, so this works even
// when AeroSpace isn't running, and an old version that doesn't know the
// command says so with a non-zero exit code.
func aerospaceSupportsSubscribe() -> Bool {
    runAerospace(["subscribe", "--help"]).ok
}

// A live connection to AeroSpace's event stream: `aerospace subscribe`
// stays running and prints one line of JSON the moment something happens,
// for example {"_event":"focused-workspace-changed","workspace":"Dev",...}.
// This is how the menu bar icon learns about workspace switches, instead
// of asking over and over. Nothing runs while nothing happens, and there
// is nothing to add to .aerospace.toml.
//
// Safety nets, because this connection can break:
//   - If AeroSpace quits or restarts, the `aerospace subscribe` process
//     ends. A new one is started every 2 seconds until it stays up, and
//     AeroSpace sends the current workspace again on every new connection,
//     so a restart can't leave the icon showing an old workspace.
//   - An AeroSpace too old for `subscribe` gets a simple check once a
//     second instead.
//   - stop() ends the process when AeroSwitcher quits.
//
// (Marked @unchecked Sendable: it is only touched on the main thread, which
// the compiler cannot see.) Everything here happens on the main thread, the reading thread hands
// each chunk over before touching anything.
final class AeroSpaceEventStream: @unchecked Sendable {
    var onWorkspace: ((String) -> Void)?
    // nil = AeroSpace is disabled. Found by testing: `aerospace enable off`
    // makes AeroSpace send {"_event":"mode-changed"} with no mode at all,
    // and `enable on` sends mode "main" again.
    var onMode: ((String?) -> Void)?
    // true = got a sign of life from AeroSpace, false = connection lost.
    var onConnection: ((Bool) -> Void)?
    // A window got focus: its id and the workspace it is in. This is what
    // the recent order (MRUTracker) is built from, so the hook line in
    // .aerospace.toml isn't needed. AeroSpace also sends the current focus
    // once on every new connection.
    var onFocus: ((_ windowID: String, _ workspace: String) -> Void)?

    private var wanted = false
    private var process: Process?
    private var pending = Data()
    private var pollTimer: Timer?
    private var pollSawWorkspace: String?
    private var connected = false

    func start() {
        wanted = true
        if aerospaceSupportsSubscribe() {
            logInfo("AeroSpace events: using `aerospace subscribe`.")
            connect()
        } else {
            logInfo("AeroSpace events: this AeroSpace has no `subscribe` command, checking the workspace once a second instead.")
            startPolling()
        }
    }

    func stop() {
        wanted = false
        pollTimer?.invalidate()
        pollTimer = nil
        let running = process
        process = nil
        running?.terminationHandler = nil
        if running?.isRunning == true { running?.terminate() }
    }

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        logInfo("AeroSpace events: \(value ? "connected" : "connection lost")")
        onConnection?(value)
    }

    private func connect() {
        guard wanted, process == nil else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: aerospacePath)
        child.arguments = ["subscribe", "focused-workspace-changed", "mode-changed", "focus-changed"]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.received(data, from: child) }
        }
        child.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.ended(finished) }
        }
        do {
            try child.run()
            process = child
        } catch {
            logError("AeroSpace events: couldn't start `aerospace subscribe`: \(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    private func received(_ data: Data, from child: Process) {
        guard child === process else { return }  // late data from a connection that already ended
        pending.append(data)
        // A chunk can end in the middle of a line, only whole lines are used.
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let event = json["_event"] as? String else {
            logWarn("AeroSpace events: `aerospace subscribe` said: \(line)")
            return
        }
        logDebug("AeroSpace event: \(line)")
        setConnected(true)
        switch event {
        case "focused-workspace-changed":
            if let workspace = json["workspace"] as? String { onWorkspace?(workspace) }
        case "mode-changed":
            onMode?(json["mode"] as? String)
        case "focus-changed":
            // windowId is a number in the JSON. It can be missing when
            // focus lands on an empty workspace, nothing to record then.
            let windowID = (json["windowId"] as? NSNumber)?.stringValue ?? (json["windowId"] as? String)
            if let windowID, let workspace = json["workspace"] as? String { onFocus?(windowID, workspace) }
        default:
            break
        }
    }

    private func ended(_ finished: Process) {
        guard finished === process else { return }
        logWarn("AeroSpace events: `aerospace subscribe` ended (exit \(finished.terminationStatus)).")
        process = nil
        setConnected(false)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard wanted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    // The fallback for an AeroSpace without `subscribe`.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.global().async {
                let name = getCurrentWorkspaceName()
                DispatchQueue.main.async { self?.polled(name) }
            }
        }
        pollTimer?.fire()
    }

    private func polled(_ name: String?) {
        guard wanted else { return }
        setConnected(name != nil)
        if name == nil { pollSawWorkspace = nil }  // after a break, report the workspace again
        if let name, name != pollSawWorkspace {
            pollSawWorkspace = name
            onWorkspace?(name)
        }
    }
}
