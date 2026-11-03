import AgentLightKit
import SwiftUI

struct SlotView: Identifiable, Equatable {
    var index: Int
    var light: LightState
    var welcomeRow: Int?
    var project: String?
    var cwd: String?
    var muted: Bool

    var id: Int { index }
    var isEmpty: Bool { project == nil }

    var caption: String {
        if isEmpty { return String(localized: "free", comment: "slot caption: no agent") }
        if muted { return String(localized: "muted", comment: "slot caption") }
        switch light {
        case .off: return "—"
        case .idle: return String(localized: "ready", comment: "slot caption: green light")
        case .busy: return String(localized: "thinking", comment: "slot caption: yellow light")
        case .attn: return String(localized: "needs you", comment: "slot caption: red light")
        }
    }
}

final class PanelModel: ObservableObject {
    @Published var slots: [SlotView] = []
    @Published var overflow: [String] = []
    @Published var device = ""
    @Published var deviceConnected = false

    var onPress: (Int) -> Void = { _ in }
    var onMute: (Int) -> Void = { _ in }
    var onRelease: (Int) -> Void = { _ in }
    var onTest: () -> Void = {}
    var onSettings: () -> Void = {}
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // a row is one device's four; an incomplete row is padded with empty space
            // so the columns line up
            ForEach(Array(stride(from: 0, to: model.slots.count, by: DeviceLink.slotsPerDevice)), id: \.self) { start in
                let row = model.slots[start..<min(start + DeviceLink.slotsPerDevice, model.slots.count)]
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row) { slot in
                        SlotColumn(slot: slot, model: model)
                    }
                    ForEach(row.count..<DeviceLink.slotsPerDevice, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
            if !model.overflow.isEmpty {
                Text("No traffic light: \(model.overflow.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.deviceConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(model.device)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Settings…") { model.onSettings() }
                    Button("Test Lights") { model.onTest() }
                    Divider()
                    Button("Quit AgentLight") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

struct SlotColumn: View {
    let slot: SlotView
    let model: PanelModel

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 7) {
                ForEach(0..<3) { row in
                    Lamp(color: [Color.red, .yellow, .green][row], lit: isLit(row))
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))

            Text(slot.project ?? "—")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(slot.cwd ?? "")
            Text(slot.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button {
                model.onPress(slot.index)
            } label: {
                Text("\(slot.index + 1)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(width: 34, height: 20)
            }
            .help(slot.isEmpty ? String(localized: "Start a new agent in this slot") : String(localized: "Go to the agent's terminal"))
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            if !slot.isEmpty {
                Button(slot.muted ? String(localized: "Unmute") : String(localized: "Mute")) { model.onMute(slot.index) }
                Button("Release Slot") { model.onRelease(slot.index) }
            }
        }
    }

    private func isLit(_ row: Int) -> Bool {
        if let w = slot.welcomeRow { return w == row }
        return slot.light == [LightState.attn, .busy, .idle][row]
    }
}

struct Lamp: View {
    let color: Color
    let lit: Bool

    var body: some View {
        Circle()
            .fill(lit ? color : color.opacity(0.14))
            .frame(width: 24, height: 24)
            .shadow(color: lit ? color.opacity(0.8) : .clear, radius: 6)
            .animation(.easeInOut(duration: 0.15), value: lit)
    }
}
