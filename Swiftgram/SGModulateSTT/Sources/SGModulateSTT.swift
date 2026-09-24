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

/// An in-progress transcription, superseded by the next partial and finally
/// by the utterance it belongs to.
///
/// There is no uuid: the API does not attach one until the utterance is
/// final. `startMs` is the only handle — the final utterance for this speech
/// carries the same `startMs` — and even that may be nil for the first
/// partial or two.
public struct SGModulatePartialUtterance: Equatable {
    public let text: String
    public let startMs: Int?
    public let speaker: String?

    public init(text: String, startMs: Int?, speaker: String?) {
        self.text = text
        self.startMs = startMs
        self.speaker = speaker
    }

    public var speakerNumber: Int? {
        guard let speaker = self.speaker else {
            return nil
        }
        return Int(speaker.trimmingCharacters(in: .whitespaces))
    }
}

public var isSGModulateSTTConfigured: Bool {
    return !SGModulateSTTCredentials.key.isEmpty
}

private let sgModulateQueue = Queue(name: "SGModulateSTT", qos: .userInitiated)

/// One WebSocket to Modulate, with the ledger that maps its stream offsets
/// back onto the wall clock. A session opens as many of these as it needs.
private final class SGModulateSocket {
    let task: URLSessionWebSocketTask
    let session: URLSession

    // Stream-time to wall-clock ledger.
    //
    // The model reports utterance boundaries as offsets into the audio *it was
    // sent*, and the VAD in front of us drops silence, so stream time runs
    // slower than the clock and by a varying amount. Latency measured against
    // stream time would therefore be wrong, and wrong in the flattering
    // direction. Instead we record, for each frame submitted, how much audio
    // had been sent by then and when that happened; an utterance's end offset
    // is then looked up to find the moment it was actually spoken.
    //
    // Offsets are per connection, which is why the ledger lives here.
    var submittedMs: Double = 0.0
    var streamClock: [(streamMs: Double, wallClock: Double)] = []
    /// How much audio had been sent when the server last said anything.
    /// The gap between this and `submittedMs` is what the watchdog reads.
    var submittedMsAtLastMessage: Double = 0.0
    /// ~10 minutes of 100 ms frames. Bounded so a long call cannot grow this
    /// without limit; older entries can be dropped because an utterance is
    /// reported within seconds of being spoken.
    static let streamClockCapacity: Int = 6000

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func record(pcm: Data, sampleRate: Int32, capturedAt: Double) {
        guard sampleRate > 0 else {
            return
        }
        // 16-bit mono: two bytes per sample.
        self.submittedMs += Double(pcm.count) / 2.0 / Double(sampleRate) * 1000.0
        self.streamClock.append((streamMs: self.submittedMs, wallClock: capturedAt))
        if self.streamClock.count > SGModulateSocket.streamClockCapacity {
            self.streamClock.removeFirst(self.streamClock.count - SGModulateSocket.streamClockCapacity)
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

    func cancel() {
        self.task.cancel(with: .goingAway, reason: nil)
        self.session.invalidateAndCancel()
    }
}

/// One live recognition session. Lives for as long as translation is on.
///
/// The socket is *not* the session. Modulate closes a connection after any
/// error, URLSession fails one that has sat idle, and our own idle timer ends
/// one gracefully after a long silence. Each of those drops the socket only;
/// the next audio frame opens a fresh one. Before this distinction existed a
/// dead socket was kept and written into for the rest of the call, which is
/// what made translation "stop working after a while" until it was toggled
/// off and on again.
public final class SGModulateSTTSession {
    public var onUtterance: ((SGModulateUtterance) -> Void)?
    /// Interim text for speech still in progress. Only fires when
    /// `SGModulateSTTConfig.partialResults` is on.
    public var onPartialUtterance: ((SGModulatePartialUtterance) -> Void)?
    public var onError: ((SGModulateSTTError) -> Void)?
    /// Fired once the stream has fully drained and the socket is closed.
    public var onFinished: (() -> Void)?
    /// Every JSON message as received, for the harness. Not used by the app.
    public var onRawMessage: ((String) -> Void)?

    /// The socket audio is currently written to.
    private var live: SGModulateSocket?
    /// A socket we have sent end-of-stream to and are still reading, so its
    /// final utterance is not lost. Audio no longer goes here.
    private var ending: SGModulateSocket?
    private var isStarted: Bool = false
    private var isDraining: Bool = false
    private var isFinished: Bool = false
    private var sampleRate: Int32 = 0
    private var channels: Int = 1
    /// Hint passed to the model; nil means "detect".
    private let languageHint: String?
    /// Ends the live socket after `idleTimeout` without audio.
    private var idleTimer: SwiftSignalKit.Timer?
    /// How many sockets this session has opened. Exposed for the harness.
    public private(set) var connectionCount: Int = 0

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
            guard let self = self, self.isStarted, !self.isFinished, !self.isDraining else {
                return
            }
            if self.live == nil {
                self.sampleRate = sampleRate
                self.connect()
            }
            guard let socket = self.live else {
                return
            }
            socket.record(pcm: pcm, sampleRate: sampleRate, capturedAt: capturedAt)
            if socket.submittedMs - socket.submittedMsAtLastMessage > SGModulateSTTConfig.unansweredAudioLimitMs {
                // Watchdog. A socket that URLSession has timed out dies
                // silently — sends still report success and the receive never
                // fails (reproduced in the harness) — and the idle timer never
                // fires while audio keeps flowing, so this is the only thing
                // that would notice. Let the old socket flush what it may
                // still hold and carry on with a fresh one.
                self.endGracefully(socket)
                self.connect()
                guard let fresh = self.live else {
                    return
                }
                fresh.record(pcm: pcm, sampleRate: sampleRate, capturedAt: capturedAt)
                self.send(pcm, on: fresh)
                return
            }
            self.send(pcm, on: socket)
        }
    }

