import Cocoa
import ServiceManagement

// MARK: - Menu bar icon
//
// The one icon AeroSwitcher puts in the menu bar. It shows the name of the
// workspace you're in, and its menu lets you switch workspace, bring back
// every window (the rescue for a window stuck off screen), reload the
// config, plus AeroSwitcher's own things (Settings, permission status,
// launch at login, About, Quit).
//
// How it stays up to date: the window manager (WorkspaceManager.swift)
// tells it the moment the workspace changes, and the menu is rebuilt from
// the manager's in-memory copy every time it opens, so a missed update
// can't leave a stale menu behind.

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem

    // What the bar currently shows.
    private var workspaceName: String?

    // `onFocus` gets every "this window now has focus" report from the
    // window manager; it feeds the recent order (see main.swift).
    init(onFocus: ((String, String) -> Void)? = nil) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        WorkspaceManager.shared.onFocusChanged = onFocus
        // Remembers where in the bar you dragged the icon (Cmd+drag).
        statusItem.autosaveName = "AeroSwitcher"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // The Permissions item follows the setup check (SetupHelp.swift).
        NotificationCenter.default.addObserver(forName: .setupStatusChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.statusItem.menu else { return }
                self.buildMenu(menu)
            }
        }
        workspaceName = WorkspaceManager.shared.focusedWorkspaceSnapshot()
        WorkspaceManager.shared.onWorkspaceChanged = { [weak self] name in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.workspaceName = name
                self.updateBar()
                self.refreshSnapshot()
            }
        }
        updateBar()
        // The manager can pause or carry on by itself (another window
        // manager started, a permission switched off and on), with no event
        // for it. A cheap look every few seconds keeps the warning symbol
        // honest.
        managerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.updateBar() }
        }

        // `pkill AeroSwitcher` (and Ctrl+C in Terminal) end the app the
        // normal way, so the window manager's quit step (atexit in
        // WorkspaceManager.swift) still puts every parked window back on
        // screen. The handlers run on a background queue on purpose: if the
        // main thread were ever stuck, a quit signal would still work.
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                logInfo("Quit by signal \(signalNumber)")
                flushLog()
                exit(0)
            }
            source.resume()
            quitSignalSources.append(source)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            logInfo("Quitting")
            flushLog()
        }
    }

    private var quitSignalSources: [DispatchSourceSignal] = []
    private var managerTimer: Timer?

    // MARK: The bar itself

    // The workspace name normally, a warning symbol while the window
    // manager is paused. The font is monospaced so the icon doesn't change
    // width much between workspace names; change the font here if you
    // prefer.
    private func updateBar() {
        guard let button = statusItem.button else { return }
        if let reason = WorkspaceManager.shared.pausedReason {
            show(symbol: "exclamationmark.triangle.fill", on: button)
            button.toolTip = "AeroSwitcher's window manager is paused: \(reason)"
        } else {
            showName(workspaceName ?? WorkspaceManager.shared.focusedWorkspaceSnapshot(), on: button)
        }
    }

    private func showName(_ name: String?, on button: NSStatusBarButton) {
        button.image = nil
        button.imagePosition = .noImage
        button.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.title = name ?? "..."
        button.toolTip = nil
    }

    private func show(symbol: String, on button: NSStatusBarButton) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
    }

    // MARK: The menu

    // What the menu shows, as last read from the window manager.
    private struct MenuSnapshot: Equatable {
        var focused: String?
        var names: [String] = []
        var apps: [String: [String]] = [:]
        var hasWorkspaces: Bool { !names.isEmpty }
    }
    private var snapshot = MenuSnapshot()

    // Reads everything the menu needs (all in memory, nothing to wait
    // for), then rebuilds the menu if anything changed (also while it's
    // open, macOS updates an open menu in place).
    private func refreshSnapshot() {
        var fresh = MenuSnapshot()
        let manager = WorkspaceManager.shared
        fresh.focused = manager.focusedWorkspaceSnapshot()
        fresh.names = manager.workspaceNamesSnapshot()
        fresh.apps = getAppNamesByWorkspace()
        updateBar()
        if fresh != snapshot {
            snapshot = fresh
            if let menu = statusItem.menu { buildMenu(menu) }
        }
    }

    // Called by macOS every time the menu is about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        buildMenu(menu)
        refreshSnapshot()
        SetupHelp.shared.refresh()
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false  // so an item set to disabled below stays disabled

        if snapshot.hasWorkspaces {
            menu.addItem(NSMenuItem.sectionHeader(title: "Workspaces"))
            for name in snapshot.names {
                let item = NSMenuItem(title: name, action: #selector(workspaceClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = name == snapshot.focused ? .on : .off
                item.attributedTitle = workspaceRowTitle(name: name, apps: snapshot.apps[name] ?? [])
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: "No workspaces set up (Settings > Workspaces)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Paused shows on its own line too, so the reason is readable
        // without hovering over the icon.
        if let reason = WorkspaceManager.shared.pausedReason {
            let paused = NSMenuItem(title: "Window manager paused: \(reason)", action: nil, keyEquivalent: "")
            paused.isEnabled = false
            menu.addItem(paused)
        }
        menu.addItem(item("Bring Back All Windows", #selector(bringBackClicked)))
        menu.addItem(item("Reload config", #selector(reloadClicked)))

        menu.addItem(.separator())
        addRestOfMenu(menu)
    }

    private func addRestOfMenu(_ menu: NSMenu) {
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
        menu.addItem(item("About AeroSwitcher", #selector(aboutClicked)))
        menu.addItem(item("Quit AeroSwitcher", #selector(quitClicked)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    // "Core" in the normal text, then the apps in it in smaller grey text,
    // cut off after about 25 characters.
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
        let cmdTabAllowed = status.accessibilityTrusted || status.inputPreflight
        row("Window manager", mark: status.managerPausedReason == nil ? "✓" : "✗", opensSetup: true)
        row("Accessibility (Cmd+Tab and windows)", mark: status.inputMonitoringOK ? "✓" : "✗",
            url: cmdTabAllowed ? nil : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            opensSetup: cmdTabAllowed)
        row("Screen Recording (thumbnails)", mark: status.screenRecording ? "✓" : "✗",
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
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
        // The bar updates when the window manager reports the switch.
    }

    @objc private func reloadClicked() {
        logInfo("Menu: reload config")
        let report = settings.reload()
        ConfigProblemsWindow.shared.update(report: report)
    }

    @objc private func bringBackClicked() {
        logInfo("Menu: bring back all windows")
        WorkspaceManager.shared.bringBackAllWindows()
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
    // MARK: About, Quit

    // The standard macOS About panel. It fills in the icon, the name, the
    // "Version 0.9.0 (57)" line and the copyright line (NSHumanReadableCopyright
    // in Info.plist) by itself; everything in the grey scrolling text below
    // them is the `credits` built here. To change what it says, change the
    // lines in `showAbout`. The version numbers come from build.sh, see
    // appVersion() in Config.swift.
    @objc private func aboutClicked() {
        logInfo("Menu: about")
        showAbout()
    }

    private func showAbout() {
        let repoURL = "https://github.com/remitoshniwal/aeroswitcher"
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let credits = NSMutableAttributedString(
            string: "Workspaces for macOS, with a Cmd+Tab that only shows the current workspace.\n\n", attributes: plain)
        func line(_ text: String, link: (word: String, url: String)? = nil) {
            let start = credits.length
            credits.append(NSAttributedString(string: text + "\n", attributes: plain))
            if let link {
                let range = (credits.string as NSString).range(of: link.word, range: NSRange(location: start, length: text.count))
                credits.addAttribute(.link, value: URL(string: link.url)!, range: range)
            }
        }
        if let v = appVersion() { line("Commit \(v.commit)") }
        line("Window management adapted from AeroSpace (MIT)", link: ("AeroSpace", "https://github.com/nikitabobko/AeroSpace"))
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
    // Posted after Launch at login was clicked (in the menu or the settings
    // window), so an open settings window shows the new state.
    static let menuBarTogglesChanged = Notification.Name("AeroSwitcherMenuBarTogglesChanged")
}
