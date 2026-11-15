import AppKit

// MARK: - Building blocks

private let contentWidth: CGFloat = 460

/// A rounded box of rows with hairlines between them, like System Settings.
@MainActor
final class FormGroup: NSView {
    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: contentWidth - 28).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

@MainActor
private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.isSelectable = false
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

/// Title (+ optional subtitle) on the left, a control on the right. The text
/// wraps; the control never gets pushed out of the box.
@MainActor
private func row(_ title: NSTextField, _ subtitle: NSTextField? = nil, icon: NSImageView? = nil,
                 accessory: NSView? = nil) -> NSView {
    let texts = NSStackView(views: [title] + (subtitle.map { [$0] } ?? []))
    texts.orientation = .vertical
    texts.alignment = .leading
    texts.spacing = 2
    texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
    var views: [NSView] = []
    if let icon { views.append(icon) }
    views.append(texts)
    views.append(spacer())
    if let accessory {
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        views.append(accessory)
    }
    let h = NSStackView(views: views)
    h.orientation = .horizontal
    h.alignment = .centerY
    h.spacing = 10
    h.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    h.translatesAutoresizingMaskIntoConstraints = false
    return h
}

/// Takes up the leftover width so controls line up on the right edge.
@MainActor
private func spacer() -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    v.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
    return v
}

@MainActor
private func caption(_ text: String) -> NSTextField {
    let l = label(text, size: 11, color: .secondaryLabelColor)
    l.preferredMaxLayoutWidth = contentWidth - 8
    return l
}

@MainActor
private func symbol(_ name: String, _ color: NSColor, size: CGFloat = 22) -> NSImageView {
    let v = NSImageView()
    v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    v.contentTintColor = color
    v.setContentHuggingPriority(.required, for: .horizontal)
    return v
}

@MainActor
private func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    return b
}

@MainActor
private func toggle(_ on: Bool, _ target: AnyObject, _ action: Selector) -> NSSwitch {
    let s = NSSwitch()
    s.state = on ? .on : .off
    s.target = target
    s.action = action
    return s
}

/// A pane: a vertical column of groups and captions with standard margins.
@MainActor
private func pane(_ views: [NSView]) -> NSView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 22, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
}

// MARK: - General

@MainActor
final class GeneralPane: NSViewController {
    private var settings = Settings.load()
    var onMenuBarChanged: (Bool) -> Void = { _ in }
    var onLayoutChange: () -> Void = {}

    private let statusIcon = NSImageView()
    private let statusTitle = label("", weight: .semibold)
    private let statusText = label("", size: 11, color: .secondaryLabelColor)
    private var statusButton: NSButton!
    private var trackpadGroup: NSView!
    private var loginSwitch: NSSwitch!
    private var loginText: NSTextField!
    private var swipeSwitch: NSSwitch!
    private var menuBarSwitch: NSSwitch!
    private var reopenHint: NSTextField!
    private var timer: Timer?
    private var lastLayoutKey = ""

