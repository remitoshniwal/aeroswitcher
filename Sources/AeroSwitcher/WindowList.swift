import Cocoa

// MARK: - Window list
//
// The questions the rest of the app asks about windows and workspaces
// (Cmd+Tab, the Cmd+` overview, the menu bar). The answers come from
// AeroSwitcher's own window manager (WorkspaceManager.swift), which keeps
// an in-memory copy of every window, so every function here answers at
// once without asking another program.
//
// Until version 1.0 these questions went to AeroSpace's command line tool;
// the function names and the AeroWindow type stayed the same so nothing
// else in the app had to change.

struct AeroWindow {
    let id: String
    let appPID: Int32   // the owning app's process ID, needed to give it real OS focus later
    let workspace: String  // which workspace this window is in
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
    let all = WorkspaceManager.shared.windowsSnapshot()
    guard scope != "all" else { return all }
    let focused = WorkspaceManager.shared.focusedWorkspaceSnapshot()
    return all.filter { $0.workspace == focused }
}

// Every window on every workspace plus the focused workspace's name, in one
// go, for Cmd+Tab (show() in WindowController.swift): it needs both the
// focused workspace's windows (the cards) and every workspace's windows (the
// grey "No window" tiles). The focused workspace is given even when it has
// no windows. Never nil any more; the optional is left from the AeroSpace
// days, when this could fail.
func getWindowsWithFocus() -> (windows: [AeroWindow], focusedWorkspace: String?)? {
    (WorkspaceManager.shared.windowsSnapshot(), WorkspaceManager.shared.focusedWorkspaceSnapshot())
}

// Called from the main thread (Cmd+Tab's confirm and cancel). Switches to
// the window's workspace if needed, raises the window and brings its app to
// the front.
func focusWindow(id: String, pid: Int32? = nil) {
    WorkspaceManager.shared.focus(windowID: id, pid: pid)
}

// Name of the workspace currently focused (e.g. "Creative"). Used to figure
// out which launcher apps belong on this particular Cmd+Tab screen, see
// LauncherApp.
func getCurrentWorkspaceName() -> String? {
    WorkspaceManager.shared.focusedWorkspaceSnapshot()
}

// Every workspace, whether or not anything's open in it right now. This is
// what lets the overview panel show an empty workspace as an empty section
// instead of leaving it out.
func getAllWorkspaceNames() -> [String] {
    WorkspaceManager.shared.workspaceNamesSnapshot()
}

// The one specific window that's focused right now. Used to remember what
// to hand focus back to when the read-only overview panel closes.
func getFocusedWindow() -> AeroWindow? {
    WorkspaceManager.shared.focusedWindowSnapshot()
}

// The app name a window is shown under. Normally the app's own name. A
// window whose process a KnownApps file claims (Steam's "Steam Helper",
// Minecraft's "java", see KnownApp.windowsFromBundleIDs and
// windowsFromFolders in Config.swift) gets that app's name instead. Done
// where the window list is built, so the Cmd+Tab card, the Cmd+` overview
// and the grey tile hiding all see the same name.
func shownAppName(pid: Int32, reported: String) -> String {
    knownApps.owner(ofPID: pid)?.name ?? reported
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
        // A KnownApps app's icon first (Steam instead of the blank Steam
        // Helper, Minecraft instead of java's program icon).
        let image = knownApps.icon(forPID: pid)
            ?? running?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? running?.icon
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

// Which apps have windows in each workspace, for the menu's workspace rows
// ("Core    Chrome, Notion"). Names only, sorted and without repeats. A
// workspace with nothing open is just missing from the result.
func getAppNamesByWorkspace() -> [String: [String]] {
    var names: [String: Set<String>] = [:]
    for window in WorkspaceManager.shared.windowsSnapshot() { names[window.workspace, default: []].insert(window.appName) }
    return names.mapValues { $0.sorted() }
}

// The menu calls this on the main thread, where the manager lives.
func switchToWorkspace(_ name: String) {
    DispatchQueue.main.async { WorkspaceManager.shared.switchTo(name) }
}
