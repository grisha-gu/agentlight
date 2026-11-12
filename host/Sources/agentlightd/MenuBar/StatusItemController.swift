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
    /// The menu bar flips between light and dark icons with the wallpaper — redraw on every flip.
    private var appearanceObservation: NSKeyValueObservation?
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
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
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
        item.button?.image = MenuBarIcon.image(lights: lights, welcomeRows: model.slots.map(\.welcomeRow),
                                               palette: menuBarPalette)

        // while the welcome animation runs, redraw 10 times a second
        let animating = daemon.welcomeUntil.values.contains { $0 > now }
        if animating, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        } else if !animating {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private var menuBarPalette: MenuBarIcon.Palette {
        MenuBarIcon.Palette.for(daemon.config.menuBarIcon,
                                on: item.button?.effectiveAppearance ?? NSAppearance(named: .darkAqua)!)
    }

    /// Debugging without screen access: icon and popover to PNG.
    @MainActor
    func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, palette, bg) in [("icon-dark.png", MenuBarIcon.Palette.plainOnDark, NSColor(white: 0.15, alpha: 1)),
                                    ("icon-light.png", .plated, NSColor(white: 0.93, alpha: 1))] {
            let icon = MenuBarIcon.image(lights: daemon.lights, welcomeRows: model.slots.map(\.welcomeRow), palette: palette)
            let onBackground = NSImage(size: icon.size, flipped: false) { r in
                bg.setFill()
                r.fill()
                icon.draw(in: r)
                return true
            }
            var rect = NSRect(origin: .zero, size: icon.size)
            if let cg = onBackground.cgImage(forProposedRect: &rect, context: nil,
                                             hints: [.ctm: NSAffineTransform(transform: .init(scale: 4))]) {
                write(cg, to: dir.appendingPathComponent(name))
            }
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

    /// How the icon looks on one kind of menu bar. On a light bar (black icons) the colored
    /// lights get lost, so each group of four (or the tail) sits on a dark rounded plate.
    struct Palette {
        let lit: [NSColor]  // red, yellow, green
        let unlit: NSColor
        let plate: NSColor?

        private static let bright = [NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1),
                                     NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),
                                     NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)]
        static let plainOnDark = Palette(lit: bright, unlit: NSColor(white: 1, alpha: 0.22), plate: nil)
        static let plainOnLight = Palette(lit: bright, unlit: NSColor(white: 0, alpha: 0.18), plate: nil)
        static let plated = Palette(lit: bright, unlit: NSColor(white: 1, alpha: 0.22),
                                    plate: NSColor(white: 0.12, alpha: 0.9))

        static func `for`(_ style: MenuBarIconStyle, on appearance: NSAppearance) -> Palette {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            let lightBar = match == .aqua || match == .vibrantLight
            switch style {
            case .plates: return .plated
            case .plain: return lightBar ? .plainOnLight : .plainOnDark
            case .auto: return lightBar ? .plated : .plainOnDark
            }
        }
    }

    static func image(lights: [LightState], welcomeRows: [Int?], palette: Palette) -> NSImage {
        let plated = palette.plate != nil
        // the plate takes the full 18 pt height, so the lights shrink a little to leave it a margin
        let d: CGFloat = plated ? 4.2 : 4.5, gapY: CGFloat = plated ? 1.1 : 1.3, gapX: CGFloat = 2.5
        let padX: CGFloat = 2.2, radius: CGFloat = 4
        // groups of four (per device) are spaced a bit wider; plates need room for their padding
        let groupGap: CGFloat = plated ? 2.5 + 2 * padX : 2.5
        let margin: CGFloat = plated ? padX : 1
        let n = lights.count
        let perGroup = DeviceLink.slotsPerDevice
        func x(_ slot: Int) -> CGFloat {
            margin + CGFloat(slot) * (d + gapX) + CGFloat(slot / perGroup) * groupGap
        }
        let size = NSSize(width: x(max(n, 1) - 1) + d + margin, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            if let plate = palette.plate {
                plate.setFill()
                for first in stride(from: 0, to: n, by: perGroup) {
                    let last = min(first + perGroup, n) - 1
                    let r = NSRect(x: x(first) - padX, y: 0,
                                   width: x(last) - x(first) + d + 2 * padX, height: size.height)
                    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
                }
            }
            let top = (size.height - (3 * d + 2 * gapY)) / 2
            for slot in 0..<n {
                for row in 0..<3 {
                    let welcome = welcomeRows.indices.contains(slot) ? welcomeRows[slot] : nil
                    let lit = welcome.map { $0 == row } ?? (lights[slot] == rows[row])
                    let r = NSRect(x: x(slot), y: top + CGFloat(row) * (d + gapY), width: d, height: d)
                    (lit ? palette.lit[row] : palette.unlit).setFill()
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
