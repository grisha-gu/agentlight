import AgentLightKit
import AppKit

let usage = """
agentlightd — демон AgentLight

  --fake-device        рисовать светофоры 1–4 в терминале вместо железа (клавиши 1–4 = кнопки)
  --transport T        hid | cdc | all (по умолчанию all: HID, затем CDC)
  --record PATH        дописывать все входящие хуки в JSONL (формат tools/hook-capture)
  --no-menubar         без иконки в строке меню
  --snapshot DIR       через 1 с сохранить иконку и popover в PNG и выйти (отладка UI)
"""

var fake = false
var transportKind = "all"
var recordPath: String?
var menubar = true
var snapshotDir: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--fake-device": fake = true
    case "--transport": transportKind = args.next() ?? "all"
    case "--record": recordPath = args.next()
    case "--no-menubar": menubar = false
    case "--snapshot": snapshotDir = args.next()
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("неизвестный аргумент \(a)\n\n\(usage)\n".utf8))
        exit(64)
    }
}

let config: Config
do {
    config = try Config.load()
} catch {
    FileHandle.standardError.write(Data("~/.agentlight/config.json: \(error)\n".utf8))
    exit(78)
}

var transports: [DeviceTransport] = []
let fakeTransport = FakeTransport()
if fake {
    // терминал занят рендером — лог в файл
    Log.toFile(Paths.log)
    transports = [fakeTransport]
} else {
    if transportKind == "all" || transportKind == "hid" { transports.append(HIDTransport()) }
    if transportKind == "all" || transportKind == "cdc" { transports.append(CDCTransport(path: config.cdcPort)) }
}

let daemon = Daemon(config: config, transports: transports, recordTo: recordPath.map { URL(fileURLWithPath: $0) })
fakeTransport.labels = { daemon.allocator.slots.map { $0.session?.projectName ?? "—" } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            try daemon.start()
        } catch {
            Log.error("не удалось стартовать: \(error)")
            exit(2)
        }
        if menubar {
            statusItem = StatusItemController(daemon: daemon)
        }
        daemon.onChange = { [weak self] in self?.statusItem?.refresh() }
        if let snapshotDir {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    self.statusItem?.snapshot(to: URL(fileURLWithPath: snapshotDir))
                }
                daemon.shutdown()
                exit(0)
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        daemon.shutdown()
    }
}

var signalSources: [DispatchSourceSignal] = []
// SIGTERM от launchctl и Ctrl-C в терминале — погасить светофоры и вернуть терминал
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        daemon.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
