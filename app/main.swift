import AppKit

/// XSwitcher's visible half: the Settings window and the optional menu bar
/// icon. The switching itself happens in xswitcher-agent, which keeps
/// running (at ~6 MB) after this window closes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: SettingsWindowController?
    private let menuBar = MenuBarController()
    private let launchedForMenuBar = CommandLine.arguments.contains("--menubar")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let wc = SettingsWindowController()
            let path = CommandLine.arguments[i + 1]
            wc.snapshot(to: URL(fileURLWithPath: path), dark: CommandLine.arguments.contains("--dark"))
            exit(0)
        }

        if CommandLine.arguments.contains("--check-updates") { // prints the result (for testing)
            Updater.check { result in
                print("current \(Updater.currentVersion), repo \(Updater.repo ?? "none"): \(result)")
                exit(0)
            }
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--login") { // on | off | status (for testing)
            let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
            do {
                if arg == "on" { try LoginItem.set(true) }
                if arg == "off" { try LoginItem.set(false) }
                print("open at login: \(LoginItem.service.status.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
            } catch {
                print("error: \(error.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) } // let the restart delays run
            return
        }

        if !LoginItem.repairIfNeeded(then: { Agent.ensureRunning() }) {
            Agent.ensureRunning()
        }
        menuBar.openSettings = { [weak self] in self?.showSettings() }
        menuBar.quit = { Agent.stop(); NSApp.terminate(nil) }
        if Settings.load().menuBar { menuBar.install() }

        if !launchedForMenuBar {
            showSettings()
        } else if !menuBar.isInstalled {
            NSApp.terminate(nil) // started for the icon, but the icon is turned off
        }
    }

    // Opening XSwitcher again from Applications or Spotlight shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func showSettings() {
        if settingsWindow == nil {
            let wc = SettingsWindowController()
            wc.onClose = { [weak self] in
                guard let self else { return }
                // Without the menu bar icon there is nothing left to show:
                // quit and leave only the small agent running.
                if !self.menuBar.isInstalled { NSApp.terminate(nil) }
            }
            wc.onMenuBarChanged = { [weak self] on in
                guard let self else { return }
                on ? self.menuBar.install() : self.menuBar.uninstall()
            }
            settingsWindow = wc
        }
        settingsWindow?.present()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate() // app.delegate is weak; this stays alive while run() runs
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = editMenu()
    app.run()
}

/// Accessory apps show no menu bar, but the key equivalents still work:
/// ⌘W closes Settings, ⌘Q quits it, ⌘C/⌘V work in text fields.
@MainActor
func editMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    appMenu.addItem(withTitle: "Quit Settings", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    return main
}
