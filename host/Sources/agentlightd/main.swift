import AgentLightKit
import AppKit

let usage = """
agentlightd — the AgentLight daemon

  --fake-device        draw traffic lights 1–4 in the terminal instead of hardware (keys 1–4 = buttons)
  --transport T        hid | cdc | all (default all: HID, then CDC)
  --record PATH        append all incoming hooks to JSONL (tools/hook-capture format)
  --no-menubar         no menu bar icon
  --snapshot DIR       after 1 s save the icon and popover as PNG and exit (UI debugging)
  -AppleLanguages "(ru)"  UI language for this run (default: the system language)
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
    case "-AppleLanguages":  // `-AppleLanguages "(ru)"` — UI language for this run; Foundation reads it from argv itself
        _ = args.next()
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(a)\n\n\(usage)\n".utf8))
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
    // the terminal is busy rendering — log to a file
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
            Log.error("failed to start: \(error)")
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
// SIGTERM from launchctl and Ctrl-C in the terminal — turn the lights off and restore the terminal
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
