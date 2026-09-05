import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import SGSimpleSettings
import SGModulateSTT
import SGOpenAILunaTranslate

// MARK: Swiftgram
//
// Orchestrates live translation for one call.
//
// Microphone audio -> speech gate -> streaming recogniser -> translator ->
// a chat message per utterance, and a rolling subtitle strip burned into the
// outgoing video.
//
// Deliberately knows nothing about tgcalls or the call UI: audio is pushed in
// through appendAudio, subtitles come out through onSubtitlesChanged. That
// keeps this testable without a call and keeps the UI free of pipeline detail.

public struct SGCallTranslationUtterance {
    public let transcription: String
    public let translation: String?
    public let detectedProperties: String

    public init(transcription: String, translation: String?, detectedProperties: String) {
        self.transcription = transcription
        self.translation = translation
        self.detectedProperties = detectedProperties
    }
}

/// One entry in the in-call language picker.
public struct SGCallLanguage {
    public let code: String
    public let title: String

    public init(code: String, title: String) {
        self.code = code
        self.title = title
    }

    /// Names the language in the *user's* locale, so someone whose phone is in
    /// English sees "Portuguese" rather than "português".
    public static func displayName(for code: String) -> String {
        if let name = Locale.current.localizedString(forIdentifier: code), !name.isEmpty {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code
    }

    static let commonCodes: [String] = [
        "en", "es", "pt", "fr", "de", "it", "nl", "pl", "tr", "ru", "uk",
        "ar", "hi", "id", "ja", "ko", "zh", "vi", "th", "sv", "da", "no", "fi"
    ]
}

public enum SGCallTranslationConfig {
    /// How many translated utterances are shown as subtitles at once.
    public static let subtitleLineCount: Int = 4

    /// Utterances kept as translation context. Matches the translator's window.
    public static let contextUtteranceCount: Int = 20
}

public final class SGCallTranslationSession {
    /// The most recent translations, oldest first, for the subtitle overlay.
    public var onSubtitlesChanged: (([String]) -> Void)?
    /// Raised when something goes wrong badly enough that the UI should show it.
    public var onError: ((String) -> Void)?

    private let account: Account
    private let peerId: PeerId
    private let queue: Queue

    private var frontEnd: SGModulateAudioFrontEnd?
    private var sttSession: SGModulateSTTSession?

    private var isEnabled: Bool = false
    private var targetLanguage: String?

    /// Ordered transcript of the call, used as translation context.
    private var previousUtterances: [String] = []
    /// Translations complete out of order; this republishes them in the order
    /// they were spoken.
    private var sequencer = SGSubtitleSequencer(windowSize: SGCallTranslationConfig.subtitleLineCount)
    private var disposables: [String: Disposable] = [:]

    public init(account: Account, peerId: PeerId) {
        self.account = account
        self.peerId = peerId
        self.queue = Queue(name: "SGCallTranslation", qos: .userInitiated)
    }

    deinit {
        for (_, disposable) in self.disposables {
            disposable.dispose()
        }
    }

    /// Whether the feature can be offered for this contact at all.
    ///
    /// Only asks whether the services are configured. It deliberately does NOT
    /// require a target language: requiring one deadlocked the feature, because
    /// the button was the surface you would set the language from, so a contact
    /// with no language set could never get one and the button never appeared.
    /// With no language known the button is shown, tapping it opens the menu,
    /// and you pick a language there.
    public static func isAvailable(accountPeerId: PeerId, peerId: PeerId) -> Bool {
        let _ = accountPeerId
        let _ = peerId
        return isSGModulateSTTConfigured && isOpenAILunaTranslateConfigured
    }

    /// True when two language tags name the same language, comparing primary
    /// subtags only. Re-exported so the call UI does not have to depend on the
    /// translator module just to tick the selected row.
    public static func languagesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        return sgLanguagesMatch(lhs, rhs)
    }

    /// Languages offered in the in-call menu.
    ///
    /// The contact's own language is pinned to the top when it is known, since
    /// it is the reason the feature exists; the rest are the widely spoken
    /// languages the recogniser and translator both handle well.
    public static func offeredLanguages(preferred: String?) -> [SGCallLanguage] {
        var result: [SGCallLanguage] = []
        if let preferred = preferred, !preferred.isEmpty {
            result.append(SGCallLanguage(code: preferred, title: SGCallLanguage.displayName(for: preferred)))
        }
        for code in SGCallLanguage.commonCodes {
            if result.contains(where: { sgLanguagesMatch($0.code, code) }) {
                continue
            }
            result.append(SGCallLanguage(code: code, title: SGCallLanguage.displayName(for: code)))
        }
        return result
    }

    public func setEnabled(_ enabled: Bool, targetLanguage: String?) {
        self.queue.async {
            if enabled == self.isEnabled && targetLanguage == self.targetLanguage {
                return
            }
            self.targetLanguage = targetLanguage
            if enabled {
                self.startImpl()
            } else {
                self.stopImpl()
            }
            self.isEnabled = enabled
        }
    }

    /// Push microphone audio. Called on the realtime audio thread — this must
    /// stay a copy-and-enqueue, which is exactly what the front-end does.
    public func appendAudio(samples: UnsafePointer<Int16>, sampleCount: Int, channels: Int, sampleRate: Int32) {
        self.frontEnd?.append(samples: samples, sampleCount: sampleCount, channels: channels, sampleRate: sampleRate)
    }

