import Foundation

/// Background-voice suppressor that runs after the denoiser.
///
/// Mirrors the level-gate stage that follows Krisp's BVC model (cut-start / cut-end thresholds and a
/// minimum run length): it tracks the level of the primary (closest, loudest) talker and ducks frames that
/// sit well below it. DeepFilterNet keeps all speech, including other people in the room; this
/// gate removes the quieter ones. It is a level-based heuristic, not a speaker-embedding model, so
/// it works best with a close mic or headset, which is also why Krisp restricts BVC to known devices.
///
/// Real speech swings 10-15 dB between syllables and between a normal and a soft voice, so the
/// reference follows the primary talker's *typical* level (slow rise, follows them down, decays
/// over time) rather than their peaks; otherwise one loud laugh mutes their normal voice for
/// seconds afterwards. The catch: a quieter second talker and the primary speaking softly look the
/// same to a level gate. On a real single-talker recording every 1 dB of background suppression
/// cost about 3% of the primary's own speech, so the defaults favour never cutting the primary.
public struct VoiceGate {
    public struct Parameters {
        /// Close the gate when a frame is this many dB below the primary talker.
        public var cutStartDb: Float = 9
        /// Reopen when it comes back within this many dB.
        public var cutEndDb: Float = 5
        /// Frames (10 ms each) the level must stay low before the gate closes.
        public var holdFrames: Int = 18
        /// Gain applied while closed.
        public var floorDb: Float = -35
        public init() {}

        /// 0 = gentle, 1 = aggressive.
        public static func strength(_ s: Float) -> Parameters {
            var p = Parameters()
            let s = min(max(s, 0), 1)
            p.cutStartDb = 12 - 4 * s
            p.cutEndDb = p.cutStartDb - 4
            p.holdFrames = Int(24 - 8 * s)
            return p
        }
    }

    public var parameters = Parameters()
    public private(set) var isOpen = true
    public private(set) var referenceDb: Float = -40

    private var lowRun = 0
    private var gain: Float = 1
    private var smoothedEnergy: Float = 1e-10
    private let attack: Float = 1 - expf(-1 / (0.003 * 48_000))
    private let release: Float = 1 - expf(-1 / (0.060 * 48_000))
    /// Light per-frame smoothing of the level the gate looks at (~10 ms time constant).
    private let levelSmoothing: Float = 1 - expf(-1)
    /// How quickly the reference rises toward a louder primary (~200 ms, so single syllables don't set it).
    private let refRise: Float = 0.05
    /// How quickly it follows the talker down while they speak more softly (~1 s).
    private let refFollowDown: Float = 0.01
    /// Unconditional decay, in dB per 10 ms frame (3 dB/s), so the reference forgets old peaks.
    private let refDecayPerFrame: Float = 0.03

    public init() {}

    /// Applies the gate to one denoised hop. `lsnr` is DeepFilterNet's local SNR for the frame.
    public mutating func process(_ frame: UnsafeMutablePointer<Float>, count: Int, lsnr: Float) {
        var energy: Float = 0
        for i in 0..<count { energy += frame[i] * frame[i] }
        smoothedEnergy += levelSmoothing * (energy / Float(count) - smoothedEnergy)
        let level = 10 * log10f(smoothedEnergy + 1e-10)
        let isSpeech = lsnr > 0 && level > -55

        referenceDb = max(referenceDb - refDecayPerFrame, -60)
        if isSpeech {
            if level > referenceDb {
                referenceDb += refRise * (level - referenceDb)
            } else if referenceDb - level < parameters.cutStartDb {
                // Still the primary talker, just quieter: let the reference follow them down.
                referenceDb += refFollowDown * (level - referenceDb)
            }
        }

        let below = referenceDb - level
        if isOpen {
            lowRun = (isSpeech && below > parameters.cutStartDb) ? lowRun + 1 : 0
            if lowRun >= parameters.holdFrames { isOpen = false; lowRun = 0 }
        } else if isSpeech && below < parameters.cutEndDb {
            isOpen = true
        }

        let target: Float = isOpen ? 1 : powf(10, parameters.floorDb / 20)
        let coef = target > gain ? attack : release
        for i in 0..<count {
            gain += coef * (target - gain)
            frame[i] *= gain
        }
    }
}
