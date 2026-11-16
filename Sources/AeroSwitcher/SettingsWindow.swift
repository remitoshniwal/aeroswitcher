import Cocoa
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings window
//
// Opened from the menu bar ("Settings..."). Five tabs:
//   General         tile status text, auto reload, launch at login, hiding
//                   AeroSpace's icon, buttons for config.json
//   Launcher tiles  which apps get a grey tile in which workspace
//   Keys            the keys used while the switcher is open, recorded by
//                   pressing them
//   Icons           custom icons per app
//   Workspaces      AeroSwitcher's own window manager (Phase 14): its
//                   workspaces and their Option+keys, the rules that send
//                   new windows to a workspace, and the maximize settings
//                   (config.json's "windowManager" section)
//
// How it saves: every change is saved the moment you make it (text fields
// when you press Return or click somewhere else), through editConfigFile in
// Config.swift. That function explains the rules; the short version is that
// it only ever changes the one part of config.json you touched, so edits
// you make by hand in the file are never thrown away, and it never writes a
// file that wouldn't load.
//
// What the window shows always comes from the file itself, read again
// after every reload (yours or its own), so a hand edit appears here
// within about a second.
//
// Launch at login and Hide AeroSpace's icon aren't in config.json, they're
// macOS's / AeroSwitcher's own preferences. Their toggles here run exactly
// the same code as the menu items (MenuBar.swift).
//
// Key recording: while you record a key, the window listens to keys typed
// into THIS window only (a "local monitor", removed again after one key).
// It never sees keys typed in other apps, and the Cmd+Tab event tap
// (HotkeyInterception.swift) is not touched: Cmd+Tab and Cmd+` still open
// the switcher as always, everything else passes through to this window.
//
// The window is a fixed size (not resizable), so it has no working green
// full screen button and the maximize script leaves it alone, the same
// trick the config problems window uses.

// Plain-English names for each keybind, shown in the Keys tab. Change the
// wording here.
private let keybindDescriptions: [String: (title: String, detail: String)] = [
    "cycleNext": ("Next card", "In the Cmd+` overview: next page"),
    "cyclePrevious": ("Previous card", "In the overview: previous page"),
    "enterGreyedRow": ("Down to the launcher tiles", "In the overview: scroll down (only on a page taller than the screen)"),
    "exitGreyedRow": ("Back up from the launcher tiles", "In the overview: scroll up"),
    "pageUp": ("Previous page of cards", "Not used in the overview"),
    "pageDown": ("Next page of cards", "Not used in the overview"),
    "confirm": ("Switch to the selected card", "Or open the selected launcher app. In the overview: close it"),
    "cancel": ("Close without switching", "Same in the overview"),
]

// MARK: The model (what the window shows, and every change it can make)

@MainActor
final class SettingsModel: ObservableObject {
    // config.json as last read. nil while the file can't be used, see
    // fileProblem; the window then shows only the problem.
    @Published private(set) var config: SwitcherConfig?
    @Published private(set) var fileProblem: String?
    // A message at the top of the window, e.g. why a change wasn't saved.
    @Published var notice: String?
    @Published private(set) var aerospaceWorkspaces: [String] = []
    @Published private(set) var launchAtLogin = false
    @Published private(set) var hidingAeroSpaceIcon = false
    @Published private(set) var recordingAction: String?
    // Which Option+key of the Workspaces tab is being recorded, if any. Kept
    // apart from recordingAction (the Keys tab) because these keys are
    // stored somewhere else in config.json and follow other rules.
    @Published private(set) var recordingWindowManagerKey: WindowManagerKeyTarget?
    // Workspace names that were renamed or removed in the Workspaces tab
    // while they still had launcher tiles. Only used for the note under the
    // workspace list; the tiles themselves are never touched from there.
    @Published private(set) var namesWithLeftoverTiles: [String] = []
    @Published var selectedWorkspace: String?

    // The file as plain JSON, exactly as shown. Handed to editConfigFile so
    // it can tell whether you changed the same part by hand meanwhile.
    private(set) var shownTree: [String: Any] = [:]
    private var keyMonitor: Any?
    private var appIconCache: [String: NSImage] = [:]
    // helperAppInside answers by Open text, looked up once (it asks macOS),
    // because SwiftUI redraws the rows often. Cleared when config.json is
    // reloaded, so a newly installed app is seen then.
    private var helperCache: [String: (helper: String, outerApp: String)?] = [:]

