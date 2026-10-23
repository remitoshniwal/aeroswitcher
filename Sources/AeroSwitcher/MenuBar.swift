import Cocoa
import ServiceManagement

// MARK: - Menu bar icon
//
// The one icon AeroSwitcher puts in the menu bar. It replaces AeroSpace's
// own icon: it shows the name of the workspace you're in, and its menu does
// what AeroSpace's menu does (switch workspace, enable or disable, reload,
// open the config) plus AeroSwitcher's own things (config.json, permission
// status, launch at login, About, Quit).
//
// AeroSpace's own icon can be hidden with "Hide AeroSpace's icon" in this
// menu (see "Hiding AeroSpace's icon" below for how). Do NOT use System
// Settings > Menu Bar > "Allow in the Menu Bar" for it, or Cmd-drag it out
// of the bar: AeroSpace quits when its icon is removed (tested), and turns
// the icon back on next time it starts.
//
// How it stays up to date:
//   - The workspace name comes from AeroSpaceEventStream (AeroSpaceBridge.swift),
//     which gets told the moment you switch.
//   - The workspace list in the menu is read fresh every time the menu is
//     opened, so even a missed event can't leave a stale menu behind.

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let stream = AeroSpaceEventStream()

    // What the bar currently shows.
    private var workspaceName: String?
    private var mode = "main"
    private var connected = false
    // AeroSpace has no command to ask whether it is enabled, but it
    // announces it on the event stream: turning it off sends a mode-changed
    // event with no mode (see AeroSpaceEventStream.onMode), turning it on
    // sends "main" again. A new connection always starts with the current
    // state, so this is right even after AeroSpace restarts.
    private var aerospaceEnabled = true

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Remembers where in the bar you dragged the icon (Cmd+drag).
        statusItem.autosaveName = "AeroSwitcher"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateBar()

        stream.onWorkspace = { [weak self] name in
            MainActor.assumeIsolated {
                self?.workspaceName = name
                self?.updateBar()
                // So the menu already has the right tick and apps next
                // time it opens.
                self?.refreshSnapshot()
            }
        }
        stream.onMode = { [weak self] mode in
            MainActor.assumeIsolated {
                self?.aerospaceEnabled = mode != nil
                if let mode { self?.mode = mode }
                self?.updateBar()
                self?.refreshSnapshot()  // enabled/disabled changes what the menu shows
            }
        }
        stream.onConnection = { [weak self] connected in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connected = connected
                self.updateBar()
                self.refreshSnapshot()
            }
        }
        // Put the divider back if AeroSpace's icon was hidden last time.
        if hideAeroSpaceIcon { showDivider(wide: true) }

        stream.start()

        // `pkill AeroSwitcher` (and Ctrl+C in Terminal) must also end the
        // `aerospace subscribe` process that belongs to this app. The
        // handlers run on a background queue on purpose: if the main thread
        // were ever stuck, a quit signal would still work.
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [stream] in
                stream.stop()
                exit(0)
            }
            source.resume()
            quitSignalSources.append(source)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [stream] _ in
            stream.stop()
        }
    }

    private var quitSignalSources: [DispatchSourceSignal] = []

    // MARK: The bar itself

    // Text for a normal state, a symbol when something's off. Fonts are
    // monospaced like AeroSpace's default so the icon doesn't change width
    // much between workspace names; change the font here if you prefer.
    private func updateBar() {
        guard let button = statusItem.button else { return }
        if !connected {
            show(symbol: "exclamationmark.triangle.fill", on: button)
            button.toolTip = "AeroSwitcher can't reach AeroSpace. Is AeroSpace running?"
        } else if !aerospaceEnabled {
            show(symbol: "pause.circle.fill", on: button)
            button.toolTip = "AeroSpace is disabled"
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let prefix = mode == "main" ? "" : "(\(mode.uppercased())) "
            button.title = prefix + (workspaceName ?? "...")
            button.toolTip = nil
        }
    }

    private func show(symbol: String, on button: NSStatusBarButton) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
    }

    // MARK: The menu

    // What the menu shows about AeroSpace, as last asked. The menu is
    // built from this right away and never waits for AeroSpace itself.
    //
    // Why: the first version asked AeroSpace while the menu was opening,
    // on the main thread, and in testing those questions sometimes took
    // over 2 seconds (from Terminal they take 10-40 ms). Likely cause, not
    // proven: while our menu opens, AeroSpace asks AeroSwitcher about its
    // windows, which our busy main thread can't answer, so both wait on
    // each other. Asking in the background avoids that either way.
    private struct MenuSnapshot: Equatable {
        var focused: String?
        var names: [String] = []
        var apps: [String: [String]] = [:]
        var disabled = false
        var reachable: Bool { focused != nil }
    }
    private var snapshot = MenuSnapshot()
    private var refreshing = false

    // Asks AeroSpace for everything the menu needs, off the main thread,
    // then rebuilds the menu if anything changed (also while it's open,
    // macOS updates an open menu in place).
    private func refreshSnapshot() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached {
            let focusedAnswer = runAerospace(["list-workspaces", "--focused"])
            var fresh = MenuSnapshot()
            fresh.focused = focusedAnswer.ok && !focusedAnswer.output.isEmpty ? focusedAnswer.output : nil
            // A disabled AeroSpace refuses every command except `enable`,
            // and says so. That's not "can't reach it", the Enable item
            // must stay usable.
            fresh.disabled = fresh.focused == nil && focusedAnswer.output.contains("disabled")
            if fresh.focused != nil {
                fresh.names = runAerospace(["list-workspaces", "--all"]).output
                    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                fresh.apps = getAppNamesByWorkspace()
            }
            let result = fresh
            await MainActor.run {
                self.refreshing = false
                guard result != self.snapshot else { return }
                self.snapshot = result
                if let menu = self.statusItem.menu { self.buildMenu(menu) }
            }
        }
    }

    // Called by macOS every time the menu is about to open: shows what's
    // known right away, and asks AeroSpace for fresh data on the side.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        buildMenu(menu)
        refreshSnapshot()
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false  // so an item set to disabled below stays disabled

        let focused = snapshot.focused
        let allNames = snapshot.names
        let disabled = snapshot.disabled
        let reachable = snapshot.reachable

        if reachable {
            menu.addItem(NSMenuItem.sectionHeader(title: "Workspaces"))
            let apps = snapshot.apps
            for name in allNames {
                let item = NSMenuItem(title: name, action: #selector(workspaceClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = name == focused ? .on : .off
                item.attributedTitle = workspaceRowTitle(name: name, apps: apps[name] ?? [])
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(
                title: disabled ? "AeroSpace is disabled" : "Can't reach AeroSpace. Is it running?",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: aerospaceEnabled ? "Disable AeroSpace" : "Enable AeroSpace",
            action: #selector(toggleEnabledClicked), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = reachable || disabled
        menu.addItem(toggle)
        menu.addItem(item("Reload config", #selector(reloadClicked)))
        menu.addItem(item("Open AeroSpace config", #selector(openAeroSpaceConfigClicked)))

        menu.addItem(.separator())

        menu.addItem(item("Open config.json", #selector(openConfigJSONClicked)))
        menu.addItem(permissionsItem(aerospaceReachable: reachable || disabled))
        let login = item("Launch at login", #selector(launchAtLoginClicked))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let hide = item("Hide AeroSpace's icon", #selector(hideAeroSpaceIconClicked))
        hide.state = hideAeroSpaceIcon ? .on : .off
        menu.addItem(hide)
        menu.addItem(item("About AeroSwitcher", #selector(aboutClicked)))
        menu.addItem(item("Quit AeroSwitcher", #selector(quitClicked)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    // "Core" in the normal text, then the apps in it in smaller grey text,
    // cut off after about 25 characters like AeroSpace does.
    private func workspaceRowTitle(name: String, apps: [String]) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let result = NSMutableAttributedString(string: name, attributes: [.font: mono])
        if !apps.isEmpty {
            var list = apps.joined(separator: ", ")
            if list.count > 25 { list = list.prefix(24) + "…" }
            result.append(NSAttributedString(string: "   " + list, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }

    // MARK: Permissions

    // CGPreflight... only LOOK at the permission, they never pop up a
    // permission dialog (the "Request" versions would, so they're avoided).
    // Accessibility isn't listed: AeroSwitcher doesn't use it, AeroSpace and
    // the maximize scripts do, and a permission can't be read for another app.
    private func permissionsItem(aerospaceReachable: Bool) -> NSMenuItem {
        let inputMonitoring = CGPreflightListenEventAccess()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let allGood = inputMonitoring && screenRecording && aerospaceReachable

        let parent = NSMenuItem(title: allGood ? "Permissions" : "Permissions (needs attention)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        func row(_ title: String, ok: Bool, url: String?) {
            let row = NSMenuItem(title: "\(ok ? "✓" : "✗")  \(title)", action: ok || url == nil ? nil : #selector(openSettingsClicked(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = url
            row.isEnabled = !ok && url != nil
            submenu.addItem(row)
        }
        row("Input Monitoring (Cmd+Tab)", ok: inputMonitoring,
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        row("Screen Recording (thumbnails)", ok: screenRecording,
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        row("AeroSpace is running", ok: aerospaceReachable, url: nil)
        parent.submenu = submenu
        return parent
    }

    @objc private func openSettingsClicked(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String, let url = URL(string: string) else { return }
        print("Menu: open System Settings page \(string)")
        NSWorkspace.shared.open(url)
    }

    // MARK: Actions

    @objc private func workspaceClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        print("Menu: switch to workspace \(name)")
        switchToWorkspace(name)
        // The bar updates when AeroSpace reports the switch (the event).
    }

    @objc private func toggleEnabledClicked() {
        let enable = !aerospaceEnabled
        print("Menu: \(enable ? "enable" : "disable") AeroSpace")
        Task.detached {
            let result = setAeroSpaceEnabled(enable)
            print("aerospace enable \(enable ? "on" : "off"): \(result.ok ? "ok" : "failed") \(result.output)")
            await MainActor.run {
                if result.ok { self.aerospaceEnabled = enable }
                self.updateBar()
            }
        }
    }

    @objc private func reloadClicked() {
        print("Menu: reload config")
        settings.reloadTogether()
    }

    @objc private func openAeroSpaceConfigClicked() {
        print("Menu: open AeroSpace config")
        Task.detached {
            // Ask AeroSpace where its config is; if it can't answer, the
            // usual place.
            let path = getAeroSpaceConfigPath() ?? NSHomeDirectory() + "/.aerospace.toml"
            await MainActor.run {
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    NSSound.beep()
                    print("No AeroSpace config found at \(path).")
                }
            }
        }
    }

    @objc private func openConfigJSONClicked() {
        print("Menu: open config.json")
        NSWorkspace.shared.open(configFileURL())
    }

    // MARK: Launch at login

    // Apple's own "open at login" for apps (SMAppService). It shows up in
    // System Settings > General > Login Items, next to anything added by
    // hand there. Having both makes macOS start the app twice at login, so
    // the by-hand entry should be removed after turning this on (the
    // second copy quits right away, see the one-copy check in main.swift,
    // but it's still better to have just one).
    //
    // macOS remembers the PATH of the app that registered. A copy sitting in
    // the project folder would leave a login item pointing there, so only a
    // copy in an Applications folder is allowed to do this.
    @objc private func launchAtLoginClicked() {
        let service = SMAppService.mainApp
        print("Menu: launch at login clicked, status was \(service.status)")
        let path = Bundle.main.bundlePath
        let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return
            default:
                guard inApplications else {
                    alert("Launch at login only works from the Applications folder",
                          "This copy of AeroSwitcher is in \(path). Move it to /Applications and open it from there, so the login item doesn't point at the wrong place.")
                    return
                }
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            print("Launch at login: status is now \(service.status)")
        } catch {
            print("Launch at login failed: \(error)")
            alert("Couldn't change Launch at login", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Hiding AeroSpace's icon
    //
    // AeroSpace's icon can't be switched off: AeroSpace quits the moment
    // macOS tells it its icon was removed (System Settings > Menu Bar, or
    // Cmd-dragging it out of the bar), and turns the icon back on when it
    // starts again. So instead it gets pushed off the screen, the same
    // trick menu bar tidying apps like Ice and Bartender use:
    //
    //   [AeroSpace's icon] [divider] [AeroSwitcher's icon] [other icons...]
    //
    // The divider is a second, invisible icon of AeroSwitcher's own that is
    // 3000 points wide. Menu bar icons are laid out from the right, so
    // everything on its left ends up far off the left edge of the screen.
    // AeroSpace still has its icon (macOS never tells it anything changed),
    // it just can't be seen. Tested on macOS 26.5: AeroSpace kept running
    // and switching workspaces with its icon off screen.
    //
    // Catch: ANY icon to the left of AeroSwitcher's own gets hidden this
    // way, not just AeroSpace's. Cmd-drag icons you want to see to the
    // right of AeroSwitcher's icon (while the divider shows as │).
    //
    // AeroSwitcher can't see which icon is AeroSpace's (on macOS 26 every
    // menu bar icon belongs to Control Center, and finding out would need
    // the Accessibility permission). So when you turn this on, the divider
    // first shows as a thin │ and you check, or drag, AeroSpace's icon to
    // its left. macOS remembers icon positions, so that's a one-time step.
    //
    // The on/off choice is stored in AeroSwitcher's own preferences, not in
    // config.json (a menu tick writing to your hand-edited file could mess
    // up its formatting). The Phase 9 settings window can move it later.

    private var divider: NSStatusItem?
    private let hideAeroSpaceIconKey = "HideAeroSpaceIcon"

    private var hideAeroSpaceIcon: Bool {
        get { UserDefaults.standard.bool(forKey: hideAeroSpaceIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideAeroSpaceIconKey) }
    }

    // wide = hiding (3000 points, no text). Not wide = the thin │ shown
    // while you arrange icons.
    private func showDivider(wide: Bool) {
        if divider == nil {
            // macOS saves each icon's place as a number under "NSStatusItem
            // Preferred Position <name>", bigger means further left. The
            // first time, place the divider just left of AeroSwitcher's
            // icon by giving it a number one bigger. After that macOS keeps
            // whatever place it ends up in.
            let defaults = UserDefaults.standard
            let dividerKey = "NSStatusItem Preferred Position AeroSwitcherDivider"
            let mainKey = "NSStatusItem Preferred Position AeroSwitcher"
            if defaults.object(forKey: dividerKey) == nil, defaults.object(forKey: mainKey) != nil {
                defaults.set(defaults.double(forKey: mainKey) + 1, forKey: dividerKey)
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "AeroSwitcherDivider"
            divider = item
        }
        divider?.length = wide ? 3000 : NSStatusItem.variableLength
        divider?.button?.title = wide ? "" : "│"
        print("Divider: \(wide ? "wide, hiding the icons on its left" : "showing as │")")
    }

    private func removeDivider() {
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        divider = nil
        print("Divider: removed, AeroSpace's icon is visible again")
    }

    @objc private func hideAeroSpaceIconClicked() {
        if hideAeroSpaceIcon {
            print("Menu: show AeroSpace's icon again")
            hideAeroSpaceIcon = false
            removeDivider()
            return
        }
        print("Menu: hide AeroSpace's icon (arranging)")
        showDivider(wide: false)
        let alert = NSAlert()
        alert.messageText = "Hide AeroSpace's icon"
        alert.informativeText = """
            A thin │ is now next to AeroSwitcher's workspace name in the menu bar. \
            Everything to the LEFT of the │ will be hidden.

            AeroSpace's workspace name has to be on the left of the │. If it isn't, \
            hold Cmd and drag it there. Keep it inside the menu bar: dragging it \
            out of the bar quits AeroSpace.

            Any other icon on the left of the │ gets hidden too, Cmd-drag it to the \
            right of AeroSwitcher's name to keep it.
            """
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            hideAeroSpaceIcon = true
            showDivider(wide: true)
        } else {
            removeDivider()
        }
    }

    // MARK: About, Quit

    @objc private func aboutClicked() {
        print("Menu: about")
        let credits = NSMutableAttributedString(
            string: "A Cmd+Tab for the current AeroSpace workspace.\n\n" + getAeroSpaceVersionText()
                + "\n\nhttps://github.com/remitoshniwal/aeroswitcher",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor])
        credits.addAttribute(.link, value: URL(string: "https://github.com/remitoshniwal/aeroswitcher")!,
                             range: (credits.string as NSString).range(of: "https://github.com/remitoshniwal/aeroswitcher"))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quitClicked() {
        print("Menu: quit")
        NSApp.terminate(nil)
    }
}
