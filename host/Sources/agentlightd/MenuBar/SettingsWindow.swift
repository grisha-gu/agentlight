import AgentLightKit
import AppKit
import SwiftUI

/// The "Settings…" window: edits ~/.agentlight/config.json via Daemon.updateConfig.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let daemon: Daemon
    private let model = SettingsModel()
    private var window: NSWindow?

    init(daemon: Daemon) {
        self.daemon = daemon
        super.init()
        model.onChooseLaunchDir = { [weak self] in self?.chooseLaunchDir() }
        model.onResetLaunchDir = { [weak self] in self?.setLaunchDir(nil) }
        model.onPick = { [weak self] dir in self?.setLaunchDir(dir) }
        model.onSlotCount = { [weak self] n in self?.setSlotCount(n) }
        model.onIconStyle = { [weak self] style in self?.setIconStyle(style) }
    }

    func show() {
        model.launchDir = daemon.config.emptySlotButtonLaunches
        model.slotCount = daemon.config.slotCount
        model.iconStyle = daemon.config.menuBarIcon
        model.recent = recentProjectDirs()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]  // the window grows when an error or a menu appears
            let w = NSWindow(contentViewController: host)
            w.setContentSize(host.view.fittingSize)
            w.title = String(localized: "AgentLight Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // the app is .accessory — without activate the window opens behind others
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// For `--snapshot`: a Form only draws in a real window, so capture it without showing it.
    func snapshot(to url: URL) {
        show()
        window?.orderOut(nil)
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func chooseLaunchDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Where to start a new agent from an empty traffic light's button")
        let current = (daemon.config.emptySlotButtonLaunches ?? "~") as NSString
        panel.directoryURL = URL(fileURLWithPath: current.expandingTildeInPath, isDirectory: true)
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.setLaunchDir(url.path)
        }
    }

    private func setLaunchDir(_ path: String?) {
        let value = path.map(Self.abbreviateHome)
        let reply = daemon.updateConfig { $0.emptySlotButtonLaunches = value }
        model.error = reply.ok ? nil : reply.message
        model.launchDir = daemon.config.emptySlotButtonLaunches
    }

    private func setSlotCount(_ n: Int) {
        let reply = daemon.updateConfig { $0.slotCount = n }
        model.error = reply.ok ? nil : reply.message
        model.slotCount = daemon.config.slotCount
    }

    private func setIconStyle(_ style: MenuBarIconStyle) {
        let reply = daemon.updateConfig { $0.menuBarIcon = style }
        model.error = reply.ok ? nil : reply.message
        model.iconStyle = daemon.config.menuBarIcon
    }

    /// Folders of the agents currently in slots — a quick pick without a dialog.
    private func recentProjectDirs() -> [String] {
        var seen = Set<String>()
        return daemon.allocator.slots.compactMap { $0.session?.cwd }
            .map(Self.abbreviateHome)
            .filter { seen.insert($0).inserted }
    }

    static func abbreviateHome(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

final class SettingsModel: ObservableObject {
    /// nil — the default (home folder)
    @Published var launchDir: String?
    @Published var recent: [String] = []
    @Published var slotCount = Config().slotCount
    @Published var iconStyle = Config().menuBarIcon
    @Published var error: String?

    var onChooseLaunchDir: () -> Void = {}
    var onResetLaunchDir: () -> Void = {}
    var onPick: (String) -> Void = { _ in }
    var onSlotCount: (Int) -> Void = { _ in }
    var onIconStyle: (MenuBarIconStyle) -> Void = { _ in }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Traffic Lights").font(.headline)
            GroupBox {
                Stepper(value: Binding(get: { model.slotCount }, set: { model.onSlotCount($0) }),
                        in: Config.slotCountRange) {
                    Text("Traffic lights in the app: \(model.slotCount)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Text("One device shows 4 traffic lights. A second connected device shows the next 4, a third another 4, and so on. Traffic lights without a device are only visible in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Menu Bar Icon").font(.headline)
                .padding(.top, 8)
            GroupBox {
                Picker("Menu Bar Icon", selection: Binding(get: { model.iconStyle }, set: { model.onIconStyle($0) })) {
                    Text("Automatic").tag(MenuBarIconStyle.auto)
                    Text("Plain").tag(MenuBarIconStyle.plain)
                    Text("On Plates").tag(MenuBarIconStyle.plates)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Text("Automatic puts each group of four lights on a dark plate when the menu bar shows black icons (a light wallpaper behind it).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("New Agent").font(.headline)
                .padding(.top, 8)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(model.launchDir ?? String(localized: "~ (default)"))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(model.launchDir == nil ? .secondary : .primary)
                            .help(model.launchDir ?? String(localized: "home folder"))
                        Spacer(minLength: 8)
                        if model.launchDir != nil {
                            Button("Reset") { model.onResetLaunchDir() }
                        }
                            Button("Choose…") { model.onChooseLaunchDir() }
                    }
                    let others = model.recent.filter { $0 != model.launchDir }
                    if !others.isEmpty {
                        Menu("Use the folder of a current agent") {
                            ForEach(others, id: \.self) { dir in
                                Button(dir) { model.onPick(dir) }
                            }
                        }
                        .fixedSize()
                    }
                }
                .padding(6)
            }
            Text("The button under an empty traffic light opens a Terminal window and runs `claude` in this folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: "AgentLight \(AgentLightVersion.string)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 480)
    }
}
