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
// To get rid of AeroSpace's icon, use System Settings > Menu Bar > "Allow in
// the Menu Bar" and switch AeroSpace off there. AeroSpace itself has no
// setting for it, and this app never changes AeroSpace.
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
            }
        }
        stream.onMode = { [weak self] mode in
            MainActor.assumeIsolated {
                self?.aerospaceEnabled = mode != nil
                if let mode { self?.mode = mode }
                self?.updateBar()
            }
        }
        stream.onConnection = { [weak self] connected in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connected = connected
                self.updateBar()
            }
        }
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

    // Called by macOS every time the menu is about to open. Rebuilt from
    // scratch each time with fresh answers from AeroSpace. These commands
    // each take roughly 25 ms and have a time limit (runAerospace), so a
    // hung AeroSpace can't freeze anything.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menu.removeAllItems()
        menu.autoenablesItems = false  // so an item set to disabled below stays disabled

        // runAerospace (not the older helpers) so each question has a time
        // limit. A failed "which workspace is focused" means AeroSpace
        // isn't answering.
        let focusedAnswer = runAerospace(["list-workspaces", "--focused"])
        let focused = focusedAnswer.ok && !focusedAnswer.output.isEmpty ? focusedAnswer.output : nil
        // A disabled AeroSpace refuses every command except `enable`, and
        // says so. That's not "can't reach it", the Enable item must stay usable.
        let disabled = focused == nil && focusedAnswer.output.contains("disabled")
        let allNames = runAerospace(["list-workspaces", "--all"]).output
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let focused { workspaceName = focused }
        let reachable = focused != nil

        if reachable {
            menu.addItem(NSMenuItem.sectionHeader(title: "Workspaces"))
            let apps = getAppNamesByWorkspace()
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
