import AppKit

// MARK: - Window sizing (Phase 14, B5)

// What used to be two AppleScripts and a shell script run by AeroSpace
// (aerospace/maximize.applescript, restore.applescript, toggle-maximize.sh),
// now done by AeroSwitcher itself when it is its own window manager:
//
//   - every NEW real window is made to fill the screen (not dialogs)
//   - Option+F (the toggle key in config.json) flips the focused window
//     between filling the screen and a centered 70% size
//
// The rules are the scripts' rules, carried over one to one, because they
// were arrived at by testing a lot of apps (see the long comment that was at
// the top of maximize.applescript, and ROADMAP.md Phase 5):
//
//   - "Is it a real window?" = it has a green full screen button, OR macOS
//     says it can go full screen at all (its AXFullScreen setting can be
//     changed; that half is for apps like Steam that hide the button). Every
//     dialog tested fails both. The more obvious checks (the window's
//     "subrole", can it be resized, is it modal) were tried and get real
//     apps wrong.
//   - The check is tried for about a second, because an app can show a
//     window a moment before it adds its buttons.
//   - A window already filling the screen (within 2 points) is left alone.
//   - The toggle key skips the check: pressing it is you deciding.
//
// What is better than the scripts: they had to find the window again by its
// TITLE inside System Events, which went wrong when two windows had the same
// title. Here the window is known by its number from the start, so it is
// always exactly the right one. And nothing has to start a program (the
// scripts took a few hundred milliseconds each).
//
// Nothing in this file decides WHEN to resize. WorkspaceManager.swift does
// (new window noticed, toggle key pressed) and calls in here.

// The screens, in the coordinates Accessibility uses for windows (x and y
// from the TOP left corner of the main screen, y growing downwards). AppKit's
// NSScreen measures from the bottom left instead, so each screen is
// converted once and kept. NSScreen should only be read on the main thread,
// while windows are moved on background threads, hence this small cache
// with a lock: the main thread refreshes it (at launch and whenever a
// display is plugged in, unplugged or changes resolution) and anyone may
// read it.
struct ScreenRects {
    // The whole screen, menu bar included.
    let full: CGRect
    // The usable part: below the menu bar and not under the Dock.
    let visible: CGRect
}

final class ScreenLayout: @unchecked Sendable {
    static let shared = ScreenLayout()
    private let lock = NSLock()
    private var screens: [ScreenRects] = []
    private var observer: NSObjectProtocol?

    // Main thread. Safe to call more than once.
    func start() {
        refresh()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
            logInfo("Screens changed: \(self?.describe() ?? "?")")
        }
    }

    private func refresh() {
        // screens[0] is always the main screen, the one whose top left
        // corner is Accessibility's (0, 0).
        let all = NSScreen.screens
        guard let mainHeight = all.first?.frame.height else { return }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        let converted = all.map { ScreenRects(full: flipped($0.frame), visible: flipped($0.visibleFrame)) }
        lock.lock()
        screens = converted
        lock.unlock()
    }

    func describe() -> String {
        lock.lock()
        defer { lock.unlock() }
        return screens.map { "\(Int($0.full.width))x\(Int($0.full.height))" }.joined(separator: ", ")
    }

    // The screen a window is on: the one holding the window's middle point,
    // else the main screen. (This Mac has one display; the "which screen" is
    // here so a second display doesn't send windows to the wrong one.) nil
    // only if no screen is known at all.
    func screen(for frame: CGRect?) -> ScreenRects? {
        lock.lock()
        defer { lock.unlock() }
        if let frame {
            let middle = CGPoint(x: frame.midX, y: frame.midY)
            if let hit = screens.first(where: { $0.full.contains(middle) }) { return hit }
        }
        return screens.first
    }

    // The screen furthest to the right: windows are parked in its bottom
    // right corner (WorkspaceManager.swift), where nothing is further right.
    func rightmostScreen() -> ScreenRects? {
        lock.lock()
        defer { lock.unlock() }
        return screens.max { $0.full.maxX < $1.full.maxX }
    }

    // Does a window sit in the parking corner? True when its top left corner
    // is within a few points of the right edge of the right-most screen and
    // in its bottom part. macOS sometimes nudges a parked window up so its
    // title bar stays reachable (seen 2026-11-14: AeroSpace's parked windows
    // sat at y 904 and 924 on a 956 point screen), hence the generous
    // "bottom fifth" instead of an exact point.
    func looksParked(_ frame: CGRect) -> Bool {
        guard let screen = rightmostScreen() else { return false }
        return frame.minX >= screen.full.maxX - 4 && frame.minY >= screen.full.maxY - screen.full.height / 5
    }
}

enum WindowSizing {
    // The frame a maximized window gets: the usable part of its screen.
    // (The script used Finder's desktop bounds, the WHOLE screen, and macOS
    // then pushed the window below the menu bar by itself. Measured on this
    // Mac 2026-11-14: screen 1470 x 956, maximized windows sit at 0, 33 and
    // are 1470 x 923, which is exactly this usable part.)
    static func maximizedFrame(on screen: ScreenRects) -> CGRect {
        screen.visible
    }

    // The "restored" frame of the toggle: 70% of the whole screen, centered
    // (restore.applescript's numbers; change 0.7 here for another size).
    static func restoredFrame(on screen: ScreenRects) -> CGRect {
        let fraction: CGFloat = 0.7
        let width = screen.full.width * fraction
        let height = screen.full.height * fraction
        return CGRect(x: screen.full.minX + (screen.full.width - width) / 2,
                      y: screen.full.minY + (screen.full.height - height) / 2,
                      width: width, height: height)
    }

    // "Within 2 points" (Prism Launcher opens 2 short, from the script).
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    // The dialog check described at the top. Runs on the window's app thread
    // (it asks the app two questions).
    static func isRealWindow(_ window: AXUIElement) -> Bool {
        if axElement(window, "AXFullScreenButton") != nil { return true }
        return axIsSettable(window, "AXFullScreen")
    }

    // A new window was noticed: decide whether it is a real window (trying
    // for about a second) and, if so, tell `whenReal`, which runs on the
    // MAIN thread. The window manager then resizes it, or, if the window is
    // parked off screen in another workspace, only remembers that it should
    // be big when it comes back. Nothing happens for a dialog, a window in
    // macOS full screen, a minimized window, or one that already fills the
    // screen.
    static func checkNewWindow(pid: pid_t, windowId: CGWindowID, attempt: Int = 0,
                               whenReal: @escaping () -> Void) {
        WindowTracker.shared.act(pid: pid, windowId: windowId, { window, _ in
            if axBool(window, "AXFullScreen") == true || axBool(window, kAXMinimizedAttribute) == true { return }
            if isRealWindow(window) {
                DispatchQueue.main.async(execute: whenReal)
            } else if attempt < 9 {
                // Not (yet) a real window: look again in a tenth of a
                // second, without keeping the app's thread busy meanwhile.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                    checkNewWindow(pid: pid, windowId: windowId, attempt: attempt + 1, whenReal: whenReal)
                }
            }
        })
    }

    // Moves and resizes a window to `frame`, on its app's thread. Returns at
    // once.
    static func setFrame(pid: pid_t, windowId: CGWindowID, _ frame: CGRect) {
        WindowTracker.shared.act(pid: pid, windowId: windowId, { window, app in
            axWithoutAnimations(app: app) {
                axSetFrame(window, topLeft: frame.origin, size: frame.size)
            }
        })
    }
}
