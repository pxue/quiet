import AVFoundation

/// Streaming mono sample-rate converter (AVAudioConverter). Passthrough when rates match.
public final class StreamResampler {
    private let converter: AVAudioConverter?
    private let inBuffer: AVAudioPCMBuffer
    private let outBuffer: AVAudioPCMBuffer
    private let maxIn: AVAudioFrameCount

    public init(from inRate: Double, to outRate: Double, maxChunk: Int = 8192) {
        let inFmt = AVAudioFormat(standardFormatWithSampleRate: inRate, channels: 1)!
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 1)!
        maxIn = AVAudioFrameCount(maxChunk)
        inBuffer = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: maxIn)!
        outBuffer = AVAudioPCMBuffer(pcmFormat: outFmt,
                                     frameCapacity: AVAudioFrameCount(Double(maxChunk) * outRate / inRate) + 64)!
        if inRate == outRate {
            converter = nil
        } else {
            converter = AVAudioConverter(from: inFmt, to: outFmt)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
    }

    /// Feeds `count` samples (≤ maxChunk) and hands converted output to `emit`.
    public func process(_ input: UnsafePointer<Float>, count: Int, emit: (UnsafePointer<Float>, Int) -> Void) {
        guard let converter else { emit(input, count); return }
        inBuffer.floatChannelData![0].update(from: input, count: count)
        inBuffer.frameLength = AVAudioFrameCount(count)
        var fed = false
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return self.inBuffer
            }
            if outBuffer.frameLength > 0 { emit(outBuffer.floatChannelData![0], Int(outBuffer.frameLength)) }
            if status != .haveData || outBuffer.frameLength == 0 { break }
        }
    }
}
