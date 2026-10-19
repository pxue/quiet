import AudioToolbox
import CoreAudio
import CRing
import Foundation

public enum PipelineError: LocalizedError {
    case audioUnit(String, OSStatus)
    case model

    public var errorDescription: String? {
        switch self {
        case let .audioUnit(step, status): return "\(step) failed (OSStatus \(status))"
        case .model: return "Could not load the DeepFilterNet model"
        }
    }
}

/// Real mic → DeepFilterNet3 (+ voice gate) → loopback device (e.g. BlackHole), which other apps pick as their mic.
///
/// Same topology as Krisp's driver: a hidden device the app writes processed audio into and a visible
/// "microphone" that meeting apps read. Quiet.driver (or plain BlackHole) plays both roles here.
///
/// Threads: the input IO callback only copies into `inRing`; a worker thread resamples to 48 kHz and runs
/// the model; the output IO callback only copies from `outRing`. No locks or allocation on IO threads.
public final class LivePipeline {
    public struct Settings {
        public var noiseReduction = true
        public var attenuationLimitDb: Float = 100
        public var isolateVoice = false
        public var isolationStrength: Float = 0.75
        public init() {}
    }

    public struct Stats {
        public var inputDb: Float = -100
        public var outputDb: Float = -100
        public var gateOpen = true
        public var processMsPerHop: Double = 0
        public var latencyMs: Double = 0
        public var underruns = 0
        public init() {}
    }

    private let inputDevice: AudioDeviceID
    private let outputDevice: AudioDeviceID
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var inputSampleRate: Double = 48_000
    private var inputChannels = 1

