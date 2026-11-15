import AppKit

/// "XSwitcher Settings": the Settings window and the optional menu bar icon.
/// It lives inside XSwitcher.app/Contents/Helpers and quits when its window
/// closes (unless the icon is on). The switching itself is XSwitcher.app's
/// main program (agent/), which keeps running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: SettingsWindowController?
    private let menuBar = MenuBarController()
    private let launchedForMenuBar = CommandLine.arguments.contains("--menubar")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { // renders the panes (for development)
            let wc = SettingsWindowController()
            wc.snapshot(to: URL(fileURLWithPath: args[i + 1]), dark: args.contains("--dark"))
            exit(0)
        }
        if args.contains("--check-updates") { // prints the result (for testing)
            Updater.check { result in
                print("current \(Updater.currentVersion), repo \(Updater.repo ?? "none"): \(result)")
                exit(0)
            }
            return
        }

        Agent.ensureRunning()
        menuBar.openSettings = { [weak self] in self?.showSettings() }
        menuBar.quit = {
            Agent.stop()
            NSApp.terminate(nil)
        }
        if Settings.load().menuBar { menuBar.install() }

        if !launchedForMenuBar {
            showSettings()
        } else if !menuBar.isInstalled {
            NSApp.terminate(nil) // started for the icon, but the icon is turned off
        }
    }

    // XSwitcher opens this again when you open XSwitcher from Applications.
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
                // Without the menu bar icon there's nothing left to show:
                // quit and leave only XSwitcher's small background part.
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

/// Used only for --snapshot: draws controls as if the app were in front,
/// without taking focus from whatever you're doing.
final class SnapshotApplication: NSApplication {
    override var isActive: Bool { true }
}

MainActor.assumeIsolated {
    // The first .shared call decides the class of the app object.
    let app = CommandLine.arguments.contains("--snapshot") ? SnapshotApplication.shared : NSApplication.shared
    let delegate = AppDelegate() // app.delegate is weak; this stays alive while run() runs
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = keyEquivalentMenu()
    app.run()
}

/// Accessory apps show no menu bar, but key equivalents still work:
/// ⌘W closes Settings, ⌘Q quits it, ⌘C/⌘V work in text fields.
@MainActor
func keyEquivalentMenu() -> NSMenu {
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
