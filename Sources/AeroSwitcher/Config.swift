import Cocoa

// MARK: - Config file (~/Library/Application Support/AeroSwitcher/config.json)
//
// Everything below reads from a plain JSON file there, created automatically
// (empty keybinds/workspaces filled in with defaults, "workspaces" itself
// left blank) the very first time AeroSwitcher runs. Edit that file and
// save it: AeroSwitcher reloads it by itself, the same way AeroSpace does
// with `auto-reload-config = true` (see SettingsStore, below). Nothing here
// needs to change or be rebuilt for that.
//
// Two things live in it:
//   "keybinds"   — which key does what while the switcher panel is open
//                  (Cmd+Tab itself always opens it; these are what happens
//                  once it's already up).
//   "workspaces" — which apps show up as a launcher tile per AeroSpace
//                  workspace, same idea as the list this replaced.
//
// Two safety notes, since a config file is very easy to typo:
//   - Same rules as AeroSpace's own config: a file that can't be read at
//     all (broken JSON, a value of the wrong type) is an ERROR, and the
//     previous working settings stay in use. Smaller mistakes (a key name
//     AeroSwitcher doesn't recognize, an icon file that won't load, a
//     misspelled setting) are WARNINGS: everything else still applies, and
//     that one thing falls back to its default. Either way a small window
//     lists exactly what's wrong (see ConfigProblemsWindow in Views.swift).
//   - "newWindowStyle" only accepts the words "finder" or "terminal" —
//     never raw AppleScript. That's deliberate: it means a mistake in this
//     file can never make the app run something you didn't intend.

struct KeybindConfig: Codable {
    var cycleNext: String = "d"        // was: right arrow
    var cyclePrevious: String = "a"    // was: left arrow
    var enterGreyedRow: String = "s"   // was: down arrow — jump onto the launcher row
    var exitGreyedRow: String = "w"    // was: up arrow — jump back off it
    var pageUp: String = "q"
    var pageDown: String = "e"
    // NOT "space" — Cmd+Space is macOS's own reserved Spotlight shortcut,
    // and it wins that fight even while this key is meant to be swallowed,
    // so anything bound here needs to be a combination nothing else on the
    // Mac already claims. "f" sits right next to the D/A/S/W cluster,
    // still a natural reach for the same hand.
    var confirm: String = "f"          // was: return
    var cancel: String = "escape"
}

struct LauncherAppConfig: Codable {
    var name: String     // shown under the grayed tile, e.g. "WhatsApp"
    var match: String    // substring checked against already-open windows' app names
    var open: String     // passed to `open -a` to actually launch it
    var newWindowStyle: String? = nil  // "finder", "terminal", or leave unset
    // Optional path to an image file (PNG, JPG, ICNS, etc.) to use as this
    // tile's icon instead of the generic dashed placeholder. `~` is
    // expanded, so "~/Pictures/AppIcons/calendar.png" works. This is a
    // real image file YOU own, not the app's own bundle icon — useful for
    // apps like Calendar whose actual macOS icon can't be replaced without
    // disabling System Integrity Protection. Applies everywhere
    // AeroSwitcher shows an icon for this app (the greyed launcher row
    // AND the Cmd+` overview), not just the launcher row, so it stays
    // consistent across both. Leave it unset for the normal behavior.
    var icon: String? = nil
}

struct SwitcherConfig: Codable {
    var keybinds = KeybindConfig()
    var workspaces: [String: [LauncherAppConfig]] = [:]
    // The small "Running" / "Quit" / "No window" line under each greyed-out
    // launcher tile (see LauncherCard). Defaults to on since it's genuinely
    // useful info the first time you see this app — set to false in
    // config.json if you'd rather have quieter tiles and just rely on the
    // small running-dot under the icon instead (same dot the Dock uses).
    //
    // Optional (nil, not a plain Bool with a default) on purpose: this field
    // was added after some config.json files already existed on disk
    // without it. Swift's auto-generated JSON decoding only tolerates a
    // missing key for an Optional property — a plain `Bool = true` still
    // throws "missing" the moment it hits an older file that predates this
    // field, which quietly discarded a real config (workspaces and all)
    // back to empty defaults the first time this shipped. nil here just
    // means "the file doesn't say" — every place that reads this treats
    // nil the same as true (see shouldShowTileStatusText(_:) below), so old files
    // keep working exactly as before, and only files that explicitly set it
    // to false actually change anything.
    var showTileStatusText: Bool? = nil
    // Custom icons for apps that AREN'T necessarily in "workspaces" at
    // all — LauncherAppConfig's own "icon" field (above) only exists on
    // entries already inside some workspace's roster, so it can't help an
    // app that isn't configured as a launcher tile anywhere but still
    // shows up with a real window (in the Cmd+\` overview) or as a
    // homeless "No window" tile. Key is matched the same substring way as
    // every other app name in this file, value is an image path (same
    // rules as LauncherAppConfig's "icon": `~` expanded, PNG/JPG/ICNS,
    // etc.). Same Optional-not-plain-dictionary reasoning as
    // showTileStatusText just above: this field didn't exist when some
    // config.json files were already written, so it has to tolerate being
    // missing entirely rather than requiring the key.
    var icons: [String: String]? = nil
    // Reload config.json by itself whenever it's saved, like AeroSpace's
    // `auto-reload-config = true`. Optional for the same "older files don't
    // have this key" reason as the two above; nil means on.
    var autoReloadConfig: Bool? = nil
}

// nil (key absent, e.g. an older config.json) means the same thing as true.
func shouldShowTileStatusText(_ config: SwitcherConfig) -> Bool {
    config.showTileStatusText ?? true
}

// nil (key absent) means the same thing as an empty dictionary — no
// standalone icon overrides configured.
func standaloneIcons(_ config: SwitcherConfig) -> [String: String] {
    config.icons ?? [:]
}

