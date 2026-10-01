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

    /// Per-speaker segmentation, off.
    ///
    /// The tap is the local microphone after echo cancellation, so there is
    /// one speaker: the person holding the phone. With diarisation on, the
    /// model regularly split that one voice into "speaker 1" and "speaker 2"
    /// (seen consistently with one tester), and everything labelled 2 was
    /// treated as a bystander — captioned in the chat with a speaker header
    /// and kept off the subtitle strip — so half of what they said never
    /// reached the other party. The API offers no way to cap the speaker
    /// count (checked against the streaming spec, 2026-09-24), and speaker
    /// numbers are only stable within one connection anyway, which the
    /// reconnect logic now makes several per call. Off, the model reports no
    /// speaker and every utterance is treated as the owner's, which is the
    /// right answer nearly all of the time.
    public static let speakerDiarization: Bool = false

    /// Accent is fed to the translator as a hint, which is the point of
    /// enabling it.
    ///
    /// Emotion is off. It was enabled for the same reason, but it earns its
    /// place far less: it is a per-utterance guess from a short, echo-cancelled
    /// microphone tap, and a wrong label is worse than no label because the
    /// translator acts on it. Turning it off also drops it from the properties
    /// line, since the model stops reporting it.
    public static let emotionSignal: Bool = false
    public static let accentSignal: Bool = true

    /// Interim results. Shown live in the subtitle strip and the chat message
    /// while the speaker is still talking, then replaced by the final
    /// transcript and its translation. Partials are never translated: they
    /// change with every frame and the translator would be paid to chase them.
    public static let partialResults: Bool = true

    /// How long to keep reading after sending end-of-stream, waiting for the
    /// model to flush its final utterance. Without this the last thing the
    /// speaker said is lost every time translation is switched off.
    public static let drainTimeout: Double = 8.0

    /// How long a socket may carry no audio before we end it (gracefully, so
    /// the server flushes its last utterance) and reconnect on the next word.
    /// The speech gate sends nothing while the other party talks, and neither
    /// side of the protocol sends keepalives, so a listener's socket has to be
    /// ended by us: left alone, URLSession times it out silently.
    public static let idleTimeout: TimeInterval = 45.0

    /// Watchdog: milliseconds of audio a socket may carry without the server
    /// saying anything before it is presumed dead, ended gracefully and
    /// replaced. The server answers at every pause with an utterance, so only
    /// a monologue with no pause at all trips this legitimately — and the cost
    /// there is an utterance split in two, not lost. A socket URLSession has
    /// silently timed out never answers again, and this is what catches it;
    /// the speech sent into it before the limit is reached is lost, which is
    /// why the limit is as short as a single breathless sentence allows.
    public static let unansweredAudioLimitMs: Double = 20_000.0

    /// Seconds without a new partial, while an utterance is still unfinished,
    /// before the socket is sent end-of-stream to force the final out.
    ///
    /// The server decides on its own when an utterance is over, from the audio
    /// it is sent. Once the speech gate shuts it is sent nothing, and testers
    /// saw a finished sentence sit unfinalised through a long pause until the
    /// next word pushed it out. The protocol guarantees the pending utterance
    /// is emitted after end-of-stream, so a stalled partial is ended that way.
    /// Partials arrive continuously while someone is talking, so this only
    /// fires in a pause; the next word opens a fresh socket (~1 s).
    public static let partialStallTimeout: Double = 2.0

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
    ///
    /// Also what lets the server *finish* an utterance: it endpoints on the
    /// silence it is sent, and once the gate shuts it is sent nothing. Testers
    /// saw long utterances hang until the speaker made any further noise —
    /// which carries a little silence with it. Against the live API a 700 ms
    /// tail was enough for a 10 s synthetic utterance, with digital silence
    /// or room tone alike, so this is insurance for real microphones rather
    /// than a reproduced fix: 1.5 s of tail costs nothing and leaves the
    /// endpointer no excuse.
    public static let vadHangoverMs: Int = 1500

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