    // MARK: Private

    private func startImpl() {
        guard isSGModulateSTTConfigured else {
            self.onError?("Transcription is not configured.")
            return
        }
        guard self.targetLanguage != nil else {
            self.onError?("No target language is set for this contact.")
            return
        }

        let session = SGModulateSTTSession(languageHint: nil)
        session.onUtterance = { [weak self] utterance in
            self?.queue.async {
                self?.handle(utterance: utterance)
            }
        }
        session.onError = { [weak self] error in
            self?.queue.async {
                switch error {
                case .notConfigured:
                    self?.onError?("Transcription is not configured.")
                case let .api(message):
                    self?.onError?(message ?? "Transcription failed.")
                case .network, .handshake:
                    // Transient. The next utterance opens a fresh socket, so
                    // there is nothing useful to tell the user mid-call.
                    break
                }
            }
        }
        session.start()

        let frontEnd = SGModulateAudioFrontEnd()
        frontEnd.onFrame = { [weak session] data, rate in
            session?.append(pcm: data, sampleRate: rate)
        }

        self.sttSession = session
        self.frontEnd = frontEnd
    }

    private func stopImpl() {
        self.frontEnd?.finish()
        self.frontEnd = nil
        // finish() drains: the last thing the speaker said still arrives, and
        // handle(utterance:) will publish it before the socket closes.
        self.sttSession?.finish()
        self.sttSession = nil

        // Cancel translations still in flight. Without this they land after the
        // user has switched translation off and push subtitles back onto the
        // outgoing video — and burn tokens for output nobody will see.
        for (_, disposable) in self.disposables {
            disposable.dispose()
        }
        self.disposables.removeAll()

        self.sequencer.reset()
        self.previousUtterances.removeAll()
        Queue.mainQueue().async { [weak self] in
            self?.onSubtitlesChanged?([])
        }
    }

    private func handle(utterance: SGModulateUtterance) {
        let targetLanguage: String = self.targetLanguage ?? ""
        guard !targetLanguage.isEmpty else {
            return
        }

        self.previousUtterances.append(utterance.text)
        if self.previousUtterances.count > SGCallTranslationConfig.contextUtteranceCount {
            self.previousUtterances.removeFirst(self.previousUtterances.count - SGCallTranslationConfig.contextUtteranceCount)
        }
        // Context for *this* utterance is what came before it, not itself.
        let context: [String] = Array(self.previousUtterances.dropLast())

        self.sequencer.enqueue(utterance.uuid)

        // An utterance already in the target language is not translated; the
        // transcription stands on its own.
        if sgLanguagesMatch(utterance.language, targetLanguage) {
            self.complete(uuid: utterance.uuid, utterance: utterance, translation: nil)
            return
        }

        let disposable = openAILunaCallTranslate(
            utterance.text,
            to: targetLanguage,
            hints: SGCallTranslationHints(language: utterance.language, accent: utterance.accent),
            previousUtterances: context
        ).start(next: { [weak self] translated in
            self?.queue.async {
                self?.complete(uuid: utterance.uuid, utterance: utterance, translation: translated)
            }
        }, error: { [weak self] _ in
            self?.queue.async {
                // Publish the transcription anyway. Losing the utterance
                // entirely because the translator hiccuped is worse than
                // showing the speaker's own words.
                self?.complete(uuid: utterance.uuid, utterance: utterance, translation: nil)
            }
        })
        self.disposables[utterance.uuid] = disposable
    }

    private func complete(uuid: String, utterance: SGModulateUtterance, translation: String?) {
        self.disposables.removeValue(forKey: uuid)?.dispose()

        self.send(utterance: utterance, translation: translation)

        // Subtitles show the target language, so an untranslated utterance
        // falls back to the speaker's own words rather than showing nothing.
        guard let published = self.sequencer.complete(uuid, text: translation ?? utterance.text) else {
            return
        }
        Queue.mainQueue().async { [weak self] in
            self?.onSubtitlesChanged?(published)
        }
    }

    private func send(utterance: SGModulateUtterance, translation: String?) {
        let text: String = SGCallTranslationSession.formatMessage(
            transcription: utterance.text,
            detectedProperties: utterance.detectedPropertiesDescription,
            translation: translation
        )
        guard !text.isEmpty else {
            return
        }
        let _ = enqueueMessages(account: self.account, peerId: self.peerId, messages: [
            .message(
                text: text,
                attributes: [],
                inlineStickers: [:],
                mediaReference: nil,
                threadId: nil,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            )
        ]).startStandalone()
    }

    /// Transcription and detected properties first, translation second, in one
    /// message per utterance.
    static func formatMessage(transcription: String, detectedProperties: String, translation: String?) -> String {
        let transcription: String = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcription.isEmpty {
            return ""
        }
        var lines: [String] = [transcription]
        if !detectedProperties.isEmpty {
            lines.append("(\(detectedProperties))")
        }
        if let translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty,
           translation != transcription {
            lines.append("")
            lines.append(translation)
        }
        return lines.joined(separator: "\n")
    }
}