    init() {
        NotificationCenter.default.addObserver(forName: .configDidReload, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .menuBarTogglesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshToggles() }
        }
    }

    func refresh() {
        helperCache = [:]
        let snapshot = readConfigSnapshot()
        shownTree = snapshot.tree ?? [:]
        fileProblem = snapshot.problem
        config = snapshot.problem == nil ? snapshot.config : nil
        // Own window manager: a workspace added or renamed in the Workspaces
        // tab should show up in the Launcher tiles tab straight away, not
        // only the next time the window opens.
        if ownWindowManager {
            aerospaceWorkspaces = windowManagerSettings.workspaceNames
        }
        if selectedWorkspace == nil || !workspaceNames.contains(selectedWorkspace!) {
            selectedWorkspace = workspaceNames.first
        }
    }

    func refreshToggles() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hidingAeroSpaceIcon = menuBar?.isHidingAeroSpaceIcon ?? false
    }

    // Asked off the main thread: the main thread also runs the Cmd+Tab
    // event tap, and must never wait for AeroSpace (see CLAUDE.md).
    //
    // When AeroSwitcher manages windows itself (ownWindowManager), AeroSpace
    // isn't running, so there is nobody to ask: the workspaces are the ones
    // in the Workspaces tab (config.json's "windowManager" section, as the
    // running app loaded it). The variable is still called
    // aerospaceWorkspaces so the Launcher tiles tab works the same in both
    // modes. refresh() keeps it up to date after every reload in that mode.
    func loadAeroSpaceWorkspaces() {
        if ownWindowManager {
            aerospaceWorkspaces = windowManagerSettings.workspaceNames
            if selectedWorkspace == nil { selectedWorkspace = workspaceNames.first }
            return
        }
        Task.detached {
            let result = runAerospace(["list-workspaces", "--all"])
            let names = result.ok
                ? result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            await MainActor.run {
                self.aerospaceWorkspaces = names
                if self.selectedWorkspace == nil { self.selectedWorkspace = self.workspaceNames.first }
            }
        }
    }

    // AeroSpace's workspaces in its own order, then any that only
    // config.json has (those are flagged in the Launcher tiles tab).
    var workspaceNames: [String] {
        let configOnly = (config?.workspaces.keys.sorted() ?? []).filter { !aerospaceWorkspaces.contains($0) }
        return aerospaceWorkspaces + configOnly
    }

    // Every change goes through here. Returns whether it was saved.
    @discardableResult
    private func edit(_ description: String, touching paths: [[String]], change: (inout [String: Any]) -> Void) -> Bool {
        let outcome = editConfigFile(description, touching: paths, shownTree: shownTree, change: change)
        refresh()
        switch outcome {
        case .saved:
            notice = nil
            return true
        case .refused(let why):
            logWarn("Settings: not saved: \(why)")
            notice = why
            NSSound.beep()
            return false
        }
    }

    // MARK: General

    func setTopLevelBool(_ key: String, _ value: Bool) {
        edit("set \(key) = \(value)", touching: [[key]]) { $0[key] = value }
    }

    func toggleLaunchAtLogin() {
        menuBar?.launchAtLoginClicked()
        refreshToggles()
    }

    func toggleHideAeroSpaceIcon() {
        menuBar?.hideAeroSpaceIconClicked()
        refreshToggles()
    }

    // MARK: Launcher tiles

    func tiles(in workspace: String) -> [LauncherAppConfig] {
        config?.workspaces[workspace] ?? []
    }

    // Changes one workspace's list of tiles. A workspace left with no tiles
    // is removed from config.json, there's nothing left to say about it.
    private func changeTiles(_ description: String, in workspace: String, _ change: @escaping (inout [Any]) -> Void) {
        edit(description, touching: [["workspaces", workspace]]) { tree in
            var workspaces = tree["workspaces"] as? [String: Any] ?? [:]
            var list = workspaces[workspace] as? [Any] ?? []
            change(&list)
            workspaces[workspace] = list.isEmpty ? nil : list
            tree["workspaces"] = workspaces
        }
    }

    func addTile(_ entry: [String: Any], to workspace: String) {
        changeTiles("add \(entry["name"] as? String ?? "?") to \(workspace)", in: workspace) { $0.append(entry) }
    }

    func removeTile(at index: Int, from workspace: String) {
        let name = tiles(in: workspace)[safe: index]?.name ?? "?"
        changeTiles("remove \(name) from \(workspace)", in: workspace) { list in
            if list.indices.contains(index) { list.remove(at: index) }
        }
    }

    func removeWorkspace(_ workspace: String) {
        edit("remove workspace \(workspace)", touching: [["workspaces", workspace]]) { tree in
            var workspaces = tree["workspaces"] as? [String: Any] ?? [:]
            workspaces[workspace] = nil
            tree["workspaces"] = workspaces
        }
    }

    // One field of one tile. nil removes the field (only for the optional
    // ones, newWindowStyle and icon).
    func setTileField(_ field: String, to value: String?, at index: Int, in workspace: String) {
        changeTiles("set workspaces.\(workspace)[\(index)].\(field) = \(value ?? "(removed)")", in: workspace) { list in
            guard list.indices.contains(index), var entry = list[index] as? [String: Any] else { return }
            entry[field] = value
            list[index] = entry
        }
    }

    // The tile's icon in the window: its custom image if it has one,
    // otherwise the app's own icon (looked up once, then remembered).
    func icon(forTile tile: LauncherAppConfig) -> NSImage {
        if let path = tile.icon ?? config?.icons?[tile.match],
           let image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath) {
            return image
        }
        return appIcon(match: tile.match, open: tile.open)
    }

    // The helper-app warning for one tile's Open text (see helperAppInside
    // in Config.swift). nil = no warning.
    func helperWarning(forOpen open: String) -> (helper: String, outerApp: String)? {
        if let cached = helperCache[open] { return cached }
        let answer = helperAppInside(openName: open)
        helperCache[open] = answer
        return answer
    }

    func appIcon(match: String, open: String) -> NSImage {
        let key = match + "|" + open
        if let cached = appIconCache[key] { return cached }
        let image = resolvedAppIcon(matchKey: match, openName: open)
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        appIconCache[key] = image
        return image
    }

    // MARK: Keys

    // What config.json says for this action (may be a name that isn't a
    // real key, the warnings below say so).
    func currentKey(for action: String) -> String {
        guard let path = keybindActions.first(where: { $0.name == action })?.keyPath else { return "" }
        return (config?.keybinds ?? KeybindConfig())[keyPath: path]
    }

    // Same checks as a reload (resolveKeybinds in Keybinds.swift), so the
    // window and the problems window always agree.
    var keybindWarnings: [String] {
        guard let config else { return [] }
        let report = ConfigReport()
        _ = resolveKeybinds(config.keybinds, report: report)
        return report.warnings
    }

    func startRecording(_ action: String) {
        stopRecording()
        recordingAction = action
        notice = nil
        // Only keys typed into AeroSwitcher's own windows reach this.
        // Returning nil swallows the key, so e.g. Cmd+W or Cmd+Q pressed
        // while recording don't close the window or quit the app.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.recorded(event) }
            return nil
        }
        logDebug("Settings: recording a key for \(action)")
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingAction = nil
        recordingWindowManagerKey = nil
    }

    private func recorded(_ event: NSEvent) {
        guard let action = recordingAction, let config else {
            stopRecording()
            return
        }
        stopRecording()
        let code = Int64(event.keyCode)
        logDebug("Settings: key pressed while recording \(action): code \(code)")
        guard let name = keyName(forCode: code) else {
            notice = "AeroSwitcher can't use that key. Pick a letter, a digit, an arrow, Space, Return, Escape, Delete, Page Up or Page Down."
            NSSound.beep()
            return
        }
        if code == 48 {
            notice = "Tab can't be used here: Cmd+Tab always opens the switcher (and Cmd+Shift+Tab goes back)."
            NSSound.beep()
            return
        }
        // The key this action has now, or its default if what's in the file
        // isn't a real key. That's what the other action gets on a swap.
        let defaults = KeybindConfig()
        let actionPath = keybindActions.first { $0.name == action }!.keyPath
        let current = config.keybinds[keyPath: actionPath]
        let currentName = keyCode(forName: current) != nil ? current : defaults[keyPath: actionPath]

        let other = keybindActions.first { $0.name != action && keyCode(forName: config.keybinds[keyPath: $0.keyPath]) == code }
        if let other {
            let otherTitle = keybindDescriptions[other.name]?.title ?? other.name
            let alert = NSAlert()
            alert.messageText = "\(keyDisplayName(name)) is already used for \"\(otherTitle)\""
            alert.informativeText = "Swap them? \"\(otherTitle)\" would get \(keyDisplayName(currentName)) instead."
            alert.addButton(withTitle: "Swap")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            edit("swap keybinds.\(action) = \(name) and keybinds.\(other.name) = \(currentName)", touching: [["keybinds"]]) { tree in
                var keybinds = tree["keybinds"] as? [String: Any] ?? [:]
                keybinds[action] = name
                keybinds[other.name] = currentName
                tree["keybinds"] = keybinds
            }
        } else {
            edit("set keybinds.\(action) = \(name)", touching: [["keybinds"]]) { tree in
                var keybinds = tree["keybinds"] as? [String: Any] ?? [:]
                keybinds[action] = name
                tree["keybinds"] = keybinds
            }
        }
        if name == "space" {
            notice = "Saved, but Cmd+Space belongs to Spotlight, and Spotlight wins: this key probably won't work while the switcher is open."
        }
    }

    func resetKeybinds() {
        let defaults = KeybindConfig()
        edit("reset keybinds to defaults", touching: [["keybinds"]]) { tree in
            // Unknown keys inside "keybinds" are left alone.
            var keybinds = tree["keybinds"] as? [String: Any] ?? [:]
            for action in keybindActions { keybinds[action.name] = defaults[keyPath: action.keyPath] }
            tree["keybinds"] = keybinds
        }
    }

    // MARK: Workspaces (the "windowManager" section)
    //
    // Everything the Workspaces tab changes lives in config.json's
    // "windowManager" section (see WindowManagerConfig in Config.swift for
    // what it looks like). The rows the tab SHOWS come from the decoded
    // config (model.config), but every change is made on the plain JSON
    // tree: the section is taken out of the freshly read file, changed, and
    // put back whole. Working on the plain tree means anything you typed
    // into the section by hand that AeroSwitcher doesn't know (an extra key
    // in a workspace, say) is kept instead of thrown away.
    //
    // The tab tries hard never to write something that would only produce a
    // warning (a rule with no app text, two workspaces with the same name or
    // key, a rule pointing at a workspace that's gone). A warning pops up
    // the config problems window, which would be a strange reply to a click
    // in Settings. Problems from hand edits are still listed in the tab.

    // nil = config.json has no "windowManager" section at all (the tab then
    // shows its empty state).
    var windowManagerConfig: WindowManagerConfig? { config?.windowManager }
    var windowManagerWorkspaces: [WindowManagerConfig.Workspace] { windowManagerConfig?.workspaces ?? [] }
    var windowManagerRules: [WindowManagerConfig.Rule] { windowManagerConfig?.rules ?? [] }
    var windowManagerWorkspaceNames: [String] { windowManagerWorkspaces.map(\.name) }

    // The window manager lines of the last load's problem list. Taken from
    // the report the app already made (settings.lastReport) instead of
    // checking again here, because checking again would write every
    // warning to the log once more on each redraw. All of these warnings
    // start with "windowManager" (see resolveWindowManager, Config.swift).
    var windowManagerWarnings: [String] {
        settings.lastReport.warnings.filter { $0.hasPrefix("windowManager") }
    }

    // How many rules send new windows to this workspace.
    func ruleCount(for workspace: String) -> Int {
        windowManagerRules.filter { $0.workspace == workspace }.count
    }

    // The one door every change in this tab goes through: takes the section
    // out of the file (or starts an empty one if there is none yet), lets
    // `change` edit it, and writes it back, all as one editConfigFile call
    // that only touches "windowManager".
    @discardableResult
    private func changeWindowManager(_ description: String, _ change: @escaping (inout [String: Any]) -> Void) -> Bool {
        edit(description, touching: [["windowManager"]]) { tree in
            var section = tree["windowManager"] as? [String: Any] ?? [:]
            change(&section)
            tree["windowManager"] = section
        }
    }

    // The section's "workspaces" or "rules" list as plain JSON entries.
    // Every entry is a { } group, the file wouldn't have loaded otherwise.
    private static func entries(_ key: String, in section: [String: Any]) -> [[String: Any]] {
        (section[key] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    // Remembers that `name` lost its workspace here while launcher tiles
    // still use it, for the note under the list (shown only while that
    // stays true, see WorkspacesTab).
    private func noteLeftoverTiles(for names: [String]) {
        for name in names where !tiles(in: name).isEmpty && !namesWithLeftoverTiles.contains(name) {
            namesWithLeftoverTiles.append(name)
        }
    }

    // "Workspace 1", or the next number that isn't taken. You rename it
    // straight after, the number only keeps the names different.
    func addWindowManagerWorkspace() {
        var number = windowManagerWorkspaces.count + 1
        while windowManagerWorkspaceNames.contains("Workspace \(number)") { number += 1 }
        let name = "Workspace \(number)"
        changeWindowManager("add window manager workspace \(name)") { section in
            var list = Self.entries("workspaces", in: section)
            list.append(["name": name])
            section["workspaces"] = list
        }
    }

    // nil = fine. Otherwise why the new name can't be used, shown at the
    // top of the window (the name field then puts the old name back).
    func renameProblem(_ newName: String, at index: Int) -> String? {
        let others = windowManagerWorkspaceNames.enumerated().filter { $0.offset != index }.map(\.element)
        if others.contains(where: { $0.caseInsensitiveCompare(newName) == .orderedSame }) {
            return "There's already a workspace called \(newName), so the old name was put back."
        }
        return nil
    }

    // Renames one workspace AND every rule that pointed at it, in the same
    // save, so no rule is ever left pointing at a name that no longer exists.
    func renameWindowManagerWorkspace(at index: Int, to newName: String) {
        guard let oldName = windowManagerWorkspaceNames[safe: index], oldName != newName else { return }
        let moved = ruleCount(for: oldName)
        let saved = changeWindowManager("rename window manager workspace \(oldName) to \(newName) (and \(moved) rules)") { section in
            var list = Self.entries("workspaces", in: section)
            guard list.indices.contains(index) else { return }
            list[index]["name"] = newName
            section["workspaces"] = list
            var rules = Self.entries("rules", in: section)
            for i in rules.indices where rules[i]["workspace"] as? String == oldName {
                rules[i]["workspace"] = newName
            }
            if section["rules"] != nil { section["rules"] = rules }
        }
        if saved { noteLeftoverTiles(for: [oldName]) }
    }

    // Removing a workspace that rules point at asks first, because those
    // rules have to go too (a rule needs a workspace to send windows to).
    func removeWindowManagerWorkspace(at index: Int) {
        guard let name = windowManagerWorkspaceNames[safe: index] else { return }
        let rules = ruleCount(for: name)
        if rules > 0 {
            let alert = NSAlert()
            alert.messageText = "Remove \(name)?"
            alert.informativeText = "\(rules) app rule\(rules == 1 ? "" : "s") send\(rules == 1 ? "s" : "") new windows to \(name). \(rules == 1 ? "It" : "They") will be removed too."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                logDebug("Settings: kept window manager workspace \(name)")
                return
            }
        }
        let saved = changeWindowManager("remove window manager workspace \(name) (and \(rules) rules)") { section in
            var list = Self.entries("workspaces", in: section)
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
            section["workspaces"] = list
            if section["rules"] != nil {
                section["rules"] = Self.entries("rules", in: section).filter { $0["workspace"] as? String != name }
            }
        }
        if saved { noteLeftoverTiles(for: [name]) }
    }

    // Moves a workspace (or rule) one place up (-1) or down (+1). The order
    // of workspaces is the order they're shown in; the order of rules
    // matters because the first rule that matches wins.
    func moveWindowManagerEntry(_ key: String, at index: Int, by offset: Int) {
        changeWindowManager("move windowManager.\(key)[\(index)] by \(offset)") { section in
            var list = Self.entries(key, in: section)
            let target = index + offset
            guard list.indices.contains(index), list.indices.contains(target) else { return }
            list.swapAt(index, target)
            section[key] = list
        }
    }

    // A new rule for an app picked in the Add Rule panel, sent to the first
    // workspace. Starting from a picked app (instead of an empty row) means
    // the file never holds a rule with no app text, which would only be a
    // warning.
    func addWindowManagerRule(app: String) {
        guard let workspace = windowManagerWorkspaceNames.first else { return }
        changeWindowManager("add window manager rule \(app) -> \(workspace)") { section in
            var rules = Self.entries("rules", in: section)
            rules.append(["app": app, "workspace": workspace])
            section["rules"] = rules
        }
    }

    // One field ("app" or "workspace") of one rule.
    func setRuleField(_ field: String, to value: String, at index: Int) {
        changeWindowManager("set windowManager.rules[\(index)].\(field) = \(value)") { section in
            var rules = Self.entries("rules", in: section)
            guard rules.indices.contains(index) else { return }
            rules[index][field] = value
            section["rules"] = rules
        }
    }

    func removeWindowManagerRule(at index: Int) {
        let app = windowManagerRules[safe: index]?.app ?? "?"
        changeWindowManager("remove window manager rule \(app)") { section in
            var rules = Self.entries("rules", in: section)
            guard rules.indices.contains(index) else { return }
            rules.remove(at: index)
            section["rules"] = rules
        }
    }

    func setMaximizeNewWindows(_ on: Bool) {
        changeWindowManager("set windowManager.maximizeNewWindows = \(on)") { $0["maximizeNewWindows"] = on }
    }

    // The key a target has in the file now (nil = none).
    func windowManagerKey(for target: WindowManagerKeyTarget) -> String? {
        let key: String?
        switch target {
        case .toggleMaximize: key = windowManagerConfig?.toggleMaximizeKey
        case .workspace(let name): key = windowManagerWorkspaces.first { $0.name == name }?.key
        }
        return (key?.isEmpty ?? true) ? nil : key
    }

    // Writes one target's key into a section (nil removes it). Shared by
    // "set a key" and "move a key from one target to another", so both
    // happen in a single save.
    private static func putKey(_ key: String?, for target: WindowManagerKeyTarget, in section: inout [String: Any]) {
        switch target {
        case .toggleMaximize:
            section["toggleMaximizeKey"] = key
        case .workspace(let name):
            var list = entries("workspaces", in: section)
            guard let i = list.firstIndex(where: { $0["name"] as? String == name }) else { return }
            list[i]["key"] = key
            section["workspaces"] = list
        }
    }

    func clearWindowManagerKey(for target: WindowManagerKeyTarget) {
        changeWindowManager("remove the key of \(target.logName)") { Self.putKey(nil, for: target, in: &$0) }
    }

    // Recording works like the Keys tab (a local monitor that only hears
    // keys typed into this window, removed after one key), but only letters
    // and digits are accepted: these keys are used with Option, and Option
    // with an arrow, Delete or Return already means something while typing
    // in almost every app (Option+Delete deletes a whole word), so taking
    // those over would get in the way.
    func startRecordingWindowManagerKey(_ target: WindowManagerKeyTarget) {
        stopRecording()
        recordingWindowManagerKey = target
        notice = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.recordedWindowManagerKey(event) }
            return nil
        }
        logDebug("Settings: recording a key for \(target.logName)")
    }

    private func recordedWindowManagerKey(_ event: NSEvent) {
        guard let target = recordingWindowManagerKey else {
            stopRecording()
            return
        }
        stopRecording()
        let code = Int64(event.keyCode)
        logDebug("Settings: key pressed while recording \(target.logName): code \(code)")
        if code == 53 { return }  // Escape: just stop recording, nothing changes
        guard let name = keyName(forCode: code), name.count == 1 else {
            notice = "Pick a letter or a digit. Option with arrows, Delete, Return or Space already does things while you type, so those aren't offered here."
            NSSound.beep()
            return
        }
        // Who has this key now, if anyone else: another workspace, or the
        // maximize toggle. Compared by key code, so "Q" and "q" are the same.
        var holders: [WindowManagerKeyTarget] = windowManagerWorkspaces.map { .workspace($0.name) }
        holders.append(.toggleMaximize)
        let other = holders.first { holder in
            holder != target && windowManagerKey(for: holder).flatMap { keyCode(forName: $0) } == code
        }
        if let other {
            // Keys here are optional, so the friendly fix is to MOVE the key
            // (the other one is left without), not to swap like the Keys tab.
            let alert = NSAlert()
            alert.messageText = "Option + \(keyDisplayName(name)) is already used for \(other.title)"
            alert.informativeText = "Use it for \(target.title) instead? \(other.title) will have no key."
            alert.addButton(withTitle: "Use It Here")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            changeWindowManager("move key \(name) from \(other.logName) to \(target.logName)") { section in
                Self.putKey(nil, for: other, in: &section)
                Self.putKey(name, for: target, in: &section)
            }
        } else {
            changeWindowManager("set the key of \(target.logName) = \(name)") { Self.putKey(name, for: target, in: &$0) }
        }
    }

    // Import from AeroSpace's .aerospace.toml (only read, never changed).
    // Asks first with the counts, then replaces the workspaces, rules and
    // maximize settings in ONE save. Keys in the section that AeroSwitcher
    // doesn't know are kept, the same as every other change here.
    func importFromAeroSpace() {
        guard let path = aeroSpaceConfigFilePath() else { return }
        guard let imported = windowManagerSectionFromAeroSpaceConfig(atPath: path) else {
            showFailureAlert("Couldn't import AeroSpace's config",
                             "No workspaces were found in \(path), so nothing was changed. Check that the file has a persistent-workspaces line or alt- workspace keys. Details are in the log: \(logFileURL().path)")
            return
        }
        let workspaces = (imported["workspaces"] as? [Any])?.count ?? 0
        let rules = (imported["rules"] as? [Any])?.count ?? 0
        let alert = NSAlert()
        alert.messageText = "Import from AeroSpace's config?"
        let counts = "\(workspaces) workspace\(workspaces == 1 ? "" : "s"), \(rules) rule\(rules == 1 ? "" : "s")."
        let replaces = windowManagerConfig == nil ? "" : " This replaces what's in this tab."
        alert.informativeText = counts + replaces + " AeroSpace's file is only read."
        alert.addButton(withTitle: windowManagerConfig == nil ? "Import" : "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            logDebug("Settings: import from AeroSpace's config cancelled")
            return
        }
        let oldNames = windowManagerWorkspaceNames
        let newNames = (imported["workspaces"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let saved = changeWindowManager("import \(workspaces) workspaces and \(rules) rules from \(path)") { section in
            for key in windowManagerKeyOrder { section[key] = nil }
            for (key, value) in imported { section[key] = value }
        }
        if saved { noteLeftoverTiles(for: oldNames.filter { !newNames.contains($0) }) }
    }

    // MARK: Icons

    struct IconRow: Identifiable {
        let key: String           // the name the icon is matched by
        let label: String         // shown in the window
        let customPath: String?   // the image file in use, if any
        let appIcon: NSImage      // the app's own icon, shown when there's no custom one
        // Every name this app goes by (tile name, match, open, running
        // name), for matching image file names in "Use icons from a folder".
        let names: [String]
        var id: String { key.lowercased() }
    }

    // Every app worth giving an icon: launcher tile apps, apps that
    // already have an "icons" entry, and every app running right now.
    func iconRows() -> [IconRow] {
        guard let config else { return [] }
        var rows: [IconRow] = []
        let allTiles = config.workspaces.keys.sorted().flatMap { config.workspaces[$0] ?? [] }
        for tile in allTiles where !rows.contains(where: { $0.key.caseInsensitiveCompare(tile.match) == .orderedSame }) {
            // A tile's own "icon" wins over the "icons" section, the same
            // order customIcon(forAppName:) in Config.swift checks them in.
            let tilePath = allTiles.first { $0.match == tile.match && $0.icon != nil }?.icon
            rows.append(IconRow(key: tile.match, label: tile.name, customPath: tilePath ?? config.icons?[tile.match],
                                appIcon: appIcon(match: tile.match, open: tile.open),
                                names: [tile.name, tile.match, tile.open]))
        }
        for (key, path) in (config.icons ?? [:]).sorted(by: { $0.key < $1.key })
        where !rows.contains(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            rows.append(IconRow(key: key, label: key, customPath: path, appIcon: appIcon(match: key, open: key), names: [key]))
        }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let name = running.localizedName, !rows.contains(where: { namesMatch($0.key, name) }) else { continue }
            let icon = running.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? running.icon
            rows.append(IconRow(key: name, label: name, customPath: nil, appIcon: icon ?? NSWorkspace.shared.icon(for: .applicationBundle),
                                names: [name]))
        }
        return rows.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    // A tile that already has its own "icon" keeps it there (changed in
    // place); anything else goes in the top-level "icons" section, which
    // applies everywhere the app shows up.
    func setIcon(path: String?, for key: String) {
        setIcons([(key: key, path: path)])
    }

    // Several icons in ONE change to config.json (the folder import), so
    // it's one save, one reload and one backup, not one per app. A nil
    // path removes that app's custom icon.
    func setIcons(_ changes: [(key: String, path: String?)]) {
        let stored = changes.map { (key: $0.key, path: $0.path.map { ($0 as NSString).abbreviatingWithTildeInPath }) }
        let description = stored.count == 1
            ? "set icon for \(stored[0].key) = \(stored[0].path ?? "(removed)")"
            : "set \(stored.count) icons: " + stored.map { "\($0.key) = \($0.path ?? "(removed)")" }.joined(separator: ", ")
        edit(description, touching: [["icons"], ["workspaces"]]) { tree in
            var workspaces = tree["workspaces"] as? [String: Any] ?? [:]
            var icons = tree["icons"] as? [String: Any] ?? [:]
            for (key, path) in stored {
                var changedATile = false
                for (name, value) in workspaces {
                    guard var list = value as? [Any] else { continue }
                    for index in list.indices {
                        guard var entry = list[index] as? [String: Any],
                              entry["match"] as? String == key, entry["icon"] != nil else { continue }
                        entry["icon"] = path
                        list[index] = entry
                        changedATile = true
                    }
                    workspaces[name] = list
                }
                if path == nil || !changedATile {
                    icons[key] = path
                }
            }
            if tree["workspaces"] != nil { tree["workspaces"] = workspaces }
            if tree["icons"] != nil || !icons.isEmpty { tree["icons"] = icons }
        }
    }

    // MARK: Icons from a folder

    struct IconFolderMatch: Identifiable {
        let row: IconRow
        let file: URL
        let exact: Bool  // false = only part of the name matched, worth a look
        var id: String { row.id }
    }

    // Matches the images in a folder to apps by file name, for "Use icons
    // from a folder...". Nothing is saved here, the sheet shows the result
    // first. Names are compared without capitals, spaces or punctuation,
    // so "vs code.png" matches the tile named "VS Code".
    //   Exact:  the file name IS one of the app's names ("calendar" for
    //           Calendar, "ableton" for the tile whose match is "Ableton").
    //   Close:  one contains the other ("settings" in "System Settings"),
    //           only for names of 4 letters or more, so a file called
    //           "go.png" doesn't land on every app with "go" in its name.
    // Each app gets at most one image: an exact match beats a close one,
    // then the shorter file name wins. Only the folder itself is looked
    // at, not folders inside it.
    func matchIcons(inFolder folder: URL) -> (matches: [IconFolderMatch], unmatched: [String]) {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        func simplified(_ name: String) -> String {
            name.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        var matches: [IconFolderMatch] = []
        for row in iconRows() {
            let names = row.names.map(simplified).filter { !$0.isEmpty }
            var best: (file: URL, exact: Bool)?
            for file in files {
                let fileName = simplified(file.deletingPathExtension().lastPathComponent)
                guard !fileName.isEmpty else { continue }
                let exact = names.contains(fileName)
                let close = !exact && names.contains { name in
                    min(name.count, fileName.count) >= 4 && (name.contains(fileName) || fileName.contains(name))
                }
                guard exact || close else { continue }
                if let current = best {
                    let better = (exact && !current.exact)
                        || (exact == current.exact && file.lastPathComponent.count < current.file.lastPathComponent.count)
                    if !better { continue }
                }
                best = (file, exact)
            }
            if let best { matches.append(IconFolderMatch(row: row, file: best.file, exact: best.exact)) }
        }
        let used = Set(matches.map { $0.file })
        let unmatched = files.filter { !used.contains($0) }.map { $0.lastPathComponent }
        logInfo("Settings: icon folder \(folder.path): \(files.count) images, \(matches.count) matched, unmatched: \(unmatched)")
        return (matches, unmatched)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// The things in the Workspaces tab that can have an Option+key: a workspace
// (by name, so the right row is still meant if the list changes while you
// record) or the maximize toggle.
enum WindowManagerKeyTarget: Equatable {
    case workspace(String)
    case toggleMaximize

    // How it's named in the window ("Core", "the maximize toggle").
    var title: String {
        switch self {
        case .workspace(let name): return name
        case .toggleMaximize: return "the maximize toggle"
        }
    }

    // How it's named in the log.
    var logName: String {
        switch self {
        case .workspace(let name): return "window manager workspace \(name)"
        case .toggleMaximize: return "windowManager.toggleMaximizeKey"
        }
    }
}

// MARK: The window

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        installEditMenuIfNeeded()
        model.refresh()
        model.refreshToggles()
        model.loadAeroSpaceWorkspaces()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "AeroSwitcher Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        // AeroSwitcher is a background app (no Dock icon). It has to become
        // the active app, or the window couldn't be typed into.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        logInfo("Settings: window shown")
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        logInfo("Settings: window closed")
    }

    // Copy, paste, select all and undo in text fields are menu shortcuts on
    // macOS: a key press is matched against the app's menus. AeroSwitcher
    // has no menus of its own (it's a menu bar app), so without these the
    // shortcuts would do nothing in the window's text fields. Deliberately
    // no Quit (Cmd+Q) item: quitting AeroSwitcher by accident while typing
    // here would also turn off Cmd+Tab.
    private func installEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Settings", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: The views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(notice).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("OK") { model.notice = nil }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.15))
            }
            if let problem = model.fileProblem {
                BrokenFileView(problem: problem, retry: { model.refresh() })
            } else {
                TabView {
                    GeneralTab(model: model).tabItem { Text("General") }
                    LauncherTab(model: model).tabItem { Text("Launcher tiles") }
                    KeysTab(model: model).tabItem { Text("Keys") }
                    IconsTab(model: model).tabItem { Text("Icons") }
                    WorkspacesTab(model: model).tabItem { Text("Workspaces") }
                }
                .padding(12)
            }
        }
        .frame(width: 760, height: 560)
    }
}

