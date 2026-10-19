import CDFCore

/// DeepFilterNet3 noise suppressor. Mono, 48 kHz, fixed 480-sample (10 ms) hops.
public final class Denoiser {
    private let handle: OpaquePointer
    public let frameLength: Int
    public let sampleRate: Double

    /// `attenuationLimitDb` caps how many dB of noise are removed; 100 means unlimited, 0 is passthrough.
    public init?(attenuationLimitDb: Float = 100) {
        guard let h = df_new(attenuationLimitDb) else { return nil }
        handle = h
        frameLength = Int(df_frame_len(h))
        sampleRate = Double(df_sample_rate(h))
    }

    deinit { df_free(handle) }

    public func setAttenuationLimit(_ db: Float) { df_set_atten_lim(handle, db) }

    /// Denoises one hop in place-safe fashion and returns the model's local SNR estimate (dB).
    @discardableResult
    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) -> Float {
        df_process(handle, input, output)
    }
}
