import Foundation
import SwiftSignalKit

// MARK: Swiftgram
/// Streaming speech recognition against Modulate's velma-2 model.
///
/// Modulate performs its own utterance segmentation and reports boundaries with
/// start_ms/duration_ms, so this client does not attempt to segment: it streams
/// speech-gated audio and republishes whatever utterances come back.

public enum SGModulateSTTError: Error {
    case notConfigured
    case network
    case handshake(Int)
    case api(String?)
}

/// A finalised utterance, with whatever signals the model attached to it.
public struct SGModulateUtterance: Equatable {
    public let uuid: String
    public let text: String
    public let startMs: Int
    public let durationMs: Int
    /// BCP 47 where the model reports one.
    public let language: String?
    public let speaker: String?
    public let emotion: String?
    public let accent: String?
    /// Seconds between the speaker finishing this utterance and the transcript
    /// arriving. nil when the audio could not be located on the wall clock —
    /// see `SGModulateSTTSession.wallClock(forStreamMs:)`.
    public let recognitionLatency: Double?

    public init(
        uuid: String,
        text: String,
        startMs: Int,
        durationMs: Int,
        language: String?,
        speaker: String?,
        emotion: String?,
        accent: String?,
        recognitionLatency: Double? = nil
    ) {
        self.uuid = uuid
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
        self.language = language
        self.speaker = speaker
        self.emotion = emotion
        self.accent = accent
        self.recognitionLatency = recognitionLatency
    }

    /// The diarisation label as a number, when it is one.
    ///
    /// The tap is the local microphone, so the first speaker the model hears is
    /// the person holding the phone. Callers use this to tell "me" from someone
    /// else in the room picked up through the same mic.
    public var speakerNumber: Int? {
        guard let speaker = self.speaker else {
            return nil
        }
        return Int(speaker.trimmingCharacters(in: .whitespaces))
    }

    /// Human-readable summary of the detected signals, for the chat message.
    public var detectedPropertiesDescription: String {
        var parts: [String] = []
        if let language = self.language, !language.isEmpty {
            parts.append(language)
        }
        if let accent = self.accent, !accent.isEmpty {
            parts.append("accent: \(accent)")
        }
        if let emotion = self.emotion, !emotion.isEmpty {
            parts.append("emotion: \(emotion)")
        }
        // Speaker is deliberately absent: it is surfaced as the message header
        // instead, and repeating it here read as noise.
        return parts.joined(separator: ", ")
    }
}

public var isSGModulateSTTConfigured: Bool {
    return !SGModulateSTTCredentials.key.isEmpty
}

private let sgModulateQueue = Queue(name: "SGModulateSTT", qos: .userInitiated)

/// One live recognition session. Owns a WebSocket for as long as audio flows.
public final class SGModulateSTTSession {
    public var onUtterance: ((SGModulateUtterance) -> Void)?
    public var onError: ((SGModulateSTTError) -> Void)?
    /// Fired once the stream has fully drained and the socket is closed.
    public var onFinished: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isOpen: Bool = false
    private var isStarted: Bool = false
    private var isDraining: Bool = false
    private var isFinished: Bool = false
    private var sampleRate: Int32 = 0
    private var channels: Int = 1
    /// Hint passed to the model; nil means "detect".
    private let languageHint: String?

    // Stream-time to wall-clock ledger.
    //
    // The model reports utterance boundaries as offsets into the audio *it was
    // sent*, and the VAD in front of us drops silence, so stream time runs
    // slower than the clock and by a varying amount. Latency measured against
    // stream time would therefore be wrong, and wrong in the flattering
    // direction. Instead we record, for each frame submitted, how much audio
    // had been sent by then and when that happened; an utterance's end offset
    // is then looked up to find the moment it was actually spoken.
    private var submittedMs: Double = 0.0
    private var streamClock: [(streamMs: Double, wallClock: Double)] = []
    /// ~10 minutes of 100 ms frames. Bounded so a long call cannot grow this
    /// without limit; older entries can be dropped because an utterance is
    /// reported within seconds of being spoken.
    private static let streamClockCapacity: Int = 6000

    public init(languageHint: String? = nil) {
        self.languageHint = languageHint
    }

