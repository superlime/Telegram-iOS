import Foundation

// MARK: Swiftgram
/// Turns the call's realtime 10 ms microphone callbacks into speech-gated
/// frames ready to stream to a recogniser.
///
/// Threading contract: `append` is called from the WebRTC audio thread and must
/// not block or allocate on the steady-state path. Everything it produces is
/// handed to `onFrame`, which is invoked on that same audio thread — the caller
/// is responsible for getting the data onto its own queue promptly.
public final class SGModulateAudioFrontEnd {
    /// Emitted with mono 16-bit PCM at `sampleRate`.
    public var onFrame: ((Data, Int32) -> Void)?

    /// Raised when the gate opens and lowered after the hangover expires, so a
    /// caller can bracket a stream with start/end markers.
    public var onSpeechStateChanged: ((Bool) -> Void)?

    private let config: FrontEndConfig

    public struct FrontEndConfig {
        public var frameDurationMs: Int
        public var vadEnabled: Bool
        public var silenceThreshold: Float
        public var hangoverMs: Int
        public var preRollMs: Int
        public var highPassEnabled: Bool
        public var highPassCutoffHz: Float

        public init(
            frameDurationMs: Int = SGModulateSTTConfig.frameDurationMs,
            vadEnabled: Bool = SGModulateSTTConfig.vadEnabled,
            silenceThreshold: Float = SGModulateSTTConfig.vadSilenceThreshold,
            hangoverMs: Int = SGModulateSTTConfig.vadHangoverMs,
            preRollMs: Int = SGModulateSTTConfig.vadPreRollMs,
            highPassEnabled: Bool = SGModulateSTTConfig.highPassFilterEnabled,
            highPassCutoffHz: Float = SGModulateSTTConfig.highPassCutoffHz
        ) {
            self.frameDurationMs = frameDurationMs
            self.vadEnabled = vadEnabled
            self.silenceThreshold = silenceThreshold
            self.hangoverMs = hangoverMs
            self.preRollMs = preRollMs
            self.highPassEnabled = highPassEnabled
            self.highPassCutoffHz = highPassCutoffHz
        }
    }

    // Accumulates mono samples until a full frame is ready.
    private var pending: [Int16] = []
    private var sampleRate: Int32 = 0
    private var samplesPerFrame: Int = 0

    // Pre-roll: a ring of frames kept from before the gate opened, so the onset
    // of speech is not clipped. An energy VAD always notices speech a little
    // after it starts; without this the first phoneme is lost.
    private var preRoll: [Data] = []
    private var preRollCapacity: Int = 0

    private var isSpeaking: Bool = false
    private var silentMsSinceSpeech: Int = 0

    // One-pole high-pass state, only used when the filter is enabled.
    private var hpPrevInput: Float = 0.0
    private var hpPrevOutput: Float = 0.0
    private var hpAlpha: Float = 1.0

    public init(config: FrontEndConfig = FrontEndConfig()) {
        self.config = config
    }

    /// Reset between calls. Must not be called concurrently with `append`.
    public func reset() {
        self.pending.removeAll(keepingCapacity: true)
        self.preRoll.removeAll(keepingCapacity: true)
        self.isSpeaking = false
        self.silentMsSinceSpeech = 0
        self.hpPrevInput = 0.0
        self.hpPrevOutput = 0.0
        self.sampleRate = 0
    }

