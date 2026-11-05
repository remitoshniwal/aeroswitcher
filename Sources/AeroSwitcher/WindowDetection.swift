import AppKit

// MARK: - Window detection (Phase 14, B1)

// Accessibility calls far more things a "window" than a person would: the
// little bubble when you switch keyboard layout, a browser's tooltip, a
// right-click menu in some apps, Chrome's find bar. A window manager has to
// sort them, and this file is how: every window gets one of three kinds.
//
//   window  a normal window (Safari, a Finder window, a game)
//   dialog  a real window that isn't meant to be big: Settings windows,
//           Open/Save panels, "About this Mac", Calculator. AeroSpace makes
//           these float; for B5 it decides which windows get maximized.
//   popup   not a window to a person at all. Never shown in Cmd+Tab, never
//           moved, never put in a workspace.
//
// The rules are AeroSpace's, copied as they are (including the per-app
// special cases and the comments explaining them), because in B1 the goal is
// that AeroSwitcher's list comes out EXACTLY like AeroSpace's, so any
// difference in the log points at a real problem rather than a different
// rule. Our own KnownApps files (Phase 13) are not mixed in yet; that comes
// once the differences are understood.
//
// Copied and adapted from AeroSpace v0.21.3-Beta
// (https://github.com/nikitabobko/AeroSpace, commit
// d56e1637c3a1ed660d0cadd7534e94fb3218d1c3): Sources/AppBundle/model/
// AxUiElementWindowType.swift, model/KnownBundleId.swift and
// windowLevelCache.swift. MIT licence, Copyright (c) 2023 Nikita Bobko, full
// text in LICENSE-AeroSpace.txt. Changes: AeroSpace's test stand-in type
// (AxUiElementMock) replaced by the real AXUIElement and the readers in
// AccessibilityHelpers.swift, the window level cache made safe to use from
// several threads, names prefixed so they can't clash with ours.
//
// If a particular app's window is sorted wrongly, this is the file to look
// at. Each special case is one `id == .something` line.

enum AXWindowKind: String {
    case window
    case dialog
    case popup
}

// Apps that need a special case below, by bundle id. (AeroSpace's
// KnownBundleId, unchanged.) Steam is listed by its HELPER's id because
// Steam's window really belongs to a helper process, which is also why
// AeroSwitcher's own rules match by app path.
enum AeroSpaceKnownBundleId: String, Equatable {
    case _1password = "com.1password.1password"
    case activityMonitor = "com.apple.ActivityMonitor"
    case alacritty = "org.alacritty"
    case braveBrowser = "com.brave.Browser"
    case chrome = "com.google.Chrome"
    case cleanshotx = "pl.maketheweb.cleanshotx"
    case codex = "com.openai.codex"
    case emacs = "org.gnu.Emacs"
    case finder = "com.apple.finder"
    case ghostty = "com.mitchellh.ghostty"
    case gimp = "org.gimp.gimp-2.10"
    case iphonesimulator = "com.apple.iphonesimulator"
    case iterm2 = "com.googlecode.iterm2"
    case kitty = "net.kovidgoyal.kitty"
    case outlook = "com.microsoft.Outlook"
    case photoBooth = "com.apple.PhotoBooth"
    case qutebrowser = "org.qutebrowser.qutebrowser"
    case screenstudio = "com.timpler.screenstudio"
    case slack = "com.tinyspeck.slackmacgap"
    case steam = "com.valvesoftware.steam.helper"
    case wezterm = "com.github.wez.wezterm"
    case wisprFlow = "com.electron.wispr-flow"
    case xcode = "com.apple.dt.Xcode"
    case zenBrowser = "app.zen-browser.zen"
    case zoom = "us.zoom.xos"

    case mozillaFirefox = "org.mozilla.firefox"
    case mozillaFirefoxDeveloperEdition = "org.mozilla.firefoxdeveloperedition"
    case mozillaFirefoxNightly = "org.mozilla.nightly"

    case vscode = "com.microsoft.VSCode"
    case vscodium = "com.vscodium"

    var isFirefox: Bool {
        self == .mozillaFirefox
            || self == .mozillaFirefoxDeveloperEdition
            || self == .mozillaFirefoxNightly
            || self == .zenBrowser
    }

    var isVscode: Bool {
        self == .vscode || self == .vscodium
    }
}

// MARK: Window level

// macOS's window server puts every window on a "level" (layer): 0 for normal
// windows, 3 for always-on-top ones, higher numbers for menus, the Dock and
// so on. A few of the rules below use it. Asking the window server for the
// whole list is the only way to get it, so the answer is kept and only asked
// again when a window turns up that isn't in the kept list (a new window).
enum MacOsWindowLevel: Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }
}

// AeroSpace keeps this cache on its main thread; here several app threads
// ask at once, so a lock guards it.
private let windowLevelLock = NSLock()
private var windowLevelCache: [CGWindowID: MacOsWindowLevel] = [:]