    override func loadView() {
        title = "General"
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusButton = button("Allow…", self, #selector(statusAction))
        let statusGroup = FormGroup([row(statusTitle, statusText, icon: statusIcon, accessory: statusButton)])

        trackpadGroup = FormGroup([row(
            label("Trackpad gesture is off", weight: .semibold),
            label("macOS 27.2 and later need “Swipe between full-screen apps” turned on for instant switching.",
                  size: 11, color: .secondaryLabelColor),
            icon: symbol("hand.draw", .systemOrange),
            accessory: button("Open Settings", self, #selector(openTrackpad)))])

        loginSwitch = toggle(false, self, #selector(loginChanged))
        loginText = label("Starts quietly in the background.", size: 11, color: .secondaryLabelColor)
        swipeSwitch = toggle(settings.swipeOverride, self, #selector(swipeChanged))
        menuBarSwitch = toggle(settings.menuBar, self, #selector(menuBarChanged))
        let options = FormGroup([
            row(label("Open at login"), loginText, accessory: loginSwitch),
            row(label("Instant trackpad swipes"),
                label("Swiping between desktops skips the animation.", size: 11, color: .secondaryLabelColor),
                accessory: swipeSwitch),
            row(label("Show in menu bar"),
                label("Shows the current desktop number. Uses about 17 MB more memory.", size: 11, color: .secondaryLabelColor),
                accessory: menuBarSwitch),
        ])
        reopenHint = caption("To come back here, open XSwitcher again from Applications or Spotlight.")
        reopenHint.isHidden = settings.menuBar
        view = pane([statusGroup, trackpadGroup, options, reopenHint])
        refresh(loginToo: true)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh(loginToo: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(loginToo: false) }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }

    func refresh(loginToo: Bool) {
        let st = Agent.status()
        if st?.isRunning != true {
            setStatus("xmark.octagon.fill", .systemRed, "XSwitcher isn't running",
                      "Start it to use your shortcuts and swipes.", button: "Start")
        } else if st?.hasAccessibility != true {
            setStatus("exclamationmark.triangle.fill", .systemOrange, "Permission needed",
                      "Click Allow, then turn on XSwitcher under Privacy & Security › Accessibility.",
                      button: "Allow…")
        } else if let failed = st?.failedShortcuts, !failed.isEmpty {
            setStatus("exclamationmark.triangle.fill", .systemOrange, "Some shortcuts are taken",
                      "Another app already uses: \(failed.joined(separator: ", ")).", button: nil)
        } else if st?.configOK == false {
            setStatus("exclamationmark.triangle.fill", .systemOrange, "Settings file has an error",
                      "Some lines couldn't be read.", button: "Show File")
        } else {
            setStatus("checkmark.circle.fill", .systemGreen, "XSwitcher is working",
                      "Desktop switching is instant.", button: nil)
        }
        trackpadGroup.isHidden = st?.trackpadGestureOn ?? true
        if loginToo {
            let state = LoginItem.state()
            loginSwitch.state = state == .off ? .off : .on
            loginText.stringValue = state == .needsApproval
                ? "Allow XSwitcher in System Settings › General › Login Items."
                : "Starts quietly in the background."
            loginText.textColor = state == .needsApproval ? .systemOrange : .secondaryLabelColor
        }
        let key = "\(trackpadGroup.isHidden)\(statusButton.isHidden)\(statusText.stringValue)\(reopenHint.isHidden)"
        if key != lastLayoutKey { lastLayoutKey = key; onLayoutChange() }
    }

    private func setStatus(_ icon: String, _ color: NSColor, _ title: String, _ text: String, button: String?) {
        statusIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
        statusIcon.contentTintColor = color
        statusTitle.stringValue = title
        statusText.stringValue = text
        statusButton.isHidden = button == nil
        statusButton.title = button ?? ""
    }

    @objc private func statusAction() {
        switch statusButton.title {
        case "Start": Agent.start()
        case "Show File": NSWorkspace.shared.activateFileViewerSelecting([Paths.config])
        default:
            Agent.requestAccess()
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    @objc private func loginChanged(_ s: NSSwitch) {
        let state = LoginItem.set(s.state == .on)
        if state == .needsApproval { open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }
        refresh(loginToo: true)
    }

    @objc private func swipeChanged(_ s: NSSwitch) {
        settings = Settings.load()
        settings.swipeOverride = s.state == .on
        save(settings)
    }

    @objc private func menuBarChanged(_ s: NSSwitch) {
        settings = Settings.load()
        settings.menuBar = s.state == .on
        save(settings)
        reopenHint.isHidden = settings.menuBar
        onMenuBarChanged(settings.menuBar)
        onLayoutChange()
    }

    @objc private func openTrackpad() { open("x-apple.systempreferences:com.apple.Trackpad-Settings.extension") }
}

// MARK: - Shortcuts

@MainActor
final class ShortcutsPane: NSViewController {
    private var settings = Settings.load()
    private var recorders: [String: ShortcutButton] = [:]
    private var desktopRecorder: ShortcutButton!
    private let desktopPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let desktopSummary = label("", size: 11, color: .secondaryLabelColor)
    private var overrideSwitch: NSSwitch!

    override func loadView() {
        title = "Shortcuts"
        let moves = FormGroup([
            shortcutRow("Move one desktop left", "left"),
            shortcutRow("Move one desktop right", "right"),
            shortcutRow("Back to previous desktop", "last"),
        ])

        desktopPopup.addItems(withTitles: (1...16).map { "Desktop \($0)" })
        desktopPopup.target = self
        desktopPopup.action = #selector(desktopPicked)
        desktopRecorder = ShortcutButton(shortcut: settings.shortcuts["space1"])
        desktopRecorder.onChange = { [weak self] s in
            guard let self else { return }
            self.setShortcut("space\(self.desktopPopup.indexOfSelectedItem + 1)", s)
        }
        let pickers = NSStackView(views: [desktopPopup, desktopRecorder])
        pickers.spacing = 8
        let jump = FormGroup([row(label("Jump to a desktop"), desktopSummary, accessory: pickers)])

        overrideSwitch = toggle(settings.overrideSystemShortcuts, self, #selector(overrideChanged))
        let override = FormGroup([row(
            label("Take over macOS's shortcuts"),
            label("Lets ⌃← and ⌃→ switch instantly instead of sliding.", size: 11, color: .secondaryLabelColor),
            accessory: overrideSwitch)])

        let restore = button("Restore Defaults", self, #selector(restoreDefaults))
        let help = caption("Click a shortcut, then press the keys. Esc cancels, ⌫ removes it.")
        let footer = NSStackView(views: [help, spacer(), restore])
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        help.preferredMaxLayoutWidth = contentWidth - 150

        view = pane([moves, jump, override, footer])
        updateSummary()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        recorders.values.forEach { $0.stop() }
        desktopRecorder.stop()
    }

    private func shortcutRow(_ title: String, _ name: String) -> NSView {
        let b = ShortcutButton(shortcut: settings.shortcuts[name])
        b.onChange = { [weak self] s in self?.setShortcut(name, s) }
        recorders[name] = b
        return row(label(title), accessory: b)
    }

    private func setShortcut(_ name: String, _ s: Shortcut?) {
        settings = Settings.load()
        if let s {
            // One shortcut, one action: remove it from wherever else it was.
            for other in Settings.bindingNames where other != name && settings.shortcuts[other] == s {
                settings.shortcuts[other] = nil
                recorders[other]?.shortcut = nil
            }
        }
        settings.shortcuts[name] = s
        save(settings)
        desktopPicked()
        updateSummary()
    }

    @objc private func desktopPicked() {
        desktopRecorder.shortcut = settings.shortcuts["space\(desktopPopup.indexOfSelectedItem + 1)"]
    }

    private func updateSummary() {
        let set = (1...16).filter { settings.shortcuts["space\($0)"] != nil }.map(String.init)
        desktopSummary.stringValue = set.isEmpty ? "No shortcuts set yet." : "Set for desktop \(set.joined(separator: ", "))."
    }

    @objc private func overrideChanged(_ s: NSSwitch) {
        settings = Settings.load()
        settings.overrideSystemShortcuts = s.state == .on
        save(settings)
    }

    @objc private func restoreDefaults() {
        let fresh = Settings()
        settings = Settings.load()
        settings.shortcuts = fresh.shortcuts
        settings.overrideSystemShortcuts = fresh.overrideSystemShortcuts
        save(settings)
        for (name, b) in recorders { b.shortcut = settings.shortcuts[name] }
        overrideSwitch.state = .on
        desktopPicked()
        updateSummary()
    }
}

// MARK: - About

@MainActor
final class AboutPane: NSViewController {
    private let updateText = label("", size: 11, color: .secondaryLabelColor)
    private var downloadButton: NSButton!
    private var downloadURL: URL?
    private var autoSwitch: NSSwitch!

    override func loadView() {
        title = "About"
        let icon = NSImageView()
        // The main app's icon file, so the 1.5 MB icon is stored only once.
        let mainIcon = Paths.mainApp.appendingPathComponent("Contents/Resources/XSwitcher.icns")
        icon.image = NSImage(contentsOf: mainIcon) ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])
        let name = label("XSwitcher", size: 20, weight: .semibold)
        let version = label("Version \(Updater.currentVersion)", size: 12, color: .secondaryLabelColor)
        let names = NSStackView(views: [name, version])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2
        let header = NSStackView(views: [icon, names])
        header.spacing = 14
        header.alignment = .centerY

        downloadButton = button("Download", self, #selector(download))
        downloadButton.isHidden = true
        let checkButton = button("Check Now", self, #selector(checkUpdates))
        let buttons = NSStackView(views: [downloadButton, checkButton])
        buttons.spacing = 8
        updateText.stringValue = Updater.repo.map { "Checks github.com/\($0) for new versions." } ?? "Update source isn't set."
        autoSwitch = toggle(Settings.load().checkUpdates, self, #selector(autoChanged))
        let updates = FormGroup([
            row(label("Updates"), updateText, accessory: buttons),
            row(label("Check automatically once a day"), accessory: autoSwitch),
        ])

        let credit = link("Based on InstantSpaceSwitcher by jurplel · MIT License",
                          "https://github.com/jurplel/InstantSpaceSwitcher")
        let source = Updater.repo.map { link("Source code on GitHub", "https://github.com/\($0)") }
        let links = NSStackView(views: [credit] + (source.map { [$0] } ?? []))
        links.orientation = .vertical
        links.alignment = .leading
        links.spacing = 4

        view = pane([header, updates, links])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if Settings.load().checkUpdates && Updater.isDue { checkUpdates() }
    }

    private func link(_ title: String, _ url: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        b.isBordered = false
        b.contentTintColor = .linkColor
        b.font = .systemFont(ofSize: 11)
        b.toolTip = url
        return b
    }

    @objc private func openLink(_ b: NSButton) { if let u = b.toolTip { open(u) } }

    @objc private func checkUpdates() {
        updateText.stringValue = "Checking…"
        downloadButton.isHidden = true
        Updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .notConfigured: self.updateText.stringValue = "Update source isn't set."
            case .noReleases: self.updateText.stringValue = "No versions published on GitHub yet."
            case .upToDate(let v): self.updateText.stringValue = "You have the latest version (\(v))."
            case let .available(version, url):
                self.updateText.stringValue = "Version \(version) is available."
                self.downloadURL = url
                self.downloadButton.isHidden = false
            case .failed(let why): self.updateText.stringValue = "Couldn't check: \(why)"
            }
        }
    }

    @objc private func download() { if let downloadURL { NSWorkspace.shared.open(downloadURL) } }

    @objc private func autoChanged(_ s: NSSwitch) {
        var settings = Settings.load()
        settings.checkUpdates = s.state == .on
        save(settings)
    }
}

// MARK: - Window

/// Toolbar tabs (General · Shortcuts · About); the window resizes to fit
/// each pane, keeping its title bar where it is.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}
    var onMenuBarChanged: (Bool) -> Void = { _ in } {
        didSet { general.onMenuBarChanged = onMenuBarChanged }
    }

    private let tabs = FittingTabController()
    private let general = GeneralPane()
    private let shortcuts = ShortcutsPane()
    private let about = AboutPane()

    init() {
        tabs.tabStyle = .toolbar
        for (vc, symbolName) in [(general as NSViewController, "gearshape"), (shortcuts, "keyboard"), (about, "info.circle")] {
            _ = vc.view // load, so the title is set
            let item = NSTabViewItem(viewController: vc)
            item.label = vc.title ?? ""
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: vc.title)
            tabs.addTabViewItem(item)
        }
        let w = SettingsNSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        general.onLayoutChange = { [weak self] in self?.tabs.fit() }
        tabs.fit()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        tabs.fit()
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    /// Renders each pane to dir/<pane>.png without showing the window.
    func snapshot(to dir: URL, dark: Bool) {
        for (i, name) in ["general", "shortcuts", "about"].enumerated() {
            tabs.selectedTabViewItemIndex = i
            guard let view = tabs.tabViewItems[i].viewController?.view else { continue }
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            view.wantsLayer = true
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
        }
        // The whole window too, title bar and tabs included (for the README),
        // drawn as the active window like it looks on screen.
        guard let w = window as? SettingsNSWindow else { return }
        w.drawsAsActive = true
        // Snapshot-only: ask AppKit for the focused look while the window
        // stays off screen and in the background.
        for name in ["acquireKeyAppearance", "acquireMainAppearance"] where w.responds(to: Selector((name))) {
            w.perform(Selector((name)))
        }
        if w.responds(to: Selector(("_setForceMainAppearance:"))) {
            w.perform(Selector(("_setForceMainAppearance:")), with: NSNumber(value: true))
        }
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000)) // drawn, but off screen
        w.orderFrontRegardless()
        for (i, name) in ["general", "shortcuts", "about"].enumerated() {
            tabs.selectedTabViewItemIndex = i
            tabs.fit()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1)) // let the toolbar catch up
            guard let frame = w.contentView?.superview else { continue }
            frame.layoutSubtreeIfNeeded()
            frame.display()
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("window-\(name)\(dark ? "-dark" : "").png"))
        }
        w.orderOut(nil)
    }
}

/// Only difference from NSWindow: snapshots can draw it as the key window.
final class SettingsNSWindow: NSWindow {
    var drawsAsActive = false
    override var isKeyWindow: Bool { drawsAsActive || super.isKeyWindow }
    override var isMainWindow: Bool { drawsAsActive || super.isMainWindow }
}

@MainActor
final class FittingTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fit()
    }

    func fit() {
        guard let w = view.window, let pane = tabViewItems[safe: selectedTabViewItemIndex]?.viewController?.view else { return }
        pane.layoutSubtreeIfNeeded()
        let size = pane.fittingSize
        let frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
        w.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: w.isVisible)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Helpers

@MainActor
private func save(_ settings: Settings) {
    do {
        try settings.save()
        Agent.reload()
    } catch {
        NSAlert(error: error).runModal()
    }
}

@MainActor
private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