    /// Arms the session. The socket itself is opened by the first audio frame:
    /// the wire format is declared in the query string, so we cannot connect
    /// until we know the sample rate the call is actually running at.
    public func start() {
        sgModulateQueue.async { [weak self] in
            self?.isStarted = true
        }
    }

    /// Enqueue mono 16-bit PCM. Safe to call from any thread.
    public func append(pcm: Data, sampleRate: Int32) {
        // Sampled here rather than on the queue: this is the moment the audio
        // reached us, and the queue hop would fold scheduling delay into every
        // latency figure we report.
        let capturedAt = CFAbsoluteTimeGetCurrent()
        sgModulateQueue.async { [weak self] in
            guard let self = self, self.isStarted, !self.isFinished else {
                return
            }
            if self.task == nil {
                self.sampleRate = sampleRate
                self.connect()
            }
            guard let task = self.task else {
                return
            }
            if sampleRate > 0 {
                // 16-bit mono: two bytes per sample.
                self.submittedMs += Double(pcm.count) / 2.0 / Double(sampleRate) * 1000.0
                self.streamClock.append((streamMs: self.submittedMs, wallClock: capturedAt))
                if self.streamClock.count > SGModulateSTTSession.streamClockCapacity {
                    self.streamClock.removeFirst(self.streamClock.count - SGModulateSTTSession.streamClockCapacity)
                }
            }
            task.send(.data(pcm)) { _ in }
        }
    }

    /// When, on the wall clock, the stream had carried `streamMs` of audio.
    ///
    /// Returns nil when the offset predates the retained ledger, which would
    /// otherwise produce a fabricated latency. Callers show nothing rather than
    /// a number they cannot stand behind.
    func wallClock(forStreamMs streamMs: Double) -> Double? {
        guard let first = self.streamClock.first, streamMs >= first.streamMs else {
            return nil
        }
        // Ledger is ascending; the first entry at or past the offset is the
        // frame that carried it.
        for entry in self.streamClock where entry.streamMs >= streamMs {
            return entry.wallClock
        }
        return self.streamClock.last?.wallClock
    }

    /// Signal end-of-stream and keep reading until the model has flushed.
    ///
    /// The last utterance of a stream is emitted *after* the server sees the
    /// end-of-stream marker, so closing the socket here would silently discard
    /// whatever the speaker just said. We stop sending, wait for "done", and
    /// only then tear down — with a timeout so a wedged server cannot keep the
    /// session alive forever.
    public func finish() {
        sgModulateQueue.async { [weak self] in
            guard let self = self, !self.isDraining, !self.isFinished else {
                return
            }
            guard self.task != nil else {
                // Nothing was ever sent; nothing to drain.
                self.teardown()
                return
            }
            self.isDraining = true
            // The protocol ends a stream with an empty text frame.
            self.task?.send(.string("")) { _ in }
            sgModulateQueue.after(SGModulateSTTConfig.drainTimeout) { [weak self] in
                self?.teardown()
            }
        }
    }

    private func teardown() {
        guard !self.isFinished else {
            return
        }
        self.isFinished = true
        self.isDraining = false
        self.isOpen = false
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.onFinished?()
    }

    // MARK: Private

