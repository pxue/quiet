import Foundation

/// The full per-hop chain shared by the live app and the CLI: DeepFilterNet3 then the voice gate.
public final class FrameProcessor {
    public let denoiser: Denoiser
    public var gate = VoiceGate()
    public var isolateVoice = false
    public var frameLength: Int { denoiser.frameLength }

    private var out: [Float]

    public init?(attenuationLimitDb: Float = 100) {
        guard let d = Denoiser(attenuationLimitDb: attenuationLimitDb) else { return nil }
        denoiser = d
        out = [Float](repeating: 0, count: d.frameLength)
    }

    public struct Result { public var lsnr: Float; public var gateOpen: Bool }

    /// Processes exactly `frameLength` samples from `input`, writing to `output`.
    @discardableResult
    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) -> Result {
        let lsnr = denoiser.process(input, output)
        if isolateVoice {
            gate.process(output, count: frameLength, lsnr: lsnr)
        }
        return Result(lsnr: lsnr, gateOpen: !isolateVoice || gate.isOpen)
    }
}
