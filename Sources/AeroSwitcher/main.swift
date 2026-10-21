import Cocoa
import SwiftUI
import ScreenCaptureKit

// GUI apps launched from Terminal don't always line-buffer stdout the way
// plain command-line tools do, which can make print() output show up late
// or out of order when you're trying to watch it live. Forcing line
// buffering here means every print() appears the moment it runs.
setvbuf(stdout, nil, _IOLBF, 0)

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

// MARK: - Thumbnail capture

// Card size on screen, in points. The capture resolution is derived from
// this, not a hardcoded pixel guess.
let cardSize = NSSize(width: 220, height: 140)

// How many real pixels one point is on this Mac's display (2.0 on Retina,
// 1.0 on older non-Retina screens). This is a `let` at file scope, so Swift
// only evaluates it once when the app launches, not on every Cmd+Tab press.
let displayScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0

// Capture at the display's real native resolution. We tried capping this
// below displayScale (first 1.5x, then 1x) to save time, but testing showed
// that made thumbnails blurrier WITHOUT making captures any faster — the
// real cost per window is ScreenCaptureKit's fixed overhead for compositing
// a window at all, not the pixel count. So there's no actual tradeoff being
// made here: capping resolution was a corner we didn't need to cut.
let captureScale: CGFloat = displayScale

// Target capture resolution: the card's point size converted to actual
// pixels for this display. Capturing a window at its full native size (a
// maximized Retina Chrome window can be 3000+ pixels wide) is the single
// biggest cost in this whole app, even though we only ever display it at
// cardSize. Rendering directly at this reduced size is both way less for
// ScreenCaptureKit to composite and less data to hand back to us.
let captureTargetSize = NSSize(width: cardSize.width * captureScale,
                                height: cardSize.height * captureScale)

@available(macOS 14.0, *)
func captureThumbnail(scWindow: SCWindow) async -> NSImage? {
    do {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()

        // Fit the window's real aspect ratio inside captureTargetSize so
        // nothing gets stretched.
        let srcW = max(scWindow.frame.width, 1)
        let srcH = max(scWindow.frame.height, 1)
        let aspect = srcW / srcH
        var outW = captureTargetSize.width
        var outH = captureTargetSize.width / aspect
        if outH > captureTargetSize.height {
            outH = captureTargetSize.height
            outW = captureTargetSize.height * aspect
        }
        config.width = max(1, Int(outW))
        config.height = max(1, Int(outH))
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    } catch {
        print("Capture failed: \(error)")
        return nil
    }
}

// Captures every window fresh, every time, concurrently rather than one at
// a time. No cache — every card you see is a real screenshot from the
// instant you pressed Cmd+Tab, nothing stale. What keeps this fast is
// captureThumbnail's small capture resolution above plus doing every
// window's capture in parallel here via withTaskGroup, not a cache trading
// correctness for speed.
@available(macOS 14.0, *)
func captureAll(_ windows: [AeroWindow], content: SCShareableContent?) async -> [ThumbnailItem] {
    guard let content = content else { return [] }

    var scByID: [CGWindowID: SCWindow] = [:]
    for w in content.windows {
        scByID[w.windowID] = w
    }

    let captured: [(AeroWindow, NSImage)] = await withTaskGroup(of: (AeroWindow, NSImage?).self) { group in
        for w in windows {
            group.addTask {
                guard let cgID = CGWindowID(w.id), let scWindow = scByID[cgID] else { return (w, nil) }
                return (w, await captureThumbnail(scWindow: scWindow))
            }
        }
        var collected: [(AeroWindow, NSImage)] = []
        for await (w, img) in group where img != nil {
            collected.append((w, img!))
        }
        return collected
    }

    var resultByID: [String: ThumbnailItem] = [:]
    for (w, img) in captured {
        resultByID[w.id] = ThumbnailItem(id: w.id, appPID: w.appPID, appName: w.displayName, image: img)
    }

    // Original (already MRU-sorted) order, dropping any window whose capture
    // failed outright rather than showing a broken card.
    return windows.compactMap { resultByID[$0.id] }
}

// MARK: - Data model

struct ThumbnailItem: Identifiable {
    let id: String
    let appPID: Int32       // the owning app's process ID — used to force real OS focus on Escape/pick/Cmd-release
    let appName: String     // display label, e.g. "Finder - Downloads"
    let image: NSImage
}

// One app's presence in one workspace, for the read-only overview panel
// (Cmd+`). No thumbnails here on purpose — just the app's own icon
// (instant, no screen capture involved) plus how many windows it has open
// in that workspace.
struct WorkspaceAppSummary: Identifiable {
    let appName: String
    let icon: NSImage?
    let windowCount: Int
    var id: String { appName }
}

// One workspace's section in the overview panel. apps is empty for a
// workspace with nothing open — the section still shows, just with no
// icons under it, so you can see at a glance which workspaces are free.
struct WorkspaceSummary: Identifiable {
    let name: String
    let apps: [WorkspaceAppSummary]
    var id: String { name }
}

// A workspace app that ISN'T currently open — shown as a grayed-out tile
// you can launch straight from the switcher instead of a live screenshot.
struct LauncherApp: Identifiable {
    let displayName: String  // shown under the grayed tile
    let matchKey: String     // substring checked against already-open windows' app names, to decide whether to hide this tile
    let openName: String     // passed to `open -a` to actually launch it
    // A handful of apps (Finder, Terminal) are single shared processes that
    // don't behave like normal apps when you ask macOS to open them: if a
    // window already exists ANYWHERE (even in a totally different
    // workspace), `open -a` just brings that existing window forward
    // instead of making a new one here. For those apps, this holds an
    // AppleScript (as separate osascript -e lines) that explicitly asks
    // for a brand new window instead. Leave it nil for every normal app.
    let newWindowScript: [String]?
    // True only for tiles orphanedRunningApps generated (an app running
    // with no window anywhere, showing up on whichever workspace you
    // happen to be on right now, not because it's actually configured for
    // this one). False for every normal, config-driven tile. LauncherCard
    // uses this to render the two visibly differently — otherwise an app
    // that's only here because it's windowless looks identical to one
    // that's actually supposed to belong to this workspace, which is
    // confusing (you'd reasonably wonder why it's showing up here at all).
    let isOrphaned: Bool
    // From config.json's optional "icon" field — a real image loaded once
    // when the config is resolved (see resolveLauncherApps). nil means "no
    // custom icon set," which falls back to the generic dashed placeholder
    // in LauncherCard. Only ever set for actually-configured tiles, never
    // for orphaned ones — those aren't in config.json at all, there's
    // nothing to load an icon from.
    let customIcon: NSImage?
    var id: String { displayName }

    init(displayName: String, matchKey: String, openName: String, newWindowScript: [String]? = nil, isOrphaned: Bool = false, customIcon: NSImage? = nil) {
        self.displayName = displayName
        self.matchKey = matchKey
        self.openName = openName
        self.newWindowScript = newWindowScript
        self.isOrphaned = isOrphaned
        self.customIcon = customIcon
    }
}

// Finder writes your "New Finder windows show" choice to its own
// preferences file, under the key NewWindowTarget (a short code like
// "PfHm" for home, "PfDe" for Desktop) plus NewWindowTargetPath (an actual
// file:// URL) for anything beyond those few named presets, Downloads and
// a custom folder both fall in that second bucket. Reading that file
// directly is far more reliable than the earlier attempt, which tried to
// ask FINDER ITSELF for this via AppleScript ("target of Finder
// preferences") — that property doesn't really exist in Finder's
// scripting dictionary, which is why it silently failed. This reads the
// real preference file instead, then just hands AppleScript the resolved
// path, sidestepping the guesswork entirely.
func finderDefaultNewWindowPath() -> String {
    let prefs = UserDefaults(suiteName: "com.apple.finder")
    let home = NSHomeDirectory()
    switch prefs?.string(forKey: "NewWindowTarget") {
    case "PfHm":
        return home
    case "PfDe":
        return "\(home)/Desktop"
    case "PfDo":
        return "\(home)/Documents"
    default:
        // Downloads, iCloud Drive, a custom folder, or anything else all
        // store the real destination here as a file:// URL, so trust this
        // over trying to guess every possible target code by name.
        if let pathString = prefs?.string(forKey: "NewWindowTargetPath"),
           let url = URL(string: pathString) {
            return url.path
        }
        return home
    }
}

private func buildFinderNewWindowScript() -> [String] {
    let path = finderDefaultNewWindowPath()
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return [
        "tell application \"Finder\" to set newWin to make new Finder window",
        "tell application \"Finder\" to set target of newWin to (POSIX file \"\(path)\" as alias)",
        "tell application \"Finder\" to activate",
    ]
}

// Resolved once, when AeroSwitcher starts up. If you change your Finder
// preference while AeroSwitcher is already running, it won't notice until
// the app restarts, an acceptable trade since that setting basically never
// changes mid-session.
let finderNewWindowScript = buildFinderNewWindowScript()

