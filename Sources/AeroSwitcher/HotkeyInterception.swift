import Cocoa

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

