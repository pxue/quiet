import AVFoundation
import CoreAudio
import QuietCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var enabled = false { didSet { enabled ? start() : stop() } }
    @Published var inputUID = UserDefaults.standard.string(forKey: "inputUID") ?? "" {
        didSet { UserDefaults.standard.set(inputUID, forKey: "inputUID"); restartIfRunning() }
    }
    @Published var outputUID = UserDefaults.standard.string(forKey: "outputUID") ?? "" {
        didSet { UserDefaults.standard.set(outputUID, forKey: "outputUID"); restartIfRunning() }
    }
    @Published var settings = LivePipeline.Settings() { didSet { pipeline?.update(settings) } }
    @Published var stats = LivePipeline.Stats()
    @Published var error: String?
    /// True when the Mac's sound output is the same loopback we write to, which would mix system audio into the mic.
    @Published var outputConflict = false

    private var pipeline: LivePipeline?
    private var timer: Timer?

    var inputs: [AudioDevice] { devices.filter { $0.inputChannels > 0 && !$0.isLoopback && !$0.name.lowercased().contains("krisp") } }
    @Published private(set) var outputs: [AudioDevice] = []

    init() {
        refreshDevices()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
    }

    func refreshDevices() {
        devices = AudioDevices.all()
        outputs = AudioDevices.virtualMicTargets()
        if !inputs.contains(where: { $0.uid == inputUID }) {
            let fallback = AudioDevices.defaultInput().flatMap { id in inputs.first { $0.id == id } } ?? inputs.first
            inputUID = fallback?.uid ?? ""
        }
        // Switch to Quiet.driver once, the first time it's seen; after that the user's pick wins.
        if outputs.contains(where: { $0.uid == AudioDevices.quietOutputUID }),
           !UserDefaults.standard.bool(forKey: "adoptedQuietDriver") {
            UserDefaults.standard.set(true, forKey: "adoptedQuietDriver")
            outputUID = AudioDevices.quietOutputUID
        }
        if !outputs.contains(where: { $0.uid == outputUID }) { outputUID = outputs.first?.uid ?? "" }
        let selectedOutput = outputs.first { $0.uid == outputUID }?.id
        outputConflict = selectedOutput != nil && selectedOutput == AudioDevices.defaultOutput()
    }

    private func start() {
        guard pipeline == nil else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."
                    self.enabled = false
                    return
                }
                self.launch()
            }
        }
    }

    private func launch() {
        guard enabled, pipeline == nil else { return }
        guard let input = inputs.first(where: { $0.uid == inputUID }) else { error = "Pick a microphone."; enabled = false; return }
        guard let output = outputs.first(where: { $0.uid == outputUID }) else {
            error = "No virtual mic found. Install Quiet.driver (driver/install_driver.sh) or BlackHole."
            enabled = false
            return
        }
        let p = LivePipeline(input: input.id, output: output.id, settings: settings)
        do {
            try p.start()
            pipeline = p
            error = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let s = self?.pipeline?.currentStats() { self?.stats = s }
                }
            }
        } catch {
            self.error = error.localizedDescription
            enabled = false
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pipeline?.stop()
        pipeline = nil
        stats = LivePipeline.Stats()
    }

    private func restartIfRunning() {
        guard pipeline != nil else { return }
        stop()
        launch()
    }
}

struct LevelBar: View {
    let label: String
    let db: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green.gradient)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, (db + 70) / 70))))
                }
            }
            .frame(height: 6)
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $model.enabled) {
                Text("Quiet").font(.headline)
            }
            .toggleStyle(.switch)

            Picker("Microphone", selection: $model.inputUID) {
                ForEach(model.inputs) { Text($0.name).tag($0.uid) }
            }
            Picker("Send to", selection: $model.outputUID) {
                ForEach(model.outputs) { Text($0.name).tag($0.uid) }
            }
            if let out = model.outputs.first(where: { $0.uid == model.outputUID }) {
                Text("In Riverside, Zoom, OBS or Meet choose “\(out.name)” as the microphone.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if model.outputConflict {
                Text("Your Mac's sound output is also set to this device, so anything playing will be sent into your mic. Pick your speakers or headphones in System Settings › Sound › Output.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Noise reduction", isOn: $model.settings.noiseReduction)
            HStack {
                Slider(value: $model.settings.attenuationLimitDb, in: 6...100)
                Text(model.settings.attenuationLimitDb >= 99 ? "max" : "\(Int(model.settings.attenuationLimitDb)) dB")
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            .disabled(!model.settings.noiseReduction)

            Toggle("Voice isolation", isOn: $model.settings.isolateVoice)
            HStack {
                Slider(value: $model.settings.isolationStrength, in: 0...1)
                Text("\(Int(model.settings.isolationStrength * 100))%")
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            .disabled(!model.settings.isolateVoice)
            Text("Mutes other people in the room. Works best with a headset or close mic.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.enabled {
                Divider()
                LevelBar(label: "In", db: model.stats.inputDb)
                LevelBar(label: "Out", db: model.stats.outputDb)
                Text(String(format: "%.2f ms per 10 ms frame · ~%.0f ms latency%@",
                            model.stats.processMsPerHop, model.stats.latencyMs,
                            model.settings.isolateVoice && !model.stats.gateOpen ? " · background muted" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text("DeepFilterNet3 · on-device").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

@main
struct QuietApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.enabled ? "waveform.badge.mic" : "mic.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
