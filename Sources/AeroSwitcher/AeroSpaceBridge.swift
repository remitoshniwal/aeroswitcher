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
    let candidates = [
        "/opt/homebrew/bin/aerospace",  // Homebrew on Apple Silicon
        "/usr/local/bin/aerospace",     // Homebrew on Intel
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        return path
    }
    print("Couldn't find the aerospace CLI at any of the usual locations (\(candidates.joined(separator: ", "))). AeroSwitcher needs AeroSpace (https://github.com/nikitabobko/AeroSpace) installed to do anything at all.")
    return candidates[0]  // fall back to the most common one so every aerospace call below fails the same obvious way, instead of crashing differently depending on which one ran first
}()

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
        print("Failed to run aerospace: \(error)")
        return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    var windows: [AeroWindow] = []
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            .map(String.init)
        if parts.count >= 4 {
            let title = parts.count >= 5 ? parts[4] : ""
            windows.append(AeroWindow(id: parts[0], appPID: Int32(parts[1]) ?? 0, workspace: parts[2], appName: parts[3], title: title))
        }
    }
    return windows
}

func focusWindow(id: String, pid: Int32? = nil) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = ["focus", "--window-id", id]
    try? process.run()

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
    print("aerospace reload-config: exit \(process.terminationStatus)\(output.isEmpty ? "" : ", \(output)")")
    return AeroSpaceReloadResult(ok: process.terminationStatus == 0, output: output)
}