func windowLevel(for windowId: CGWindowID) -> MacOsWindowLevel? {
    windowLevelLock.lock()
    defer { windowLevelLock.unlock() }
    if let known = windowLevelCache[windowId] { return known }
    var result: [CGWindowID: MacOsWindowLevel] = [:]
    let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list {
        guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
        result[number] = .new(windowLevel: layer)
    }
    windowLevelCache = result
    return result[windowId]
}

// MARK: The rules

// Which kind a window is. Called on the window's app thread
// (WindowTracker.swift), since every check asks the app. `app` is the app's
// own element (for "which window does the app say is focused").
func axWindowKind(
    _ window: AXUIElement,
    app: AXUIElement,
    _ id: AeroSpaceKnownBundleId?,
    _ activationPolicy: NSApplication.ActivationPolicy,
    _ windowLevel: MacOsWindowLevel?
) -> AXWindowKind {
    if !axIsWindowHeuristic(window, app: app, id, activationPolicy, windowLevel) { return .popup }
    if axIsDialogHeuristic(window, id, windowLevel) { return .dialog }
    return .window
}

// Small shortcuts for "does this window have its red / yellow / green button,
// and is it enabled". A button is itself an element with an "enabled" flag.
private func button(_ window: AXUIElement, _ attribute: String) -> AXUIElement? {
    axElement(window, attribute)
}
private func buttonEnabled(_ window: AXUIElement, _ attribute: String) -> Bool {
    button(window, attribute).flatMap { axBool($0, kAXEnabledAttribute) } == true
}

// AeroSpace's isDialogHeuristic. The comments inside are AeroSpace's own
// (they explain which app each rule is for).
func axIsDialogHeuristic(
    _ window: AXUIElement,
    _ id: AeroSpaceKnownBundleId?,
    _ windowLevel: MacOsWindowLevel?
) -> Bool {
    // Note: a lot of windows don't have title on startup. So please don't rely on the title

    if id == ._1password && windowLevel != .normalWindow {
        return true
    }

    if id == .iphonesimulator {
        return true
    }

    // Don't tile:
    // - Chrome cmd+f window ("AXUnknown" value)
    // - login screen (it's also a window from Apple's API perspective) ("AXUnknown" value)
    // - XCode "Build succeeded" popup
    // - IntelliJ tooltips, context menus, drop downs
    // - macOS native file picker (IntelliJ -> "Open...") (kAXDialogSubrole value)
    //
    // Minimized windows or windows of a hidden app have subrole "AXDialog"
    if axString(window, kAXSubroleAttribute) != kAXStandardWindowSubrole &&
        id != .qutebrowser // qutebrowser regular window has AXDialog subrole when decorations are disabled
    {
        return true
    }
    // Firefox: Picture in Picture window doesn't have minimize button.
    // todo. bug: when firefox shows non-native fullscreen, minimize button is disabled for all other non-fullscreen windows
    if id?.isFirefox == true && !buttonEnabled(window, kAXMinimizeButtonAttribute) {
        return true
    }
    if id == .photoBooth { return true }
    if id == .ghostty {
        return !buttonEnabled(window, kAXFullScreenButtonAttribute) &&
            buttonEnabled(window, kAXCloseButtonAttribute)
    }
    // Heuristic: float windows without fullscreen button (such windows are not designed to be big)
    // - IntelliJ various dialogs (Rebase..., Edit commit message, Settings, Project structure)
    // - Finder copy file dialog
    // - System Settings
    // - Apple logo -> About this Mac
    // - Calculator
    // - Battle.net login dialog
    // Fullscreen button is presented but disabled:
    // - Safari -> Pinterest -> Log in with Google
    // - Kap screen recorder https://github.com/wulkano/Kap
    // - flameshot? https://github.com/nikitabobko/AeroSpace/issues/112
    // - Drata Agent https://github.com/nikitabobko/AeroSpace/issues/134
    if !buttonEnabled(window, kAXFullScreenButtonAttribute) &&
        id != .gimp && // Gimp doesn't show fullscreen button

        // "Drag out" a tab out of Chrome window. Technically, it shouldn't be necessary, but
        // apparently there is some sort of race condition between users releasing mouse up and
        // Chrome reactivating the fullscreen button
        id != .chrome &&

        id != .activityMonitor && // Activity Monitor doesn't show fullscreen button

        // Terminal apps and Emacs have an option to hide their title bars
        id != .alacritty && // ~/.alacritty.toml: window.decorations = "Buttonless"
        id != .kitty && // ~/.config/kitty/kitty.conf: hide_window_decorations titlebar-and-corners
        id != .wezterm &&
        id != .qutebrowser && // :set window.hide_decoration
        id != .iterm2 &&
        id != .emacs &&
        id?.isVscode != true && // "window.nativeFullScreen": false
        id != .steam
    {
        return true
    }
    return false
}