// `do script` with nothing to run opens a fresh window running your
// default shell — same fix your aerospace.toml's alt-enter binding already
// uses for Terminal.
//
// One extra wrinkle Finder doesn't have: Terminal can be fully quit (it's
// a normal app, not a background system process like Finder), and when
// it's cold, just launching it already opens Terminal's own default
// startup window on top of whatever `do script` creates — two windows
// for one click. `wasRunning` is checked BEFORE `activate` touches
// Terminal at all (checking `is running` never launches it, so this is a
// true "was it cold" read), and `do script` only fires when it's actually
// needed: either Terminal was already running (so the launch-time window
// never happened, whatever's onscreen is old news, always force a genuine
// new one — that's the whole point of this script existing), or it just
// cold-launched and, for whatever reason, still has zero windows (some
// setups don't auto-open one on startup). If it cold-launched AND already
// has a window from that launch, there's nothing left to do.
let terminalNewWindowScript = [
    """
    set wasRunning to application "Terminal" is running
    tell application "Terminal"
        activate
        if wasRunning or (count of windows) = 0 then
            tell (do script) to activate
        end if
    end tell
    """
]

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
private let customIconsByMatchKey: [(matchKey: String, icon: NSImage)] =
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

// MARK: - SwiftUI view

// Purely presentational: it just draws whatever rows it's handed for the
// CURRENT page. All the "how many rows fit, which page is that" math lives
// in SwitcherWindowController below, so there's exactly one place that
// logic can go wrong instead of two.
struct SwitcherView: View {
    let visibleRealRows: [[ThumbnailItem]]
    let visibleLauncherRows: [[LauncherTile]]
    let selectedItemID: String?
    let selectedLauncherID: String?
    let referenceWidth: CGFloat  // every row centers under this same width
    let maxWidth: CGFloat
    let panelHeight: CGFloat
    let pageIndex: Int
    let totalPages: Int
    let onPick: (ThumbnailItem) -> Void
    let onLaunch: (LauncherApp) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 16) {
                ForEach(Array(visibleRealRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row) { item in
                            ThumbnailCard(item: item, isSelected: item.id == selectedItemID) { onPick(item) }
                        }
                    }
                    .frame(width: referenceWidth, alignment: .center)
                }

                if !visibleLauncherRows.isEmpty {
                    // A thin divider so the "not running yet" row never
                    // looks like just another row of open windows — but
                    // only when there's actually a real-window row above it
                    // to divide from. With zero windows open (everything's
                    // greyed out), there's nothing to separate the launcher
                    // row from, so the line would just be floating there
                    // for no reason.
                    if !visibleRealRows.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: referenceWidth, height: 1)
                    }

                    ForEach(Array(visibleLauncherRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 16) {
                            ForEach(row) { tile in
                                LauncherCard(app: tile.app, isRunning: tile.isRunning, isSelected: tile.app.id == selectedLauncherID) {
                                    onLaunch(tile.app)
                                }
                            }
                        }
                        .frame(width: referenceWidth, alignment: .center)
                    }
                }

                // Little dots showing which page you're on, only shown once
                // there's more than one — most of the time this never
                // appears at all.
                if totalPages > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<totalPages, id: \.self) { i in
                            Circle()
                                .fill(i == pageIndex ? Color.white.opacity(0.9) : Color.white.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: maxWidth, height: panelHeight)
        .background(.ultraThinMaterial)                       // native frosted-glass blur, like the real Cmd+Tab
        .clipShape(RoundedRectangle(cornerRadius: 20))         // rounds the WHOLE panel, not just the cards
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)  // faint edge so it doesn't disappear on light backgrounds
        )
    }
}

private struct ThumbnailCard: View {
    let item: ThumbnailItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: cardSize.width, height: cardSize.height)
                .background(Color(white: 0.15))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                )
            Text(item.appName)
                .foregroundColor(.white)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardSize.width)  // never let a long title stretch the column
        }
        .frame(width: cardSize.width)  // pin the whole card's width too
        .onTapGesture(perform: onTap)
    }
}

// A grayed-out placeholder for an app that belongs to this workspace but
// doesn't have a window here right now. That covers two different
// situations that look identical otherwise: the app is fully quit, or it's
// running fine just with no window in THIS workspace (another workspace,
// or none anywhere). isRunning tells them apart, shown as a small dot
// under the icon (the same convention as the Dock) plus a text label,
// since the dot alone is easy to miss at this size.
//
// A THIRD situation looks identical to those two without extra help:
// app.isOrphaned tiles (from orphanedRunningApps) aren't configured for
// this workspace at all, they're just an app with no window anywhere,
// shown on whichever workspace you happened to be viewing. The "No window"
// caption is the main way you tell them apart from a real "belongs here"
// tile, plus a deliberately opposite dimming choice below: isOrphaned
// tiles get the LIGHTER treatment (they're not really supposed to be
// here, but they're at least genuinely running), while actually-configured
// tiles get dimmed HARDER — running or quit, either way it's the
// workspace's own roster doing the not-currently-open-here waiting, so
// that's the one that should visually recede, not the app that showed up
// uninvited. That dimming (see `dim` below) applies to the box, the
// running-dot, the selection ring, and both text labels — NOT the icon
// itself, which always renders at full brightness regardless of any of
// this, so it stays recognizable even on a greyed tile.
private struct LauncherCard: View {
    let app: LauncherApp
    let isRunning: Bool
    let isSelected: Bool
    let onTap: () -> Void

    // Everything on a greyed tile dims by this amount EXCEPT the icon
    // itself, which stays at full, undimmed brightness — an icon at 15-30%
    // opacity is hard to actually recognize at a glance, defeating the
    // point of showing a real one at all. Kept as one named value so the
    // box, running-dot, selection ring, and both text labels all still
    // dim by the exact same amount they always did, just no longer
    // multiplied into the icon too.
    private var dim: Double { app.isOrphaned ? 0.6 : 0.4 }

    var body: some View {
        VStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.15))
                .frame(width: cardSize.width, height: cardSize.height)
                // Applied here, BEFORE the icon's .overlay() below, on
                // purpose — SwiftUI's .opacity() only affects the view
                // it's directly attached to, not content added via a
                // LATER .overlay() call. That's exactly what keeps this
                // dimming scoped to just the box itself and lets the icon
                // (added next) render at full brightness on top of it.
                .opacity(dim)
                .overlay(
                    Group {
                        // Three-way fallback, in order:
                        //   1. app.customIcon — this SPECIFIC entry's own
                        //      per-workspace "icon" field. Since an app
                        //      configured in several workspaces (Finder
                        //      being the obvious one) is actually several
                        //      separate LauncherAppConfig entries, one per
                        //      workspace, this only ever covers the exact
                        //      entry that set it — a workspace whose copy
                        //      of that entry didn't set "icon" falls
                        //      through, even if some OTHER workspace's
                        //      copy did.
                        //   2. customIcon(forAppName:) — config.json's
                        //      standalone top-level "icons" dict, checked
                        //      by name rather than by entry, so it applies
                        //      the same everywhere regardless of which
                        //      workspace's copy of an app this tile is.
                        //      This used to be missing here entirely (only
                        //      the overview checked it), which meant a
                        //      standalone "icons" entry silently never
                        //      showed up on the greyed launcher row at
                        //      all — fixed now, both sources are checked
                        //      wherever AeroSwitcher shows an icon.
                        //   3. resolvedAppIcon — this app's own real macOS
                        //      icon, so every tile shows something
                        //      recognizable even with no config at all.
                        if let shown = app.customIcon ?? customIcon(forAppName: app.matchKey) ?? resolvedAppIcon(matchKey: app.matchKey, openName: app.openName) {
                            // No opacity on the icon itself, deliberately
                            // — see `dim` above. Full brightness, same as
                            // any other icon in the app.
                            Image(nsImage: shown)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 44, height: 44)
                        } else {
                            // Same reasoning — full white, not dimmed,
                            // even though this is the rarer placeholder
                            // case (only shown if resolvedAppIcon couldn't
                            // find anything at all, e.g. a typo in "open").
                            Image(systemName: "app.dashed")
                                .font(.system(size: 36))
                                .foregroundColor(.white)
                        }
                    }
                )
                .overlay(alignment: .bottom) {
                    if isRunning {
                        Circle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 5, height: 5)
                            .padding(.bottom, 6)
                            .opacity(dim)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                        .opacity(dim)
                )
            Text(app.displayName)
                .foregroundColor(.white.opacity(app.isOrphaned ? 0.5 : 0.35))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardSize.width)
                .opacity(dim)
            // Off by default's the other way around — this line only draws
            // at all if config.json's showTileStatusText is true (the
            // built-in default). Set it to false for quieter tiles that
            // just rely on the running-dot above instead.
            if shouldShowTileStatusText(appConfig) {
                Text(app.isOrphaned ? "No window" : (isRunning ? "Running" : "Quit"))
                    .foregroundColor(.white.opacity(0.3))
                    .font(.system(size: 10))
                    .opacity(dim)
            }
        }
        .frame(width: cardSize.width)
        .onTapGesture(perform: onTap)
    }
}