    /// Called from the realtime audio thread with interleaved samples.
    public func append(samples: UnsafePointer<Int16>, sampleCount: Int, channels: Int, sampleRate: Int32) {
        guard sampleCount > 0, channels > 0 else {
            return
        }

        if sampleRate != self.sampleRate {
            self.configure(sampleRate: sampleRate)
        }

        // Downmix to mono. Recognisers want one channel and the call is mono in
        // practice, but the ADM is not contractually obliged to hand us one.
        if channels == 1 {
            self.pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: sampleCount))
        } else {
            self.pending.reserveCapacity(self.pending.count + sampleCount)
            for frame in 0 ..< sampleCount {
                var acc = 0
                for channel in 0 ..< channels {
                    acc += Int(samples[frame * channels + channel])
                }
                self.pending.append(Int16(clamping: acc / channels))
            }
        }

        while self.pending.count >= self.samplesPerFrame {
            var frame = Array(self.pending[0 ..< self.samplesPerFrame])
            self.pending.removeFirst(self.samplesPerFrame)

            if self.config.highPassEnabled {
                self.applyHighPass(&frame)
            }
            self.process(frame: frame)
        }
    }

    /// Force the gate shut, flushing any speech state. Used when translation is
    /// switched off or the call ends.
    public func finish() {
        if self.isSpeaking {
            self.isSpeaking = false
            self.onSpeechStateChanged?(false)
        }
        self.pending.removeAll(keepingCapacity: true)
        self.preRoll.removeAll(keepingCapacity: true)
    }

    // MARK: Private

    private func configure(sampleRate: Int32) {
        self.sampleRate = sampleRate
        self.samplesPerFrame = max(1, Int(sampleRate) * self.config.frameDurationMs / 1000)
        self.preRollCapacity = max(0, self.config.preRollMs / max(1, self.config.frameDurationMs))
        self.pending.removeAll(keepingCapacity: true)
        self.preRoll.removeAll(keepingCapacity: true)

        // One-pole high-pass coefficient for the configured cutoff.
        let dt = 1.0 / Float(sampleRate)
        let rc = 1.0 / (2.0 * Float.pi * self.config.highPassCutoffHz)
        self.hpAlpha = rc / (rc + dt)
        self.hpPrevInput = 0.0
        self.hpPrevOutput = 0.0
    }

    private func applyHighPass(_ frame: inout [Int16]) {
        for i in 0 ..< frame.count {
            let x = Float(frame[i])
            let y = self.hpAlpha * (self.hpPrevOutput + x - self.hpPrevInput)
            self.hpPrevInput = x
            self.hpPrevOutput = y
            frame[i] = Int16(clamping: Int(y.rounded()))
        }
    }

    private func process(frame: [Int16]) {
        let data = frame.withUnsafeBufferPointer { Data(buffer: $0) }

        guard self.config.vadEnabled else {
            self.onFrame?(data, self.sampleRate)
            return
        }

        let isLoud = SGModulateAudioFrontEnd.rms(frame) >= self.config.silenceThreshold

        if isLoud {
            self.silentMsSinceSpeech = 0
            if !self.isSpeaking {
                self.isSpeaking = true
                self.onSpeechStateChanged?(true)
                // Flush the pre-roll so the recogniser hears the attack.
                for buffered in self.preRoll {
                    self.onFrame?(buffered, self.sampleRate)
                }
                self.preRoll.removeAll(keepingCapacity: true)
            }
            self.onFrame?(data, self.sampleRate)
            return
        }

        if self.isSpeaking {
            // Hangover: keep sending through short pauses so we do not chop a
            // sentence in half at every comma.
            self.silentMsSinceSpeech += self.config.frameDurationMs
            self.onFrame?(data, self.sampleRate)
            if self.silentMsSinceSpeech >= self.config.hangoverMs {
                self.isSpeaking = false
                self.silentMsSinceSpeech = 0
                self.onSpeechStateChanged?(false)
            }
            return
        }

        // Silent and not speaking: remember it in case speech starts next frame.
        if self.preRollCapacity > 0 {
            self.preRoll.append(data)
            if self.preRoll.count > self.preRollCapacity {
                self.preRoll.removeFirst(self.preRoll.count - self.preRollCapacity)
            }
        }
    }

    static func rms(_ frame: [Int16]) -> Float {
        guard !frame.isEmpty else {
            return 0.0
        }
        var acc: Double = 0.0
        for sample in frame {
            let normalized = Double(sample) / 32768.0
            acc += normalized * normalized
        }
        return Float((acc / Double(frame.count)).squareRoot())
    }
}
