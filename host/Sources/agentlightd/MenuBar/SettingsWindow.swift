import AgentLightKit
import AppKit
import SwiftUI

/// Окно «Настройки…»: правит ~/.agentlight/config.json через Daemon.updateConfig.
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
    }

    func show() {
        model.launchDir = daemon.config.emptySlotButtonLaunches
        model.slotCount = daemon.config.slotCount
        model.recent = recentProjectDirs()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]  // окно растёт, когда появляется ошибка или меню
            let w = NSWindow(contentViewController: host)
            w.setContentSize(host.view.fittingSize)
            w.title = "Настройки AgentLight"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // приложение .accessory — без activate окно откроется под чужими
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Для `--snapshot`: Form рисуется только в настоящем окне, поэтому снимаем его, не показывая.
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
        panel.prompt = "Выбрать"
        panel.message = "Где запускать нового агента по кнопке пустого светофора"
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

    /// Каталоги агентов, что сейчас в слотах, — быстрый выбор без диалога.
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
    /// nil — по умолчанию (домашний каталог)
    @Published var launchDir: String?
    @Published var recent: [String] = []
    @Published var slotCount = Config().slotCount
    @Published var error: String?

    var onChooseLaunchDir: () -> Void = {}
    var onResetLaunchDir: () -> Void = {}
    var onPick: (String) -> Void = { _ in }
    var onSlotCount: (Int) -> Void = { _ in }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Светофоры").font(.headline)
            GroupBox {
                Stepper(value: Binding(get: { model.slotCount }, set: { model.onSlotCount($0) }),
                        in: Config.slotCountRange) {
                    Text("Светофоров в приложении: \(model.slotCount)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Text("Одно устройство показывает 4 светофора. Второе подключённое — следующие 4, третье — ещё 4 и так далее. Светофоры, на которые устройства не хватило, видны только в строке меню.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Новый агент").font(.headline)
                .padding(.top, 8)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(model.launchDir ?? "~ (по умолчанию)")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(model.launchDir == nil ? .secondary : .primary)
                            .help(model.launchDir ?? "домашний каталог")
                        Spacer(minLength: 8)
                        if model.launchDir != nil {
                            Button("Сбросить") { model.onResetLaunchDir() }
                        }
                        Button("Выбрать…") { model.onChooseLaunchDir() }
                    }
                    let others = model.recent.filter { $0 != model.launchDir }
                    if !others.isEmpty {
                        Menu("Взять папку одного из текущих агентов") {
                            ForEach(others, id: \.self) { dir in
                                Button(dir) { model.onPick(dir) }
                            }
                        }
                        .fixedSize()
                    }
                }
                .padding(6)
            }
            Text("Кнопка под пустым светофором открывает окно Terminal и запускает в этой папке `claude`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