    private func send(_ pcm: Data, on socket: SGModulateSocket) {
        socket.task.send(.data(pcm)) { [weak self] error in
            guard error != nil else {
                return
            }
            sgModulateQueue.async {
                self?.socketFailed(socket)
            }
        }
        self.rearmIdleTimer()
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
            self.idleTimer?.invalidate()
            self.idleTimer = nil
            guard let socket = self.live else {
                // Nothing in flight; nothing to drain.
                self.teardown()
                return
            }
            self.isDraining = true
            self.sendEndOfStream(socket)
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
        self.idleTimer?.invalidate()
        self.idleTimer = nil
        self.live?.cancel()
        self.live = nil
        self.ending?.cancel()
        self.ending = nil
        self.onFinished?()
    }

    // MARK: Socket lifecycle

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
        // Kept well clear of our own idle timer and watchdog. When this fires
        // on a websocket the task dies *silently* — sends keep succeeding and
        // the receive never fails — so it is not a safety net, it is the
        // failure mode the timer and watchdog exist to pre-empt.
        configuration.timeoutIntervalForRequest = SGModulateSTTConfig.idleTimeout * 4.0
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        let socket = SGModulateSocket(task: task, session: session)
        self.live = socket
        self.connectionCount += 1
        task.resume()

        self.receiveNext(socket)
    }

    /// Whether messages from `socket` are still wanted.
    private func isCurrent(_ socket: SGModulateSocket) -> Bool {
        return self.live === socket || self.ending === socket
    }

    /// Forget `socket`, whichever role it holds. A later frame reconnects.
    /// Sockets already forgotten are ignored, so a late failure from an old
    /// one cannot kill its successor.
    private func closeSocket(_ socket: SGModulateSocket) {
        guard self.isCurrent(socket) else {
            return
        }
        if self.live === socket {
            self.live = nil
            self.idleTimer?.invalidate()
            self.idleTimer = nil
        }
        if self.ending === socket {
            self.ending = nil
        }
        socket.cancel()
    }

    private func socketFailed(_ socket: SGModulateSocket) {
        guard self.isCurrent(socket), !self.isFinished else {
            return
        }
        let wasLive = self.live === socket
        self.closeSocket(socket)
        if wasLive && !self.isDraining {
            // Transient as far as the caller is concerned: the next frame
            // opens a fresh socket. Reported so it can be logged.
            self.onError?(.network)
        }
    }

    private func sendEndOfStream(_ socket: SGModulateSocket) {
        // The protocol ends a stream with an empty text frame.
        socket.task.send(.string("")) { _ in }
    }

    /// The idle timer ends a socket that has carried no audio for a while.
    ///
    /// The speech gate sends nothing while the other party talks, and neither
    /// side of the protocol sends keepalives, so a listener's socket would
    /// otherwise sit until something fails it. Ending it ourselves lets the
    /// server flush anything it still holds; the next word opens a new one,
    /// which costs a connection round-trip rather than a lost utterance.
    private func rearmIdleTimer() {
        self.idleTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: SGModulateSTTConfig.idleTimeout, repeat: false, completion: { [weak self] in
            self?.idleExpired()
        }, queue: sgModulateQueue)
        self.idleTimer = timer
        timer.start()
    }

    private func idleExpired() {
        guard let socket = self.live, !self.isDraining, !self.isFinished else {
            return
        }
        self.idleTimer = nil
        self.endGracefully(socket)
    }

    /// Stop writing to `socket` but keep reading it: send end-of-stream so the
    /// server flushes whatever it still holds, then drop it on "done" or, if
    /// that never comes, after the drain timeout. Audio spoken from now on
    /// goes to a new socket.
    private func endGracefully(_ socket: SGModulateSocket) {
        guard self.live === socket else {
            return
        }
        self.idleTimer?.invalidate()
        self.idleTimer = nil
        self.ending?.cancel()
        self.ending = socket
        self.live = nil
        self.sendEndOfStream(socket)
        sgModulateQueue.after(SGModulateSTTConfig.drainTimeout) { [weak self] in
            self?.closeSocket(socket)
        }
    }

    private func receiveNext(_ socket: SGModulateSocket) {
        socket.task.receive { [weak self] result in
            sgModulateQueue.async {
                guard let self = self, !self.isFinished, self.isCurrent(socket) else {
                    // Finished, or a message from a socket we already dropped.
                    return
                }
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text):
                        self.handle(text: text, from: socket)
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handle(text: text, from: socket)
                        }
                    @unknown default:
                        break
                    }
                    if self.isCurrent(socket) {
                        self.receiveNext(socket)
                    }
                case .failure:
                    self.socketFailed(socket)
                }
            }
        }
    }

    private func handle(text: String, from socket: SGModulateSocket) {
        socket.submittedMsAtLastMessage = socket.submittedMs
        self.onRawMessage?(text)
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
            if let spokenAt = socket.wallClock(forStreamMs: Double(startMs + durationMs)) {
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
            // The server closes the connection after an error, so the socket
            // is gone either way; dropping it now means the next frame
            // reconnects instead of being written into a closing socket.
            if self.live === socket {
                self.onError?(.api(object["error"] as? String ?? object["message"] as? String))
            }
            self.closeSocket(socket)
        case "done":
            // The model has flushed everything it had.
            if self.isDraining && self.live === socket {
                self.teardown()
            } else {
                // A stream we ended for idleness; the session lives on.
                self.closeSocket(socket)
            }
        case "partial_utterance":
            guard let payload = object["partial_utterance"] as? [String: Any] else {
                return
            }
            let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return
            }
            self.onPartialUtterance?(SGModulatePartialUtterance(
                text: text,
                startMs: payload["start_ms"] as? Int,
                speaker: sgModulateStringValue(payload["speaker"])
            ))
        default:
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