// The Cmd+` overview: every workspace, purely to look at, a few at a time.
// No selection, no clicking, no arrow keys — just app icons and how many
// windows each has open, per workspace, so you can see everything without
// hunting through the normal switcher one workspace at a time. Escape or
// letting go of Cmd just closes it. `workspaces` is already just the
// slice for the CURRENT page, already sized to fit — same "controller does
// the math, this just draws it" split as SwitcherView. width/height match
// the normal switcher's own maximum panel size exactly (see
// currentPanelViewAndSize()), so the two panels feel like one app. No
// scrolling, ever: paging with Tab/Shift+Tab or A/D keeps the whole thing
// keyboard-driven with your left hand, same as the normal switcher,
// rather than needing the mouse/trackpad to scroll.
struct WorkspacesOverviewView: View {
    let workspaces: [WorkspaceSummary]
    let pageIndex: Int
    let totalPages: Int
    let width: CGFloat
    let height: CGFloat

    private let iconSize: CGFloat = 48

    // Shared sizing constants — computeOverviewPages (on the controller)
    // uses these exact same numbers to estimate section heights, so a
    // card's real size and its estimated size never drift apart from each
    // other. Keeping them in one place here, rather than copied as magic
    // numbers in two spots, is what keeps that guaranteed.
    static let cardPadding: CGFloat = 12          // inside each card, every side
    static let cardGap: CGFloat = 14              // between one workspace's card and the next
    static let headerHeight: CGFloat = 24         // workspace name + spacing before its content
    static let iconRowHeight: CGFloat = 48 + 4 + 14  // icon + inner spacing + name label
    static let iconColumnWidth: CGFloat = 48 + 20    // iconSize + the grid's minimum column width
    static let iconSpacing: CGFloat = 16             // the grid's row AND column spacing
    // Every card is at least this tall — one header plus one icon row's
    // worth of space — even a workspace with nothing open at all. That's
    // what keeps every card the same height in the common case (nothing,
    // or few enough apps to fit one row), rather than empty ones looking
    // noticeably shorter than busy ones. A workspace with enough apps to
    // wrap onto a second icon row still grows taller than this, real
    // content is never clipped to force a uniform height.
    static let minCardContentHeight: CGFloat = headerHeight + iconRowHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Self.cardGap) {
            ForEach(workspaces) { workspace in
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.name)
                        .foregroundColor(.white.opacity(0.6))
                        .font(.system(size: 13, weight: .semibold))

                    // No "Nothing open" label — an empty card is just the
                    // name and blank space below it, at the same height a
                    // one-row card would be.
                    if !workspace.apps.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.iconColumnWidth), spacing: Self.iconSpacing)], alignment: .leading, spacing: Self.iconSpacing) {
                            ForEach(workspace.apps) { app in
                                WorkspaceAppIcon(app: app, iconSize: iconSize)
                            }
                        }
                    }
                }
                .frame(minHeight: Self.minCardContentHeight, alignment: .topLeading)
                .padding(Self.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A card per workspace, not just spacing between blocks of
                // text — makes it obvious at a glance where one workspace
                // ends and the next begins, especially once there are
                // several in a row.
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }

            Spacer(minLength: 0)

            // Same page-dots convention as the normal switcher, only shown
            // once there's more than one page.
            if totalPages > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == pageIndex ? Color.white.opacity(0.9) : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(24)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct WorkspaceAppIcon: View {
    let app: WorkspaceAppSummary
    let iconSize: CGFloat

    // windowCount is only ever 0 for homeless apps (homelessAppSummary) —
    // whether merged into their own remembered workspace's card, or
    // landing in the catch-all "Running, no window" section when
    // AeroSwitcher has no history for them at all. Every real
    // per-workspace app has at least one window by construction, so this
    // alone is enough to tell the two apart without a separate flag.
    private var isWindowless: Bool { app.windowCount == 0 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        // Dimmed, same convention the normal switcher's
                        // grayed-out launcher tiles already use for "not
                        // fully here" — here that means "running, but
                        // nothing to actually switch to."
                        .opacity(isWindowless ? 0.55 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.2))
                        .frame(width: iconSize, height: iconSize)
                }
                if isWindowless {
                    // A dashed ring around an otherwise-real icon reads as
                    // "present, but not solid" — distinct from both a
                    // normal icon (solid, full opacity) and the launcher
                    // row's fully-placeholder dashed-square icon (which
                    // means "not even running").
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: iconSize, height: iconSize)
                } else if app.windowCount > 1 {
                    Text("\(app.windowCount)")
                        .foregroundColor(.white)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .offset(x: 4, y: 4)
                }
            }
            Text(app.appName)
                .foregroundColor(.white.opacity(isWindowless ? 0.5 : 0.8))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: iconSize + 20)
        }
    }
}

// MARK: - Most-recently-used tracking

// AeroSpace itself already knows exactly when any window gets focus, down
// to the specific window ID (see the on-focus-changed line in
// ~/.aerospace.toml). Reading that is far more reliable than us trying to
// guess from app-level activation, it works correctly even for two windows
// of the exact same app.
//
// One small log file PER WORKSPACE, under /tmp/aerospace-mru/, rather than
// one shared file for the whole Mac. AeroSpace's hook only ever hands us
// the window ID directly, not which workspace it's in, so the hook itself
// asks `aerospace list-workspaces --focused` to figure out which file to
// append to. Splitting it this way isn't just about file size, it fixes a
// real correctness issue too: with one shared history, heavy switching in
// whatever workspace you're using right now could crowd out an older,
// less-visited workspace's own recency order entirely. Keeping each
// workspace's history separate means that can't happen, each one only
// ever competes with its own past, not everyone else's.
class MRUTracker {
    private let logDir = "/tmp/aerospace-mru"

    // Each workspace's own log file grows by one line every focus change
    // within it, forever, with nothing on the AeroSpace side to trim it.
    // We only ever care about the most recent handful of window IDs
    // anyway, so this is both how many we keep AND the cue for when it's
    // worth rewriting a file back down to size.
    private let maxRemembered = 300

    private func logPath(for workspace: String) -> String {
        "\(logDir)/\(workspace).log"
    }

    private func recentWindowIDs(workspace: String) -> [String] {
        let path = logPath(for: workspace)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var seen = Set<String>()
        var result: [String] = []
        for line in content.split(separator: "\n").reversed() {
            let id = line.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty && !seen.contains(id) {
                seen.insert(id)
                result.append(id)
                if result.count >= maxRemembered { break }  // no point reading further back than we'll ever use
            }
        }

        // Once a workspace's own file has grown enough to be worth the
        // trouble, rewrite it down to just the recent IDs we actually kept
        // above, so no single workspace's log can grow past a few hundred
        // short lines no matter how long the Mac's been on.
        if content.utf8.count > maxRemembered * 20 {
            let trimmed = result.reversed().joined(separator: "\n") + "\n"
            try? trimmed.write(toFile: path, atomically: true, encoding: .utf8)
        }

        return result
    }

    // Puts the most recently focused window(s) first, by actual window ID,
    // using just THIS workspace's own history. Anything we've never seen
    // focus falls back to AeroSpace's own order, at the end. If we don't
    // know the workspace (shouldn't normally happen), skip reordering
    // entirely rather than guessing.
    func sorted(_ windows: [AeroWindow], workspace: String?) -> [AeroWindow] {
        guard let workspace = workspace else { return windows }
        let recent = recentWindowIDs(workspace: workspace)
        func rank(_ id: String) -> Int {
            recent.firstIndex(of: id) ?? Int.max
        }
        return windows.enumerated().sorted { a, b in
            let ra = rank(a.element.id)
            let rb = rank(b.element.id)
            if ra != rb { return ra < rb }
            return a.offset < b.offset  // stable fallback
        }.map { $0.element }
    }
}