// What gets written out the very first time AeroSwitcher runs on a Mac
// that's never had a config.json before (see loadConfig, below). Deliberately
// empty rather than any one person's real setup — this same built app might
// get shared with someone else (a friend, family member, whoever), and their
// workspace names and apps won't match anyone else's ~/.aerospace.toml, so
// baking in specifics here would just be confusing clutter in a stranger's
// config file, not a head start. AeroSwitcher_Documentation.md has a filled-in
// example to copy from instead — the "workspaces" section is entirely
// optional anyway, everything else still works fine with it empty, you just
// won't see any greyed-out "not running yet" tiles until you add some.
let defaultSwitcherConfig = SwitcherConfig(
    keybinds: KeybindConfig(),
    workspaces: [:],
    showTileStatusText: true,  // written out explicitly so a fresh config.json shows it, instead of leaving the key out entirely
    autoReloadConfig: true     // same reason
)

// ~/Library/Application Support/<AppName>/ is the standard place a Mac app
// is supposed to keep its own settings — it's where every well-behaved app
// puts this kind of file, and it stays out of your home folder's normal
// listing (Library is hidden by default), instead of a loose dotfile sitting
// directly in ~.
// Shared by configFileURL (below) and AppWorkspaceTracker — both files
// live in the same folder, so there's exactly one place that creates it.
//
// AEROSWITCHER_CONFIG_DIR is only for testing: it points a copy started from
// Terminal at a scratch folder instead, so trying out broken config files
// can never touch the real one. A normally opened app never has it set.
// (Setting HOME doesn't work for this, NSHomeDirectory() ignores it.)
func appSupportDirectory() -> URL {
    let dir = ProcessInfo.processInfo.environment["AEROSWITCHER_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AeroSwitcher")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        logError("Couldn't create \(dir.path): \(error)")
    }
    return dir
}

func configFileURL() -> URL {
    appSupportDirectory().appendingPathComponent("config.json")
}

// The version of this build, read from the app's own Info.plist. Where each
// part comes from (see build.sh): the version is typed by hand in Info.plist,
// the build number is the git commit count, the commit is the short git hash
// (with "-dirty" when the build had uncommitted changes). Run without an app
// bundle (swift run) there is no Info.plist, so it says "dev build".
func appVersion() -> (version: String, build: String, commit: String)? {
    guard let info = Bundle.main.infoDictionary,
          let version = info["CFBundleShortVersionString"] as? String else { return nil }
    return (version, info["CFBundleVersion"] as? String ?? "?", info["AeroSwitcherCommit"] as? String ?? "?")
}

func appVersionText() -> String {
    guard let v = appVersion() else { return "AeroSwitcher dev build" }
    return "AeroSwitcher \(v.version) (build \(v.build), \(v.commit))"
}

func writeConfig(_ config: SwitcherConfig, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(config)
        try data.write(to: url)
    } catch {
        logError("Couldn't write default config to \(url.path): \(error)")
    }
}

// Collects everything wrong with one read of config.json, so it can all be
// shown together in one window (and still printed, for when the app runs
// from Terminal). Errors mean the file couldn't be used at all, warnings
// mean one part of it was ignored. Same split as AeroSpace's config.
final class ConfigReport {
    var errors: [String] = []
    var warnings: [String] = []
    // Only meaningful when there are errors: true if the settings from
    // before this reload are still in use, false if there was nothing to
    // keep (the app just started) and the built-in defaults are in use.
    var keptPreviousSettings = false

    var isClean: Bool { errors.isEmpty && warnings.isEmpty }

    func error(_ message: String) {
        errors.append(message)
        logError("Config error: \(message)")
    }

    func warning(_ message: String) {
        warnings.append(message)
        logWarn("Config warning: \(message)")
    }
}

// True when this launch created config.json because it didn't exist yet,
// which is the best sign there is of a first launch ever. Used only by the
// setup help window; set while `settings` is created at start-up.
var firstRunThisLaunch = false

// Reads and decodes config.json. nil means it couldn't be used at all (the
// reason is in `report`), and the caller decides what to fall back to.
func readConfigFile(report: ConfigReport) -> SwitcherConfig? {
    let url = configFileURL()
    if !FileManager.default.fileExists(atPath: url.path) {
        // First run — write out a real, ready-to-edit file (with keybind
        // defaults already filled in) instead of leaving you to guess the
        // format from scratch. "workspaces" starts empty on purpose; see
        // AeroSwitcher_Documentation.md for a filled-in example to copy from.
        writeConfig(defaultSwitcherConfig, to: url)
        firstRunThisLaunch = true  // the setup help window shows its welcome text (SetupHelp.swift)
        logInfo("Created \(url.path). Add your own workspace apps to it (see AeroSwitcher_Documentation.md for an example) and save it, AeroSwitcher picks up changes by itself.")
        return defaultSwitcherConfig
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        report.error("Couldn't read \(url.path): \(error.localizedDescription)")
        return nil
    }
    do {
        let config = try JSONDecoder().decode(SwitcherConfig.self, from: data)
        warnAboutUnknownKeys(in: data, report: report)
        return config
    } catch {
        report.error(describeDecodingError(error))
        return nil
    }
}

