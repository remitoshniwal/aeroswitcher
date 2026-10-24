import Cocoa
import SwiftUI
import ScreenCaptureKit

// GUI apps launched from Terminal don't always line-buffer stdout the way
// plain command-line tools do, which can make print() output show up late
// or out of order when you're trying to watch it live. Forcing line
// buffering here means every print() appears the moment it runs.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - One copy only
//
// Two AeroSwitchers at once would both swallow Cmd+Tab and both put an icon
// in the menu bar. That can happen at login if the app is started both by a
// hand-made Login Items entry and by the menu's "Launch at login". So a copy
// that finds another one already running quits at once.
//
// It waits a moment first (up to 3 seconds) for the other one to go away,
// because `pkill AeroSwitcher; open AeroSwitcher.app` starts the new copy
// while the old one is still shutting down, and that must still work.
// A test copy started with AEROSWITCHER_CONFIG_DIR (see Config.swift) skips
// the check, that's the documented way to run a second one on purpose.
if ProcessInfo.processInfo.environment["AEROSWITCHER_CONFIG_DIR"] == nil,
   let bundleID = Bundle.main.bundleIdentifier {
    func otherCopyRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
    }
    var waited = 0.0
    while otherCopyRunning() && waited < 3 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 0.1
    }
    if otherCopyRunning() {
        print("Another AeroSwitcher is already running, quitting this copy.")
        exit(0)
    }
}

// MARK: - Start-up order
//
// This app used to be one big main.swift, and it's now split into one file
// per section (AeroSpaceBridge.swift, Config.swift, Views.swift, and so on).
// That split changes one subtle thing, which these lines undo:
//
// Shared values like `appConfig` are worked out differently depending on
// which file they live in. In main.swift, Swift computes them right away,
// top to bottom, the moment the app launches. In any OTHER file, Swift
// waits and computes each one the first time something actually uses it.
// Left alone, that would quietly move things like "load config.json, print
// any mistakes in it, load your custom icon images, read Finder's new-window
// setting" from app launch to your first Cmd+Tab, making that first Cmd+Tab
// a bit slower and the launch messages show up late.
//
// Touching each one here (`_ =` means "compute it, I don't need the result")
// keeps everything happening at launch, in the same order as before the
// split. If you add a new shared `let` in another file that does real work
// when it's created (reads a file, prints, loads images), add it here too.
_ = aerospacePath
_ = cardSize
_ = displayScale
_ = captureScale
_ = captureTargetSize
_ = finderNewWindowScript
_ = terminalNewWindowScript
_ = defaultSwitcherConfig
_ = settings  // reads config.json (launcher tiles, custom icons, keybinds), see SettingsStore

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
var menuBar: MenuBarController?

Task { @MainActor in
    let c = SwitcherWindowController()
    c.mru = MRUTracker()
    controller = c

    hotkeys = HotkeyManager(controller: c)
    hotkeys?.start()

    // The menu bar icon (workspace name and menu), see MenuBar.swift.
    menuBar = MenuBarController()

    // From here on, saving config.json reloads it, and `pkill -HUP
    // AeroSwitcher` reloads it together with AeroSpace's config.
    settings.startWatching()
    // Checks AeroSpace and the permissions, and opens the setup window on a
    // first launch or when something required is missing (SetupHelp.swift).
    SetupHelp.shared.launchCheck()
    // Anything wrong in config.json at launch gets the same window a
    // reload would show, instead of only a print nobody sees.
    ConfigProblemsWindow.shared.update(report: settings.lastReport, aerospace: nil)
}

app.run()