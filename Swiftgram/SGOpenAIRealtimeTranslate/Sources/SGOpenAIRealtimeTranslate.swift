import Foundation
import SwiftSignalKit
import SGOpenAITranslate

// MARK: Swiftgram
//
// OpenAI Realtime translation backend, over the GA WebSocket transport.
//
// This is a second OpenAI backend rather than a replacement for the
// chat-completions one: `gpt-realtime-2` is not reachable over
// /v1/chat/completions at all — the live API answers 404/400 — so the socket is
// the only way to use it.
//
// Protocol notes, all confirmed against the live endpoint rather than the docs:
//
//  * The old `OpenAI-Beta: realtime=v1` header is now rejected outright ("The
//    Realtime Beta API is no longer supported"). Authorization is the only
//    header needed.
//  * `session.update` must carry `session.type = "realtime"`, otherwise the
//    server answers "Missing required parameter: 'session.type'".
//  * Text arrives as `response.output_text.delta` events and is terminated by
//    `response.done`.
//  * Only one response may be in flight per connection: a second
//    `response.create` before `response.done` fails with
//    `conversation_already_has_active_response`. A batch is therefore
//    translated sequentially down one socket.
//  * `conversation.item.delete` does not work here (`item_delete_invalid_item_id`)
//    and desynchronises the read loop, so earlier turns cannot be pruned.
//    Measured growth is roughly 25 input tokens per message, which is cheap,
//    but the socket is still capped at `maxMessagesPerConnection` items.
//
// The socket is opened per request and closed when the batch finishes. Holding
// one open between translations would save the 1-3s handshake, but it would
// also keep an authenticated connection alive for the life of the app.

public enum OpenAIRealtimeTranslateError {
    case notConfigured
    /// The socket failed or closed before the batch finished.
    case network
    /// The HTTP upgrade was refused; carries the status code (401 for a bad key).
    case handshake(Int)
    /// An `error` event from the server, or a response that came back not-completed.
    case api(String?, String?)
    case timeout
}

public var isOpenAIRealtimeTranslateConfigured: Bool {
    return !SGOpenAITranslateCredentials.key.isEmpty
}

private let sgRealtimeQueue: Queue = Queue(name: "SGOpenAIRealtimeTranslate")

private let sgRealtimeSession: URLSession = {
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = 60.0
    configuration.timeoutIntervalForResource = 300.0
    return URLSession(configuration: configuration)
}()

private func truncatedForDisplay(_ message: String?) -> String? {
    guard let message: String = message else {
        return nil
    }
    if message.count > 160 {
        return String(message.prefix(160)) + "..."
    }
    return message
}

/// Translates a list of texts down a single realtime connection, one at a time.
/// Every method runs on `sgRealtimeQueue`; nothing here is thread-safe on its own.
private final class SGOpenAIRealtimeConnection {
    private let texts: [String]
    private let toLang: String
    private let completed: ([String]) -> Void
    private let failed: (OpenAIRealtimeTranslateError) -> Void

    private var task: URLSessionWebSocketTask?
    private var watchdog: SwiftSignalKit.Timer?

    private var results: [String] = []
    private var index: Int = 0
    private var buffer: String = ""
    private var sessionReady: Bool = false
    private var isFinished: Bool = false

    init(texts: [String], toLang: String, completed: @escaping ([String]) -> Void, failed: @escaping (OpenAIRealtimeTranslateError) -> Void) {
        self.texts = texts
        self.toLang = toLang
        self.completed = completed
        self.failed = failed
    }

    func start() {
        guard var components: URLComponents = URLComponents(string: SGOpenAIRealtimeTranslateConfig.endpoint) else {
            self.fail(.notConfigured)
            return
        }
        components.queryItems = [URLQueryItem(name: "model", value: SGOpenAIRealtimeTranslateConfig.model)]
        guard let url: URL = components.url else {
            self.fail(.notConfigured)
            return
        }

        var request: URLRequest = URLRequest(url: url)
        request.setValue("Bearer \(SGOpenAITranslateCredentials.key)", forHTTPHeaderField: "Authorization")

        let task: URLSessionWebSocketTask = sgRealtimeSession.webSocketTask(with: request)
        self.task = task
        task.resume()

        self.rearmWatchdog()
        self.receiveNext()

        let instructions: String = String(format: SGOpenAIRealtimeTranslateConfig.instructions, self.toLang)
        self.send([
            "type": "session.update",
            "session": [
                // Required since the beta was retired; omitting it is an error.
                "type": "realtime",
                "output_modalities": ["text"],
                "instructions": instructions
            ] as [String: Any]
        ])
    }

    func cancel() {
        if self.isFinished {
            return
        }
        self.isFinished = true
        self.watchdog?.invalidate()
        self.watchdog = nil
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
    }

    // MARK: - Transport

