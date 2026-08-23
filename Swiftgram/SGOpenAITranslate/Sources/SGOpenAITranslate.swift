import Foundation
import SwiftSignalKit

// MARK: Swiftgram
//
// OpenAI chat-completions translation backend.
//
// Unlike the other services this one is a general model behind a prompt, not a
// translation API, so two things differ:
//
//  * Each message is its own request. The model could be asked to translate a
//    batch in one call, but that means trusting it to return exactly N items in
//    order, and a single malformed reply would corrupt a whole chat. One request
//    per message is more expensive and more correct.
//  * The reply is post-processed. Models like to wrap output in quotes or add a
//    preamble even when told not to, so the obvious cases are stripped.
//
// The request body is deliberately minimal — model and messages only. Newer
// reasoning-capable models reject `temperature` and renamed `max_tokens`, and
// omitting both keeps this compatible with whatever `model` is configured.

public enum OpenAITranslateError {
    case notConfigured
    case network
    case api(Int, String?)
}

public var isOpenAITranslateConfigured: Bool {
    return !SGOpenAITranslateCredentials.key.isEmpty
}

private let sgOpenAITranslateSession: URLSession = {
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = 60.0
    configuration.timeoutIntervalForResource = 120.0
    return URLSession(configuration: configuration)
}()

// MARK: Swiftgram
// Shared by both OpenAI backends (chat-completions and realtime): a general
// model wraps its output in quotes even when told not to, so strip one added
// pair. Exported rather than duplicated so the two backends cannot drift.
public func sgStripModelQuoting(_ raw: String, original: String) -> String {
    var text: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Strip a single pair of wrapping quotes the model added itself. Only when
    // the original was not itself quoted, so genuinely quoted messages survive.
    let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{00AB}", "\u{00BB}")]
    let originalTrimmed: String = original.trimmingCharacters(in: .whitespacesAndNewlines)
    for (open, close) in pairs {
        if text.count >= 2, text.hasPrefix(String(open)), text.hasSuffix(String(close)),
           !(originalTrimmed.hasPrefix(String(open)) && originalTrimmed.hasSuffix(String(close))) {
            text = String(text.dropFirst().dropLast())
            break
        }
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: Swiftgram
// Shared by the chat-completions OpenAI backends: pulls OpenAI's own
// `error.message` out of a failure body so a misconfigured model is
// self-diagnosing in the comparison screen. Exported rather than duplicated.
public func sgParseOpenAIErrorMessage(_ data: Data?) -> String? {
    guard let data: Data = data else {
        return nil
    }
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return nil
    }
    guard let error = object["error"] as? [String: Any] else {
        return nil
    }
    guard let message = error["message"] as? String else {
        return nil
    }
    // These come back long enough to overflow a table cell.
    if message.count > 160 {
        return String(message.prefix(160)) + "..."
    }
    return message
}

public func openAITranslate(_ text: String, _ toLang: String) -> Signal<String, OpenAITranslateError> {
    if SGOpenAITranslateCredentials.key.isEmpty {
        return .fail(.notConfigured)
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .single(text)
    }
    guard let url: URL = URL(string: SGOpenAITranslateCredentials.endpoint) else {
        return .fail(.notConfigured)
    }

    let systemPrompt: String = String(format: SGOpenAITranslateCredentials.systemPrompt, toLang)
    let body: [String: Any] = [
        "model": SGOpenAITranslateCredentials.model,
        "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": text]
        ]
    ]
    guard let bodyData: Data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
        return .fail(.network)
    }

    return Signal { subscriber in
        let completed: Atomic<Bool> = Atomic(value: false)
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(SGOpenAITranslateCredentials.key)", forHTTPHeaderField: "Authorization")

        let task: URLSessionDataTask = sgOpenAITranslateSession.dataTask(with: request, completionHandler: { data, response, _ in
            let _ = completed.swap(true)

            guard let response: HTTPURLResponse = response as? HTTPURLResponse else {
                subscriber.putError(.network)
                return
            }
            guard response.statusCode == 200 else {
                subscriber.putError(.api(response.statusCode, sgParseOpenAIErrorMessage(data)))
                return
            }
            guard let data: Data = data,
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                subscriber.putError(.network)
                return
            }

            let result: String = sgStripModelQuoting(content, original: text)
            if result.isEmpty {
                subscriber.putError(.network)
            } else {
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
        })
        task.resume()

        return ActionDisposable {
            if !completed.with({ $0 }) {
                task.cancel()
            }
        }
    }
}

public func openAITranslateBatch(_ texts: [String], _ toLang: String) -> Signal<[String], OpenAITranslateError> {
    if texts.isEmpty {
        return .single([])
    }
    let signals: [Signal<String, OpenAITranslateError>] = texts.map { text in
        return openAITranslate(text, toLang)
    }
    return combineLatest(signals)
}