// Remembers which workspace each app was last actually seen with a window
// in — used only for "homeless" apps (running, no window anywhere, not
// configured for any workspace either; see homelessRunningApps below), so
// an app like Preview, closed while you were in Dev, keeps showing up
// specifically on Dev afterward instead of drifting to whichever workspace
// you simply happen to be browsing the next time you open the switcher.
//
// Updated opportunistically, not by a separate background hook: every
// time AeroSwitcher already fetches the full cross-workspace window list
// (both the normal switcher and the Cmd+` overview do this on every
// open), record() gets called with that snapshot. That's accurate as long
// as you're using AeroSwitcher normally — an app it's genuinely never seen
// with a window (freshly installed, or you haven't opened the switcher
// since launch) just has no entry yet, and callers fall back to something
// reasonable for that case themselves.
//
// Persisted as a small JSON file, same folder and same idea as
// config.json, so this survives quitting and relaunching AeroSwitcher,
// not just remembered for the current run.
class AppWorkspaceTracker {
    private let fileURL = appSupportDirectory().appendingPathComponent("app-workspaces.json")
    private var mapping: [String: String]  // app name (lowercased) -> workspace

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            mapping = decoded
        } else {
            mapping = [:]
        }
    }

    func workspace(for appName: String) -> String? {
        mapping[appName.lowercased()]
    }

    func record(_ windows: [AeroWindow]) {
        var changed = false
        for w in windows {
            let key = w.appName.lowercased()
            if mapping[key] != w.workspace {
                mapping[key] = w.workspace
                changed = true
            }
        }
        guard changed else { return }  // no point writing to disk when nothing actually moved
        do {
            try JSONEncoder().encode(mapping).write(to: fileURL)
        } catch {
            print("Couldn't save \(fileURL.path): \(error)")
        }
    }
}

// MARK: - Window management

// Bundles everything needed to render one page of the switcher: which real
// rows and launcher rows fall on it, plus the page number itself.
private struct PageData {
    let realRows: [[ThumbnailItem]]
    let launcherRows: [[LauncherTile]]
    let totalRowCount: Int
    let page: Int
    let totalPages: Int
}

@MainActor
class SwitcherWindowController: NSObject {
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    var items: [ThumbnailItem] = []
    var selectedIndex = 0
    var launcherItems: [LauncherApp] = []
    // nil while Tab-cycling real windows normally. Set to an index into
    // launcherItems the moment you press the down arrow to "enter" the
    // grayed-out row. Cmd+Tab / arrow-cycling real windows always resets
    // this back to nil first, so Tab can never land selection on a grayed
    // tile — that's what keeps them out of the normal cycling order.
    var launcherSelectedIndex: Int? = nil
    // Which page you're LOOKING at, when it's different from wherever your
    // selection currently is. nil means "just show whatever page contains
    // the current selection" (the normal, default behavior). Set only by
    // Page Up / Page Down, and cleared the instant selection moves again,
    // so browsing and picking never fight each other.
    var manualPageOverride: Int? = nil
    var isLoading = false
    var mru: MRUTracker?
    // Self-contained (unlike mru, nothing outside the controller needs
    // it), so it's just created here directly rather than wired in from
    // the app-entry Task.
    let appWorkspaceTracker = AppWorkspaceTracker()

    // True only for a session opened with Cmd+` (see handleOverviewKey) —
    // shows a read-only overview of every workspace at once (app icons +
    // window counts, no thumbnails, no selection) instead of the normal
    // interactive single-workspace switcher. Reset back to false at the
    // start of every normal Cmd+Tab session too, so it can never leak from
    // one session into the next.
    private(set) var showingAllWorkspaces = false
    // What the overview panel shows — rebuilt fresh every time it opens,
    // sorted alphabetically by workspace name.
    var workspaceSummaries: [WorkspaceSummary] = []
    // Workspace sections, already split into pages — each page packed with
    // as many sections as actually fit within the panel's height (same
    // budget as the normal switcher: windowMaxHeight()), computed fresh
    // every time the overview opens by computeOverviewPages(). Sections
    // vary in height (an app-heavy workspace needs more icon rows than an
    // empty one), so this is a greedy fit rather than a fixed count per
    // page — first page gets as many as fit, then the next page starts
    // fresh, same idea as the normal switcher packing rows into pages.
    private var overviewPages: [[WorkspaceSummary]] = []
    // Which page of workspaces the overview is currently showing. Reset to
    // 0 at the start of every overview session.
    private var overviewPageIndex = 0
    // Whatever window was actually focused right before the overview panel
    // took over, so Escape/Cmd-release can hand focus back to it. Only used
    // in overview mode — the normal switcher uses items.first for this
    // instead, since it already has the full window list.
    private var originalFocusedWindow: AeroWindow?

    private var isVisible = false
    var isOpen: Bool { isVisible }

    // True from the moment Cmd+Tab is first pressed until the session ends,
    // even while the window is still loading. isOpen alone isn't enough to
    // gate on: it only flips true once thumbnails finish loading and the
    // window actually appears, which is asynchronous. If Cmd got released
    // before that finished, checking isOpen would see "not open yet" and
    // silently ignore the release — that's the bug where the panel got
    // stuck on screen.
    private var sessionActive = false
    // If Cmd was released before we finished loading, act on it the instant
    // loading completes instead of leaving the panel open with nothing left
    // to close it.
    private var confirmPending = false
    // Set right before show() when a fresh normal-switcher session starts
    // with Shift held (Cmd+Shift+Tab from cold) — tells show() to land the
    // initial selection on the LAST window (least-recently-used) instead
    // of the second one, matching native macOS's own Cmd+Shift+Tab.
    private var pendingStartReversed = false

    // Single entry point for every Cmd+Tab / Cmd+Shift+Tab keydown — this
    // is back to matching native macOS Cmd+Tab exactly, now that Cmd+`
    // (see handleOverviewKey, below) is its own separate key for opening
    // the overview instead of sharing Tab with Shift:
    //   - Nothing open: Shift decides where you land — plain Cmd+Tab lands
    //     one window forward (the normal, most common case), Cmd+Shift+Tab
    //     lands on your least-recently-used window instead.
    //   - Already open: Shift always just means "go backward". In the
    //     normal switcher that's the previous window; in the overview
    //     (which has no window selection) Tab/Shift+Tab instead page
    //     through workspaces, same physical key as everything else that
    //     cycles through something.
    func handleTabPress(reverse: Bool) {
        guard sessionActive else {
            beginSession(startReversed: reverse)
            return
        }
        if showingAllWorkspaces {
            if reverse { overviewPageUp() } else { overviewPageDown() }
            return
        }
        if reverse { movePrevious() } else { moveNext() }
    }

    private func beginSession(startReversed: Bool) {
        guard !sessionActive else { moveNext(); return }  // shouldn't happen via handleTabPress, kept as a safe fallback
        sessionActive = true
        confirmPending = false
        showingAllWorkspaces = false
        pendingStartReversed = startReversed
        show()
    }

    // Cmd+` (backtick, no Shift) — the all-workspaces overview's own key,
    // completely separate from Cmd+Tab. Only does anything from cold;
    // pressed while a session (either switcher) is already open, it's
    // ignored rather than trying to switch modes mid-session.
    func handleOverviewKey() {
        guard !sessionActive else { return }
        sessionActive = true
        confirmPending = false
        showingAllWorkspaces = true
        overviewPageIndex = 0
        show()
    }

    // Called when Cmd is released. If the panel's already up, confirm and
    // close normally. If it's still loading, remember to act the moment it
    // finishes rather than leaving things stuck.
    func endSession() {
        guard sessionActive else { return }
        if isOpen {
            confirmSelection()
        } else {
            confirmPending = true
        }
    }