    private let inRing = qring_new(48_000)!
    private let outRing = qring_new(48_000)!
    private var inputABL: UnsafeMutableAudioBufferListPointer?
    private let maxIOFrames = 8192
    private let outScratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)

    // Output jitter buffer: start playing once 20 ms is queued, trim if drift pushes it past 80 ms.
    private let primeFrames: UInt32 = 960
    private let maxQueuedFrames: UInt32 = 3840
    private var priming = true
    private var underruns = 0

    private let wake = DispatchSemaphore(value: 0)
    private var worker: Thread?
    private var running = false

    private let lock = NSLock()
    private var pendingSettings: Settings?
    private var stats = Stats()

    public init(input: AudioDeviceID, output: AudioDeviceID, settings: Settings) {
        inputDevice = input
        outputDevice = output
        pendingSettings = settings
    }

    deinit {
        stop()
        qring_free(inRing)
        qring_free(outRing)
        outScratch.deallocate()
    }

    public func update(_ settings: Settings) {
        lock.lock(); pendingSettings = settings; lock.unlock()
    }

    public func currentStats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.underruns = underruns
        return s
    }

    public func start() throws {
        guard !running else { return }
        guard let processor = FrameProcessor() else { throw PipelineError.model }
        try setUpInput()
        try setUpOutput()
        running = true
        let thread = Thread { [unowned self] in self.workLoop(processor) }
        thread.qualityOfService = .userInteractive
        thread.name = "Quiet DSP"
        worker = thread
        thread.start()
        try check(AudioOutputUnitStart(outputUnit!), "Start output")
        try check(AudioOutputUnitStart(inputUnit!), "Start input")
    }

    public func stop() {
        guard running else { return }
        running = false
        wake.signal()
        for unit in [inputUnit, outputUnit].compactMap({ $0 }) {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        outputUnit = nil
        if let abl = inputABL {
            for buffer in abl { buffer.mData?.deallocate() }
            free(abl.unsafeMutablePointer)
            inputABL = nil
        }
    }

    // MARK: - DSP worker

    private func workLoop(_ processor: FrameProcessor) {
        let hop = processor.frameLength
        let resampler = StreamResampler(from: inputSampleRate, to: processor.denoiser.sampleRate)
        let chunk = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        let hopIn = UnsafeMutablePointer<Float>.allocate(capacity: hop)
        let hopOut = UnsafeMutablePointer<Float>.allocate(capacity: hop)
        defer { chunk.deallocate(); hopIn.deallocate(); hopOut.deallocate() }
        var filled = 0
        var inDb: Float = -100, outDb: Float = -100, procMs = 0.0

        while running {
            _ = wake.wait(timeout: .now() + .milliseconds(50))

            lock.lock()
            if let s = pendingSettings {
                pendingSettings = nil
                processor.denoiser.setAttenuationLimit(s.noiseReduction ? s.attenuationLimitDb : 0)
                processor.isolateVoice = s.isolateVoice
                processor.gate.parameters = .strength(s.isolationStrength)
            }
            lock.unlock()

            var gateOpen = true
            while running {
                let n = Int(qring_read(inRing, chunk, 2048))
                if n == 0 { break }
                resampler.process(chunk, count: n) { samples, count in
                    var i = 0
                    while i < count {
                        let take = min(hop - filled, count - i)
                        (hopIn + filled).update(from: samples + i, count: take)
                        filled += take
                        i += take
                        guard filled == hop else { continue }
                        filled = 0

                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let result = processor.process(hopIn, hopOut)
                        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                        procMs = procMs * 0.95 + dt * 0.05
                        inDb = max(level(hopIn, hop), inDb - 1.5)
                        outDb = max(level(hopOut, hop), outDb - 1.5)
                        gateOpen = result.gateOpen

                        qring_write(outRing, hopOut, UInt32(hop))
                        let queued = qring_available(outRing)
                        if queued > maxQueuedFrames { qring_skip(outRing, queued - primeFrames) }
                    }
                }
            }

            lock.lock()
            stats.inputDb = inDb
            stats.outputDb = outDb
            stats.gateOpen = gateOpen
            stats.processMsPerHop = procMs
            stats.latencyMs = Double(qring_available(outRing) + qring_available(inRing)) / 48.0 + 30
            lock.unlock()
        }
    }

    private func level(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        var e: Float = 0
        for i in 0..<n { e += p[i] * p[i] }
        return 10 * log10f(e / Float(n) + 1e-10)
    }

    // MARK: - IO callbacks (real-time threads)

    fileprivate func onInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, let abl = inputABL, frames <= UInt32(maxIOFrames) else { return noErr }
        for i in 0..<abl.count { abl[i].mDataByteSize = frames * 4 }
        let status = AudioUnitRender(unit, flags, time, 1, frames, abl.unsafeMutablePointer)
        guard status == noErr else { return status }

        // Mono mixdown into the first buffer: average a stereo pair, otherwise take channel 1.
        let first = abl[0].mData!.assumingMemoryBound(to: Float.self)
        if inputChannels == 2 {
            let second = abl[1].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) { first[i] = 0.5 * (first[i] + second[i]) }
        }
        qring_write(inRing, first, frames)
        wake.signal()
        return noErr
    }

    fileprivate func onOutput(_ data: UnsafeMutablePointer<AudioBufferList>, _ frames: UInt32) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(data)
        let n = Int(frames)
        if priming && qring_available(outRing) >= primeFrames { priming = false }
        var got = 0
        if !priming {
            got = Int(qring_read(outRing, outScratch, frames))
            if got < n { priming = true; underruns += 1 }
        }
        if got < n { (outScratch + got).update(repeating: 0, count: n - got) }
        for buffer in abl {
            buffer.mData?.copyMemory(from: outScratch, byteCount: n * 4)
        }
        return noErr
    }

    // MARK: - AUHAL setup

    private func makeHAL() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw PipelineError.audioUnit("Find AUHAL", -1)
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "Create AUHAL")
        return unit!
    }

    private func setUpInput() throws {
        let unit = try makeHAL()
        var on: UInt32 = 1, off: UInt32 = 0, device = inputDevice
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, "Enable input")
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, "Disable output")
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, "Select input device")

        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size),
                  "Read input format")
        inputSampleRate = hw.mSampleRate
        inputChannels = Int(hw.mChannelsPerFrame)

        var fmt = floatFormat(rate: hw.mSampleRate, channels: hw.mChannelsPerFrame)
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, "Set input client format")

        let abl = AudioBufferList.allocate(maximumBuffers: inputChannels)
        for i in 0..<inputChannels {
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxIOFrames * 4),
                                 mData: UnsafeMutableRawPointer.allocate(byteCount: maxIOFrames * 4, alignment: 16))
        }
        inputABL = abl

        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, _, frames, _ in
            Unmanaged<LivePipeline>.fromOpaque(refCon).takeUnretainedValue().onInput(flags, time, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, "Input callback")
        try check(AudioUnitInitialize(unit), "Initialize input")
        inputUnit = unit
    }

    private func setUpOutput() throws {
        let unit = try makeHAL()
        var device = outputDevice
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, "Select output device")

        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hw, &size),
                  "Read output format")
        // AUHAL converts our 48 kHz model rate to whatever the loopback device runs at.
        var fmt = floatFormat(rate: 48_000, channels: max(hw.mChannelsPerFrame, 1))
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, "Set output client format")

        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, data in
            guard let data else { return noErr }
            return Unmanaged<LivePipeline>.fromOpaque(refCon).takeUnretainedValue().onOutput(data, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, "Output callback")
        try check(AudioUnitInitialize(unit), "Initialize output")
        outputUnit = unit
    }

    private func floatFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: inout T, _ step: String) throws {
        let status = withUnsafeMutableBytes(of: &value) {
            AudioUnitSetProperty(unit, property, scope, element, $0.baseAddress, UInt32($0.count))
        }
        try check(status, step)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw PipelineError.audioUnit(step, status) }
    }
}