// AeroSpace's isWindowHeuristic ("is this a window at all, or a popup").
func axIsWindowHeuristic(
    _ window: AXUIElement,
    app: AXUIElement,
    _ id: AeroSpaceKnownBundleId?,
    _ activationPolicy: NSApplication.ActivationPolicy,
    _ windowLevel: MacOsWindowLevel?
) -> Bool {
    if windowLevel != .normalWindow &&
        // Slowly roll out windowLevel for applications for which we have the appropriate dumps
        (id == .slack || id == .chrome || id?.isFirefox == true || id == .braveBrowser || id == .screenstudio || id == .cleanshotx || id == .iterm2 || id == .outlook || id == .codex || id == .wisprFlow)
    {
        return false
    }

    // Just don't do anything with "Ghostty Quick Terminal" windows.
    // Its position and size are managed by the Ghostty itself
    // https://github.com/nikitabobko/AeroSpace/issues/103
    // https://github.com/ghostty-org/ghostty/discussions/3512
    if id == .ghostty && axString(window, kAXIdentifierAttribute) == "com.mitchellh.ghostty.quickTerminal" {
        return false
    }

    if id == .xcode && axString(window, kAXIdentifierAttribute) == "open_quickly" {
        return false
    }

    if id == .iterm2 && button(window, kAXFullScreenButtonAttribute) == nil {
        return false
    }

    if activationPolicy == .accessory && button(window, kAXCloseButtonAttribute) == nil && id != .steam {
        return false
    }

    // Emacs child frames (posframes, corfu completion popups, etc.)
    // These are transient UI elements that should not be managed as windows.
    // https://github.com/nikitabobko/AeroSpace/issues/776
    if id == .emacs && axString(window, kAXSubroleAttribute) == kAXFloatingWindowSubrole {
        return false
    }

    if id?.isFirefox != true {
        return axIsWindowHeuristicOld(window, app: app, id)
    }

    // Try to filter out incredibly weird popup like AXWindows without any buttons.
    // E.g.
    // - Sonoma (macOS 14) keyboard layout switch (AXSubrole == AXDialog)
    // - IntelliJ context menu (right mouse click)
    // - Telegram context menu (right mouse click)
    // - Share window purple "pill" indicator https://github.com/nikitabobko/AeroSpace/issues/1101. Title is not empty
    // - Tooltips on links mouse hover in browsers (Chrome, Firefox)
    // - Tooltips on buttons (e.g. new tab, Extensions) mouse hover in browsers (Chrome, Firefox). Title is not empty
    // Make sure that the following AXWindow remain windows:
    // - macOS native file picker ("Open..." menu) (subrole == kAXDialogSubrole)
    // - telegram image viewer (subrole == kAXFloatingWindowSubrole)
    // - Finder preview (hit space) (subrole == "Quick Look")
    // - Firefox non-native video fullscreen (about:config -> full-screen-api.macos-native-full-screen -> false, subrole == AXUnknown)
    return button(window, kAXCloseButtonAttribute) != nil ||
        button(window, kAXFullScreenButtonAttribute) != nil ||
        button(window, kAXZoomButtonAttribute) != nil ||
        button(window, kAXMinimizeButtonAttribute) != nil ||

        axBool(window, kAXFocusedAttribute) == true ||  // 3 different ways to detect if the window is focused
        axBool(window, kAXMainAttribute) == true ||
        focusedWindowId(of: app) == axWindowId(of: window) ||

        axString(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
}

// AeroSpace's isWindowHeuristicOld ("0.18.3 hotfix"), used for every app
// except Firefox-type browsers.
private func axIsWindowHeuristicOld(_ window: AXUIElement, app: AXUIElement, _ id: AeroSpaceKnownBundleId?) -> Bool {
    let subrole = axString(window, kAXSubroleAttribute)

    // Try to filter out incredibly weird popup like AXWindows without any buttons.
    // E.g.
    // - Sonoma (macOS 14) keyboard layout switch
    // - IntelliJ context menu (right mouse click)
    // - Telegram context menu (right mouse click)
    //
    // AeroSpace writes `get(...) == false` for the focused/main checks, so a
    // window that doesn't answer them at all (nil) does NOT count as "not
    // focused". Kept exactly like that.
    if button(window, kAXCloseButtonAttribute) == nil &&
        button(window, kAXFullScreenButtonAttribute) == nil &&
        button(window, kAXZoomButtonAttribute) == nil &&
        button(window, kAXMinimizeButtonAttribute) == nil &&

        axBool(window, kAXFocusedAttribute) == false &&  // Three different ways to detect if the window is not focused
        axBool(window, kAXMainAttribute) == false &&
        focusedWindowId(of: app) != axWindowId(of: window) &&

        subrole != kAXStandardWindowSubrole &&
        // Share window purple "pill" indicator has "Window" title https://github.com/nikitabobko/AeroSpace/issues/1101
        { let title = axString(window, kAXTitleAttribute) ?? ""; return title.isEmpty || title == "Window" }() // Maybe it doesn't work in non-English locale
    {
        return false
    }
    return subrole == kAXStandardWindowSubrole ||
        subrole == kAXDialogSubrole || // macOS native file picker ("Open..." menu) (kAXDialogSubrole value)
        subrole == kAXFloatingWindowSubrole || // telegram image viewer
        id == .finder && subrole == "Quick Look" // Finder preview (hit space) is a floating window
}

// The window number of the window the app itself says is focused.
private func focusedWindowId(of app: AXUIElement) -> CGWindowID? {
    axElement(app, kAXFocusedWindowAttribute).flatMap { axWindowId(of: $0) }
}