    private func show() {
        guard !isLoading else { return }
        isLoading = true

        if showingAllWorkspaces {
            showOverview()
            return
        }

        Task { @MainActor in
            defer { isLoading = false }
            guard #available(macOS 14.0, *) else { sessionActive = false; return }

            // Asking AeroSpace for the window list (a subprocess), asking
            // ScreenCaptureKit for its shareable-content snapshot, and
            // asking AeroSpace which workspace is focused don't depend on
            // each other, so kick off all three at once instead of waiting
            // for one to finish before starting the next. The AeroSpace
            // calls also run off the main actor so the subprocess wait
            // can't stall the UI.
            async let windowListTask = Task.detached { getWindows(scope: "focused") }.value
            // excludingDesktopWindows skips the wallpaper/desktop-icon layer
            // from the enumeration, never something you'd want in the
            // switcher anyway, so this is a free speedup. onScreenWindowsOnly
            // was tried too, but it silently drops any window you've
            // manually minimized (yellow button) since a minimized window
            // isn't technically "on screen" — since you do minimize things
            // sometimes, that trade wasn't worth it, so it's back to false.
            async let contentTask: SCShareableContent? = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            async let workspaceNameTask = Task.detached { getCurrentWorkspaceName() }.value
            // Needed for orphanedRunningApps below — has to be the FULL
            // cross-workspace list, not just this workspace's, since "zero
            // windows on the entire Mac" is what actually makes an app
            // unreachable, not just "zero windows here."
            async let allWindowsTask = Task.detached { getWindows(scope: "all") }.value

            // Used to bail out here the moment the workspace had zero real
            // windows open — but an empty workspace can still have greyed
            // launcher tiles worth showing (apps that belong there but
            // just aren't running yet), so keep going even when this is
            // empty and only actually give up once launcher tiles turn out
            // to be empty too, below.
            let rawWindows = await windowListTask
            // Awaited here (rather than later) so the MRU sort below knows
            // which workspace's own history to use. Costs nothing extra:
            // this task started concurrently with the others above, so by
            // now it's essentially always already finished.
            let workspaceName = await workspaceNameTask
            let windows = mru?.sorted(rawWindows, workspace: workspaceName) ?? rawWindows

            let content = await contentTask
            let loaded = await captureAll(windows, content: content)
            let configuredLauncherItems = missingLauncherApps(workspace: workspaceName, runningItems: loaded)
            let allWindows = await allWindowsTask
            // Keep the tracker current with today's real cross-workspace
            // snapshot before asking it anything, so orphanedRunningApps
            // below always sees the freshest "last known workspace" data.
            self.appWorkspaceTracker.record(allWindows)
            // Apps running with no window anywhere AND no config entry in
            // any workspace — added on top of your configured tiles rather
            // than replacing them, so a genuinely homeless running app is
            // never just invisible. Only shown here if this IS its
            // tracked workspace (or it has no tracked workspace yet); an
            // app configured for, or last seen in, a DIFFERENT workspace
            // is deliberately excluded — it already has (or will have) a
            // proper place to show up, it shouldn't also show up here.
            // sortedLauncherItems puts everything actually alive (Running
            // + orphaned "No window" tiles) ahead of fully Quit apps, so
            // the row reads left-to-right as "stuff you could jump
            // straight to" before "stuff that needs a fresh launch."
            self.launcherItems = sortedLauncherItems(configuredLauncherItems + orphanedRunningApps(allWindows: allWindows, workspace: workspaceName, tracker: self.appWorkspaceTracker))

            // Truly nothing to show at all — no real windows, no launcher
            // tiles either. Only now is there actually nothing to open for.
            guard !loaded.isEmpty || !self.launcherItems.isEmpty else { sessionActive = false; return }
            self.items = loaded

            self.manualPageOverride = nil  // fresh session always starts on the page your selection is on

            if loaded.isEmpty {
                // No real windows at all — land straight on the greyed
                // launcher row instead of trying to select a real window
                // that doesn't exist.
                self.selectedIndex = 0
                self.launcherSelectedIndex = 0
            } else {
                self.launcherSelectedIndex = nil
                // A single tap should already move OFF the window you're
                // on, same as native Cmd+Tab — the current window stays
                // first in the (unchanged) MRU order, but the highlight
                // starts one over. Cmd+Shift+Tab from cold instead lands on
                // the LAST window (least-recently-used), same as native
                // macOS's own Cmd+Shift+Tab.
                if self.pendingStartReversed {
                    self.selectedIndex = loaded.count - 1
                } else {
                    self.selectedIndex = loaded.count > 1 ? 1 : 0
                }
            }

            if confirmPending {
                // Cmd was already released while this was loading — jump
                // straight to confirming the selected tile (focusing a
                // window, or launching an app if it landed on the greyed
                // row), no need to ever flash the panel open for a press
                // this quick. confirmSelection() already resets
                // sessionActive/confirmPending via hide().
                confirmPending = false
                confirmSelection()
                return
            }

            self.present()
        }
    }

    // The Cmd+` overview: much lighter than the normal switcher since
    // there's no ScreenCaptureKit thumbnail capture involved at all, just
    // two AeroSpace CLI calls (the window list and the workspace list)
    // plus each app's own icon, which is instant.
    private func showOverview() {
        Task { @MainActor in
            defer { isLoading = false }

            // Captured BEFORE the panel takes over keyboard focus, so
            // Escape/Cmd-release can hand focus back to whatever you were
            // actually using — the overview itself never focuses anything.
            async let focusedTask = Task.detached { getFocusedWindow() }.value
            async let windowsTask = Task.detached { getWindows(scope: "all") }.value
            async let namesTask = Task.detached { getAllWorkspaceNames() }.value

            self.originalFocusedWindow = await focusedTask
            let windows = await windowsTask
            // Alphabetical rather than whatever order AeroSpace happens to
            // list workspaces in — so the overview's layout is always the
            // same and predictable, not dependent on definition order in
            // ~/.aerospace.toml or which ones you've visited recently.
            let names = await namesTask.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            // Keep the tracker current with today's real snapshot first,
            // same as the normal switcher does.
            self.appWorkspaceTracker.record(windows)
            let homeless = homelessRunningApps(allWindows: windows, tracker: self.appWorkspaceTracker)
            // Homeless apps with a remembered workspace merge straight
            // into that workspace's own card (as a dimmed, windowCount-0
            // entry — see WorkspaceAppIcon) instead of a separate section,
            // so Preview closed while you were on Dev shows up ON Dev,
            // same "stays where it came from" behavior as the switcher.
            let tracked = homeless.filter { $0.lastWorkspace != nil }
            let extraByWorkspace = Dictionary(grouping: tracked, by: { $0.lastWorkspace! })
                .mapValues { $0.map(homelessAppSummary) }
            var summaries = buildWorkspaceSummaries(allWorkspaceNames: names, windows: windows, extraApps: extraByWorkspace)

            // Only apps AeroSwitcher has genuinely never seen with a
            // window at all get the separate "Running, no window" section
            // — there's no workspace to credibly put those on. Only added
            // when there's actually at least one, so a Mac with nothing
            // truly homeless never shows an empty section for it.
            let untracked = homeless.filter { $0.lastWorkspace == nil }
            if !untracked.isEmpty {
                summaries.append(WorkspaceSummary(name: "Running, no window", apps: untracked.map(homelessAppSummary)))
            }
            self.workspaceSummaries = summaries
            self.overviewPages = computeOverviewPages(self.workspaceSummaries)

            guard !self.workspaceSummaries.isEmpty else { sessionActive = false; return }

            if confirmPending {
                // Nothing to "confirm" in a read-only panel — Cmd was
                // released before loading even finished, so just close
                // straight back up without ever flashing it open.
                confirmPending = false
                closeOverview()
                return
            }

            self.present()
        }
    }

    func moveNext() {
        guard !items.isEmpty else { return }
        launcherSelectedIndex = nil  // Tab always snaps back to the real windows
        manualPageOverride = nil     // ...and to whatever page that selection is actually on
        selectedIndex = (selectedIndex + 1) % items.count
        refresh()
    }

    func movePrevious() {
        guard !items.isEmpty else { return }
        launcherSelectedIndex = nil
        manualPageOverride = nil
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        refresh()
    }

    // Left/right arrow while focus is already on the grayed-out row —
    // moves between launcher tiles instead of real windows.
    func moveLauncherNext() {
        guard !launcherItems.isEmpty else { return }
        manualPageOverride = nil
        let current = launcherSelectedIndex ?? 0
        launcherSelectedIndex = (current + 1) % launcherItems.count
        refresh()
    }

    func moveLauncherPrevious() {
        guard !launcherItems.isEmpty else { return }
        manualPageOverride = nil
        let current = launcherSelectedIndex ?? 0
        launcherSelectedIndex = (current - 1 + launcherItems.count) % launcherItems.count
        refresh()
    }

    // Page Up / Page Down: jump to another page AND select its first tile
    // (real window or greyed launcher app, whichever the page starts with).
    // Earlier this only changed what was drawn without touching selection,
    // but that left pages you could land on with nothing highlighted at
    // all, no way to tell what Return would even do. Selecting the first
    // tile as you land fixes that, and it's just as fast to keep arrowing
    // from there if the one you want isn't first.
    func jumpPage(by delta: Int) {
        let data = pageData()
        guard data.totalPages > 1 else { return }
        let base = manualPageOverride ?? data.page
        let newPage = min(max(base + delta, 0), data.totalPages - 1)
        selectFirstItem(onPage: newPage)
        manualPageOverride = nil  // selection now lives on newPage, so normal auto-follow already shows it
        refresh()
    }

    private func selectFirstItem(onPage page: Int) {
        let realRows = chunk(items)
        let launcherRows = chunk(launcherItems)
        let startRow = page * maxRows
        if startRow < realRows.count {
            launcherSelectedIndex = nil
            selectedIndex = min(startRow * capacity, max(items.count - 1, 0))
        } else {
            let launcherRowIndex = startRow - realRows.count
            guard launcherRowIndex < launcherRows.count else { return }
            launcherSelectedIndex = min(launcherRowIndex * capacity, max(launcherItems.count - 1, 0))
        }
    }

