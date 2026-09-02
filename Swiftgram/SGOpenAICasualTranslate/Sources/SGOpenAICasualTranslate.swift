import Foundation
import SwiftSignalKit
import SGOpenAITranslate

// MARK: Swiftgram
//
// A second chat-completions OpenAI backend, identical in mechanism to
// SGOpenAITranslate but pointed at gpt-4o and driven by a different prompt.
//
// The two exist side by side because they are answering different questions.
// The `openai` backend optimises for fidelity — it is told to preserve the
// original and not editorialise. This one optimises for how a native speaker
// would actually phrase the message in conversation: regional idiom, casual
// register, contractions. On a chat app that is often the better translation
// and sometimes a worse one, which is exactly why both are selectable and why
// the comparison screen shows them together.
//
// Everything else is a deliberate copy of SGOpenAITranslate — one request per
// message, the same minimal request body, the same error surfacing. The two
// shared helpers (`sgStripModelQuoting`, `sgParseOpenAIErrorMessage`) are
// imported from that module rather than duplicated, so the backends cannot
// drift apart in how they clean output or report failures.

public enum OpenAICasualTranslateError {
    case notConfigured
    case network
    case api(Int, String?)
}

public var isOpenAICasualTranslateConfigured: Bool {
    return !SGOpenAITranslateCredentials.key.isEmpty
}

private let sgOpenAICasualTranslateSession: URLSession = {
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = 60.0
    configuration.timeoutIntervalForResource = 120.0
    return URLSession(configuration: configuration)
}()

// MARK: Swiftgram
// One preceding message, as handed to the model for context.
//
// `sender` is a short label ("You", a first name), never a full contact record:
// the model needs it to get gendered agreement and formality (tu/vous, du/Sie)
// right, and a first name is enough for that. Callers build these; this module
// only formats them.
public struct SGCasualTranslateContextMessage {
    public let sender: String?
    public let text: String

    public init(sender: String?, text: String) {
        self.sender = sender
        self.text = text
    }
}

/// Renders the context window as a short labelled transcript. Each line is
/// clipped so one long message cannot dominate the request.
///
/// Public because every chat-completions provider that takes context formats it
/// the same way; duplicating this is how the providers would drift.
public func sgFormatTranslationContext(_ context: [SGCasualTranslateContextMessage], maxCharacters: Int) -> String? {
    var lines: [String] = []
    for entry in context {
        var line: String = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            continue
        }
        if line.count > maxCharacters {
            line = String(line.prefix(maxCharacters)) + "..."
        }
        // Newlines inside a quoted message would break the one-line-per-turn
        // shape the model is being shown, so flatten them.
        line = line.replacingOccurrences(of: "\n", with: " ")
        if let sender = entry.sender, !sender.isEmpty {
            lines.append("\(sender): \(line)")
        } else {
            lines.append(line)
        }
    }
    if lines.isEmpty {
        return nil
    }
    return lines.joined(separator: "\n")
}

public func openAICasualTranslate(_ text: String, _ toLang: String, context: [SGCasualTranslateContextMessage] = []) -> Signal<String, OpenAICasualTranslateError> {
    if SGOpenAITranslateCredentials.key.isEmpty {
        return .fail(.notConfigured)
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .single(text)
    }
    guard let url: URL = URL(string: SGOpenAICasualTranslateConfig.endpoint) else {
        return .fail(.notConfigured)
    }

    // With no context this builds byte-identical requests to before, so the
    // context-free callers (the comparison screen, the batch path) are
    // unaffected by this feature.
    var systemPrompt: String = String(format: SGOpenAICasualTranslateConfig.systemPrompt, toLang)
    var messages: [[String: Any]] = []
    if let transcript = sgFormatTranslationContext(context, maxCharacters: SGOpenAICasualTranslateConfig.maxContextMessageCharacters) {
        systemPrompt += " " + SGOpenAICasualTranslateConfig.contextInstruction
        messages.append(["role": "system", "content": systemPrompt])
        messages.append(["role": "user", "content": "Recent conversation, for context only:\n" + transcript])
        messages.append(["role": "user", "content": "Message to translate:\n" + text])
    } else {
        messages.append(["role": "system", "content": systemPrompt])
        messages.append(["role": "user", "content": text])
    }

    let body: [String: Any] = [
        "model": SGOpenAICasualTranslateConfig.model,
        "messages": messages
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

        let task: URLSessionDataTask = sgOpenAICasualTranslateSession.dataTask(with: request, completionHandler: { data, response, _ in
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

public func openAICasualTranslateBatch(_ texts: [String], _ toLang: String) -> Signal<[String], OpenAICasualTranslateError> {
    if texts.isEmpty {
        return .single([])
    }
    let signals: [Signal<String, OpenAICasualTranslateError>] = texts.map { text in
        return openAICasualTranslate(text, toLang)
    }
    return combineLatest(signals)
}