// Swift's JSON reading gives very general error messages ("the data
// couldn't be read because it isn't in the correct format"). This turns
// them into something that says WHERE in the file the problem is, e.g.
// "workspaces.Core[2].open is missing".
func describeDecodingError(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else { return error.localizedDescription }
    func path(_ keys: [CodingKey]) -> String {
        var result = ""
        for key in keys {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += (result.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return result.isEmpty ? "the file" : result
    }
    func expected(_ type: Any.Type) -> String {
        let name = "\(type)"
        if type == Bool.self { return "true or false" }
        if type == String.self { return "text in double quotes" }
        if name.hasPrefix("Array") { return "a list in [ ]" }
        if name.hasPrefix("Dictionary") { return "a group in { }" }
        return name
    }
    switch decodingError {
    case .typeMismatch(let type, let context):
        return "\(path(context.codingPath)) has the wrong kind of value, it should be \(expected(type))."
    case .valueNotFound(let type, let context):
        return "\(path(context.codingPath)) is empty (null), it should be \(expected(type))."
    case .keyNotFound(let key, let context):
        return "\(path(context.codingPath + [key])) is missing."
    case .dataCorrupted(let context):
        // A JSON typo (missing comma, extra bracket...) lands here. The
        // underlying error usually knows the line and column.
        let detail = (context.underlyingError as NSError?)?.userInfo["NSDebugDescription"] as? String
        return "config.json isn't valid JSON" + (detail.map { ": \($0)" } ?? ".") + " A common cause is a missing or extra comma."
    @unknown default:
        return decodingError.localizedDescription
    }
}

// Swift's JSON reading silently skips keys it doesn't know, so a typo like
// "showTileStatsText" would just quietly do nothing. AeroSpace warns about
// unknown keys in its config, so this does the same. Only checks spelling,
// the decode above already checked the values.
func warnAboutUnknownKeys(in data: Data, report: ConfigReport) {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    let topLevelKeys: Set = ["keybinds", "workspaces", "showTileStatusText", "icons", "autoReloadConfig"]
    let keybindKeys: Set = ["cycleNext", "cyclePrevious", "enterGreyedRow", "exitGreyedRow", "pageUp", "pageDown", "confirm", "cancel"]
    let appKeys: Set = ["name", "match", "open", "newWindowStyle", "icon"]
    for key in root.keys.sorted() where !topLevelKeys.contains(key) {
        report.warning("\"\(key)\" isn't a setting AeroSwitcher knows, so it's ignored. Check the spelling.")
    }
    if let keybinds = root["keybinds"] as? [String: Any] {
        for key in keybinds.keys.sorted() where !keybindKeys.contains(key) {
            report.warning("keybinds.\(key) isn't a keybind AeroSwitcher knows, so it's ignored. Check the spelling.")
        }
    }
    if let workspaces = root["workspaces"] as? [String: Any] {
        for workspace in workspaces.keys.sorted() {
            for (index, entry) in ((workspaces[workspace] as? [[String: Any]]) ?? []).enumerated() {
                for key in entry.keys.sorted() where !appKeys.contains(key) {
                    report.warning("workspaces.\(workspace)[\(index)].\(key) isn't an app setting AeroSwitcher knows, so it's ignored. Check the spelling.")
                }
            }
        }
    }
}

// Shared by both config.json sources of a custom icon — a per-app "icon"
// field inside "workspaces", and the standalone top-level "icons" dict —
// so there's exactly one place that expands `~`, loads the file, and
// warns if it didn't work, rather than two copies that could drift.
// `context` is just for that warning message, so it's clear which config
// entry the bad path came from.
func loadCustomIcon(path: String, context: String, report: ConfigReport) -> NSImage? {
    let expanded = (path as NSString).expandingTildeInPath
    if let image = NSImage(contentsOfFile: expanded) {
        return image
    }
    report.warning("\(context) has icon \"\(path)\", which couldn't be loaded as an image, so it's ignored.")
    return nil
}

func resolveLauncherApps(from config: SwitcherConfig, report: ConfigReport) -> [String: [LauncherApp]] {
    var result: [String: [LauncherApp]] = [:]
    // Sorted only so warnings come out in the same order every time.
    for workspace in config.workspaces.keys.sorted() {
        let apps = config.workspaces[workspace] ?? []
        result[workspace] = apps.map { entry in
            let script: [String]?
            switch entry.newWindowStyle?.lowercased() {
            case "finder": script = finderNewWindowScript
            case "terminal": script = terminalNewWindowScript
            case .some(let other):
                report.warning("workspace \"\(workspace)\", app \"\(entry.name)\" has newWindowStyle \"\(other)\", which isn't recognized (only \"finder\" or \"terminal\" are), so it's ignored.")
                script = nil
            case nil:
                script = nil
            }
            // Loaded once per (re)load, right here, rather than by path
            // every time a tile draws — a bad or missing path is only ever
            // reported once per load, instead of on every Cmd+Tab.
            let loadedIcon = entry.icon.flatMap {
                loadCustomIcon(path: $0, context: "workspace \"\(workspace)\", app \"\(entry.name)\"", report: report)
            }
            return LauncherApp(displayName: entry.name, matchKey: entry.match, openName: entry.open, newWindowScript: script, customIcon: loadedIcon)
        }
    }
    return result
}

// Everything the rest of the app needs from one successful read of
// config.json, worked out once per load instead of on every Cmd+Tab.
struct LoadedSettings {
    let config: SwitcherConfig
    let launcherApps: [String: [LauncherApp]]
    // Every config.json entry that set a custom icon, flattened across all
    // workspaces, matchKey paired with the already-loaded image.
    let customIcons: [(matchKey: String, icon: NSImage)]
    let keybinds: ResolvedKeybinds

    init(config: SwitcherConfig, report: ConfigReport) {
        self.config = config
        let launcherApps = resolveLauncherApps(from: config, report: report)
        self.launcherApps = launcherApps
        // Source 1: every "icon" set on a per-app entry inside "workspaces".
        // Source 2: config.json's standalone top-level "icons" dict — for an
        // app that isn't in "workspaces" at all, so there's no LauncherApp
        // entry for it to carry a customIcon on. This is the only source that
        // can give a custom icon to an app you haven't added as a launcher
        // tile anywhere.
        self.customIcons = launcherApps.values.flatMap { $0 }.compactMap { app in
            app.customIcon.map { (app.matchKey, $0) }
        } + standaloneIcons(config).sorted { $0.key < $1.key }.compactMap { (name, path) -> (String, NSImage)? in
            loadCustomIcon(path: path, context: "icons entry \"\(name)\"", report: report).map { (name, $0) }
        }
        self.keybinds = resolveKeybinds(config.keybinds, report: report)
    }
}

// MARK: - Reloading (same idea as AeroSpace's auto-reload-config)
//
// The one place the current settings live. It used to be a few global
// `let`s, worked out once at launch, so any change to config.json needed
// the app restarted. Now:
//   - Saving config.json reloads it within a moment (if autoReloadConfig
//     isn't turned off), like AeroSpace with `auto-reload-config = true`.
//   - `pkill -HUP AeroSwitcher` reloads AeroSwitcher AND AeroSpace together
//     and shows both results in one window (reloadTogether). That's the
//     command to bind to a key in .aerospace.toml, and what a menu bar
//     "Reload config" item will call later.
//   - A config.json that can't be read keeps the previous settings, a
//     partly wrong one applies the rest. Either way the problems window
//     opens, and closes by itself once a save has no problems left.
//
// Every read and every reload happens on the main thread (the event tap,
// the panel, the file watcher and the reload signal all run there), the
// lock is only a cheap safety net in case that ever changes.
final class SettingsStore {
    private let lock = NSLock()
    private var loaded: LoadedSettings
    // What the last load found, so the problems window can be shown at
    // launch once the app is far enough along to show windows.
    private(set) var lastReport: ConfigReport

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var reloadSignal: DispatchSourceSignal?
    private var pendingAutoReload: DispatchWorkItem?

    var current: LoadedSettings {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    init() {
        let report = ConfigReport()
        let config = readConfigFile(report: report)
        // Nothing to keep yet at launch, so a broken file means defaults
        // until it's fixed, same as before this existed (but now you're
        // told, instead of the tiles just quietly disappearing).
        loaded = LoadedSettings(config: config ?? defaultSwitcherConfig, report: report)
        lastReport = report
    }

    // Reads config.json again. On an error the current settings stay in
    // use; otherwise the new ones replace them right away, the next Cmd+Tab
    // already uses them.
    @discardableResult
    func reload() -> ConfigReport {
        let report = ConfigReport()
        if let config = readConfigFile(report: report) {
            let newSettings = LoadedSettings(config: config, report: report)
            lock.lock()
            loaded = newSettings
            lock.unlock()
            if report.isClean { logInfo("Reloaded config.json, no problems.") }
        } else {
            report.keptPreviousSettings = true
        }
        lastReport = report
        updateFileWatcher()
        // Tells the settings window (SettingsWindow.swift) to show what's
        // in the file now, e.g. right after you saved a hand edit.
        NotificationCenter.default.post(name: .configDidReload, object: nil)
        return report
    }

    // Called once at launch (main.swift), after the event tap is running.
    func startWatching() {
        updateFileWatcher()

        // SIGHUP is the classic "reload your settings" signal for programs
        // without a window. By default it quits the app, so that default is
        // switched off first and replaced with a reload.
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        source.setEventHandler { [weak self] in self?.reloadTogether() }
        source.resume()
        reloadSignal = source
    }

    // "Reload config" for both apps at once: AeroSwitcher's config.json,
    // and AeroSpace's ~/.aerospace.toml through `aerospace reload-config
    // --no-gui` (so AeroSpace doesn't open its own error window too). Both
    // results end up in the same problems window. AeroSpace's reload runs
    // off the main thread, it's a separate program and takes a moment.
    func reloadTogether() {
        logInfo("Reload requested: reloading config.json and AeroSpace's config together.")
        let report = reload()
        Task.detached {
            let aerospaceResult = reloadAeroSpaceConfig()
            await MainActor.run {
                ConfigProblemsWindow.shared.update(report: report, aerospace: aerospaceResult)
            }
        }
    }

    // Starts, keeps or stops watching config.json, depending on
    // autoReloadConfig. Watching means: macOS tells us when the file
    // changes, no checking over and over.
    private func updateFileWatcher() {
        let wanted = current.config.autoReloadConfig ?? true
        if !wanted {
            fileWatcher?.cancel()
            fileWatcher = nil
            return
        }
        if fileWatcher == nil { armFileWatcher(attempt: 0) }
    }

    private func armFileWatcher(attempt: Int) {
        let path = configFileURL().path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Right after an editor swapped the file (see below), there can
            // be a moment where it doesn't exist yet. Try again a few times.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.armFileWatcher(attempt: attempt + 1)
                }
            } else {
                // Added to the last report and shown in the problems window,
                // so it isn't only a line in the log nobody reads.
                // Two retry chains can run side by side after a file swap,
                // so the same warning is only added once.
                let message = "AeroSwitcher can't watch \(path) for changes, so saving it won't reload it by itself. Use Reload config in the menu, or restart AeroSwitcher."
                if !lastReport.warnings.contains(message) {
                    lastReport.warning(message)
                    MainActor.assumeIsolated {
                        ConfigProblemsWindow.shared.update(report: lastReport, aerospace: nil)
                    }
                }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // Many editors (TextEdit, VS Code with some settings) don't
            // change the file in place, they write a new copy and swap it
            // in. The file being watched is then gone, so watch the new one.
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                self.fileWatcher = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.armFileWatcher(attempt: 0)
                }
            }
            self.scheduleAutoReload()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatcher = source
    }

    // One save often arrives as several change events in a row; waiting a
    // moment and reloading once avoids reading a half-written file.
    private func scheduleAutoReload() {
        pendingAutoReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            logInfo("config.json changed, reloading.")
            let report = self.reload()
            MainActor.assumeIsolated {
                ConfigProblemsWindow.shared.update(report: report, aerospace: nil)
            }
        }
        pendingAutoReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

let settings = SettingsStore()

// MARK: - Editing config.json from the settings window
//
// The settings window (SettingsWindow.swift) changes config.json through
// editConfigFile below, never by writing out its own copy of the settings.
// That matters for three reasons:
//
//   - Your hand edits survive. Every change starts by reading the file as
//     it is RIGHT NOW, changes only the one part it's about (one keybind,
//     one workspace's tiles...), and writes that back. Something you saved
//     by hand a second ago, anywhere else in the file, is still there.
//   - Unknown keys survive. The file is read as plain JSON, not as
//     SwitcherConfig, so a key AeroSwitcher doesn't know (a typo you meant
//     to fix, a setting from a newer version) is kept instead of silently
//     dropped, the way Swift's normal decoding would.
//   - It can't break the file. The result is test-read as SwitcherConfig
//     before it's written, and a file that's already broken is never
//     overwritten (you fix it first).
//
// What does change: the file is written in one fixed layout (see
// houseStyleJSON), so the first save from the window tidies the spacing
// and key order of the whole file once. Values are never touched. The
// file as it was before that first save is kept as config.json.backup.

extension Notification.Name {
    // Posted after every reload of config.json: a save in your editor, a
    // `pkill -HUP`, or a change made by the settings window itself.
    static let configDidReload = Notification.Name("AeroSwitcherConfigDidReload")
}

// config.json as it is on disk right now, read two ways.
struct ConfigFileSnapshot {
    // As plain JSON, every key, known or not. This is what gets edited.
    let tree: [String: Any]?
    // Read the normal way, for showing it. nil = it wouldn't load.
    let config: SwitcherConfig?
    // Why it can't be used, in the same words as the problems window.
    // nil means the file is fine.
    let problem: String?
}

// The real file to write. If config.json is ever a symlink (some people
// keep settings in a dotfiles folder), the file it points to is written,
// otherwise the save below would replace the link with a plain file.
func configFileWriteURL() -> URL {
    configFileURL().resolvingSymlinksInPath()
}

func readConfigSnapshot() -> ConfigFileSnapshot {
    let url = configFileWriteURL()
    guard let data = try? Data(contentsOf: url) else {
        return ConfigFileSnapshot(tree: nil, config: nil, problem: "Couldn't read \(url.path).")
    }
    return configSnapshot(of: data)
}

func configSnapshot(of data: Data) -> ConfigFileSnapshot {
    let tree = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    do {
        let config = try JSONDecoder().decode(SwitcherConfig.self, from: data)
        return ConfigFileSnapshot(tree: tree, config: config,
                                  problem: tree == nil ? "config.json isn't a { } group at the top level." : nil)
    } catch {
        return ConfigFileSnapshot(tree: tree, config: nil, problem: describeDecodingError(error))
    }
}

// The value at a path like ["workspaces", "Dev"], or nil if it isn't there.
func configValue(at path: [String], in tree: [String: Any]) -> Any? {
    var current: Any? = tree
    for key in path {
        current = (current as? [String: Any])?[key]
    }
    return current
}

// Whether two pieces of plain JSON are the same (same keys, same values).
func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return (a as AnyObject).isEqual(b)
    default: return false
    }
}