    // Confirms whatever is currently selected, whether that's a real window
    // or a launcher tile. Used by both the Return key and by releasing Cmd,
    // so the two can never disagree about what "confirm" means. The
    // overview panel is read-only, so there's nothing to "confirm" there —
    // Cmd-release/Return/F just close it, same as Escape.
    func confirmSelection() {
        if showingAllWorkspaces { closeOverview(); return }
        if let idx = launcherSelectedIndex, launcherItems.indices.contains(idx) {
            launchApp(launcherItems[idx])
            hide()
            return
        }
        // Even with nothing to focus, still close the panel — leaving it
        // open here would strand it in a state where the session never
        // properly ends, and Cmd+Tab afterward would think a session was
        // already running instead of starting a fresh one.
        guard !items.isEmpty else { hide(); return }
        focusWindow(id: items[selectedIndex].id, pid: items[selectedIndex].appPID)
        hide()
    }

    // Shared by Escape and by confirmSelection() while the overview is
    // open — both mean the same thing in a read-only panel, just hand
    // focus back to whatever was actually focused before it opened.
    private func closeOverview() {
        if let original = originalFocusedWindow {
            focusWindow(id: original.id, pid: original.appPID)
        }
        hide()
    }

    private var overviewTotalPages: Int { max(1, overviewPages.count) }

    // Just the workspaces that belong on the CURRENT overview page —
    // WorkspacesOverviewView only ever draws whatever it's handed, all the
    // "which page has what" math (computeOverviewPages, below) already ran
    // once when the overview opened.
    private func overviewPageSlice() -> [WorkspaceSummary] {
        guard overviewPageIndex < overviewPages.count else { return [] }
        return overviewPages[overviewPageIndex]
    }

    // Tab/Shift+Tab and A/D (your configured cycleNext/cyclePrevious) page
    // through the overview — same physical keys as everything else that
    // cycles through something in this app, rather than a separate set
    // just for this one panel.
    func overviewPageUp() {
        guard overviewTotalPages > 1 else { return }
        overviewPageIndex = max(overviewPageIndex - 1, 0)
        refresh()
    }

    func overviewPageDown() {
        guard overviewTotalPages > 1 else { return }
        overviewPageIndex = min(overviewPageIndex + 1, overviewTotalPages - 1)
        refresh()
    }

    // Estimates roughly how tall one workspace section will render at, so
    // computeOverviewPages can decide how many fit per page — same idea as
    // rowHeight for the normal switcher, just for a section whose height
    // actually varies (more apps wrap onto more icon rows), rather than a
    // single fixed constant. These numbers mirror WorkspacesOverviewView's
    // own layout (icon size, fonts, spacing) closely enough to be a good
    // estimate without needing SwiftUI to actually measure anything ahead
    // of time.
    private func estimatedOverviewSectionHeight(_ workspace: WorkspaceSummary, availableWidth: CGFloat) -> CGFloat {
        // Each workspace renders inside its own card (see
        // WorkspacesOverviewView) with cardPadding on every side, so that
        // padding counts toward the section's real height, and the inner
        // content (the icon grid) has cardPadding less width to work with
        // on the left AND right than the full available width. Every card
        // also has a shared minimum height (minCardContentHeight) so an
        // empty workspace's card isn't visibly shorter than a busy one's.
        let cardPadding = WorkspacesOverviewView.cardPadding
        let innerWidth = availableWidth - cardPadding * 2
        if workspace.apps.isEmpty {
            return WorkspacesOverviewView.minCardContentHeight + cardPadding * 2
        }
        let columnWidth = WorkspacesOverviewView.iconColumnWidth
        let spacing = WorkspacesOverviewView.iconSpacing
        let columns = max(1, Int((innerWidth + spacing) / (columnWidth + spacing)))
        let iconRows = Int(ceil(Double(workspace.apps.count) / Double(columns)))
        let gridHeight = CGFloat(iconRows) * WorkspacesOverviewView.iconRowHeight + CGFloat(max(iconRows - 1, 0)) * spacing
        let contentHeight = max(WorkspacesOverviewView.minCardContentHeight, WorkspacesOverviewView.headerHeight + gridHeight)
        return contentHeight + cardPadding * 2
    }

    // Packs workspace sections into pages, greedily filling each page with
    // as many as actually fit within the panel's height budget before
    // starting the next — matches the normal switcher's own row-packing
    // philosophy (pageData()), just generalized to sections of unequal
    // height instead of uniform rows.
    //
    // Non-empty workspaces are packed first, empty ones are packed
    // separately afterward and always start on a fresh page — so a
    // "Nothing open" card never sits in the middle of a page next to
    // workspaces that actually matter, and once you've scrolled past the
    // busy ones, that's it, everything after is empty. `workspaces` is
    // already alphabetical coming in (see showOverview), and that order is
    // preserved within each of the two groups.
    private func computeOverviewPages(_ workspaces: [WorkspaceSummary]) -> [[WorkspaceSummary]] {
        let sectionSpacing = WorkspacesOverviewView.cardGap  // must match the view's own VStack spacing
        let panelPadding: CGFloat = 48     // 24pt top + bottom
        let dotsReserve: CGFloat = 22      // room for the page dots, reserved whether or not they end up shown
        let availableWidth = windowMaxWidth() - panelPadding
        let availableHeight = windowMaxHeight() - panelPadding - dotsReserve

        func pack(_ list: [WorkspaceSummary]) -> [[WorkspaceSummary]] {
            var pages: [[WorkspaceSummary]] = []
            var currentPage: [WorkspaceSummary] = []
            var currentHeight: CGFloat = 0

            for workspace in list {
                let sectionHeight = estimatedOverviewSectionHeight(workspace, availableWidth: availableWidth)
                let neededHeight = currentPage.isEmpty ? sectionHeight : currentHeight + sectionSpacing + sectionHeight
                if !currentPage.isEmpty && neededHeight > availableHeight {
                    pages.append(currentPage)
                    currentPage = [workspace]
                    currentHeight = sectionHeight
                } else {
                    currentPage.append(workspace)
                    currentHeight = neededHeight
                }
            }
            if !currentPage.isEmpty { pages.append(currentPage) }
            return pages
        }

        let nonEmpty = workspaces.filter { !$0.apps.isEmpty }
        let empty = workspaces.filter { $0.apps.isEmpty }
        return pack(nonEmpty) + pack(empty)
    }

    var rowHeight: CGFloat {
        cardSize.height + 40  // thumbnail + label + spacing
    }

    private func windowMaxWidth() -> CGFloat {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1200
        return screenWidth * 0.85
    }

