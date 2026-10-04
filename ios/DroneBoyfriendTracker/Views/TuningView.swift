// Live PID / feedforward / limit tuning. Names and ranges come from the ESP32,
// so this screen never goes out of sync with the firmware.
// Changes apply instantly; "Save" writes them to the ESP32's flash (disarmed only).

import SwiftUI

struct TuningView: View {
    @ObservedObject var link: DroneLink
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ParamInfo?
    @State private var editText = ""

    private struct ParamGroup: Identifiable {
        let title: String
        let pattern: String
        var id: String { title }
    }

    private let groups: [ParamGroup] = [
        ParamGroup(title: "Rate loop", pattern: "rate_"),
        ParamGroup(title: "Angle loop", pattern: "angle_"),
        ParamGroup(title: "Filters", pattern: "lpf"),
        ParamGroup(title: "Limits", pattern: "max_"),
        ParamGroup(title: "Motors / hover", pattern: "motor_|hover|liftoff|tilt_|i_limit|heading_"),
        ParamGroup(title: "Failsafe / landing", pattern: "link_|failsafe|land_|crash|auto_disarm|arm_"),
        ParamGroup(title: "Battery", pattern: "batt_"),
        ParamGroup(title: "Follow", pattern: "follow_"),
        ParamGroup(title: "Attitude", pattern: "ahrs|trim_"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                PinkBackground()
                List {
                    Section {
                        HStack {
                            Button("Save to drone") { link.send(.paramSave) }
                                .buttonStyle(CandyButtonStyle(compact: true))
                                .disabled(link.telemetry?.armed ?? true)
                            Button("Reload") { link.requestParams() }
                                .buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true))
                            Button("Level cal") { link.send(.calLevel) }
                                .buttonStyle(CandyButtonStyle(tint: .lilacCandy, compact: true))
                            Button("Gyro cal") { link.send(.calGyro) }
                                .buttonStyle(CandyButtonStyle(tint: .lilacCandy, compact: true))
                            Button("Defaults") { link.send(.paramReset) }
                                .buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true))
                        }
                        if link.telemetry?.paramsDirty == true {
                            Text("Unsaved changes (they work now, but are lost on power-off until saved).")
                                .font(.caption).foregroundStyle(Theme.warn)
                        }
                        AckToast(link: link)
                    }
                    .listRowBackground(Color.clear)

                    if link.params.isEmpty {
                        Text("Waiting for the drone… (connected: \(link.connected ? "yes" : "no"))").foregroundStyle(Theme.muted)
                            .listRowBackground(Theme.panel.opacity(0.7))
                    }
                    ForEach(groups) { group in
                        let items = link.params.filter { matches($0.name, group.pattern) && !claimedEarlier($0.name, before: group.title) }
                        if !items.isEmpty {
                            Section(group.title) {
                                ForEach(items) { p in row(p) }
                            }
                            .listRowBackground(Theme.panel.opacity(0.75))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Set \(editing?.name ?? "")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("value", text: $editText).keyboardType(.numbersAndPunctuation)
                Button("Set") {
                    if let p = editing, let v = Float(editText.replacingOccurrences(of: ",", with: ".")) { link.setParam(id: p.id, value: v) }
                    editing = nil
                }
                Button("Cancel", role: .cancel) { editing = nil }
            } message: {
                if let p = editing { Text("Range \(fmt(p.min)) … \(fmt(p.max))") }
            }
        }
        .onAppear { link.requestParams() }
        .tint(Theme.pink)
    }

    private func matches(_ name: String, _ pattern: String) -> Bool {
        pattern.split(separator: "|").contains { name.contains($0) }
    }

    /// Each param is shown once, in the first group that matches it.
    private func claimedEarlier(_ name: String, before group: String) -> Bool {
        for g in groups {
            if g.title == group { return false }
            if matches(name, g.pattern) { return true }
        }
        return false
    }

    private func row(_ p: ParamInfo) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                Text(fmt(p.value)).font(.system(size: 15, weight: .bold, design: Theme.fontDesign)).foregroundStyle(Theme.softPink)
                    .onTapGesture { editText = fmt(p.value); editing = p }
            }
            Spacer()
            step(p, "÷1.5") { $0 / 1.5 }
            step(p, "−10%") { $0 / 1.1 }
            step(p, "+10%") { $0 * 1.1 }
            step(p, "×1.5") { $0 * 1.5 }
        }
    }

    private func step(_ p: ParamInfo, _ label: String, _ f: @escaping (Float) -> Float) -> some View {
        Button(label) {
            var v = f(p.value)
            if p.value == 0 { // multiplicative steps can't leave zero: use 2% of the range
                let s = (p.max - p.min) * 0.02
                v = label.contains("+") || label.contains("×") ? s : 0
            }
            link.setParam(id: p.id, value: min(p.max, max(p.min, v)))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .font(.system(size: 12, weight: .bold, design: Theme.fontDesign))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(Theme.candy.opacity(0.8)))
        .buttonStyle(.plain)
    }

    private func fmt(_ v: Float) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 100 { return String(format: "%.0f", v) }
        if a >= 1 { return String(format: "%.2f", v) }
        if a >= 0.01 { return String(format: "%.4f", v) }
        return String(format: "%.6f", v)
    }
}