enum ConfigEditOutcome {
    case saved
    case refused(String)  // why nothing was saved, shown in the window
}

// Only the first change in each run of the app makes the backup, so the
// backup is "the file before the window touched it", not "one change ago".
private var configBackupMadeThisRun = false

// The one way the settings window changes config.json.
//   description: what the change is, for the log ("set keybinds.confirm = g").
//   touching:    the parts of the file this change is about.
//   shownTree:   the file as the window last showed it. If one of the
//                `touching` parts is different in the file now, you edited
//                that same part by hand in the meantime, so nothing is
//                written and the window shows the new version instead.
//   change:      makes the change on the freshly read file.
@MainActor
func editConfigFile(_ description: String, touching paths: [[String]], shownTree: [String: Any],
                    change: (inout [String: Any]) -> Void) -> ConfigEditOutcome {
    let url = configFileWriteURL()
    guard let original = try? Data(contentsOf: url) else {
        return .refused("Couldn't read \(url.path), so nothing was changed.")
    }
    let before = configSnapshot(of: original)
    guard var tree = before.tree, before.problem == nil else {
        return .refused("config.json can't be read right now, so nothing was changed. Fix it first: \(before.problem ?? "unknown problem")")
    }
    for path in paths where !sameJSON(configValue(at: path, in: tree), configValue(at: path, in: shownTree)) {
        return .refused("config.json was changed meanwhile (\(path.joined(separator: "."))), so that wasn't saved. The window now shows the new version, please do it again.")
    }
    change(&tree)
    let data = Data(houseStyleJSON(tree).utf8)
    do {
        _ = try JSONDecoder().decode(SwitcherConfig.self, from: data)
    } catch {
        logWarn("Settings: refused \"\(description)\", the result wouldn't load: \(describeDecodingError(error))")
        return .refused("That change would leave config.json unable to load, so it wasn't saved. (\(describeDecodingError(error)))")
    }
    if !configBackupMadeThisRun {
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("config.json.backup")
        do {
            try original.write(to: backupURL, options: .atomic)
            configBackupMadeThisRun = true
            logInfo("Settings: copied config.json to \(backupURL.path) before the first change.")
        } catch {
            return .refused("Couldn't make the backup copy \(backupURL.path), so nothing was changed. (\(error.localizedDescription))")
        }
    }
    // .atomic writes a complete new file and swaps it in, so a reload can
    // never read a half-written file. The file watcher in SettingsStore
    // already copes with swapped-in files (editors do the same).
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        return .refused("Couldn't save config.json: \(error.localizedDescription)")
    }
    logInfo("Settings: \(description)")
    // Applied right away, even with autoReloadConfig turned off: that
    // setting is about hand edits, the window's changes always apply.
    let report = settings.reload()
    ConfigProblemsWindow.shared.update(report: report, aerospace: nil)
    return .saved
}

