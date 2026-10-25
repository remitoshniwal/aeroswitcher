import Cocoa
import ServiceManagement

// MARK: - Menu bar icon
//
// The one icon AeroSwitcher puts in the menu bar. It replaces AeroSpace's
// own icon: it shows the name of the workspace you're in, and its menu does
// what AeroSpace's menu does (switch workspace, enable or disable, reload,
// open the config) plus AeroSwitcher's own things (Settings, permission
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

    // `onFocus` gets every "this window now has focus" event of the one
    // `aerospace subscribe` connection this icon already keeps (see main.swift).
    init(onFocus: ((String, String) -> Void)? = nil) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        stream.onFocus = onFocus
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
        // The Permissions item follows the setup check (SetupHelp.swift).
        NotificationCenter.default.addObserver(forName: .setupStatusChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.statusItem.menu else { return }
                self.buildMenu(menu)
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
                logInfo("Quit by signal \(signalNumber)")
                stream.stop()
                flushLog()
                exit(0)
            }
            source.resume()
            quitSignalSources.append(source)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [stream] _ in
            stream.stop()
            logInfo("Quitting")
            flushLog()
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
        SetupHelp.shared.refresh()
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

        // "Settings..." opens the settings window (SettingsWindow.swift).
        // Holding Option while the menu is open swaps it for "Open
        // config.json" (a standard macOS menu trick: an "alternate" item
        // with the same key and Option added).
        let settingsItem = item("Settings...", #selector(settingsClicked))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        let openConfig = item("Open config.json", #selector(openConfigJSONClicked))
        openConfig.keyEquivalent = ","
        openConfig.keyEquivalentModifierMask = [.command, .option]
        openConfig.isAlternate = true
        menu.addItem(openConfig)
        menu.addItem(permissionsItem())
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

    // Built from the same check as the setup help window (SetupHelp.swift),
    // so the two always agree. Everything there only LOOKS at permissions,
    // nothing pops up a macOS dialog. The first check runs at launch; until
    // it has answered the submenu says so.
    private func permissionsItem() -> NSMenuItem {
        guard let status = SetupHelp.shared.statusForMenu() else {
            let parent = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let checking = NSMenuItem(title: "Checking...", action: nil, keyEquivalent: "")
            checking.isEnabled = false
            submenu.addItem(checking)
            parent.submenu = submenu
            return parent
        }
        let allGood = status.requiredMissing.isEmpty && !status.hasWarnings

        let parent = NSMenuItem(title: allGood ? "Permissions" : "Permissions (needs attention)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // mark: "✓" fine, "✗" missing, "!" optional or unclear. A row with a
        // page to open (url) or a window to open (opensSetup) is clickable
        // while it isn't fine.
        func row(_ title: String, mark: String, url: String? = nil, opensSetup: Bool = false) {
            let clickable = mark != "✓" && (url != nil || opensSetup)
            let row = NSMenuItem(title: "\(mark)  \(title)", action: clickable ? #selector(permissionRowClicked(_:)) : nil, keyEquivalent: "")
            row.target = self
            row.representedObject = url ?? ""
            row.isEnabled = clickable
            submenu.addItem(row)
        }
        row("Input Monitoring (Cmd+Tab)", mark: status.inputMonitoringOK ? "✓" : "✗",
            url: status.inputPreflight ? nil : "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            opensSetup: status.inputPreflight)
        row("Screen Recording (thumbnails)", mark: status.screenRecording ? "✓" : "✗",
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        let installedMark = status.cliPath == nil ? "✗" : (status.needsRestartForCLI ? "!" : "✓")
        row("AeroSpace installed", mark: installedMark, opensSetup: true)
        let runningMark: String
        switch status.aerospace {
        case .running: runningMark = "✓"
        case .notInstalled, .notRunning: runningMark = "✗"
        case .disabled, .unknown: runningMark = "!"
        }
        row("AeroSpace running", mark: runningMark, opensSetup: true)
        row("Recent order", mark: status.recentOrderNeedsHook && status.hook != .present ? "!" : "✓", opensSetup: true)
        submenu.addItem(.separator())
        submenu.addItem(item("Setup...", #selector(setupHelpClicked)))
        parent.submenu = submenu
        return parent
    }

    @objc private func permissionRowClicked(_ sender: NSMenuItem) {
        if let string = sender.representedObject as? String, !string.isEmpty, let url = URL(string: string) {
            logInfo("Menu: open System Settings page \(string)")
            NSWorkspace.shared.open(url)
        } else {
            setupHelpClicked()
        }
    }

    @objc private func setupHelpClicked() {
        logInfo("Menu: setup help")
        SetupHelp.shared.show()
    }

    // MARK: Actions

    @objc private func workspaceClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        logInfo("Menu: switch to workspace \(name)")
        switchToWorkspace(name)
        // The bar updates when AeroSpace reports the switch (the event).
    }

    @objc private func toggleEnabledClicked() {
        let enable = !aerospaceEnabled
        logInfo("Menu: \(enable ? "enable" : "disable") AeroSpace")
        Task.detached {
            let result = setAeroSpaceEnabled(enable)
            logInfo("aerospace enable \(enable ? "on" : "off"): \(result.ok ? "ok" : "failed") \(result.output)")
            await MainActor.run {
                if result.ok { self.aerospaceEnabled = enable }
                self.updateBar()
            }
        }
    }

    @objc private func reloadClicked() {
        logInfo("Menu: reload config")
        settings.reloadTogether()
    }

    @objc private func openAeroSpaceConfigClicked() {
        logInfo("Menu: open AeroSpace config")
        Task.detached {
            // Ask AeroSpace where its config is; if it can't answer, the
            // usual place.
            let path = getAeroSpaceConfigPath() ?? NSHomeDirectory() + "/.aerospace.toml"
            await MainActor.run {
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    logWarn("No AeroSpace config found at \(path).")
                    showFailureAlert("No AeroSpace config found",
                        "AeroSpace reads \(path). Create that file, then try again.")
                }
            }
        }
    }

    @objc private func openConfigJSONClicked() {
        logInfo("Menu: open config.json")
        NSWorkspace.shared.open(configFileURL())
    }

    @objc private func settingsClicked() {
        logInfo("Menu: settings")
        SettingsWindow.shared.show()
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
    //
    // Not private: the settings window's "Launch at login" toggle calls
    // this same function, so both always behave the same.
    @objc func launchAtLoginClicked() {
        defer { NotificationCenter.default.post(name: .menuBarTogglesChanged, object: nil) }
        let service = SMAppService.mainApp
        logInfo("Menu: launch at login clicked, status was \(service.status)")
        let path = Bundle.main.bundlePath
        let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        // Both ways, not just turning it on: a test copy in the project
        // folder sees the installed app's login item as its own (same app
        // ID), so turning it OFF there would quietly remove the real one.
        // That happened once while testing the settings window.
        guard inApplications else {
            logWarn("Launch at login: refused, this copy is in \(path)")
            alert("Launch at login only works from the Applications folder",
                  "This copy of AeroSwitcher is in \(path). Change Launch at login from the copy in /Applications, so the login item always points at the right place.")
            return
        }
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return
            default:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            logInfo("Launch at login: status is now \(service.status)")
        } catch {
            logError("Launch at login failed: \(error)")
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
    // config.json: it belongs with the divider's saved position (also in
    // these preferences, and only meaningful on this Mac), and turning it on
    // needs the arranging step above, which a hand edit of config.json would
    // skip. The settings window shows it as a toggle that runs this code.

    private var divider: NSStatusItem?
    private let hideAeroSpaceIconKey = "HideAeroSpaceIcon"

    private var hideAeroSpaceIcon: Bool {
        get { UserDefaults.standard.bool(forKey: hideAeroSpaceIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideAeroSpaceIconKey) }
    }

    // For the settings window's toggle.
    var isHidingAeroSpaceIcon: Bool { hideAeroSpaceIcon }

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
        logInfo("Divider: \(wide ? "wide, hiding the icons on its left" : "showing as │")")
    }

    private func removeDivider() {
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        divider = nil
        logInfo("Divider: removed, AeroSpace's icon is visible again")
    }

    // Not private, for the same reason as launchAtLoginClicked: the settings
    // window's toggle runs exactly this, alert and all.
    @objc func hideAeroSpaceIconClicked() {
        defer { NotificationCenter.default.post(name: .menuBarTogglesChanged, object: nil) }
        if hideAeroSpaceIcon {
            logInfo("Menu: show AeroSpace's icon again")
            hideAeroSpaceIcon = false
            removeDivider()
            return
        }
        logInfo("Menu: hide AeroSpace's icon (arranging)")
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

    // The standard macOS About panel. It fills in the icon, the name, the
    // "Version 0.9.0 (57)" line and the copyright line (NSHumanReadableCopyright
    // in Info.plist) by itself; everything in the grey scrolling text below
    // them is the `credits` built here. To change what it says, change the
    // lines in `showAbout`. The version numbers come from build.sh, see
    // appVersion() in Config.swift.
    @objc private func aboutClicked() {
        logInfo("Menu: about")
        // AeroSpace is asked off the main thread first (the same thread runs
        // the Cmd+Tab hook, and a slow AeroSpace used to freeze it for up to
        // 2 seconds here). The panel opens once there's an answer.
        Task.detached {
            let aerospaceText = getAeroSpaceVersionText()
            await MainActor.run { self.showAbout(aerospaceText: aerospaceText) }
        }
    }

    // `aerospace --version` prints two lines (the command's version and the
    // running app's). The app's is the one that matters, so show that one.
    private func aerospaceVersionLine(_ text: String) -> String {
        if let range = text.range(of: "server version: ") {
            let version = text[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\n" }).first ?? ""
            if !version.isEmpty && !version.hasPrefix("Can't") { return "AeroSpace \(version)" }
        }
        if let range = text.range(of: "client version: ") {
            let version = text[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\n" }).first ?? ""
            if !version.isEmpty { return "AeroSpace \(version) (not running)" }
        }
        return "AeroSpace isn't reachable"
    }

    private func showAbout(aerospaceText: String) {
        let repoURL = "https://github.com/remitoshniwal/aeroswitcher"
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let credits = NSMutableAttributedString(
            string: "A Cmd+Tab for the current AeroSpace workspace.\n\n", attributes: plain)
        func line(_ text: String, link: (word: String, url: String)? = nil) {
            let start = credits.length
            credits.append(NSAttributedString(string: text + "\n", attributes: plain))
            if let link {
                let range = (credits.string as NSString).range(of: link.word, range: NSRange(location: start, length: text.count))
                credits.addAttribute(.link, value: URL(string: link.url)!, range: range)
            }
        }
        if let v = appVersion() { line("Commit \(v.commit)") }
        line(aerospaceVersionLine(aerospaceText))
        line("")
        line("Source code on GitHub", link: ("Source code on GitHub", repoURL))
        line("MIT License", link: ("MIT License", repoURL + "/blob/main/LICENSE"))
        line("Log folder", link: ("Log folder", logDirectoryURL().absoluteString))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let v = appVersion() {
            options[.applicationVersion] = v.version
            options[.version] = v.build
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func quitClicked() {
        logInfo("Menu: quit")
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    // Posted after Launch at login or Hide AeroSpace's icon was clicked
    // (in the menu or the settings window), so an open settings window
    // shows the new state.
    static let menuBarTogglesChanged = Notification.Name("AeroSwitcherMenuBarTogglesChanged")
}