// Shown instead of the tabs while config.json can't be read. Nothing can be
// changed then, so a broken file is never overwritten: fix it first.
struct BrokenFileView: View {
    let problem: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("config.json has an error").font(.title2)
            Text("The settings window can't change anything until it's fixed, so your file is never overwritten. AeroSwitcher keeps using the last settings that worked.")
                .foregroundStyle(.secondary)
            Text(problem)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Open config.json") { NSWorkspace.shared.open(configFileURL()) }
                Button("Try again", action: retry)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Switcher") {
                Toggle("Show Running / Quit / No window under launcher tiles", isOn: Binding(
                    get: { model.config?.showTileStatusText ?? true },
                    set: { model.setTopLevelBool("showTileStatusText", $0) }))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Reload config.json by itself when it's saved", isOn: Binding(
                        get: { model.config?.autoReloadConfig ?? true },
                        set: { model.setTopLevelBool("autoReloadConfig", $0) }))
                    Text("Only matters when you edit the file by hand. Changes made in this window always apply at once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("AeroSwitcher") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLaunchAtLogin() }))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Hide AeroSpace's icon", isOn: Binding(
                        get: { model.hidingAeroSpaceIcon },
                        set: { _ in model.toggleHideAeroSpaceIcon() }))
                    Text("Same as the menu item. Hides every menu bar icon to the left of AeroSwitcher's.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Setup") {
                Text("Checks AeroSpace and the permissions AeroSwitcher needs.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Setup...") { SetupHelp.shared.show() }
            }
            Section("config.json") {
                Text(configFileURL().path).font(.callout).textSelection(.enabled)
                Text("Everything in this window is saved to this file the moment you change it. You can still edit the file by hand.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open config.json") { NSWorkspace.shared.open(configFileURL()) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([configFileURL()]) }
                    // Same as the menu's Reload config: both AeroSwitcher and AeroSpace.
                    Button("Reload config") { settings.reloadTogether() }
                }
            }
            Section("Log") {
                Text(logFileURL().path).font(.callout).textSelection(.enabled)
                Text("What AeroSwitcher did and what went wrong. Look through it before sharing it, it contains file paths.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show log") {
                    // Selects the file in Finder, or opens the folder if nothing was written yet.
                    if FileManager.default.fileExists(atPath: logFileURL().path) {
                        NSWorkspace.shared.activateFileViewerSelecting([logFileURL()])
                    } else {
                        NSWorkspace.shared.open(logDirectoryURL())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LauncherTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            List(model.workspaceNames, id: \.self, selection: $model.selectedWorkspace) { name in
                HStack {
                    Text(name)
                    Spacer()
                    if !model.aerospaceWorkspaces.isEmpty && !model.aerospaceWorkspaces.contains(name) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            .frame(width: 170)
            Divider()
            if let workspace = model.selectedWorkspace {
                WorkspaceTilesView(model: model, workspace: workspace).id(workspace)
            } else {
                // In own window manager mode nobody is asked, the list is
                // just empty until workspaces are added in the Workspaces tab.
                Text(model.aerospaceWorkspaces.isEmpty
                     ? (ownWindowManager ? "No workspaces yet. Add them in the Workspaces tab." : "Asking AeroSpace for its workspaces...")
                     : "Pick a workspace")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct WorkspaceTilesView: View {
    @ObservedObject var model: SettingsModel
    let workspace: String
    @State private var picking = false

    var body: some View {
        let tiles = model.tiles(in: workspace)
        VStack(alignment: .leading, spacing: 8) {
            Text("Launcher tiles in \(workspace)").font(.headline)
            Text("A grey tile shows for each app here that has no window in this workspace. Tiles are always shown in alphabetical order, Running before Quit.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.aerospaceWorkspaces.isEmpty && !model.aerospaceWorkspaces.contains(workspace) {
                HStack {
                    Text(ownWindowManager
                         ? "The Workspaces tab has no workspace called \(workspace), so these tiles never show."
                         : "AeroSpace has no workspace called \(workspace), so these tiles never show.")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Remove \(workspace)") { model.removeWorkspace(workspace) }
                }
            }
            List {
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    TileRow(model: model, workspace: workspace, index: index, tile: tile)
                }
                if tiles.isEmpty {
                    Text("No tiles yet.").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add app...") { picking = true }
                Spacer()
            }
        }
        .padding(.leading, 12)
        .sheet(isPresented: $picking) {
            AppPickerView(model: model, workspace: workspace, isPresented: $picking)
        }
    }
}

struct TileRow: View {
    @ObservedObject var model: SettingsModel
    let workspace: String
    let index: Int
    let tile: LauncherAppConfig

    @State private var expanded = false

    // A plain arrow button instead of SwiftUI's DisclosureGroup: with a
    // DisclosureGroup the remove button had to sit inside its title, where
    // SwiftUI merges it into the title for accessibility (VoiceOver, and
    // testing scripts, couldn't press it), and moved outside it the list
    // stopped drawing the arrow at all.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 14)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Hide details of \(tile.name)" : "Show details of \(tile.name)")
                Image(nsImage: model.icon(forTile: tile)).resizable().frame(width: 24, height: 24)
                Text(tile.name)
                // Visible without opening the row: this tile's Open text
                // leads to a helper app (details below).
                if model.helperWarning(forOpen: tile.open) != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Open leads to a helper app inside another app, see the details")
                        .accessibilityLabel("Warning: Open leads to a helper app")
                }
                Spacer()
                Button {
                    model.removeTile(at: index, from: workspace)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this tile")
                .accessibilityLabel("Remove \(tile.name)")
            }
            if expanded {
                details.padding(.leading, 22)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommitTextField(label: "Name", value: tile.name, required: true, onRefused: { model.notice = $0 }) {
                model.setTileField("name", to: $0, at: index, in: workspace)
            }
            CommitTextField(label: "Match", value: tile.match, required: true, onRefused: { model.notice = $0 }) {
                model.setTileField("match", to: $0, at: index, in: workspace)
            }
            Text("The tile hides while a window of an app whose name contains this is open here. It has to match the name AeroSpace uses for the app.")
                .font(.caption).foregroundStyle(.secondary)
            CommitTextField(label: "Open", value: tile.open, required: true, onRefused: { model.notice = $0 }) {
                model.setTileField("open", to: $0, at: index, in: workspace)
            }
            Text("The name macOS opens the app by, usually its name in the Applications folder.")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = model.helperWarning(forOpen: tile.open) {
                // The Roblox Studio problem: see helperAppInside, Config.swift.
                VStack(alignment: .leading, spacing: 4) {
                    Label("macOS opens a helper app hidden inside \((warning.outerApp as NSString).lastPathComponent) for this name, not the app itself. It may start and quit at once, so the tile seems to do nothing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use \(warning.outerApp) instead") {
                        model.setTileField("open", to: warning.outerApp, at: index, in: workspace)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            Picker("New window", selection: Binding(
                get: { tile.newWindowStyle?.lowercased() ?? "" },
                set: { model.setTileField("newWindowStyle", to: $0.isEmpty ? nil : $0, at: index, in: workspace) })) {
                Text("Normal").tag("")
                Text("Finder (always a new window)").tag("finder")
                Text("Terminal (always a new window)").tag("terminal")
            }
            .frame(maxWidth: 360)
        }
        .padding(.vertical, 4)
    }
}

// A text field that saves when you press Return or click elsewhere, not
// on every letter (every save is a reload).
struct CommitTextField: View {
    let label: String
    let value: String
    var required = false
    // false = no label in front of the field (the label is then only the
    // grey placeholder text inside it), for rows that sit under a heading,
    // like the app rules in the Workspaces tab.
    var showsLabel = true
    // An extra check before saving: returns why the new text can't be used
    // (shown through onRefused, and the old text is put back), or nil if
    // it's fine. Used to refuse a workspace name that's already taken.
    var problem: ((String) -> String?)? = nil
    // Called with a message when an empty value was refused.
    var onRefused: ((String) -> Void)? = nil
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            if showsLabel {
                Text(label).frame(width: 50, alignment: .leading)
            }
            field
        }
    }

    private var field: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in
                if !focused { text = newValue }
            }
            .onSubmit { save() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save() }
            }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty && required {
            text = value  // can't be empty, put the old value back
            NSSound.beep()
            onRefused?("\(label) can't be empty, so the old value was put back.")
            return
        }
        if trimmed != value, let why = problem?(trimmed) {
            text = value
            NSSound.beep()
            onRefused?(why)
            return
        }
        if trimmed != value { commit(trimmed) }
    }
}

// The "Add app..." list: running apps first, then everything installed.
struct AppPickerView: View {
    @ObservedObject var model: SettingsModel
    let workspace: String
    @Binding var isPresented: Bool
    @State private var apps: [InstalledApp]?
    @State private var runningPaths = Set<String>()
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an app to \(workspace)").font(.headline)
            TextField("Search", text: $search)
            if let apps {
                let shown = apps.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
                List(shown) { app in
                    let alreadyAdded = model.tiles(in: workspace).contains { $0.open.caseInsensitiveCompare(app.fileName) == .orderedSame }
                    Button {
                        add(app)
                    } label: {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                            Text(app.displayName)
                            if runningPaths.contains(app.path) {
                                Text("running").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if alreadyAdded {
                                Text("already a tile here").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(alreadyAdded)
                }
            } else {
                ProgressView("Looking for apps...").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Other...") { chooseOther() }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 480)
        .task {
            let running = Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.standardizedFileURL.path })
            let started = Date()
            let found = await Task.detached { scanInstalledApps() }.value
            logInfo("Settings: found \(found.count) apps in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            runningPaths = running
            apps = found.filter { running.contains($0.path) } + found.filter { !running.contains($0.path) }
        }
    }

    private func add(_ app: InstalledApp) {
        model.addTile(suggestedLauncherEntry(for: app), to: workspace)
        isPresented = false
    }

    // For an app somewhere the list doesn't look.
    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(installedApp(at: url.standardizedFileURL.path))
    }
}

struct KeysTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(keybindActions.map { $0.name }, id: \.self) { name in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(keybindDescriptions[name]?.title ?? name)
                            Text(keybindDescriptions[name]?.detail ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.recordingAction == name {
                            Text("Press a key...").foregroundStyle(Color.accentColor)
                            Button("Cancel") { model.stopRecording() }
                        } else {
                            Text(keyDisplayName(model.currentKey(for: name)))
                                .font(.body.monospaced())
                                .frame(minWidth: 70)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Button("Record") { model.startRecording(name) }
                        }
                    }
                }
            } header: {
                Text("Keys while the switcher is open (hold Cmd)")
            } footer: {
                Text("Every key here only works while Cmd is still held after Cmd+Tab, so it never gets in the way of typing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.keybindWarnings.isEmpty {
                Section("Problems") {
                    ForEach(model.keybindWarnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            Section("Fixed, can't be changed") {
                fixedRow("Open the switcher, next card", "Cmd+Tab")
                fixedRow("Previous card", "Cmd+Shift+Tab")
                fixedRow("Overview of every workspace", "Cmd+`")
            }
            HStack {
                Spacer()
                Button("Reset to defaults") { model.resetKeybinds() }
            }
        }
        .formStyle(.grouped)
    }

    private func fixedRow(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).font(.body.monospaced()).foregroundStyle(.secondary)
        }
    }
}

struct IconsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var importFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("Custom icons show in the switcher's launcher tiles and the Cmd+` overview. The image file is not copied, so keep it where it is.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use icons from a folder...") { chooseFolder() }
            }
            List(model.iconRows()) { row in
                let custom = row.customPath.flatMap { NSImage(contentsOfFile: ($0 as NSString).expandingTildeInPath) }
                HStack {
                    Image(nsImage: custom ?? row.appIcon).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                        if let path = row.customPath {
                            Text(path).font(.caption).foregroundStyle(custom == nil ? .red : .secondary)
                            if custom == nil {
                                Text("This image can't be loaded, the app's own icon is used.").font(.caption).foregroundStyle(.red)
                            }
                        } else {
                            Text("The app's own icon").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Choose image...") { chooseImage(for: row.key) }
                    if row.customPath != nil {
                        Button("Remove") { model.setIcon(path: nil, for: row.key) }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { importFolder != nil }, set: { if !$0 { importFolder = nil } })) {
            if let importFolder {
                IconFolderImportView(model: model, folder: importFolder) { self.importFolder = nil }
            }
        }
    }

    // The folder import: pick a folder, then a sheet shows which image
    // goes to which app before anything is saved.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder with your icon images. An image named after an app is matched to it (calendar.png goes to Calendar)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFolder = url
    }

    private func chooseImage(for key: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setIcon(path: url.path, for: key)
    }
}