// MARK: The layout config.json is written in
//
// One fixed layout, close to how a hand-made config.json usually looks:
//
//   {
//     "keybinds" : {
//       "cycleNext" : "d",
//       ...
//     },
//     "workspaces" : {
//       "Core" : [
//         { "name" : "WhatsApp", "match" : "Whatsapp", "open" : "Whatsapp" },
//         ...
//       ]
//     },
//     "showTileStatusText" : false,
//     "icons" : {}
//   }
//
// Top level in the order below, then any keys AeroSwitcher doesn't know,
// alphabetically. Workspaces alphabetically. One line per app, keys in the
// order name, match, open, newWindowStyle, icon, then unknown ones. To
// change the layout, change the key orders here.

let topLevelKeyOrder = ["keybinds", "workspaces", "showTileStatusText", "autoReloadConfig", "icons"]
let keybindKeyOrder = ["cycleNext", "cyclePrevious", "enterGreyedRow", "exitGreyedRow", "pageUp", "pageDown", "confirm", "cancel"]
let appEntryKeyOrder = ["name", "match", "open", "newWindowStyle", "icon"]

func houseStyleJSON(_ tree: [String: Any]) -> String {
    let keys = orderedKeys(tree.keys, first: topLevelKeyOrder)
    let lines = keys.map { key -> String in
        let value = tree[key]!
        let rendered: String
        switch key {
        case "keybinds": rendered = jsonBlock(value, indent: 1, keyOrder: keybindKeyOrder)
        case "workspaces": rendered = workspacesBlock(value)
        default: rendered = jsonBlock(value, indent: 1, keyOrder: [])
        }
        return "  " + jsonFragment(key) + " : " + rendered
    }
    return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
}

// `first` in that order (only the ones present), then the rest A to Z.
private func orderedKeys(_ keys: Dictionary<String, Any>.Keys, first: [String]) -> [String] {
    first.filter { keys.contains($0) } + keys.filter { !first.contains($0) }.sorted()
}

