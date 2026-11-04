import ApplicationServices

// MARK: - Accessibility helpers (Phase 14, AeroSwitcher replaces AeroSpace)

// This file is where AeroSwitcher talks to OTHER apps' windows through
// macOS's Accessibility system (the "AX" API). Accessibility is how a
// window manager reads a window's size, position and kind, and later moves
// it. AeroSwitcher already has Accessibility permission for the Cmd+Tab hook,
// so nothing new has to be granted for this.
//
// Step B0 (2026-11-05) only adds the one piece below. Nothing calls it yet,
// so the compiler leaves it out of the built app entirely (checked with `nm`)
// and the app behaves exactly as before. Later steps (B1 on) add the rest of
// the helpers here.
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
