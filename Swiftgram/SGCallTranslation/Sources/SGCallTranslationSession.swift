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
    /// Raised for recoverable hiccups, for logging only.
    public var onTransientError: ((String) -> Void)?

    private let account: Account
    private let peerId: PeerId
    private let queue: Queue

    private var frontEnd: SGModulateAudioFrontEnd?
    private var sttSession: SGModulateSTTSession?
    /// Read on the audio thread, so audio is not copied and queued while the
    /// feature is off. Everything else in here belongs to `queue`.
    private let acceptsAudio = Atomic<Bool>(value: false)

    private var isEnabled: Bool = false
    private var targetLanguage: String?
    /// The language the person holding the phone reads, used when the speaker
    /// is already speaking the configured target.
    private var userLanguage: String?

    /// Messages posted but not yet completed with a translation, oldest first.
    private var messages: [String: SGCallTranslationMessage] = [:]
    private var messageOrder: [String] = []
    /// Enough to cover any translation still in flight several times over,
    /// without letting a long call accumulate these forever.
    private static let retainedMessageCount: Int = 40

    /// Ordered transcript of the call, used as translation context.
    private var previousUtterances: [String] = []
    /// One line per utterance: partial transcript, then final, then translation.
    private var strip = SGSubtitleStrip(windowSize: SGCallTranslationConfig.subtitleLineCount)
    private var disposables: [String: Disposable] = [:]

    /// Speech the recogniser is still working on. Keyed by the segment's
    /// start offset, which is the only handle a partial carries — there is no
    /// uuid until the utterance is final, and the final carries the same
    /// start offset, which is how the two are joined up.
    private struct Provisional {
        let key: String
        var startMs: Int?
        var text: String
        var speakerNumber: Int?
        /// Posted once the partial has enough words to be worth a message.
        var message: SGCallTranslationMessage?
        var lastChatEditAt: Double = 0.0
        var chatEditScheduled: Bool = false
    }
    private var provisionals: [Provisional] = []
    /// Chat edits are rate-limited by Telegram, and partials arrive several
    /// times a second. The strip is local and updates on every one.
    private static let chatEditInterval: Double = 2.5
    /// A partial shorter than this is not worth a chat message yet: the first
    /// few arrive as single letters.
    private static let minimumPartialLengthForChat: Int = 12

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

    /// The language to translate this utterance into, or nil to leave it alone.
    ///
    /// Normally that is the configured target. When the speaker is *already*
    /// speaking the target language, translating to it would be a no-op, so we
    /// turn the translation around and put it into the language the phone's
    /// owner reads instead — which is the case where someone else in the room
    /// answers in the target language and the owner is the one who needs help.
    ///
    /// Returns nil only when there is nowhere useful to go: no known language
    /// for the reader, or the reader already reads what was said.
    public static func resolveTranslationTarget(detected: String?, target: String, userLanguage: String?) -> String? {
        if !sgLanguagesMatch(detected, target) {
            return target
        }
        guard let userLanguage = userLanguage, !userLanguage.isEmpty else {
            return nil
        }
        if sgLanguagesMatch(detected, userLanguage) {
            return nil
        }
        return userLanguage
    }

    public func setEnabled(_ enabled: Bool, targetLanguage: String?, userLanguage: String?) {
        self.queue.async {
            if enabled == self.isEnabled && targetLanguage == self.targetLanguage && userLanguage == self.userLanguage {
                return
            }
            self.targetLanguage = targetLanguage
            self.userLanguage = userLanguage
            if enabled {
                self.startImpl()
            } else {
                self.stopImpl()
            }
            self.isEnabled = enabled
        }
    }

    /// Push microphone audio. Called on the realtime audio thread, under the
    /// audio device's own lock and ahead of the buffer reaching WebRTC.
    ///
    /// This must stay a copy-and-enqueue. The gate, downmix and framing run on
    /// the session queue, which is also where `stopImpl` tears the front end
    /// down — so the front end is only ever touched from one queue. It used
    /// to be driven from here directly, racing `finish()` on the queue.
    public func appendAudio(samples: UnsafePointer<Int16>, sampleCount: Int, channels: Int, sampleRate: Int32) {
        guard sampleCount > 0, channels > 0, self.acceptsAudio.with({ $0 }) else {
            return
        }
        let data = Data(bytes: samples, count: sampleCount * channels * MemoryLayout<Int16>.size)
        self.queue.async { [weak self] in
            guard let self = self, let frontEnd = self.frontEnd else {
                return
            }
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: Int16.self).baseAddress else {
                    return
                }
                frontEnd.append(samples: base, sampleCount: sampleCount, channels: channels, sampleRate: sampleRate)
            }
        }
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
        session.onPartialUtterance = { [weak self] partial in
            self?.queue.async {
                self?.handle(partial: partial)
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
                    // Transient: the recogniser drops the socket and the next
                    // frame opens a fresh one, so there is nothing to tell the
                    // user mid-call. Worth a log line, though.
                    self?.onTransientError?("Transcription socket dropped; reconnecting on next speech.")
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
        let _ = self.acceptsAudio.swap(true)
    }

    private func stopImpl() {
        let _ = self.acceptsAudio.swap(false)
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

        // Stop chasing edits for messages whose translation will now never
        // arrive. The posted transcripts stay: they are a record of what was
        // actually said, and deleting them because the user toggled the feature
        // off would be worse than leaving them untranslated.
        for (_, message) in self.messages {
            message.cancel()
        }
        self.messages.removeAll()
        self.messageOrder.removeAll()
        for provisional in self.provisionals {
            provisional.message?.cancel()
        }
        self.provisionals.removeAll()

        self.strip.reset()
        self.previousUtterances.removeAll()
        Queue.mainQueue().async { [weak self] in
            self?.onSubtitlesChanged?([])
        }
    }

    // MARK: Partials

    private static func partialKey(startMs: Int?) -> String {
        return startMs.map { "partial:\($0)" } ?? "partial:pending"
    }

    /// Interim text for speech in progress: goes straight onto the strip, and
    /// into a chat message at a throttled rate. Never translated — it changes
    /// with every frame, and the translator would be paid to chase it.
    private func handle(partial: SGModulatePartialUtterance) {
        guard self.isEnabled else {
            return
        }
        let key = SGCallTranslationSession.partialKey(startMs: partial.startMs)
        var index = self.provisionals.firstIndex(where: { $0.key == key })
        if index == nil, partial.startMs != nil,
           let pendingIndex = self.provisionals.firstIndex(where: { $0.startMs == nil }) {
            // The first partial or two arrive before the server has placed
            // the segment on the clock. Now it has: adopt the offset, and
            // carry the line and message across under the new key.
            let pendingKey = self.provisionals[pendingIndex].key
            self.provisionals[pendingIndex].startMs = partial.startMs
            let renamed = Provisional(
                key: key,
                startMs: partial.startMs,
                text: self.provisionals[pendingIndex].text,
                speakerNumber: self.provisionals[pendingIndex].speakerNumber,
                message: self.provisionals[pendingIndex].message,
                lastChatEditAt: self.provisionals[pendingIndex].lastChatEditAt,
                chatEditScheduled: self.provisionals[pendingIndex].chatEditScheduled
            )
            self.provisionals[pendingIndex] = renamed
            let _ = self.strip.removePartial(key: pendingKey)
            index = pendingIndex
        }
        if index == nil {
            self.provisionals.append(Provisional(key: key, startMs: partial.startMs, text: partial.text, speakerNumber: partial.speakerNumber))
            index = self.provisionals.count - 1
        }
        guard let i = index else {
            return
        }
        self.provisionals[i].text = partial.text
        if let speakerNumber = partial.speakerNumber {
            self.provisionals[i].speakerNumber = speakerNumber
        }

        if SGCallMessageFormatter.isLocalSpeaker(self.provisionals[i].speakerNumber) {
            if let published = self.strip.setPartial(key: key, text: partial.text) {
                self.publish(published)
            }
        }
        self.flushPartialToChat(key: key)
    }

    /// Post or edit the provisional chat message, no more often than
    /// `chatEditInterval`. A partial that arrives inside the interval is held
    /// and the newest one is sent when it expires.
    private func flushPartialToChat(key: String) {
        guard let i = self.provisionals.firstIndex(where: { $0.key == key }) else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - self.provisionals[i].lastChatEditAt
        if elapsed < SGCallTranslationSession.chatEditInterval {
            if !self.provisionals[i].chatEditScheduled {
                self.provisionals[i].chatEditScheduled = true
                self.queue.after(SGCallTranslationSession.chatEditInterval - elapsed) { [weak self] in
                    guard let self = self, let j = self.provisionals.firstIndex(where: { $0.key == key }) else {
                        return
                    }
                    self.provisionals[j].chatEditScheduled = false
                    self.flushPartialToChat(key: key)
                }
            }
            return
        }
        let body = SGCallMessageFormatter.partialBody(transcription: self.provisionals[i].text, speakerNumber: self.provisionals[i].speakerNumber)
        guard !body.isEmpty else {
            return
        }
        if let message = self.provisionals[i].message {
            message.update(text: body.text, entities: SGCallTranslationSession.messageEntities(body.entities))
        } else {
            guard self.provisionals[i].text.count >= SGCallTranslationSession.minimumPartialLengthForChat else {
                return
            }
            let message = SGCallTranslationMessage(account: self.account, peerId: self.peerId, queue: self.queue)
            message.send(text: body.text, entities: SGCallTranslationSession.messageEntities(body.entities))
            self.provisionals[i].message = message
        }
        self.provisionals[i].lastChatEditAt = now
    }

    /// Find the in-progress segment a final utterance grew out of, and retire
    /// it. Matched on start offset; the segment still waiting for one is the
    /// fallback. Anything older than the utterance is superseded — the API
    /// promises a final supersedes every partial before it — and is dropped,
    /// its stub message left to stand as whatever was heard.
    private func takeProvisional(for utterance: SGModulateUtterance) -> Provisional? {
        var matchIndex = self.provisionals.firstIndex(where: { $0.startMs == utterance.startMs })
        if matchIndex == nil {
            matchIndex = self.provisionals.firstIndex(where: { $0.startMs == nil })
        }
        let match = matchIndex.map { self.provisionals.remove(at: $0) }

        let stale = self.provisionals.filter { ($0.startMs ?? Int.max) < utterance.startMs }
        for orphan in stale {
            if let published = self.strip.removePartial(key: orphan.key) {
                self.publish(published)
            }
            // The stub's ellipsis promised more; make it read as complete.
            if let message = orphan.message {
                let body = SGCallMessageFormatter.body(
                    transcription: orphan.text,
                    detectedProperties: "",
                    speakerNumber: orphan.speakerNumber,
                    recognitionLatency: nil,
                    translation: nil,
                    translationLanguageName: nil,
                    translationLatency: nil
                )
                if !body.isEmpty {
                    message.update(text: body.text, entities: SGCallTranslationSession.messageEntities(body.entities))
                }
            }
        }
        self.provisionals.removeAll(where: { orphan in stale.contains(where: { $0.key == orphan.key }) })
        return match
    }

    // MARK: Utterances

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

        let provisional = self.takeProvisional(for: utterance)

        // Subtitles are burned into the video the other person sees, so they
        // carry only what the phone's owner said. Captioning a bystander picked
        // up through the same microphone would put words on the outgoing video
        // that the owner never spoke — and that the other party has no way to
        // attribute. Such utterances still get a chat message; they just do not
        // enter the subtitle strip.
        //
        // Diarisation is currently off (see SGModulateSTTConfig), so every
        // utterance arrives unlabelled and counts as the owner's. The gate is
        // kept so that turning it back on needs no change here.
        let isLocalSpeaker = SGCallMessageFormatter.isLocalSpeaker(utterance.speakerNumber)
        if isLocalSpeaker {
            // The final transcript takes over the partial's line — or gets a
            // line of its own if it arrived without partials — and shows
            // until the translation replaces it.
            if let published = self.strip.commit(partialKey: provisional?.key, uuid: utterance.uuid, text: utterance.text) {
                self.publish(published)
            }
        } else if let provisional = provisional {
            if let published = self.strip.removePartial(key: provisional.key) {
                self.publish(published)
            }
        }

        // Post what was said straight away. The translation is seconds behind,
        // and holding the whole message back for it left the chat lagging the
        // conversation badly enough to be useless as a live record.
        self.post(utterance: utterance, reusing: provisional?.message)

        guard let destination = SGCallTranslationSession.resolveTranslationTarget(
            detected: utterance.language,
            target: targetLanguage,
            userLanguage: self.userLanguage
        ) else {
            self.complete(uuid: utterance.uuid, utterance: utterance, translation: nil, destination: nil, translationLatency: nil)
            return
        }

        let submittedAt = CFAbsoluteTimeGetCurrent()
        let disposable = openAILunaCallTranslate(
            utterance.text,
            to: destination,
            hints: SGCallTranslationHints(language: utterance.language, accent: utterance.accent),
            previousUtterances: context
        ).start(next: { [weak self] translated in
            let latency = CFAbsoluteTimeGetCurrent() - submittedAt
            self?.queue.async {
                self?.complete(uuid: utterance.uuid, utterance: utterance, translation: translated, destination: destination, translationLatency: latency)
            }
        }, error: { [weak self] _ in
            self?.queue.async {
                // The transcript is already posted, so a failed translation
                // costs the translation only — not the utterance.
                self?.complete(uuid: utterance.uuid, utterance: utterance, translation: nil, destination: nil, translationLatency: nil)
            }
        })
        self.disposables[utterance.uuid] = disposable
    }

    /// Send the transcript-only message — or, when the partials already
    /// posted one, edit the final transcript into it — and remember it so the
    /// translation can be edited in.
    private func post(utterance: SGModulateUtterance, reusing existing: SGCallTranslationMessage?) {
        let body = SGCallMessageFormatter.body(
            transcription: utterance.text,
            detectedProperties: utterance.detectedPropertiesDescription,
            speakerNumber: utterance.speakerNumber,
            recognitionLatency: utterance.recognitionLatency,
            translation: nil,
            translationLanguageName: nil,
            translationLatency: nil
        )
        guard !body.isEmpty else {
            return
        }
        let message: SGCallTranslationMessage
        if let existing = existing {
            message = existing
            message.update(text: body.text, entities: SGCallTranslationSession.messageEntities(body.entities))
        } else {
            message = SGCallTranslationMessage(account: self.account, peerId: self.peerId, queue: self.queue)
            message.send(text: body.text, entities: SGCallTranslationSession.messageEntities(body.entities))
        }
        self.messages[utterance.uuid] = message
        self.messageOrder.append(utterance.uuid)
        self.evictOldMessages()
    }

    /// Drop references to messages old enough that any edit has long since
    /// settled. Cancels nothing — these have already been posted.
    private func evictOldMessages() {
        while self.messageOrder.count > SGCallTranslationSession.retainedMessageCount {
            let uuid = self.messageOrder.removeFirst()
            self.messages.removeValue(forKey: uuid)
        }
    }

    private func complete(
        uuid: String,
        utterance: SGModulateUtterance,
        translation: String?,
        destination: String?,
        translationLatency: Double?
    ) {
        self.disposables.removeValue(forKey: uuid)?.dispose()

        // Edit the translation into the message we already posted. Nothing to
        // do when there is no translation: the transcript stands on its own,
        // and rewriting it with identical text would only mark it edited.
        if let translation = translation, !translation.isEmpty, let message = self.messages[uuid] {
            let body = SGCallMessageFormatter.body(
                transcription: utterance.text,
                detectedProperties: utterance.detectedPropertiesDescription,
                speakerNumber: utterance.speakerNumber,
                recognitionLatency: utterance.recognitionLatency,
                translation: translation,
                translationLanguageName: destination.map { SGCallLanguage.displayName(for: $0) },
                translationLatency: translationLatency
            )
            if !body.isEmpty {
                message.update(text: body.text, entities: SGCallTranslationSession.messageEntities(body.entities))
            }
        }

        guard SGCallMessageFormatter.isLocalSpeaker(utterance.speakerNumber) else {
            // Never entered the strip; nothing to update.
            return
        }
        // Subtitles show the target language, so an untranslated utterance
        // keeps the speaker's own words rather than showing nothing.
        guard let published = self.strip.translate(uuid: uuid, text: translation ?? utterance.text) else {
            return
        }
        self.publish(published)
    }

    private func publish(_ lines: [String]) {
        Queue.mainQueue().async { [weak self] in
            self?.onSubtitlesChanged?(lines)
        }
    }

    /// Bridges the formatter's transport-free entities onto Telegram's.
    static func messageEntities(_ entities: [SGCallMessageEntity]) -> [MessageTextEntity] {
        return entities.map { entity in
            switch entity.kind {
            case .bold:
                return MessageTextEntity(range: entity.range, type: .Bold)
            case .blockQuote:
                return MessageTextEntity(range: entity.range, type: .BlockQuote(isCollapsed: false))
            }
        }
    }
}
