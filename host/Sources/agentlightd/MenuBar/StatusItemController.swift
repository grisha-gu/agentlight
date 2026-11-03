import AgentLightKit
import AppKit
import SwiftUI

/// Menu bar icon: mini traffic lights for all slots; click opens a popover with large ones.
final class StatusItemController: NSObject {
    private let daemon: Daemon
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = PanelModel()
    private lazy var panel = NSHostingController(rootView: PanelView(model: model))
    private var animationTimer: Timer?
    private lazy var settings = SettingsWindowController(daemon: daemon)

    init(daemon: Daemon) {
        self.daemon = daemon
        super.init()
        model.onPress = { [weak self, weak daemon] slot in
            self?.popover.performClose(nil)  // the terminal window is about to come to the front
            daemon?.button(slot: slot, .press)
        }
        model.onMute = { [weak daemon] slot in daemon?.button(slot: slot, .long) }
        model.onRelease = { [weak daemon] slot in daemon?.release(slot: slot) }
        model.onTest = { [weak daemon] in daemon?.runTest() }
        model.onSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.settings.show()
        }

        popover.behavior = .transient
        // height depends on the number of rows (slot_count) — the popover takes its size from SwiftUI
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.toolTip = "AgentLight"
        }
        refresh()
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.contentSize = panel.view.fittingSize
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func refresh() {
        let now = Date()
        let lights = daemon.lights
        model.slots = daemon.allocator.slots.enumerated().map { i, s in
            SlotView(index: i,
                     light: lights.indices.contains(i) ? lights[i] : .off,
                     welcomeRow: Self.welcomeRow(until: daemon.welcomeUntil[i] ?? .distantPast, now: now),
                     project: s.session?.projectName,
                     cwd: s.session?.cwd,
                     muted: s.muted)
        }
        model.overflow = daemon.allocator.overflow.map(\.projectName)
        model.device = daemon.link.status.localizedText
        model.deviceConnected = daemon.link.isActive
        item.button?.image = MenuBarIcon.image(lights: lights, welcomeRows: model.slots.map(\.welcomeRow))

        // while the welcome animation runs, redraw 10 times a second
        let animating = daemon.welcomeUntil.values.contains { $0 > now }
        if animating, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        } else if !animating {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    /// Debugging without screen access: icon and popover to PNG.
    @MainActor
    func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let icon = MenuBarIcon.image(lights: daemon.lights, welcomeRows: model.slots.map(\.welcomeRow))
        var rect = NSRect(origin: .zero, size: icon.size)
        if let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform(transform: .init(scale: 4))]) {
            write(cg, to: dir.appendingPathComponent("icon.png"))
        }
        for (name, scheme) in [("panel-light.png", ColorScheme.light), ("panel-dark.png", .dark)] {
            let view = PanelView(model: model)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage { write(cg, to: dir.appendingPathComponent(name)) }
        }
        settings.snapshot(to: dir.appendingPathComponent("settings.png"))
    }

    private func write(_ cg: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A top-to-bottom wave over 1.2 s: which light is lit now (0 — red).
    static func welcomeRow(until: Date, now: Date) -> Int? {
        let left = until.timeIntervalSince(now)
        guard left > 0 else { return nil }
        return min(2, Int((1.2 - left) / 0.4))
    }
}

enum MenuBarIcon {
    static let rows: [LightState] = [.attn, .busy, .idle]

    static func color(_ row: Int) -> NSColor {
        [NSColor.systemRed, .systemYellow, .systemGreen][row]
    }

    static func image(lights: [LightState], welcomeRows: [Int?]) -> NSImage {
        let d: CGFloat = 4.5, gapY: CGFloat = 1.3, gapX: CGFloat = 2.5
        // groups of four (per device) are spaced a bit wider
        let groupGap: CGFloat = 2.5
        let n = lights.count
        func x(_ slot: Int) -> CGFloat {
            1 + CGFloat(slot) * (d + gapX) + CGFloat(slot / DeviceLink.slotsPerDevice) * groupGap
        }
        let size = NSSize(width: x(max(n, 1) - 1) + d + 1, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            let top = (size.height - (3 * d + 2 * gapY)) / 2
            for slot in 0..<n {
                for row in 0..<3 {
                    let welcome = welcomeRows.indices.contains(slot) ? welcomeRows[slot] : nil
                    let lit = welcome.map { $0 == row } ?? (lights[slot] == rows[row])
                    let r = NSRect(x: x(slot), y: top + CGFloat(row) * (d + gapY), width: d, height: d)
                    (lit ? color(row) : NSColor.labelColor.withAlphaComponent(0.22)).setFill()
                    NSBezierPath(ovalIn: r).fill()
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

extension DeviceLink.Status {
    /// `DeviceLink.statusText` in the user's language.
    var localizedText: String {
        switch self {
        case .disconnected:
            return String(localized: "Device not connected")
        case .connecting(let name):
            return String(localized: "\(name): connected", comment: "device name: connected, waiting for READY")
        case .switchedOff(let d):
            return String(localized: "\(d.name): switched off", comment: "device name: power switch is off")
        case .single(let d):
            return "\(d.name): fw \(d.identity.firmware), uid \(d.identity.uid)"
        case .several(let ds):
            let list = ds.map { d in
                d.powerOn ? "\(d.name) \(d.slotRangeText)"
                    : String(localized: "\(d.name) \(d.slotRangeText) (off)", comment: "device name, slot range, power switch is off")
            }
            return String(localized: "Devices: \(ds.count) — \(list.joined(separator: ", "))")
        }
    }
}