    private func connect() {
        guard isSGModulateSTTConfigured else {
            self.onError?(.notConfigured)
            return
        }
        guard var components = URLComponents(string: SGModulateSTTConfig.endpoint) else {
            self.onError?(.network)
            return
        }

        // Everything is configured through the query string. The streaming API
        // authenticates this way too — unlike the batch API it does not accept
        // an X-API-Key header. A JSON config frame can carry the feature
        // toggles, but *not* the audio format, so there is no reason to send one.
        var query: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: SGModulateSTTCredentials.key),
            // Raw PCM is headerless, so the format has to be declared here.
            URLQueryItem(name: "audio_format", value: "s16le"),
            URLQueryItem(name: "sample_rate", value: "\(self.sampleRate)"),
            URLQueryItem(name: "num_channels", value: "\(self.channels)"),
            URLQueryItem(name: "speaker_diarization", value: SGModulateSTTConfig.speakerDiarization ? "true" : "false"),
            URLQueryItem(name: "emotion_signal", value: SGModulateSTTConfig.emotionSignal ? "true" : "false"),
            URLQueryItem(name: "accent_signal", value: SGModulateSTTConfig.accentSignal ? "true" : "false"),
            URLQueryItem(name: "partial_results", value: SGModulateSTTConfig.partialResults ? "true" : "false")
        ]
        // The hint is an ISO 639-1 code, so a BCP 47 tag has to be reduced to
        // its primary subtag: "pt-BR" is not accepted, "pt" is.
        if let hint = sgModulatePrimaryLanguageSubtag(self.languageHint) {
            query.append(URLQueryItem(name: "language", value: hint))
        }
        components.queryItems = query

        guard let url = components.url else {
            self.onError?(.network)
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SGModulateSTTConfig.idleTimeout
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        self.isOpen = true

        self.receiveNext()
    }

    private func receiveNext() {
        guard let task = self.task else {
            return
        }
        task.receive { [weak self] result in
            sgModulateQueue.async {
                guard let self = self, !self.isFinished else {
                    return
                }
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text):
                        self.handle(text: text)
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handle(text: text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                case .failure:
                    self.isOpen = false
                    self.onError?(.network)
                }
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "utterance":
            guard let payload = object["utterance"] as? [String: Any] else {
                return
            }
            let startMs = payload["start_ms"] as? Int ?? 0
            let durationMs = payload["duration_ms"] as? Int ?? 0
            // Measured from the END of the utterance: that is the earliest
            // moment a transcript of it could possibly exist.
            var latency: Double? = nil
            if let spokenAt = self.wallClock(forStreamMs: Double(startMs + durationMs)) {
                latency = max(0.0, CFAbsoluteTimeGetCurrent() - spokenAt)
            }
            let utterance = SGModulateUtterance(
                uuid: payload["utterance_uuid"] as? String ?? UUID().uuidString,
                text: (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                startMs: startMs,
                durationMs: durationMs,
                language: payload["language"] as? String,
                speaker: sgModulateStringValue(payload["speaker"]),
                emotion: sgModulateStringValue(payload["emotion"]),
                accent: sgModulateStringValue(payload["accent"]),
                recognitionLatency: latency
            )
            guard !utterance.text.isEmpty else {
                return
            }
            self.onUtterance?(utterance)
        case "error":
            self.onError?(.api(object["error"] as? String ?? object["message"] as? String))
        case "done":
            // The model has flushed everything it had; safe to close now.
            self.teardown()
        default:
            // "partial_utterance" is ignored: we publish finalised utterances
            // only, so there is nothing to do with an interim result.
            break
        }
    }
}

/// speaker/emotion/accent are not uniformly typed: `speaker` comes back as an
/// integer, the signals as strings, and the docs leave room for a labelled
/// object. Accept all three shapes.
///
/// "Unknown" is the model's way of saying it had no opinion, so it is mapped to
/// nil rather than passed on — it is not a useful hint to a translator, and it
/// would be noise in the chat message.
private func sgModulateStringValue(_ value: Any?) -> String? {
    var result: String? = nil
    if let string = value as? String {
        result = string
    } else if let number = value as? NSNumber {
        result = number.stringValue
    } else if let object = value as? [String: Any] {
        for key in ["label", "name", "value"] {
            if let string = object[key] as? String, !string.isEmpty {
                result = string
                break
            }
        }
    }
    guard let value = result?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    if value.caseInsensitiveCompare("unknown") == .orderedSame {
        return nil
    }
    return value
}

/// Reduces a BCP 47 tag to the ISO 639-1 primary subtag the API expects.
/// "pt-BR" -> "pt", "zh-Hans" -> "zh". Returns nil for anything that is not a
/// two-letter code, so a malformed setting degrades to auto-detect rather than
/// being rejected by the server.
func sgModulatePrimaryLanguageSubtag(_ tag: String?) -> String? {
    guard let tag = tag, !tag.isEmpty else {
        return nil
    }
    let primary = tag.split(separator: "-").first.map(String.init) ?? tag
    guard primary.count == 2 else {
        return nil
    }
    return primary.lowercased()
}
