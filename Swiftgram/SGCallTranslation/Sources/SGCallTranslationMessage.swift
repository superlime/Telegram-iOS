import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore

// MARK: Swiftgram
/// One chat message that is posted early and completed later.
///
/// An utterance produces its transcript in about a second and its translation
/// a second or two after that. Waiting for both before posting anything makes
/// the chat lag the conversation badly, so the transcript goes out immediately
/// and the same message is edited when the translation lands.
///
/// The awkward part is that a just-sent message does not have an id the server
/// will accept an edit for. `enqueueMessages` hands back a *local* id; the
/// message only gains a cloud id once it has actually been delivered. Postbox's
/// `messageView` follows that transition for us — it tracks the message by
/// stable id, so the view updates with the cloud message when the local one is
/// replaced. We wait for that, and hold any edit that arrives first.
final class SGCallTranslationMessage {
    private let account: Account
    private let peerId: PeerId
    private let queue: Queue

    private var cloudMessageId: MessageId?
    /// A translation that arrived before the message had a cloud id.
    private var deferredEdit: (text: String, entities: [MessageTextEntity])?
    private var isCancelled: Bool = false

    private let sendDisposable = MetaDisposable()
    private let idDisposable = MetaDisposable()
    private let editDisposable = MetaDisposable()

    init(account: Account, peerId: PeerId, queue: Queue) {
        self.account = account
        self.peerId = peerId
        self.queue = queue
    }

    deinit {
        self.sendDisposable.dispose()
        self.idDisposable.dispose()
        self.editDisposable.dispose()
    }

    /// Post the message. Call once.
    func send(text: String, entities: [MessageTextEntity]) {
        var attributes: [MessageAttribute] = []
        if !entities.isEmpty {
            attributes.append(TextEntitiesMessageAttribute(entities: entities))
        }
        let signal = enqueueMessages(account: self.account, peerId: self.peerId, messages: [
            .message(
                text: text,
                attributes: attributes,
                inlineStickers: [:],
                mediaReference: nil,
                threadId: nil,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            )
        ])
        |> deliverOn(self.queue)

        self.sendDisposable.set(signal.start(next: { [weak self] ids in
            guard let self = self, !self.isCancelled else {
                return
            }
            guard let localId = ids.first.flatMap({ $0 }) else {
                return
            }
            self.awaitCloudId(localId: localId)
        }))
    }

    /// Replace the message body, now or as soon as the message is sendable.
    func update(text: String, entities: [MessageTextEntity]) {
        self.queue.async { [weak self] in
            guard let self = self, !self.isCancelled else {
                return
            }
            if let messageId = self.cloudMessageId {
                self.applyEdit(messageId: messageId, text: text, entities: entities)
            } else {
                self.deferredEdit = (text: text, entities: entities)
            }
        }
    }

    /// Abandon any in-flight work. The message already posted is left alone —
    /// deleting what the user said mid-call would be worse than leaving a
    /// transcript without its translation.
    func cancel() {
        self.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.isCancelled = true
            self.deferredEdit = nil
            self.sendDisposable.dispose()
            self.idDisposable.dispose()
            self.editDisposable.dispose()
        }
    }

    // MARK: Private

    private func awaitCloudId(localId: MessageId) {
        if localId.namespace == Namespaces.Message.Cloud {
            self.adopt(messageId: localId)
            return
        }
        let signal = self.account.postbox.messageView(localId)
        |> map { view -> MessageId? in
            guard let message = view.message else {
                return nil
            }
            return message.id.namespace == Namespaces.Message.Cloud ? message.id : nil
        }
        |> filter { $0 != nil }
        |> take(1)
        |> deliverOn(self.queue)

        self.idDisposable.set(signal.start(next: { [weak self] messageId in
            guard let self = self, let messageId = messageId, !self.isCancelled else {
                return
            }
            self.adopt(messageId: messageId)
        }))
    }

    private func adopt(messageId: MessageId) {
        self.cloudMessageId = messageId
        if let deferred = self.deferredEdit {
            self.deferredEdit = nil
            self.applyEdit(messageId: messageId, text: deferred.text, entities: deferred.entities)
        }
    }

    private func applyEdit(messageId: MessageId, text: String, entities: [MessageTextEntity]) {
        let attribute: TextEntitiesMessageAttribute? = entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: entities)
        let signal = TelegramEngine(account: self.account).messages.requestEditMessage(
            messageId: messageId,
            text: text,
            media: .keep,
            entities: attribute,
            richText: nil,
            inlineStickers: [:]
        )
        self.editDisposable.set(signal.start())
    }
}
