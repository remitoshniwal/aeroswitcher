import AppKit

// MARK: - Accessibility helpers (Phase 14, AeroSwitcher replaces AeroSpace)

// This file is where AeroSwitcher talks to OTHER apps' windows through
// macOS's Accessibility system (the "AX" API). Accessibility is how a
// window manager reads a window's size, position and kind, and later moves
// it. AeroSwitcher already has Accessibility permission for the Cmd+Tab hook,
// so nothing new has to be granted for this.
//
// Step B0 (2026-11-05) added the window number function below. Step B1
// added the attribute readers and the change observer further down, used by
// the watch-only window tracker (WindowTracker.swift). Nothing here moves or
// changes a window; that starts in B3.
//
// Parts of this file are copied or adapted from AeroSpace v0.21.3-Beta
// (https://github.com/nikitabobko/AeroSpace, commit
// d56e1637c3a1ed660d0cadd7534e94fb3218d1c3, the version installed on the
// owner's Mac). MIT licence, Copyright (c) 2023 Nikita Bobko. The full
// licence text is in LICENSE-AeroSpace.txt at the top of the repo.

// The window's number, from an Accessibility window.
//
// Accessibility hands out window objects (AXUIElement) but never says which
// macOS window number they are. Everything else in AeroSwitcher uses that
// number: the screenshots (ScreenCaptureKit), the recent order, and today's
// AeroSpace answers (`%{window-id}`). This private macOS function is the
// bridge. "Private" means Apple uses it inside macOS but never documented it,
// so in theory a macOS update could remove it. Every window manager on the
// Mac (AeroSpace, yabai, Amethyst, AltTab) depends on it, which makes that
// unlikely, but it is the one thing in Phase 14 that is not ours to control.
//
// AeroSpace declares it in a small C header (Sources/PrivateApi/include/
// private.h). The same header shows this Swift form in a comment, which
// saves AeroSwitcher a separate C target: @_silgen_name tells the Swift
// compiler "this function exists in macOS under exactly this name, link to
// it". Once something calls it, a wrong name would make the app fail to
// START (not crash later), so a successful launch proves it was found.
//
// Tested in B0 (2026-11-05, a separate test program, not the app): for every
// window AeroSpace listed, this gave the same number AeroSpace reported, the
// same app, and a number the window server (and so ScreenCaptureKit) knows.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: inout CGWindowID) -> AXError

// The friendly wrapper (from AeroSpace's containingWindowId(), in
// Sources/AppBundle/util/accessibility.swift): the window number, or nil when
// the element is not inside a real window (for example Finder's desktop,
// which Accessibility also lists as a "window").
func axWindowId(of element: AXUIElement) -> CGWindowID? {
    var windowId = CGWindowID()
    return _AXUIElementGetWindow(element, &windowId) == .success && windowId != kCGNullWindowID
        ? windowId
        : nil
}

// MARK: Reading attributes (B1)

// Everything Accessibility knows about a window is an "attribute" with a
// name: kAXSubroleAttribute ("what kind of window"), kAXMinimizedAttribute,
// kAXCloseButtonAttribute (the red button, itself an element) and so on.
// These small helpers read one and hand it back already converted, or nil
// when the app doesn't have that attribute or didn't answer. (AeroSpace's
// version, `AXUIElement.get(_:)` in util/accessibility.swift, wraps the same
// call in typed attribute objects; plain functions are enough here.)
//
// Every call here goes to ANOTHER app and waits for its answer. That is why
// they are only ever made from the window tracker's background threads
// (WindowTracker.swift), never from the main thread that also runs Cmd+Tab,
// and why each app gets a 1 second limit (axApplication below).
func axValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var raw: AnyObject?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success ? raw : nil
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axValue(element, attribute) as? String
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    (axValue(element, attribute) as? NSNumber)?.boolValue
}

// An attribute that is itself an element (a button, the focused window).
// Accessibility hands back a generic object, so check it really is an
// element before treating it as one.
func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let raw = axValue(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return (raw as! AXUIElement)
}

// The element that stands for a whole app, with the 1 second limit: an app
// that is frozen (beach ball) would otherwise make every question to it wait
// about 6 seconds, macOS's default.
func axApplication(pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    return app
}

// An app's windows with their numbers (AeroSpace's `Ax.windowsAttr`).
// Elements without a number are skipped: Finder's desktop is one.
func axWindows(ofApp app: AXUIElement) -> [(id: CGWindowID, element: AXUIElement)] {
    guard let list = axValue(app, kAXWindowsAttribute) as? [AnyObject] else { return [] }
    return list.compactMap { raw in
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        return axWindowId(of: element).map { (id: $0, element: element) }
    }
}

// MARK: Being told about changes (B1)

// An app can tell AeroSwitcher when something happens ("a window was
// created", "this window was closed"). That is an AXObserver plus a list of
// notification names. Copied from AeroSpace's AxSubscription
// (util/AxSubscription.swift): all names must work or none are kept, and
// letting go of the object stops the notifications. The observer's events
// arrive on the run loop of the thread that created it, so create AND drop
// it on the same app thread (WindowTracker.swift does).
final class AXSubscription {
    let observer: AXObserver
    let element: AXUIElement
    private var names: [String] = []

    // nil when the app refused (it's still starting up, or it doesn't
    // support Accessibility). The caller tries again at the next refresh.
    init?(pid: pid_t, element: AXUIElement, names: [String], callback: AXObserverCallback) {
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return nil }
        self.observer = observer
        self.element = element
        for name in names {
            guard AXObserverAddNotification(observer, element, name as CFString, nil) == .success else {
                removeAll()
                return nil
            }
            self.names.append(name)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func removeAll() {
        for name in names {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
        names = []
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        removeAll()
    }
}