    private func windowMaxHeight() -> CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return screenHeight * 0.8
    }

    private let columnSpacing: CGFloat = 16
    private var columnStride: CGFloat { cardSize.width + columnSpacing }

    // How many columns comfortably fit without scrolling, computed fresh
    // from the current screen size every time.
    private var capacity: Int {
        max(1, Int(windowMaxWidth() / columnStride))
    }

    // How many rows comfortably fit vertically, same idea as capacity but
    // for height. Once there are more rows than this, they spill onto
    // additional pages instead of making the panel taller than the screen.
    private var maxRows: Int {
        max(1, Int(windowMaxHeight() / rowHeight))
    }

    private func chunk<T>(_ array: [T]) -> [[T]] {
        guard capacity > 0, !array.isEmpty else { return [] }
        return stride(from: 0, to: array.count, by: capacity).map {
            Array(array[$0..<min($0 + capacity, array.count)])
        }
    }

    // The single source of truth for "what does the panel look like right
    // now": every real-window row, then the launcher row(s) right after
    // them, split into pages of maxRows rows each, then sliced down to
    // whichever page should currently be visible. That page defaults to
    // wherever the current selection lives, unless manualPageOverride says
    // otherwise.
    private func pageData() -> PageData {
        let realRows = chunk(items)
        let launcherRows = chunk(launcherItems)
        let totalRowCount = realRows.count + launcherRows.count
        let totalPages = max(1, Int(ceil(Double(max(totalRowCount, 1)) / Double(maxRows))))

        let selectedRealRow = items.isEmpty ? 0 : selectedIndex / max(1, capacity)
        let selectedLauncherRow: Int? = {
            guard let idx = launcherSelectedIndex, !launcherRows.isEmpty else { return nil }
            return realRows.count + (idx / max(1, capacity))
        }()
        let derivedRow = selectedLauncherRow ?? selectedRealRow
        let derivedPage = derivedRow / maxRows

        let page = min(manualPageOverride ?? derivedPage, totalPages - 1)
        let startRow = page * maxRows
        let endRow = min(startRow + maxRows, totalRowCount)

        var visibleReal: [[ThumbnailItem]] = []
        var visibleLauncher: [[LauncherTile]] = []
        if startRow < endRow {
            for rowIdx in startRow..<endRow {
                if rowIdx < realRows.count {
                    visibleReal.append(realRows[rowIdx])
                } else {
                    // Only worth checking isAppRunning for tiles actually
                    // shown on this page, not the whole roster every time.
                    let appsRow = launcherRows[rowIdx - realRows.count]
                    visibleLauncher.append(appsRow.map { LauncherTile(app: $0, isRunning: isAppRunning($0)) })
                }
            }
        }

        return PageData(realRows: visibleReal, launcherRows: visibleLauncher,
                         totalRowCount: totalRowCount, page: page, totalPages: totalPages)
    }

    private func rowWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return CGFloat(columnStride) }
        return CGFloat(count) * cardSize.width + CGFloat(count - 1) * columnSpacing
    }

    // Window is exactly as wide as it needs to be for however many columns
    // your current item count actually uses, capped at windowMaxWidth().
    // Beyond the cap, each row scrolls horizontally instead of growing.
    private func windowWidth() -> CGFloat {
        let columnsUsed = min(max(items.count, launcherItems.count, 1), capacity)
        return min(rowWidth(columnsUsed) + 48, windowMaxWidth())
    }

    private func currentView() -> SwitcherView {
        let data = pageData()
        let selectedItemID = items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
        let selectedLauncherID = launcherSelectedIndex.flatMap {
            launcherItems.indices.contains($0) ? launcherItems[$0].id : nil
        }
        let referenceColumns = min(max(items.count, launcherItems.count, 1), capacity)

        // Sized to what's actually on THIS page, not the tallest possible
        // page. A trailing page that's just the launcher row would otherwise
        // get stretched to full maxRows height, leaving a big empty gap
        // under one lone row of tiles.
        let effectiveRows = max(data.realRows.count + data.launcherRows.count, 1)
        // The divider itself only renders when there's a real row AND a
        // launcher row on this page — matches SwitcherView's own condition
        // exactly, so the reserved space and the actual drawn line never
        // disagree.
        let dividerAllowance: CGFloat = (!data.realRows.isEmpty && !data.launcherRows.isEmpty) ? 17 : 0
        let dotsAllowance: CGFloat = data.totalPages > 1 ? 22 : 0
        let height = rowHeight * CGFloat(effectiveRows) + dividerAllowance + dotsAllowance + 48

        return SwitcherView(
            visibleRealRows: data.realRows,
            visibleLauncherRows: data.launcherRows,
            selectedItemID: selectedItemID,
            selectedLauncherID: selectedLauncherID,
            referenceWidth: rowWidth(referenceColumns),
            maxWidth: windowWidth(),
            panelHeight: height,
            pageIndex: data.page,
            totalPages: data.totalPages,
            onPick: { [weak self] item in
                focusWindow(id: item.id, pid: item.appPID)
                self?.hide()
            },
            onLaunch: { [weak self] app in
                launchApp(app)
                self?.hide()
            }
        )
    }

    // Whichever panel is actually showing right now, type-erased to AnyView
    // since the two are completely different view trees (SwitcherView for
    // the normal switcher, WorkspacesOverviewView for the read-only
    // overview) hosted in the same NSHostingView. Also hands back the size
    // that view wants, computed alongside it so both stay in sync.
    private func currentPanelViewAndSize() -> (AnyView, NSSize) {
        if showingAllWorkspaces {
            // Same maximum footprint as the normal switcher, not a size of
            // its own — so the two panels feel like the same app, and
            // computeOverviewPages() (which already budgeted against these
            // same two numbers) and this stay in agreement.
            let size = NSSize(width: windowMaxWidth(), height: windowMaxHeight())
            let view = WorkspacesOverviewView(
                workspaces: overviewPageSlice(),
                pageIndex: overviewPageIndex,
                totalPages: overviewTotalPages,
                width: size.width,
                height: size.height
            )
            return (AnyView(view), size)
        }
        let view = currentView()
        return (AnyView(view), NSSize(width: windowWidth(), height: view.panelHeight))
    }

    // Creates the NSWindow and its SwiftUI host ONCE, the very first time
    // the switcher is opened, and reuses both on every later open. Tearing
    // down and rebuilding a whole window and view hierarchy on every single
    // Cmd+Tab press is allocation work that just isn't necessary, updating
    // an existing window's size and content is far cheaper.
    // A plain, borderless NSWindow can never become the "key" window (the
    // one that actually receives keyboard events) — that's an AppKit
    // default, not a bug. It's why the panel could show thumbnails and
    // react to clicks the whole time, but every arrow key, Return, and
    // Escape press was silently going nowhere. This tiny subclass just
    // says "yes, I can become key" so keyboard input actually reaches it.
    class SwitcherPanel: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private func ensureWindow() -> (NSWindow, NSHostingView<AnyView>) {
        if let window = window, let hostingView = hostingView {
            return (window, hostingView)
        }
        let (panelView, _) = currentPanelViewAndSize()
        let hosting = NSHostingView(rootView: panelView)
        let win = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.contentView = hosting
        self.window = win
        self.hostingView = hosting
        return (win, hosting)
    }

    private func present() {
        let (win, hosting) = ensureWindow()
        let (panelView, size) = currentPanelViewAndSize()

        // .rootView (rather than swapping in a new NSHostingView) lets
        // SwiftUI diff against what's already on screen instead of building
        // the whole view tree from nothing.
        hosting.rootView = panelView
        hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        win.setContentSize(size)
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    // Navigation used to live in a local NSEvent keyDown monitor here,
    // which needs this window to be the genuine OS-level key window to
    // ever fire. For a background/accessory app (no Dock icon) that's
    // surprisingly unreliable — the app can report itself as active and
    // key internally while the WindowServer doesn't actually agree, and
    // when that happens a local monitor just silently never fires, even
    // though everything looks focused from the inside. HotkeyManager's
    // global tap doesn't have that problem: it already reliably sees every
    // key regardless of focus state (that's how Tab and Cmd-release always
    // worked), so these are called from there instead, directly, while a
    // session is open — named after what each key DOES rather than which
    // physical key triggers it, since that's fully configurable now (see
    // config.json).
    func cycleForward() {
        if launcherSelectedIndex != nil { moveLauncherNext() } else { moveNext() }
    }

    func cycleBackward() {
        if launcherSelectedIndex != nil { moveLauncherPrevious() } else { movePrevious() }
    }

    // Jump onto the grayed-out row, if there's anything there
    func enterGreyedRow() {
        guard !launcherItems.isEmpty else { return }
        launcherSelectedIndex = 0
        manualPageOverride = nil
        refresh()
    }

    // Jump back off the grayed-out row. Only if there's an actual
    // real-window row to land on — with none open at all (an empty
    // workspace), there'd be nothing left selected at all otherwise.
    func exitGreyedRow() {
        guard launcherSelectedIndex != nil, !items.isEmpty else { return }
        launcherSelectedIndex = nil
        manualPageOverride = nil
        refresh()
    }

    // Escape — cancel, and hand focus back to whatever you were on.
    // items.first is always the window you were originally on (MRU-sorted,
    // never reordered by Tab-cycling). The overview panel has no items
    // (it never captures thumbnails), so it uses originalFocusedWindow
    // instead, via the same closeOverview() confirmSelection() also uses.
    func cancelSession() {
        if showingAllWorkspaces { closeOverview(); return }
        if let original = items.first {
            focusWindow(id: original.id, pid: original.appPID)
        }
        hide()
    }

    // Called by the normal switcher's own navigation (cycleForward,
    // enterGreyedRow, jumpPage, ...) and by the overview's own paging
    // (overviewPageUp/Down) — currentPanelViewAndSize() already knows
    // which of those is relevant based on showingAllWorkspaces.
    func refresh() {
        let (panelView, size) = currentPanelViewAndSize()
        hostingView?.rootView = panelView
        // Height can change page to page (a launcher row's divider only
        // shows up on the page it's actually on) and width can change with
        // item count, so keep the real window frame in sync too, not just
        // the SwiftUI content.
        if window?.frame.size != size {
            window?.setContentSize(size)
            window?.center()
        }
    }

    func hide() {
        window?.orderOut(nil)  // hidden, not destroyed — ensureWindow() reuses it next time
        isVisible = false
        sessionActive = false
        confirmPending = false
    }
}

// MARK: - Keybind resolution

// Translates the human-readable key names used in config.json
// (like "d" or "space") into the raw numeric codes macOS actually uses for
// keys. Only the keys that make sense to rebind are listed here — letters,
// digits, the arrows, and a handful of named keys. If you type a name
// that's not in this list, resolveKeybinds() below falls back to that
// key's own default and tells you exactly what happened, rather than the
// app just quietly not responding to that key.
func keyCode(forName name: String) -> Int64? {
    let table: [String: Int64] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "tab": 48, "return": 36, "enter": 36, "escape": 53, "delete": 51,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "pageup": 116, "pagedown": 121,
    ]
    return table[name.lowercased()]
}

struct ResolvedKeybinds {
    let cycleNext: Int64
    let cyclePrevious: Int64
    let enterGreyedRow: Int64
    let exitGreyedRow: Int64
    let pageUp: Int64
    let pageDown: Int64
    let confirm: Int64
    let cancel: Int64
}