    private func receiveNext() {
        guard let task: URLSessionWebSocketTask = self.task else {
            return
        }
        task.receive(completionHandler: { [weak self] result in
            sgRealtimeQueue.async {
                guard let strongSelf = self, !strongSelf.isFinished else {
                    return
                }
                switch result {
                    case let .success(message):
                        if case let .string(text) = message {
                            strongSelf.handle(text)
                        } else if case let .data(data) = message, let text = String(data: data, encoding: .utf8) {
                            strongSelf.handle(text)
                        }
                        if !strongSelf.isFinished {
                            strongSelf.receiveNext()
                        }
                    case .failure:
                        // A refused upgrade surfaces here as a read failure, but
                        // the HTTP response is still attached to the task — that
                        // is the only place a 401 for a bad key is visible.
                        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
                            strongSelf.fail(.handshake(response.statusCode))
                        } else {
                            strongSelf.fail(.network)
                        }
                }
            }
        })
    }

    private func send(_ object: [String: Any]) {
        guard let data: Data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string: String = String(data: data, encoding: .utf8) else {
            self.fail(.network)
            return
        }
        self.task?.send(.string(string), completionHandler: { [weak self] error in
            guard error != nil else {
                return
            }
            sgRealtimeQueue.async {
                self?.fail(.network)
            }
        })
    }

    private func rearmWatchdog() {
        self.watchdog?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: SGOpenAIRealtimeTranslateConfig.idleTimeout, repeat: false, completion: { [weak self] in
            self?.fail(.timeout)
        }, queue: sgRealtimeQueue)
        self.watchdog = timer
        timer.start()
    }

    // MARK: - Protocol

    private func handle(_ raw: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: []) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }
        self.rearmWatchdog()

        switch type {
            case "session.updated":
                if !self.sessionReady {
                    self.sessionReady = true
                    self.sendNext()
                }
            case "response.output_text.delta":
                if let delta = object["delta"] as? String {
                    self.buffer += delta
                }
            case "response.done":
                self.handleResponseDone(object)
            case "error":
                let error = object["error"] as? [String: Any]
                self.fail(.api(error?["code"] as? String, truncatedForDisplay(error?["message"] as? String)))
            default:
                break
        }
    }

    private func handleResponseDone(_ object: [String: Any]) {
        let response = object["response"] as? [String: Any]
        let status: String = (response?["status"] as? String) ?? "completed"
        if status != "completed" {
            let details = response?["status_details"] as? [String: Any]
            let error = details?["error"] as? [String: Any]
            self.fail(.api(error?["code"] as? String ?? status, truncatedForDisplay(error?["message"] as? String)))
            return
        }

        // Deltas are the normal path; fall back to the assembled item in case a
        // response arrives without having streamed.
        var text: String = self.buffer
        if text.isEmpty {
            text = self.assembledText(from: response) ?? ""
        }

        guard self.index < self.texts.count else {
            self.fail(.network)
            return
        }
        let original: String = self.texts[self.index]
        let cleaned: String = sgStripModelQuoting(text, original: original)
        if cleaned.isEmpty {
            self.fail(.api("empty_response", nil))
            return
        }

        self.results.append(cleaned)
        self.index += 1
        self.sendNext()
    }

    private func assembledText(from response: [String: Any]?) -> String? {
        guard let output = response?["output"] as? [[String: Any]] else {
            return nil
        }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else {
                continue
            }
            for part in content {
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    /// Queues the next non-empty text, or finishes when the list is exhausted.
    private func sendNext() {
        while self.index < self.texts.count && self.texts[self.index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Whitespace-only input gives a general model nothing to work with
            // and invites it to invent a reply, so it never reaches the wire.
            self.results.append(self.texts[self.index])
            self.index += 1
        }
        if self.index >= self.texts.count {
            self.finish()
            return
        }

        self.buffer = ""
        self.send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": self.texts[self.index]]]
            ] as [String: Any]
        ])
        self.send(["type": "response.create"])
    }

    private func finish() {
        if self.isFinished {
            return
        }
        let results: [String] = self.results
        self.cancel()
        self.completed(results)
    }

    private func fail(_ error: OpenAIRealtimeTranslateError) {
        if self.isFinished {
            return
        }
        self.cancel()
        self.failed(error)
    }
}

private func realtimeTranslateChunk(_ texts: [String], _ toLang: String) -> Signal<[String], OpenAIRealtimeTranslateError> {
    return Signal { subscriber in
        let connection = SGOpenAIRealtimeConnection(texts: texts, toLang: toLang, completed: { results in
            subscriber.putNext(results)
            subscriber.putCompletion()
        }, failed: { error in
            subscriber.putError(error)
        })
        sgRealtimeQueue.async {
            connection.start()
        }
        return ActionDisposable {
            sgRealtimeQueue.async {
                connection.cancel()
            }
        }
    }
}

public func openAIRealtimeTranslate(_ text: String, _ toLang: String) -> Signal<String, OpenAIRealtimeTranslateError> {
    if !isOpenAIRealtimeTranslateConfigured {
        return .fail(.notConfigured)
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .single(text)
    }
    return realtimeTranslateChunk([text], toLang)
    |> mapToSignal { results -> Signal<String, OpenAIRealtimeTranslateError> in
        guard let first: String = results.first else {
            return .fail(.network)
        }
        return .single(first)
    }
}

public func openAIRealtimeTranslateBatch(_ texts: [String], _ toLang: String) -> Signal<[String], OpenAIRealtimeTranslateError> {
    if texts.isEmpty {
        return .single([])
    }
    if !isOpenAIRealtimeTranslateConfigured {
        return .fail(.notConfigured)
    }

    let limit: Int = max(1, SGOpenAIRealtimeTranslateConfig.maxMessagesPerConnection)
    if texts.count <= limit {
        return realtimeTranslateChunk(texts, toLang)
    }

    // Concurrency is forbidden *within* a connection, not across them, so long
    // batches fan out over several sockets and are stitched back in order.
    var chunks: [[String]] = []
    var offset: Int = 0
    while offset < texts.count {
        let end: Int = min(offset + limit, texts.count)
        chunks.append(Array(texts[offset ..< end]))
        offset = end
    }
    return combineLatest(chunks.map({ realtimeTranslateChunk($0, toLang) }))
    |> map { chunkResults -> [String] in
        return chunkResults.flatMap({ $0 })
    }
}
