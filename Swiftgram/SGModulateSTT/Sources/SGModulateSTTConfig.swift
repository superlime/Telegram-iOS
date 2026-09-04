import Foundation

// MARK: Swiftgram
/// Tunables for live call transcription.
///
/// Deliberately committed (unlike the API key) so the behaviour of a build is
/// reproducible from the tree.
public enum SGModulateSTTConfig {
    /// Streaming endpoint. Auth is a query parameter here, not a header — the
    /// batch API uses X-API-Key but the streaming API does not accept it.
    public static let endpoint: String = "wss://platform.modulate.ai/api/velma-2-stt-streaming"

    /// Per-speaker segmentation. Of limited use for us: the tap is the local
    /// microphone after echo cancellation, so there is normally exactly one
    /// speaker. Left on because it costs nothing and does help when someone
    /// else in the room talks.
    public static let speakerDiarization: Bool = true

    /// Emotion and accent are fed to the translator as hints, which is the
    /// point of enabling them.
    public static let emotionSignal: Bool = true
    public static let accentSignal: Bool = true

    /// Interim results. We only ever publish finalised utterances, so asking
    /// for partials would just cost bandwidth.
    public static let partialResults: Bool = false

    /// How long to keep reading after sending end-of-stream, waiting for the
    /// model to flush its final utterance. Without this the last thing the
    /// speaker said is lost every time translation is switched off.
    public static let drainTimeout: Double = 8.0

    /// How long the socket may sit idle before we tear it down and reconnect
    /// on the next utterance. Keeps a muted call from holding a socket open.
    public static let idleTimeout: TimeInterval = 45.0

    // MARK: Audio front-end

    /// Milliseconds of audio per WebSocket frame. 100 ms balances latency
    /// against per-frame overhead.
    public static let frameDurationMs: Int = 100

    /// Speech is gated on a simple energy VAD before being sent.
    ///
    /// This is *not* segmentation — Modulate does its own, and emits utterance
    /// boundaries with start_ms/duration_ms. The gate exists only so that a
    /// silent or muted call does not stream (and bill for) dead air.
    public static let vadEnabled: Bool = true

    /// RMS below this (on a 0...1 scale) counts as silence. Deliberately low:
    /// a gate that clips the onset of speech costs more in accuracy than a
    /// little wasted bandwidth costs in money.
    public static let vadSilenceThreshold: Float = 0.006

    /// Keep streaming for this long after speech stops, so trailing consonants
    /// and short pauses mid-sentence are not cut off.
    public static let vadHangoverMs: Int = 700

    /// Send this much audio from *before* speech was detected. Energy VADs are
    /// inherently late, and without a pre-roll the first phoneme is clipped —
    /// which is exactly the part a recogniser needs most.
    public static let vadPreRollMs: Int = 300

    /// Optional 80 Hz high-pass filter, off by default.
    ///
    /// It is off because it is very likely redundant and possibly harmful: the
    /// audio we tap has already been through the VoiceProcessingIO unit, and
    /// WebRTC's APM applies its own high-pass on this path. The real threat to
    /// recognition accuracy in a noisy room is not low-frequency rumble, it is
    /// the noise suppression and AGC that follow — both tuned for human
    /// intelligibility rather than for a recogniser.
    ///
    /// Left in, and A/B-able, rather than argued about in the abstract.
    public static let highPassFilterEnabled: Bool = false
    public static let highPassCutoffHz: Float = 80.0
}
