import Cocoa

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