// The "Use icons from a folder..." sheet. Lists every app an image was
// matched to, each with a tick (all ticked to start with), and the images
// that didn't match any app. Only "Use" saves anything, all in one change.
struct IconFolderImportView: View {
    @ObservedObject var model: SettingsModel
    let folder: URL
    let close: () -> Void
    @State private var matches: [SettingsModel.IconFolderMatch] = []
    @State private var unmatched: [String] = []
    @State private var chosen = Set<String>()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icons from \((folder.path as NSString).abbreviatingWithTildeInPath)").font(.headline)
            Text("Matched by file name. Untick anything that's wrong. Nothing is saved until you click Use.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                if loaded && matches.isEmpty {
                    Text("No image in this folder is named after one of your apps.").foregroundStyle(.secondary)
                }
                ForEach(matches) { match in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { chosen.contains(match.id) },
                            set: { if $0 { chosen.insert(match.id) } else { chosen.remove(match.id) } }))
                            .labelsHidden()
                        Image(nsImage: currentIcon(match.row)).resizable().frame(width: 24, height: 24)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Image(nsImage: NSImage(contentsOf: match.file) ?? match.row.appIcon).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.row.label)
                            Text(match.file.lastPathComponent
                                 + (match.exact ? "" : ", close match")
                                 + (match.row.customPath != nil ? ", replaces the current custom icon" : ""))
                                .font(.caption)
                                .foregroundStyle(match.exact ? Color.secondary : Color.orange)
                        }
                    }
                }
                if !unmatched.isEmpty {
                    Section("Not matched to any app") {
                        Text(unmatched.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        Text("Rename an image to the app's name, or use Choose image... on that app's row.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Use \(chosen.count) icon\(chosen.count == 1 ? "" : "s")") {
                    model.setIcons(matches.filter { chosen.contains($0.id) }.map { (key: $0.row.key, path: $0.file.path) })
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 480)
        .onAppear {
            let result = model.matchIcons(inFolder: folder)
            matches = result.matches
            unmatched = result.unmatched
            chosen = Set(result.matches.map { $0.id })
            loaded = true
        }
    }

    private func currentIcon(_ row: SettingsModel.IconRow) -> NSImage {
        row.customPath.flatMap { NSImage(contentsOfFile: ($0 as NSString).expandingTildeInPath) } ?? row.appIcon
    }
}

// The Workspaces tab: AeroSwitcher's own window manager settings, the
// "windowManager" section of config.json. Every button and field here saves
// at once through the model's changeWindowManager (text fields when you
// press Return or click elsewhere), like the other tabs. The wording of
// everything you see is in this struct; the rules about what may be saved
// are in the model (MARK: Workspaces).
struct WorkspacesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // Looked up on each redraw (two "does this file exist" checks, cheap),
        // so the Import button appears as soon as the file does.
        let aeroSpaceConfig = aeroSpaceConfigFilePath()
        Form {
            Section {
                Text(ownWindowManager
                     ? "AeroSwitcher manages your windows with these workspaces and rules."
                     : "These are used when AeroSwitcher manages windows itself (switch in the Setup window). Until then AeroSpace's own config is used.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.windowManagerConfig == nil {
                emptyState(aeroSpaceConfig: aeroSpaceConfig)
            } else {
                workspacesSection
                rulesSection
                maximizeSection
                if !model.windowManagerWarnings.isEmpty {
                    Section("Problems") {
                        ForEach(model.windowManagerWarnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    }
                }
                if let aeroSpaceConfig {
                    Section("AeroSpace") {
                        importButton
                        Text("Reads \((aeroSpaceConfig as NSString).abbreviatingWithTildeInPath) and replaces everything in this tab with what's in it. AeroSpace's file is never changed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // config.json has no "windowManager" section at all yet.
    private func emptyState(aeroSpaceConfig: String?) -> some View {
        Section {
            Text("No workspaces yet").font(.headline)
            Text(aeroSpaceConfig == nil
                 ? "Add your first workspace to start."
                 : "Add your first workspace, or bring in the workspaces and rules from AeroSpace's config.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Add Workspace") { model.addWindowManagerWorkspace() }
                if aeroSpaceConfig != nil { importButton }
            }
        }
    }

    private var importButton: some View {
        Button("Import from AeroSpace's Config...") { model.importFromAeroSpace() }
    }

    private var workspacesSection: some View {
        let workspaces = model.windowManagerWorkspaces
        // Renamed or removed workspaces whose launcher tiles are still in
        // config.json under the old name (and no workspace has that name
        // again), see noteLeftoverTiles in the model.
        let leftovers = model.namesWithLeftoverTiles.filter {
            !model.tiles(in: $0).isEmpty && !model.windowManagerWorkspaceNames.contains($0)
        }
        return Section {
            ForEach(Array(workspaces.enumerated()), id: \.offset) { index, workspace in
                HStack {
                    CommitTextField(label: "Name", value: workspace.name, required: true,
                                    problem: { model.renameProblem($0, at: index) },
                                    onRefused: { model.notice = $0 }) {
                        model.renameWindowManagerWorkspace(at: index, to: $0)
                    }
                    .frame(maxWidth: 260)
                    Spacer()
                    WindowManagerKeyControl(model: model, target: .workspace(workspace.name))
                    moveButtons("workspaces", index: index, count: workspaces.count, name: workspace.name)
                    removeButton(name: workspace.name) { model.removeWindowManagerWorkspace(at: index) }
                }
            }
            if workspaces.isEmpty {
                Text("No workspaces yet.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Workspace") { model.addWindowManagerWorkspace() }
                Spacer()
            }
        } header: {
            Text("Workspaces")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shown in this order. Option + key goes to that workspace, Option + Shift + key moves the focused window there.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(leftovers, id: \.self) { name in
                    Text("\(name) still has launcher tiles in the Launcher tiles tab.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var rulesSection: some View {
        let rules = model.windowManagerRules
        let names = model.windowManagerWorkspaceNames
        return Section {
            if !rules.isEmpty {
                HStack {
                    Text("App path contains").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Workspace").font(.caption).foregroundStyle(.secondary)
                    // Room for the arrows and the remove button below.
                    Spacer().frame(width: 72)
                }
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack {
                    CommitTextField(label: "App path contains", value: rule.app, required: true, showsLabel: false,
                                    onRefused: { model.notice = $0 }) {
                        model.setRuleField("app", to: $0, at: index)
                    }
                    Spacer()
                    Picker("Workspace", selection: Binding(
                        get: { rule.workspace },
                        set: { if $0 != rule.workspace { model.setRuleField("workspace", to: $0, at: index) } })) {
                        ForEach(names, id: \.self) { Text($0).tag($0) }
                        // A rule edited by hand to a workspace that doesn't
                        // exist still needs an entry, or the picker would
                        // show nothing. The Problems list says why.
                        if !names.contains(rule.workspace) {
                            Text("\(rule.workspace) (missing)").tag(rule.workspace)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    moveButtons("rules", index: index, count: rules.count, name: rule.app)
                    removeButton(name: rule.app) { model.removeWindowManagerRule(at: index) }
                }
            }
            if rules.isEmpty {
                Text("No rules yet.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Rule...") { chooseAppForRule() }
                    .disabled(names.isEmpty)
                    .help(names.isEmpty ? "Add a workspace first" : "Pick an app, its new windows will go to a workspace")
                Spacer()
            }
        } header: {
            Text("App rules")
        } footer: {
            Text("A new window goes to the first rule that matches where its app is on disk (for example Google Chrome.app). No match: it stays in the workspace you are in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var maximizeSection: some View {
        Section("Maximize") {
            Toggle("Make every new window fill the screen", isOn: Binding(
                get: { model.windowManagerConfig?.maximizeNewWindows ?? true },
                set: { model.setMaximizeNewWindows($0) }))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toggle full screen")
                    Text("Flips the focused window between filling the screen and a centered smaller size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                WindowManagerKeyControl(model: model, target: .toggleMaximize)
            }
        }
    }

    // Up and down arrows for one row of a list.
    private func moveButtons(_ list: String, index: Int, count: Int, name: String) -> some View {
        HStack(spacing: 2) {
            Button {
                model.moveWindowManagerEntry(list, at: index, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move up")
            .accessibilityLabel("Move \(name) up")
            Button {
                model.moveWindowManagerEntry(list, at: index, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index >= count - 1)
            .help("Move down")
            .accessibilityLabel("Move \(name) down")
        }
        .buttonStyle(.borderless)
    }

    private func removeButton(name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
        .accessibilityLabel("Remove \(name)")
    }

    // "Add Rule...": pick the app, and the rule's text becomes the app's
    // file name ("Google Chrome.app"). That's the part of its place on disk
    // that's the same on every Mac. You can edit the text afterwards, for
    // example to match every app in a folder.
    private func chooseAppForRule() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Rule"
        panel.message = "Pick the app whose new windows should go to a workspace. You can change the workspace afterwards."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addWindowManagerRule(app: url.lastPathComponent)
    }
}

// The key of one workspace or of the maximize toggle: shown as
// "Option + Q", with Record (press the key) and None (no key).
struct WindowManagerKeyControl: View {
    @ObservedObject var model: SettingsModel
    let target: WindowManagerKeyTarget

    var body: some View {
        HStack(spacing: 6) {
            if model.recordingWindowManagerKey == target {
                Text("Press a letter or digit...").foregroundStyle(Color.accentColor)
                Button("Cancel") { model.stopRecording() }
            } else {
                let key = model.windowManagerKey(for: target)
                Text(key.map { "Option + \(keyDisplayName($0))" } ?? "No key")
                    .font(.body.monospaced())
                    .foregroundStyle(key == nil ? .secondary : .primary)
                    .frame(minWidth: 100)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button("Record") { model.startRecordingWindowManagerKey(target) }
                Button("None") { model.clearWindowManagerKey(for: target) }
                    .disabled(key == nil)
            }
        }
    }
}
