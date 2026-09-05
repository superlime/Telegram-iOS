import Foundation

// MARK: Swiftgram
/// Builds the chat message for one utterance.
///
/// Pure Foundation on purpose: no Postbox, no TelegramCore. The layout and the
/// entity offsets are the part most likely to be wrong, and keeping this free
/// of the messaging stack means it can be exercised directly instead of by
/// making a call and squinting at the result.

public enum SGCallMessageEntityKind: Equatable {
    case bold
    case blockQuote
}

/// A styled range. Offsets are UTF-16 code units, which is what Telegram's
/// entity ranges are counted in — using Character offsets would misplace every
/// entity after an emoji or a combining mark.
public struct SGCallMessageEntity: Equatable {
    public let range: Range<Int>
    public let kind: SGCallMessageEntityKind

    public init(range: Range<Int>, kind: SGCallMessageEntityKind) {
        self.range = range
        self.kind = kind
    }
}

public struct SGCallMessageBody: Equatable {
    public let text: String
    public let entities: [SGCallMessageEntity]

    public init(text: String, entities: [SGCallMessageEntity]) {
        self.text = text
        self.entities = entities
    }

    public var isEmpty: Bool {
        return self.text.isEmpty
    }
}

public enum SGCallMessageFormatter {
    /// The speaker the local microphone hears first is the person holding the
    /// phone. Anyone else on this tap is someone in the room with them.
    public static let localSpeakerNumber: Int = 1

    /// Whether this utterance came from the person holding the phone.
    ///
    /// A nil label means diarisation had no opinion, which is treated as the
    /// local speaker: with a microphone tap that is overwhelmingly the likely
    /// answer, and the alternative would caption the user's own speech as a
    /// stranger's.
    public static func isLocalSpeaker(_ speakerNumber: Int?) -> Bool {
        guard let speakerNumber = speakerNumber else {
            return true
        }
        return speakerNumber == self.localSpeakerNumber
    }

    /// - Parameters:
    ///   - speakerNumber: nil when diarisation said nothing, which is treated
    ///     as the local speaker rather than as an unknown third party.
    ///   - translationLanguageName: the language actually translated *into*,
    ///     which is not always the configured target — see the session's
    ///     same-language handling.
    public static func body(
        transcription: String,
        detectedProperties: String,
        speakerNumber: Int?,
        recognitionLatency: Double?,
        translation: String?,
        translationLanguageName: String?,
        translationLatency: Double?
    ) -> SGCallMessageBody {
        let transcription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcription.isEmpty {
            return SGCallMessageBody(text: "", entities: [])
        }

        let isRemoteSpeaker = !self.isLocalSpeaker(speakerNumber)

        var lines: [String] = []
        var headerLength: Int = 0

        if isRemoteSpeaker, let speakerNumber = speakerNumber {
            let header = "Speaker \(speakerNumber)"
            headerLength = header.utf16.count
            lines.append(header)
        }

        lines.append(transcription)

        if let meta = self.metaLine(properties: detectedProperties, latency: recognitionLatency, verb: "transcribed") {
            lines.append(meta)
        }

        if let translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty,
           translation != transcription {
            lines.append("")
            lines.append(translation)
            if let meta = self.metaLine(properties: translationLanguageName ?? "", latency: translationLatency, verb: "translated") {
                lines.append(meta)
            }
        }

        let text = lines.joined(separator: "\n")

        var entities: [SGCallMessageEntity] = []
        if isRemoteSpeaker {
            if headerLength > 0 {
                entities.append(SGCallMessageEntity(range: 0 ..< headerLength, kind: .bold))
            }
            // Quoting the whole body is how a message gets a visually distinct
            // background: Telegram renders a blockquote with its own tint and
            // an accent bar, and per-message bubble colours are not something
            // a sender can set.
            entities.append(SGCallMessageEntity(range: 0 ..< text.utf16.count, kind: .blockQuote))
        }

        return SGCallMessageBody(text: text, entities: entities)
    }

    /// "(en, accent: British · transcribed in 1.2s)", dropping whichever half
    /// is missing, and the whole line when both are.
    static func metaLine(properties: String, latency: Double?, verb: String) -> String? {
        var parts: [String] = []
        let properties = properties.trimmingCharacters(in: .whitespacesAndNewlines)
        if !properties.isEmpty {
            parts.append(properties)
        }
        if let latency = latency, latency.isFinite, latency >= 0.0 {
            parts.append("\(verb) in \(self.formatSeconds(latency))")
        }
        if parts.isEmpty {
            return nil
        }
        return "(" + parts.joined(separator: " · ") + ")"
    }

    /// Sub-second precision matters here — the difference between 0.4s and 0.9s
    /// is the difference between usable and not — but a third decimal would be
    /// noise given the measurement is bounded by 100 ms audio frames.
    static func formatSeconds(_ value: Double) -> String {
        return String(format: "%.1fs", value)
    }
}