// A group or list over several lines, `indent` levels deep. Anything else
// (text, a number, true/false) on one line.
private func jsonBlock(_ value: Any, indent: Int, keyOrder: [String]) -> String {
    let pad = String(repeating: "  ", count: indent)
    if let dict = value as? [String: Any] {
        if dict.isEmpty { return "{}" }
        let inner = orderedKeys(dict.keys, first: keyOrder).map {
            pad + "  " + jsonFragment($0) + " : " + jsonBlock(dict[$0]!, indent: indent + 1, keyOrder: [])
        }
        return "{\n" + inner.joined(separator: ",\n") + "\n" + pad + "}"
    }
    if let list = value as? [Any] {
        if list.isEmpty { return "[]" }
        let inner = list.map { pad + "  " + jsonBlock($0, indent: indent + 1, keyOrder: []) }
        return "[\n" + inner.joined(separator: ",\n") + "\n" + pad + "]"
    }
    return jsonFragment(value)
}

private func workspacesBlock(_ value: Any) -> String {
    guard let dict = value as? [String: Any], !dict.isEmpty else {
        return jsonBlock(value, indent: 1, keyOrder: [])
    }
    let inner = dict.keys.sorted().map { name -> String in
        let apps = dict[name]!
        guard let list = apps as? [Any], !list.isEmpty else {
            return "    " + jsonFragment(name) + " : " + jsonBlock(apps, indent: 2, keyOrder: [])
        }
        let rows = list.map { "      " + appEntryLine($0) }
        return "    " + jsonFragment(name) + " : [\n" + rows.joined(separator: ",\n") + "\n    ]"
    }
    return "{\n" + inner.joined(separator: ",\n") + "\n  }"
}

private func appEntryLine(_ entry: Any) -> String {
    guard let dict = entry as? [String: Any], !dict.isEmpty else { return jsonFragment(entry) }
    let parts = orderedKeys(dict.keys, first: appEntryKeyOrder).map { jsonFragment($0) + " : " + jsonFragment(dict[$0]!) }
    return "{ " + parts.joined(separator: ", ") + " }"
}

// One value written by Apple's own JSON writer on one line, so text is
// escaped correctly. withoutEscapingSlashes keeps icon paths readable
// ("~/Pictures/x.png", not "~\/Pictures\/x.png").
private func jsonFragment(_ value: Any) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
}

// MARK: Installed apps (the settings window's "Add app" list)

struct InstalledApp: Identifiable {
    let path: String
    let displayName: String  // what Finder shows, e.g. "Visual Studio Code"
    let fileName: String     // the .app's file name without ".app", what `open -a` takes
    let bundleName: String?  // the name inside the app, e.g. "Code"
    let bundleID: String?
    var id: String { path }
}

func installedApp(at path: String) -> InstalledApp {
    let info = Bundle(path: path)?.infoDictionary
    let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let shown = FileManager.default.displayName(atPath: path)
    return InstalledApp(
        path: path,
        displayName: shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown,
        fileName: fileName,
        bundleName: info?["CFBundleName"] as? String,
        bundleID: info?["CFBundleIdentifier"] as? String)
}

// Every app in the usual places, plus one folder deep (for apps that come
// in a folder, like "Utilities"). Finder lives somewhere else, so it's
// added by hand. Slow-ish (a few hundred apps), so the window runs it in
// the background.
func scanInstalledApps() -> [InstalledApp] {
    let fileManager = FileManager.default
    let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    var paths = ["/System/Library/CoreServices/Finder.app"]
    for root in roots {
        for item in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] where !item.hasPrefix(".") {
            let full = root + "/" + item
            if item.hasSuffix(".app") {
                paths.append(full)
                continue
            }
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: full, isDirectory: &isFolder), isFolder.boolValue else { continue }
            for inner in (try? fileManager.contentsOfDirectory(atPath: full)) ?? [] where inner.hasSuffix(".app") {
                paths.append(full + "/" + inner)
            }
        }
    }
    var seen = Set<String>()
    return paths
        .filter { seen.insert($0).inserted }
        .map(installedApp(at:))
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
}

// The config.json entry for a picked app. "match" has to be the name
// AeroSpace reports for the app's windows, and that's a guess for an app
// that isn't running: the bundle's own name is usually it, or a shorter
// part of it, which still works since matching is "contains" (Brave's
// bundle says "Brave", AeroSpace says "Brave Browser"). A running app's
// name is exactly what AeroSpace reports, so that's used when there is one.
// Every field can be fixed in the window's Advanced section.
func suggestedLauncherEntry(for app: InstalledApp) -> [String: Any] {
    let runningName = NSWorkspace.shared.runningApplications
        .first { $0.bundleURL?.standardizedFileURL.path == app.path }?.localizedName
    var entry: [String: Any] = [
        "name": app.displayName,
        "match": runningName ?? app.bundleName ?? app.fileName,
        "open": app.fileName,
    ]
    // The two apps that need their own "new window" script (see
    // LauncherApp.newWindowScript in DataModel.swift).
    switch app.bundleID {
    case "com.apple.finder": entry["newWindowStyle"] = "finder"
    case "com.apple.Terminal": entry["newWindowStyle"] = "terminal"
    default: break
    }
    return entry
}

// The names the rest of the app already used, now reading whatever is
// currently loaded instead of a value fixed at launch.
var appConfig: SwitcherConfig { settings.current.config }
var workspaceLauncherApps: [String: [LauncherApp]] { settings.current.launcherApps }
var customIconsByMatchKey: [(matchKey: String, icon: NSImage)] { settings.current.customIcons }

// The one place every icon shown anywhere in AeroSwitcher (the overview's
// real-window icons, its homeless-app icons, and — see LauncherCard — the
// greyed launcher row) checks first, before falling back to whatever it
// would've shown otherwise (the OS's own running-app icon, or the generic
// dashed placeholder). Keeps a custom icon set once in config.json
// consistent across every one of AeroSwitcher's own views, not just
// wherever it happened to be added first.
func customIcon(forAppName name: String) -> NSImage? {
    customIconsByMatchKey.first { namesMatch($0.matchKey, name) }?.icon
}

