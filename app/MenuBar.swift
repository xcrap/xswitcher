import AppKit

// Private SkyLight calls, the same ones the agent uses (agent/cgs.h).
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32, _ display: CFString?) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyActiveMenuBarDisplayIdentifier") private func CGSCopyActiveMenuBarDisplayIdentifier(_ cid: Int32) -> Unmanaged<CFString>?

enum Desktops {
    /// Current desktop (0-based) and count on the display with the menu bar.
    static func onMenuBarDisplay() -> (current: Int, count: Int)? {
        let cid = CGSMainConnectionID()
        let active = CGSGetActiveSpace(cid)
        let want = CGSCopyActiveMenuBarDisplayIdentifier(cid)?.takeRetainedValue() as String?
        guard let displays = CGSCopyManagedDisplaySpaces(cid, nil)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        guard let d = displays.first(where: { $0["Display Identifier"] as? String == want }) ?? displays.first,
              let spaces = d["Spaces"] as? [[String: Any]] else { return nil }
        let current = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? active
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let index = ids.firstIndex(of: current) else { return nil }
        return (index, ids.count)
    }
}

/// Optional menu bar icon showing the current desktop number.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    private var item: NSStatusItem?
    private var spaceObserver: Any?
    private var updateTimer: Timer?
    private var update: (version: String, url: URL)?
    private var iconCache: [Int: NSImage] = [:]

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        it.menu = menu
        item = it
        refreshIcon()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshIcon() } }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdatesIfDue() }
        }
        checkForUpdatesIfDue()
    }

    func uninstall() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        updateTimer?.invalidate()
        updateTimer = nil
    }

    var isInstalled: Bool { item != nil }

    private func refreshIcon() {
        let n = (Desktops.onMenuBarDisplay()?.current ?? -1) + 1
        item?.button?.image = icon(n)
        item?.button?.toolTip = n > 0 ? "XSwitcher: desktop \(n)" : "XSwitcher"
    }

    private func icon(_ n: Int) -> NSImage {
        if let cached = iconCache[n] { return cached }
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1), xRadius: 4, yRadius: 4)
            box.lineWidth = 1.4
            NSColor.black.setStroke()
            box.stroke()
            let text = (n > 0 ? "\(n)" : "·") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                                                        .foregroundColor: NSColor.black]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        iconCache[n] = img
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let info = Desktops.onMenuBarDisplay() {
            for i in 0..<info.count {
                let mi = NSMenuItem(title: "Desktop \(i + 1)", action: #selector(goTo(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = i + 1
                mi.state = i == info.current ? .on : .off
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }
        if let update {
            let mi = NSMenuItem(title: "Update available: \(update.version)…", action: #selector(openUpdate), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit XSwitcher", action: #selector(quitClicked), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
        refreshIcon()
    }

    @objc private func goTo(_ sender: NSMenuItem) { Agent.goTo(desktop: sender.tag) }
    @objc private func settingsClicked() { openSettings() }
    @objc private func quitClicked() { quit() }
    @objc private func openUpdate() { if let url = update?.url { NSWorkspace.shared.open(url) } }

    private func checkForUpdatesIfDue() {
        guard Settings.load().checkUpdates, Updater.isDue else { return }
        Updater.check { [weak self] result in
            if case let .available(version, url) = result { self?.update = (version, url) }
        }
    }
}
