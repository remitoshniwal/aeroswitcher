import Cocoa

// MARK: - Config file (~/Library/Application Support/AeroSwitcher/config.json)
//
// Everything below reads from a plain JSON file there, created automatically
// (empty keybinds/workspaces filled in with defaults, "workspaces" itself
// left blank) the very first time AeroSwitcher runs. Edit that file and
// relaunch the app any time — nothing here needs to change or be rebuilt
// for that.
//
// Two things live in it:
//   "keybinds"   — which key does what while the switcher panel is open
//                  (Cmd+Tab itself always opens it; these are what happens
//                  once it's already up).
//   "workspaces" — which apps show up as a launcher tile per AeroSpace
//                  workspace, same idea as the list this replaced.
//
// Two safety notes, since a config file is very easy to typo:
//   - A key name AeroSwitcher doesn't recognize falls back to that one
//     key's own default and prints which one, instead of silently doing
//     nothing or crashing.
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
    showTileStatusText: true  // written out explicitly so a fresh config.json shows it, instead of leaving the key out entirely
)

// ~/Library/Application Support/<AppName>/ is the standard place a Mac app
// is supposed to keep its own settings — it's where every well-behaved app
// puts this kind of file, and it stays out of your home folder's normal
// listing (Library is hidden by default), instead of a loose dotfile sitting
// directly in ~.
// Shared by configFileURL (below) and AppWorkspaceTracker — both files
// live in the same folder, so there's exactly one place that creates it.
func appSupportDirectory() -> URL {
    let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/AeroSwitcher")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        print("Couldn't create \(dir.path): \(error)")
    }
    return dir
}

func configFileURL() -> URL {
    appSupportDirectory().appendingPathComponent("config.json")
}

func writeConfig(_ config: SwitcherConfig, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(config)
        try data.write(to: url)
    } catch {
        print("Couldn't write default config to \(url.path): \(error)")
    }
}

func loadConfig() -> SwitcherConfig {
    let url = configFileURL()
    if !FileManager.default.fileExists(atPath: url.path) {
        // First run — write out a real, ready-to-edit file (with keybind
        // defaults already filled in) instead of leaving you to guess the
        // format from scratch. "workspaces" starts empty on purpose; see
        // AeroSwitcher_Documentation.md for a filled-in example to copy from.
        writeConfig(defaultSwitcherConfig, to: url)
        print("Created \(url.path). Add your own workspace apps to it (see AeroSwitcher_Documentation.md for an example) and relaunch AeroSwitcher to pick up changes.")
        return defaultSwitcherConfig
    }
    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SwitcherConfig.self, from: data)
    } catch {
        print("Couldn't read \(url.path) (\(error.localizedDescription)) — using default settings instead. Fix the JSON there and relaunch to pick up your changes.")
        return defaultSwitcherConfig
    }
}

let appConfig = loadConfig()

// Shared by both config.json sources of a custom icon — a per-app "icon"
// field inside "workspaces", and the standalone top-level "icons" dict —
// so there's exactly one place that expands `~`, loads the file, and
// warns if it didn't work, rather than two copies that could drift.
// `context` is just for that warning message, so it's clear which config
// entry the bad path came from.
func loadCustomIcon(path: String, context: String) -> NSImage? {
    let expanded = (path as NSString).expandingTildeInPath
    if let image = NSImage(contentsOfFile: expanded) {
        return image
    }
    print("Config: \(context) has icon \"\(path)\", which couldn't be loaded as an image — ignoring it.")
    return nil
}

func resolveLauncherApps(from config: SwitcherConfig) -> [String: [LauncherApp]] {
    var result: [String: [LauncherApp]] = [:]
    for (workspace, apps) in config.workspaces {
        result[workspace] = apps.map { entry in
            let script: [String]?
            switch entry.newWindowStyle?.lowercased() {
            case "finder": script = finderNewWindowScript
            case "terminal": script = terminalNewWindowScript
            case .some(let other):
                print("Config: workspace \"\(workspace)\", app \"\(entry.name)\" has newWindowStyle \"\(other)\", which isn't recognized (only \"finder\" or \"terminal\" are) — ignoring it.")
                script = nil
            case nil:
                script = nil
            }
            // Loaded once, right here, rather than by path every time a
            // tile draws — a bad or missing path only ever prints once, at
            // startup, instead of spamming on every Cmd+Tab.
            let loadedIcon = entry.icon.flatMap {
                loadCustomIcon(path: $0, context: "workspace \"\(workspace)\", app \"\(entry.name)\"")
            }
            return LauncherApp(displayName: entry.name, matchKey: entry.match, openName: entry.open, newWindowScript: script, customIcon: loadedIcon)
        }
    }
    return result
}

let workspaceLauncherApps: [String: [LauncherApp]] = resolveLauncherApps(from: appConfig)

// Every config.json entry that set a custom icon, flattened across all
// workspaces, matchKey paired with the already-loaded image. Built once
// here rather than re-scanning workspaceLauncherApps on every icon draw.
// Not `private` (which would hide it from every other file) only because
// main.swift touches it at launch, see "Start-up order" there. Nothing
// outside this file is meant to read it otherwise, use customIcon(forAppName:).
let customIconsByMatchKey: [(matchKey: String, icon: NSImage)] =
    // Source 1: every "icon" set on a per-app entry inside "workspaces".
    workspaceLauncherApps.values.flatMap { $0 }.compactMap { app in
        app.customIcon.map { (app.matchKey, $0) }
    }
    // Source 2: config.json's standalone top-level "icons" dict — for an
    // app that isn't in "workspaces" at all, so there's no LauncherApp
    // entry for it to carry a customIcon on. This is the only source that
    // can give a custom icon to an app you haven't added as a launcher
    // tile anywhere.
    + standaloneIcons(appConfig).compactMap { (name, path) -> (String, NSImage)? in
        loadCustomIcon(path: path, context: "icons entry \"\(name)\"").map { (name, $0) }
    }

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
    if let script = app.newWindowScript {
        // Run off the main actor, since waiting for osascript to finish
        // (needed below to actually see whether it succeeded) would
        // otherwise stall the UI thread right as the panel is closing.
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = script.flatMap { ["-e", $0] }
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                // AppleScript errors (a bad property name, a typo, etc.)
                // don't throw in Swift, osascript just exits non-zero and
                // prints the reason to stderr. The Finder launcher script
                // silently failed exactly this way once already, so this
                // print is the difference between "nothing happens, no
                // idea why" and an actual error message to go look up.
                if process.terminationStatus != 0 {
                    let errText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    print("launchApp: AppleScript for \(app.displayName) failed: \(errText)")
                }
            } catch {
                print("launchApp: couldn't run osascript for \(app.displayName): \(error)")
            }
        }
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", app.openName]
    try? process.run()
}

