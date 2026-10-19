import AVFoundation
import Foundation
import QuietCore

// quiet-cli <in.wav|aiff|m4a> <out.wav> [--atten DB] [--isolate] [--strength 0..1]
// Runs the exact frame chain the live app uses, offline, and reports speed.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var atten: Float = 100
var isolate = false
var strength: Float = 0.75
var liveSeconds: Int?
var inputName: String?
var positional: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--atten": atten = Float(args.removeFirst()) ?? atten
    case "--isolate": isolate = true
    case "--strength": strength = Float(args.removeFirst()) ?? strength
    case "--live": liveSeconds = Int(args.removeFirst()) ?? 10
    case "--input": inputName = args.removeFirst()
    default: positional.append(a)
    }
}

// Live mode: real mic → pipeline → first loopback device, printing stats once a second.
if let seconds = liveSeconds {
    let devices = AudioDevices.all()
    let input = devices.first { d in d.inputChannels > 0 && !d.isLoopback && (inputName.map { d.name.contains($0) } ?? (d.id == AudioDevices.defaultInput())) }
    guard let input, let output = AudioDevices.virtualMicTargets().first else {
        fail("need an input device and a loopback output (BlackHole)")
    }
    var settings = LivePipeline.Settings()
    settings.attenuationLimitDb = atten
    settings.isolateVoice = isolate
    settings.isolationStrength = strength
    let pipeline = LivePipeline(input: input.id, output: output.id, settings: settings)
    do { try pipeline.start() } catch { fail("start: \(error.localizedDescription)") }
    print("live: \(input.name) → \(output.name)")
    for t in 1...seconds {
        Thread.sleep(forTimeInterval: 1)
        let s = pipeline.currentStats()
        print(String(format: "t=%2ds in %6.1f dB  out %6.1f dB  %.3f ms/hop  latency ~%.0f ms  underruns %d",
                     t, s.inputDb, s.outputDb, s.processMsPerHop, s.latencyMs, s.underruns))
    }
    pipeline.stop()
    exit(0)
}

guard positional.count == 2 else {
    fail("usage: quiet-cli <input> <output.wav> [--atten DB] [--isolate] [--strength 0..1]\n       quiet-cli --live SECONDS [--input NAME] [--isolate]")
}

let inFile: AVAudioFile
do { inFile = try AVAudioFile(forReading: URL(fileURLWithPath: positional[0])) } catch { fail("read: \(error)") }
let fmt = inFile.processingFormat
let frames = AVAudioFrameCount(inFile.length)
guard let source = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { fail("alloc") }
do { try inFile.read(into: source) } catch { fail("read: \(error)") }

// Downmix to mono.
let n = Int(source.frameLength)
var mono = [Float](repeating: 0, count: n)
let channels = Int(fmt.channelCount)
for c in 0..<channels {
    let p = source.floatChannelData![c]
    for i in 0..<n { mono[i] += p[i] / Float(channels) }
}

guard let processor = FrameProcessor(attenuationLimitDb: atten) else { fail("model load failed") }
processor.isolateVoice = isolate
processor.gate.parameters = .strength(strength)
let hop = processor.frameLength

// Resample to the model rate and collect.
var resampled: [Float] = []
resampled.reserveCapacity(Int(Double(n) * 48_000 / fmt.sampleRate) + hop)
let rs = StreamResampler(from: fmt.sampleRate, to: processor.denoiser.sampleRate)
mono.withUnsafeBufferPointer { buf in
    var i = 0
    while i < n {
        let take = min(4096, n - i)
        rs.process(buf.baseAddress! + i, count: take) { p, c in resampled.append(contentsOf: UnsafeBufferPointer(start: p, count: c)) }
        i += take
    }
}
let pad = (hop - resampled.count % hop) % hop
resampled.append(contentsOf: [Float](repeating: 0, count: pad + hop * 3))

var output = [Float](repeating: 0, count: resampled.count)
var gateClosedFrames = 0
var lsnrSum: Float = 0
let hops = resampled.count / hop
let t0 = Date()
resampled.withUnsafeBufferPointer { inp in
    output.withUnsafeMutableBufferPointer { out in
        for h in 0..<hops {
            let r = processor.process(inp.baseAddress! + h * hop, out.baseAddress! + h * hop)
            lsnrSum += r.lsnr
            if !r.gateOpen { gateClosedFrames += 1 }
        }
    }
}
let elapsed = Date().timeIntervalSince(t0)

let outFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                               AVLinearPCMIsFloatKey: false]
do {
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: positional[1]), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(output.count))!
    buf.frameLength = AVAudioFrameCount(output.count)
    output.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: output.count) }
    try file.write(from: buf)
} catch { fail("write: \(error)") }

let audioSeconds = Double(resampled.count) / 48_000
print(String(format: "audio %.2fs  processed in %.3fs  RTF %.3f  (%.3f ms per 10 ms hop)  mean lSNR %.1f dB  gate closed %.1f%%",
             audioSeconds, elapsed, elapsed / audioSeconds, elapsed * 1000 / Double(hops),
             lsnrSum / Float(hops), 100 * Double(gateClosedFrames) / Double(hops)))