// The greyed launcher row's fallback for a tile with no customIcon set:
// this app's OWN real macOS icon, not a generic placeholder — nothing
// hardcoded to any particular app, this works off whatever "match"/"open"
// you actually typed into config.json, same as every other app-matching
// path in this file.
//
// Two-step, because a tile here might represent an app that's currently
// running (just with no window in this workspace) OR one that's fully
// quit, and only the first of those has a live process to ask:
//   1. If it's running anywhere right now, use THAT running instance's
//      actual icon — most accurate, and picks up anything dynamic (some
//      apps badge their Dock icon with a live count, for example).
//   2. Otherwise, ask Launch Services to resolve openName by name alone,
//      same as `open -a` already does to launch it, and read the icon off
//      the resolved app bundle on disk. Works even for a fully quit app.
// nil (falling through to the dashed placeholder) only happens if neither
// step finds anything at all — e.g. a typo in "open" that doesn't match
// any real installed app.
//
// fullPath(forApplication:) is Apple-deprecated but still functional as
// of this writing; there's no name-only replacement API (the modern ones
// all need a bundle identifier, which config.json never has), so this is
// a deliberate, working choice, not an accidental use of old API.
func resolvedAppIcon(matchKey: String, openName: String) -> NSImage? {
    if let running = NSWorkspace.shared.runningApplications.first(where: { app in
        guard let name = app.localizedName else { return false }
        return namesMatch(matchKey, name)
    }) {
        // Bundle-on-disk lookup rather than running.icon directly — same
        // reasoning as buildWorkspaceSummaries' icon(forAppName:pid:):
        // .icon can hand back a generic placeholder the first time it's
        // asked about a process, this is synchronous and always correct.
        if let path = running.bundleURL?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return running.icon
    }
    if let path = NSWorkspace.shared.fullPath(forApplication: openName) {
        return NSWorkspace.shared.icon(forFile: path)
    }
    return nil
}

// Every app configured for this workspace that ISN'T already one of the
// real, currently-open windows. Those are the ones that get a grayed tile.
func missingLauncherApps(workspace: String?, runningItems: [ThumbnailItem]) -> [LauncherApp] {
    guard let workspace = workspace, let roster = workspaceLauncherApps[workspace] else { return [] }
    return roster
        .filter { app in
            !runningItems.contains { $0.appName.localizedCaseInsensitiveContains(app.matchKey) }
        }
        // Alphabetical rather than whatever order they happen to be listed
        // in config.json — so the launcher row is always in the same,
        // predictable order regardless of how you've edited that file.
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
}

func namesMatch(_ a: String, _ b: String) -> Bool {
    a.localizedCaseInsensitiveContains(b) || b.localizedCaseInsensitiveContains(a)
}

// One running app with no window open anywhere on the Mac, and no
// config.json entry in any workspace either — see homelessRunningApps
// below for exactly what qualifies. lastWorkspace is whatever
// AppWorkspaceTracker remembers as the last workspace this app actually
// had a window in, if any — nil means AeroSwitcher has no history for it
// at all yet.
struct HomelessApp {
    let name: String
    let icon: NSImage?
    let lastWorkspace: String?
}

