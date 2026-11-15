import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}
    var onMenuBarChanged: (Bool) -> Void = { _ in }

    private var settings = Settings.load()
    private var recorders: [String: ShortcutButton] = [:]
    private var timer: Timer?

    private let stack = NSStackView()
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusText = NSTextField(labelWithString: "")
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private var trackpadRow: NSView!
    private var desktopGrid: NSGridView!
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private var overrideBox: NSButton!
    private var swipeBox: NSButton!
    private var loginBox: NSButton!
    private var loginNote: NSView!
    private var menuBarBox: NSButton!
    private var autoUpdateBox: NSButton!
    private let updateText = NSTextField(wrappingLabelWithString: "")
    private let downloadButton = NSButton(title: "Download", target: nil, action: nil)
    private var downloadURL: URL?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "XSwitcher"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        refreshStatus()
        fitWindow()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Showing

    func present() {
        settings = Settings.load()
        for (name, b) in recorders { b.shortcut = settings.shortcuts[name] }
        refreshStatus()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        if settings.checkUpdates && Updater.isDue { checkUpdates() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        recorders.values.forEach { $0.stop() }
        onClose()
    }

    // MARK: - Layout

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Status line
        statusDot.font = .systemFont(ofSize: 14)
        statusText.font = .systemFont(ofSize: 13, weight: .medium)
        statusButton.bezelStyle = .rounded
        statusButton.target = self
        statusButton.action = #selector(statusButtonClicked)
        let statusRow = NSStackView(views: [statusDot, statusText, statusButton])
        statusRow.spacing = 6
        stack.addArrangedSubview(statusRow)

        let trackpadText = note("Your trackpad's “swipe between full-screen apps” gesture is off. macOS 27.2 and later need it on for instant switching.")
        let trackpadButton = NSButton(title: "Open Trackpad Settings", target: self, action: #selector(openTrackpadSettings))
        trackpadButton.bezelStyle = .rounded
        trackpadRow = NSStackView(views: [trackpadText, trackpadButton])
        (trackpadRow as! NSStackView).orientation = .vertical
        (trackpadRow as! NSStackView).alignment = .leading
        trackpadRow.isHidden = true
        stack.addArrangedSubview(trackpadRow)

        stack.addArrangedSubview(separator())

        // Shortcuts
        stack.addArrangedSubview(header("Keyboard shortcuts"))
        let main = NSGridView(views: [
            shortcutRow("Move one desktop left", "left"),
            shortcutRow("Move one desktop right", "right"),
            shortcutRow("Go back to previous desktop", "last"),
        ])
        styleGrid(main)
        stack.addArrangedSubview(main)

        overrideBox = checkbox("Take over macOS's own shortcuts (needed for ⌃← and ⌃→)", #selector(overrideToggled))
        overrideBox.state = settings.overrideSystemShortcuts ? .on : .off
        stack.addArrangedSubview(overrideBox)

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggleDesktops)
        let discLabel = NSButton(title: "Shortcuts to jump straight to a desktop", target: self, action: #selector(toggleDesktopsFromLabel))
        discLabel.isBordered = false
        stack.addArrangedSubview(NSStackView(views: [disclosure, discLabel]))

        var rows: [[NSView]] = []
        for i in 1...8 {
            rows.append(shortcutRow("Desktop \(i)", "space\(i)", width: 104) + [NSView()]
                        + shortcutRow("Desktop \(i + 8)", "space\(i + 8)", width: 104))
        }
        desktopGrid = NSGridView(views: rows)
        styleGrid(desktopGrid)
        desktopGrid.column(at: 3).width = 12
        desktopGrid.isHidden = !Settings.bindingNames.dropFirst(3).contains { settings.shortcuts[$0] != nil }
        disclosure.state = desktopGrid.isHidden ? .off : .on
        stack.addArrangedSubview(desktopGrid)

        stack.addArrangedSubview(note("Click a shortcut, then press the keys. Esc cancels, Delete clears it."))
        stack.addArrangedSubview(separator())

        // Trackpad
        stack.addArrangedSubview(header("Trackpad"))
        swipeBox = checkbox("Make trackpad swipes between desktops instant", #selector(swipeToggled))
        swipeBox.state = settings.swipeOverride ? .on : .off
        stack.addArrangedSubview(swipeBox)
        stack.addArrangedSubview(separator())

        // General
        stack.addArrangedSubview(header("General"))
        loginBox = checkbox("Open XSwitcher when I log in", #selector(loginToggled))
        stack.addArrangedSubview(loginBox)
        let approve = NSButton(title: "Open Login Items", target: self, action: #selector(openLoginItems))
        approve.bezelStyle = .rounded
        loginNote = NSStackView(views: [note("macOS needs you to allow XSwitcher in Login Items."), approve])
        loginNote.isHidden = true
        stack.addArrangedSubview(loginNote)
        menuBarBox = checkbox("Show the desktop number in the menu bar (uses ~17 MB more memory)", #selector(menuBarToggled))
        menuBarBox.state = settings.menuBar ? .on : .off
        stack.addArrangedSubview(menuBarBox)
        stack.addArrangedSubview(note("Hidden? Open XSwitcher from Applications to get back to this window."))
        stack.addArrangedSubview(separator())

        // Updates
        stack.addArrangedSubview(header("Updates"))
        let check = NSButton(title: "Check for Updates", target: self, action: #selector(checkUpdates))
        check.bezelStyle = .rounded
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(download)
        downloadButton.isHidden = true
        let version = NSTextField(labelWithString: "Version \(Updater.currentVersion)")
        stack.addArrangedSubview(NSStackView(views: [version, check, downloadButton]))
        updateText.textColor = .secondaryLabelColor
        updateText.font = .systemFont(ofSize: 11)
        updateText.preferredMaxLayoutWidth = 430
        updateText.isHidden = true
        stack.addArrangedSubview(updateText)
        autoUpdateBox = checkbox("Check automatically once a day", #selector(autoUpdateToggled))
        autoUpdateBox.state = settings.checkUpdates ? .on : .off
        stack.addArrangedSubview(autoUpdateBox)
        stack.addArrangedSubview(separator())

        // Credit
        let credit = NSButton(title: "Based on InstantSpaceSwitcher by jurplel · MIT License", target: self, action: #selector(openUpstream))
        credit.isBordered = false
        credit.contentTintColor = .linkColor
        credit.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(credit)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        window?.contentView = content
    }

    private func fitWindow() {
        guard let w = window else { return }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height) // keep the title bar in place
        w.setFrame(frame, display: true, animate: false)
    }

    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 430
        return l
    }

    private func checkbox(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 436).isActive = true
        return box
    }

    private func styleGrid(_ g: NSGridView) {
        g.rowSpacing = 6
        g.columnSpacing = 8
        g.yPlacement = .center
        g.column(at: 0).xPlacement = .leading
        g.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func shortcutRow(_ label: String, _ name: String, width: CGFloat = 150) -> [NSView] {
        let b = ShortcutButton(shortcut: settings.shortcuts[name], width: width)
        b.onChange = { [weak self] s in self?.setShortcut(name, s) }
        recorders[name] = b
        let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")!,
                             target: self, action: #selector(clearShortcut(_:)))
        clear.isBordered = false
        clear.contentTintColor = .tertiaryLabelColor
        clear.identifier = NSUserInterfaceItemIdentifier(name)
        clear.toolTip = "Remove this shortcut"
        return [NSTextField(labelWithString: label), b, clear]
    }

    // MARK: - Status

    private func refreshStatus() {
        let st = Agent.status()
        statusButton.isHidden = false
        if st == nil || st?.isRunning != true {
            setStatus(.systemRed, "XSwitcher isn't running", button: "Start")
        } else if st?.hasAccessibility != true {
            setStatus(.systemOrange, "Needs permission: turn on XSwitcher and xswitcher-agent", button: "Allow in Settings…")
        } else if let failed = st?.failedShortcuts, !failed.isEmpty {
            setStatus(.systemOrange, "Another app already uses: \(failed.joined(separator: ", "))", button: nil)
        } else if st?.configOK == false {
            setStatus(.systemOrange, "The settings file has an error", button: "Show File")
        } else {
            setStatus(.systemGreen, "Working: switching is instant", button: nil)
        }
        trackpadRow.isHidden = st?.trackpadGestureOn ?? true
        let wantsLogin = LoginItem.isEnabled || LoginItem.needsApproval
        loginBox.state = wantsLogin ? .on : .off
        loginNote.isHidden = !LoginItem.needsApproval
    }

    private func setStatus(_ color: NSColor, _ text: String, button: String?) {
        statusDot.textColor = color
        statusText.stringValue = text
        statusButton.isHidden = button == nil
        statusButton.title = button ?? ""
    }

    @objc private func statusButtonClicked() {
        switch statusButton.title {
        case "Start": Agent.start()
        case "Show File": NSWorkspace.shared.activateFileViewerSelecting([Paths.config])
        default:
            // Puts both halves in the Accessibility list (the agent asks for
            // itself), then opens that list.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("local.xswitcher.requestAccess"), object: nil, userInfo: nil, deliverImmediately: true)
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshStatus() }
    }

    // MARK: - Actions

    private func save() {
        do {
            try settings.save()
            Agent.reload()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func setShortcut(_ name: String, _ s: Shortcut?) {
        if let s {
            // One shortcut, one action: drop it from wherever else it was.
            for (other, b) in recorders where other != name && settings.shortcuts[other] == s {
                settings.shortcuts[other] = nil
                b.shortcut = nil
            }
        }
        settings.shortcuts[name] = s
        save()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        recorders[name]?.shortcut = nil
        setShortcut(name, nil)
    }

    @objc private func overrideToggled(_ b: NSButton) {
        settings.overrideSystemShortcuts = b.state == .on
        save()
    }

    @objc private func toggleDesktops() {
        desktopGrid.isHidden = disclosure.state == .off
        fitWindow()
    }

    @objc private func toggleDesktopsFromLabel() {
        disclosure.state = disclosure.state == .on ? .off : .on
        toggleDesktops()
    }

    @objc private func swipeToggled(_ b: NSButton) {
        settings.swipeOverride = b.state == .on
        save()
    }

    @objc private func loginToggled(_ b: NSButton) {
        do {
            try LoginItem.set(b.state == .on)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change “Open at login”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshStatus() }
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func menuBarToggled(_ b: NSButton) {
        settings.menuBar = b.state == .on
        save()
        onMenuBarChanged(settings.menuBar)
    }

    @objc private func autoUpdateToggled(_ b: NSButton) {
        settings.checkUpdates = b.state == .on
        save()
    }

    @objc private func checkUpdates() {
        updateText.isHidden = false
        updateText.stringValue = "Checking…"
        downloadButton.isHidden = true
        Updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .notConfigured:
                self.updateText.stringValue = "Updates aren't set up yet: the GitHub repo still needs to be added (XSUpdateRepo in Info.plist)."
            case .noReleases:
                self.updateText.stringValue = "No versions have been published on GitHub yet."
            case .upToDate(let v):
                self.updateText.stringValue = "You have the latest version (\(v))."
            case let .available(version, url):
                self.updateText.stringValue = "Version \(version) is available."
                self.downloadURL = url
                self.downloadButton.isHidden = false
            case .failed(let why):
                self.updateText.stringValue = "Couldn't check for updates: \(why)"
            }
            self.fitWindow()
        }
        fitWindow()
    }

    @objc private func download() { if let downloadURL { NSWorkspace.shared.open(downloadURL) } }
    @objc private func openTrackpadSettings() { open("x-apple.systempreferences:com.apple.Trackpad-Settings.extension") }
    @objc private func openUpstream() { open("https://github.com/jurplel/InstantSpaceSwitcher") }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    // MARK: - Development

    /// Renders the window to a PNG without showing it (used to check the layout).
    func snapshot(to url: URL, dark: Bool) {
        guard let view = window?.contentView else { return }
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if dark { desktopGrid.isHidden = false; disclosure.state = .on }
        fitWindow()
        view.layoutSubtreeIfNeeded()
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
