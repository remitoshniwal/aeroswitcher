import Cocoa
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings window
//
// Opened from the menu bar ("Settings..."). Four tabs:
//   General         tile status text, auto reload, launch at login, hiding
//                   AeroSpace's icon, buttons for config.json
//   Launcher tiles  which apps get a grey tile in which workspace
//   Keys            the keys used while the switcher is open, recorded by
//                   pressing them
//   Icons           custom icons per app
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
    @Published var selectedWorkspace: String?

    // The file as plain JSON, exactly as shown. Handed to editConfigFile so
    // it can tell whether you changed the same part by hand meanwhile.
    private(set) var shownTree: [String: Any] = [:]
    private var keyMonitor: Any?
    private var appIconCache: [String: NSImage] = [:]

    init() {
        NotificationCenter.default.addObserver(forName: .configDidReload, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .menuBarTogglesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshToggles() }
        }
    }

    func refresh() {
        let snapshot = readConfigSnapshot()
        shownTree = snapshot.tree ?? [:]
        fileProblem = snapshot.problem
        config = snapshot.problem == nil ? snapshot.config : nil
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
    func loadAeroSpaceWorkspaces() {
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
            print("Settings: not saved: \(why)")
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
        print("Settings: recording a key for \(action)")
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingAction = nil
    }

    private func recorded(_ event: NSEvent) {
        guard let action = recordingAction, let config else {
            stopRecording()
            return
        }
        stopRecording()
        let code = Int64(event.keyCode)
        print("Settings: key pressed while recording \(action): code \(code)")
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
        print("Settings: icon folder \(folder.path): \(files.count) images, \(matches.count) matched, unmatched: \(unmatched)")
        return (matches, unmatched)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
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
        print("Settings: window shown")
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        print("Settings: window closed")
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
                Text(model.aerospaceWorkspaces.isEmpty ? "Asking AeroSpace for its workspaces..." : "Pick a workspace")
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
                    Text("AeroSpace has no workspace called \(workspace), so these tiles never show.")
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
            CommitTextField(label: "Name", value: tile.name, required: true) {
                model.setTileField("name", to: $0, at: index, in: workspace)
            }
            CommitTextField(label: "Match", value: tile.match, required: true) {
                model.setTileField("match", to: $0, at: index, in: workspace)
            }
            Text("The tile hides while a window of an app whose name contains this is open here. It has to match the name AeroSpace uses for the app.")
                .font(.caption).foregroundStyle(.secondary)
            CommitTextField(label: "Open", value: tile.open, required: true) {
                model.setTileField("open", to: $0, at: index, in: workspace)
            }
            Text("The name macOS opens the app by, usually its name in the Applications folder.")
                .font(.caption).foregroundStyle(.secondary)
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
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading)
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
            print("Settings: found \(found.count) apps in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
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