// Every "normal" running app (native Cmd+Tab's own definition — see the
// .regular filter below) that's genuinely homeless right now: NO window
// open anywhere on the whole Mac, AND not configured for any workspace in
// config.json either. Native macOS Cmd+Tab still shows a windowless app
// (picking one just activates it with nothing open); AeroSwitcher fully
// replaces Cmd+Tab, so without finding these explicitly, an app you closed
// the last window of (without quitting it) would just silently disappear —
// no real window to switch to, and no launcher tile either.
//
// The "not configured anywhere" half matters just as much as the
// "no window" half: an app that IS configured for some workspace (even a
// different one than you're currently looking at, e.g. WhatsApp under
// Core) already has a proper home — the instant you're actually on THAT
// workspace, it shows up there correctly as a normal "Running" tile via
// missingLauncherApps + isAppRunning, exactly like it always did. This is
// only meant to catch apps with nowhere else to show up at all, not to
// scatter every configured-but-windowless app across whichever workspace
// you happen to be browsing.
//
// Shared by both orphanedRunningApps (switcher tiles, below) and the
// Cmd+` overview's own handling of these, so there's exactly one place
// this detection lives rather than two copies that could quietly drift
// apart.
//
// `allWindows` should be the FULL cross-workspace window list, not just
// one workspace's — an app with a window somewhere else already has a way
// back to it (switch workspaces, or the overview), it's only "zero windows
// on the entire Mac" that's the real dead end this exists to fix.
func homelessRunningApps(allWindows: [AeroWindow], tracker: AppWorkspaceTracker) -> [HomelessApp] {
    let namesWithWindows = allWindows.map { $0.appName }
    let configuredAnywhere = workspaceLauncherApps.values.flatMap { $0 }.map { $0.matchKey }
    return NSWorkspace.shared.runningApplications
        // .regular excludes background helpers and menu-bar-only
        // utilities (which is also why AeroSwitcher itself, an .accessory
        // app, never shows up as one of its own tiles).
        .filter { $0.activationPolicy == .regular }
        .compactMap { app -> HomelessApp? in
            guard let name = app.localizedName else { return nil }
            guard !namesWithWindows.contains(where: { namesMatch($0, name) }) else { return nil }
            guard !configuredAnywhere.contains(where: { namesMatch($0, name) }) else { return nil }
            // Bundle-on-disk icon, same reasoning as icon(forAppName:pid:)
            // and resolvedAppIcon — app.icon can return a generic
            // placeholder the first time it's asked about a process.
            let icon = app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? app.icon
            return HomelessApp(name: name, icon: icon, lastWorkspace: tracker.workspace(for: name))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

// Homeless apps to show as extra launcher tiles on THIS workspace
// specifically. Shown here if AppWorkspaceTracker remembers this exact
// workspace as where it was last seen with a window — OR, if it has no
// history at all yet, it falls back to showing wherever you currently
// are, so a brand new homeless app still has somewhere to appear the
// very first time, before there's any history for it. Once AeroSwitcher
// has seen it with a window at least once, it sticks to that workspace
// specifically from then on, rather than following you around.
func orphanedRunningApps(allWindows: [AeroWindow], workspace: String?, tracker: AppWorkspaceTracker) -> [LauncherApp] {
    homelessRunningApps(allWindows: allWindows, tracker: tracker)
        .filter { $0.lastWorkspace == nil || $0.lastWorkspace == workspace }
        .map { LauncherApp(displayName: $0.name, matchKey: $0.name, openName: $0.name, isOrphaned: true) }
}

// windowCount is always 0 here, on purpose: that's exactly what
// WorkspaceAppIcon checks to render these visibly differently (dimmed,
// dashed) from apps that actually have a window open somewhere.
//
// customIcon(forAppName:) IS checked here, unlike you might expect —
// homelessRunningApps only excludes apps configured in "workspaces", but
// config.json's standalone "icons" dict is deliberately separate from
// that (see SwitcherConfig.icons), specifically so an app that ISN'T a
// launcher tile anywhere can still get a custom icon. So a homeless app
// absolutely can have one, just from that second source, not from
// "workspaces".
func homelessAppSummary(_ app: HomelessApp) -> WorkspaceAppSummary {
    WorkspaceAppSummary(appName: app.name, icon: customIcon(forAppName: app.name) ?? app.icon, windowCount: 0)
}

// Whether this app is running ANYWHERE on the Mac right now, not just in
// the current workspace. A greyed-out tile can mean two different things:
// the app is fully quit, or it's running fine with windows somewhere else
// (another workspace, or none at all), and those lead to different
// outcomes when you click the tile, so it's worth showing which one it is.
func isAppRunning(_ app: LauncherApp) -> Bool {
    NSWorkspace.shared.runningApplications.contains { running in
        guard let name = running.localizedName else { return false }
        return name.localizedCaseInsensitiveContains(app.matchKey)
    }
}

// Order for the greyed-out launcher row: three groups, not two. Orphaned
// "No window" tiles (apps that showed up here uninvited, but are at least
// genuinely running right now) come first, then actually-configured
// "Running" tiles (this workspace's own roster, just with a window
// somewhere else), then fully "Quit" tiles last — those are doing the
// least right now, no window anywhere AND not even open. Alphabetical
// within each of the three groups.
func sortedLauncherItems(_ apps: [LauncherApp]) -> [LauncherApp] {
    // Lower rank = earlier in the row.
    func rank(_ app: LauncherApp) -> Int {
        if app.isOrphaned { return 0 }      // "No window"
        return isAppRunning(app) ? 1 : 2    // "Running" then "Quit"
    }
    return apps.sorted { a, b in
        let (rankA, rankB) = (rank(a), rank(b))
        if rankA != rankB { return rankA < rankB }
        return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }
}

// Pairs a launcher tile with that running/quit status, purely for
// rendering. Selection still indexes into the plain [LauncherApp] roster
// on the controller, unchanged, this wrapper only exists on the way to the
// view.
struct LauncherTile: Identifiable {
    let app: LauncherApp
    let isRunning: Bool
    var id: String { app.id }
}

func launchApp(_ app: LauncherApp) {
    // Everything runs off the main actor: waiting for the command to finish
    // (needed to see whether it worked) would otherwise stall the UI thread
    // right as the panel is closing.
    Task.detached {
        let process = Process()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        if let script = app.newWindowScript {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = script.flatMap { ["-e", $0] }
            logInfo("launchApp: tile \"\(app.displayName)\" runs its new-window AppleScript")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", app.openName]
            // Which app macOS finds for this name. A launch that "worked" but
            // did nothing (Roblox Studio's tile started a hidden helper app
            // inside Studio and quit again) shows up here as a path inside
            // another .app, or as "no app found". The same deprecated lookup
            // as resolvedAppIcon, kept for the same reason: no other call
            // turns a plain name into an app. Only the app's file path is
            // logged, never a window title.
            let resolved = NSWorkspace.shared.fullPath(forApplication: app.openName) ?? "no app found by that name"
            logInfo("launchApp: tile \"\(app.displayName)\" runs open -a \"\(app.openName)\", macOS resolves that to \(resolved)")
        }
        let startedAt = Date()
        do {
            try process.run()
            // AppleScript errors (a bad property name, a typo, etc.) and a
            // wrong app name don't throw in Swift, the command just exits
            // non-zero and prints the reason to stderr. The Finder launcher
            // script silently failed exactly this way once already, so the
            // difference between "nothing happens, no idea why" and a real
            // message is this check.
            let errText = shortErrorText(String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            process.waitUntilExit()
            // Exit 0 only means the command was accepted. It says nothing about
            // whether a window then appeared.
            logInfo("launchApp: tile \"\(app.displayName)\" command finished, exit \(process.terminationStatus), \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
            guard process.terminationStatus != 0 else { return }
            logError("launchApp: \(app.newWindowScript == nil ? "open -a \(app.openName)" : "AppleScript for \(app.displayName)") failed (exit \(process.terminationStatus)): \(errText)")
            await MainActor.run {
                if app.newWindowScript == nil {
                    showFailureAlert("Couldn't open \(app.displayName)",
                        "macOS said: \(errText.isEmpty ? "no reason given" : errText)\n\nCheck the Open name of this tile in Settings > Launcher tiles. Details are in the log (Settings > General > Show log).")
                } else {
                    // -1743 is macOS saying AeroSwitcher may not control that app yet.
                    let notAllowed = errText.contains("-1743") || errText.lowercased().contains("not authorized")
                    showFailureAlert("Couldn't open a new \(app.displayName) window",
                        "macOS said: \(errText.isEmpty ? "no reason given" : errText)\n\n"
                        + (notAllowed ? "Allow AeroSwitcher to control \(app.displayName) in System Settings > Privacy & Security > Automation. " : "")
                        + "Details are in the log (Settings > General > Show log).")
                }
            }
        } catch {
            logError("launchApp: couldn't run \(app.newWindowScript == nil ? "open" : "osascript") for \(app.displayName): \(error)")
            await MainActor.run {
                showFailureAlert("Couldn't open \(app.displayName)", "AeroSwitcher couldn't start the command that opens apps. \(error.localizedDescription)")
            }
        }
    }
}