func resolveKeybinds(_ config: KeybindConfig) -> ResolvedKeybinds {
    let defaults = KeybindConfig()
    func resolve(_ label: String, _ configured: String, fallback: String) -> Int64 {
        if let code = keyCode(forName: configured) { return code }
        print("Config: \"\(configured)\" isn't a key AeroSwitcher recognizes for \(label) — using the default (\"\(fallback)\") instead. Check config.json.")
        return keyCode(forName: fallback)!  // the built-in defaults are always valid names
    }
    let resolved = ResolvedKeybinds(
        cycleNext: resolve("cycleNext", config.cycleNext, fallback: defaults.cycleNext),
        cyclePrevious: resolve("cyclePrevious", config.cyclePrevious, fallback: defaults.cyclePrevious),
        enterGreyedRow: resolve("enterGreyedRow", config.enterGreyedRow, fallback: defaults.enterGreyedRow),
        exitGreyedRow: resolve("exitGreyedRow", config.exitGreyedRow, fallback: defaults.exitGreyedRow),
        pageUp: resolve("pageUp", config.pageUp, fallback: defaults.pageUp),
        pageDown: resolve("pageDown", config.pageDown, fallback: defaults.pageDown),
        confirm: resolve("confirm", config.confirm, fallback: defaults.confirm),
        cancel: resolve("cancel", config.cancel, fallback: defaults.cancel)
    )

    // Two actions silently sharing one key means only the first one in the
    // switch below ever fires — easy to do by accident when hand-editing
    // the file, so call it out instead of leaving the other key looking
    // "broken" for no obvious reason.
    let named: [(String, Int64)] = [
        ("cycleNext", resolved.cycleNext), ("cyclePrevious", resolved.cyclePrevious),
        ("enterGreyedRow", resolved.enterGreyedRow), ("exitGreyedRow", resolved.exitGreyedRow),
        ("pageUp", resolved.pageUp), ("pageDown", resolved.pageDown),
        ("confirm", resolved.confirm), ("cancel", resolved.cancel),
    ]
    for i in 0..<named.count {
        for j in (i + 1)..<named.count where named[i].1 == named[j].1 {
            print("Config: \"\(named[i].0)\" and \"\(named[j].0)\" are both bound to the same key — \"\(named[j].0)\" will never fire. Check config.json.")
        }
        // Tab (keyCode 48) is permanently what opens the switcher in the
        // first place — it's handled separately, before any of these, so
        // binding another action to it here would just never be reachable.
        if named[i].1 == 48 {
            print("Config: \"\(named[i].0)\" is bound to Tab, which is always reserved for opening the switcher — pick a different key in config.json.")
        }
    }

    return resolved
}

// MARK: - Cmd+Tab interception

// @MainActor because everything it eventually touches on the controller
// (SwitcherWindowController) is itself MainActor-isolated, and because the
// tap's run loop source below is added to whichever run loop is "current"
// at the moment start() runs — since start() is only ever called from a
// MainActor Task at launch, that's the main thread's run loop, so the
// callback genuinely does fire on the main thread every time.
@MainActor
class HotkeyManager {
    var eventTap: CFMachPort?
    let controller: SwitcherWindowController
    let keybinds: ResolvedKeybinds

    init(controller: SwitcherWindowController, keybinds: ResolvedKeybinds) {
        self.controller = controller
        self.keybinds = keybinds
    }

    func start() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            // The C callback itself isn't statically known to Swift as
            // running on the main thread, but it always is here (see the
            // note above) — assumeIsolated lets us call straight into the
            // @MainActor handle() synchronously instead of scheduling it
            // for "sometime later" with Task{}, which is what let session
            // state and the actual keypress drift out of sync before.
            return MainActor.assumeIsolated {
                manager.handle(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            print("Could not create the event tap. Check System Settings > Privacy & Security > Input Monitoring, AeroSwitcher needs to be allowed there.")
            return
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Cmd+Tab is now handled by AeroSwitcher. Press Ctrl+C here to stop and restore normal Cmd+Tab.")
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS will automatically switch the tap off if it ever decides
        // our callback was too slow to respond — even one slow moment while
        // your Mac is busy with something else is enough. Without this,
        // that's permanent: nothing crashes, there's no error, Cmd+Tab and
        // Escape just silently stop doing anything until the app is
        // relaunched. This turns it back on the instant that happens, so a
        // one-off hiccup never turns into "it stopped working."
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // AeroSwitcher only has business with Cmd+Tab and whatever happens
        // while Cmd is held afterward. AeroSpace's own shortcuts (workspace
        // switching, window moving, all of ~/.aerospace.toml) are all
        // Option-based, and this app should never be anywhere near those —
        // so anything with Option held is handed straight back untouched,
        // before any other logic below even looks at it.
        if event.flags.contains(.maskAlternate) {
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if keyCode == 48 && event.flags.contains(.maskCommand) { // Tab key while Cmd held
                let reverse = event.flags.contains(.maskShift)
                controller.handleTabPress(reverse: reverse)
                return nil // swallow so the system switcher never sees it
            }

            // ` (backtick, keycode 50) while Cmd held, with no Shift —
            // opens the all-workspaces overview. Fixed, like Tab, not
            // configurable: it's how you OPEN a panel, not a navigation
            // action inside one already open, same category as Cmd+Tab.
            if keyCode == 50 && event.flags.contains(.maskCommand) && !event.flags.contains(.maskShift) {
                controller.handleOverviewKey()
                return nil
            }

            // Every other switcher key only matters while the panel is
            // actually open — this used to go through a local NSEvent
            // monitor on the panel's own window, which needed that window
            // to be the genuine OS-level key window to ever fire. For a
            // background/accessory app that turned out to be unreliable:
            // the app could report itself as active and key internally
            // while the WindowServer silently didn't agree, so the local
            // monitor just never ran, even though Tab and Cmd-release
            // (handled here, in the tap, all along) kept working fine.
            // Handling these here too sidesteps that entirely.
            //
            // Requiring Cmd to still be held matters a lot here: without
            // it, this would swallow Q/W/E/A/S/D/F/Escape/Page-Up/Down
            // globally, for every app on the Mac, any time the panel
            // happened to still be open — including AeroSpace's own
            // Alt+Q/W/E/A/S/D workspace switching, which uses the exact
            // same letters with a different modifier. Checking for Cmd
            // means this can only ever fire during a real Cmd+Tab session.
            if controller.isOpen && event.flags.contains(.maskCommand) {
                // The overview is read-only, so only paging/confirm/cancel
                // mean anything there — enterGreyedRow/exitGreyedRow (W/S)
                // have nothing to do since there's no greyed row here, and
                // Page Up/Down (Q/E) aren't used either: paging reuses
                // cycleNext/cyclePrevious (A/D) instead, the same physical
                // keys Tab/Shift+Tab already page with (see
                // handleTabPress), so there's exactly one pair of keys for
                // "move through this panel" instead of two unrelated ones.
                if controller.showingAllWorkspaces {
                    switch keyCode {
                    case keybinds.cyclePrevious: controller.overviewPageUp(); return nil
                    case keybinds.cycleNext: controller.overviewPageDown(); return nil
                    case keybinds.confirm: controller.confirmSelection(); return nil
                    case keybinds.cancel: controller.cancelSession(); return nil
                    default: break
                    }
                } else {
                    switch keyCode {
                    case keybinds.cycleNext: controller.cycleForward(); return nil
                    case keybinds.cyclePrevious: controller.cycleBackward(); return nil
                    case keybinds.enterGreyedRow: controller.enterGreyedRow(); return nil
                    case keybinds.exitGreyedRow: controller.exitGreyedRow(); return nil
                    case keybinds.pageUp: controller.jumpPage(by: -1); return nil
                    case keybinds.pageDown: controller.jumpPage(by: 1); return nil
                    case keybinds.confirm: controller.confirmSelection(); return nil
                    case keybinds.cancel: controller.cancelSession(); return nil
                    default: break
                    }
                }
            }
        }

        if type == .flagsChanged {
            if !event.flags.contains(.maskCommand) {
                controller.endSession()
            }
        }

        return Unmanaged.passRetained(event)
    }
}

// MARK: - App entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// A background app that's never been "active" yet takes a beat to
// register itself as activatable with macOS the very first time. If that
// first activation is still in progress the moment the switcher panel
// tries to become key, the panel can silently miss it — which is exactly
// why every key besides the very-first Cmd+Tab in a run worked, but the
// first one never did. Activating once here, right at launch, means
// that's already settled long before you ever press Cmd+Tab for real.
app.activate(ignoringOtherApps: true)

var controller: SwitcherWindowController?
var hotkeys: HotkeyManager?

Task { @MainActor in
    let c = SwitcherWindowController()
    c.mru = MRUTracker()
    controller = c

    hotkeys = HotkeyManager(controller: c, keybinds: resolveKeybinds(appConfig.keybinds))
    hotkeys?.start()
}

app.run()