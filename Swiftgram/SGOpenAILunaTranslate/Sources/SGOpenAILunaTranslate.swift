import Foundation
import SwiftSignalKit
import SGOpenAITranslate
import SGOpenAICasualTranslate

// MARK: Swiftgram
//
// The casual translator on gpt-5.6-luna, with a wider conversation window.
//
// This is deliberately the SAME provider as SGOpenAICasualTranslate in every
// respect except two: the model id, and a 20-message context window instead of
// six. It even shares that module's prompt constants rather than copying them,
// so a change to the casual wording applies to both. That is the point - with
// prompt and mechanism held fixed, putting the two side by side in the
// comparison screen isolates the model and the window size as the variables.
//
// Everything shared lives upstream and is imported, never duplicated: the API
// key and the two output-cleaning helpers from SGOpenAITranslate, the context
// message type and its transcript formatter from SGOpenAICasualTranslate.

public enum OpenAILunaTranslateError {
    case notConfigured
    case network
    case api(Int, String?)
}

public var isOpenAILunaTranslateConfigured: Bool {
    return !SGOpenAITranslateCredentials.key.isEmpty
}

private let sgOpenAILunaTranslateSession: URLSession = {
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = 60.0
    configuration.timeoutIntervalForResource = 120.0
    return URLSession(configuration: configuration)
}()

public func openAILunaTranslate(_ text: String, _ toLang: String, context: [SGCasualTranslateContextMessage] = []) -> Signal<String, OpenAILunaTranslateError> {
    if SGOpenAITranslateCredentials.key.isEmpty {
        return .fail(.notConfigured)
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .single(text)
    }
    guard let url: URL = URL(string: SGOpenAILunaTranslateConfig.endpoint) else {
        return .fail(.notConfigured)
    }

    // With no context this builds byte-identical requests to before, so the
    // context-free callers (the comparison screen, the batch path) are
    // unaffected by this feature.
    var systemPrompt: String = String(format: SGOpenAILunaTranslateConfig.systemPrompt, toLang)
    var messages: [[String: Any]] = []
    if let transcript = sgFormatTranslationContext(context, maxCharacters: SGOpenAILunaTranslateConfig.maxContextMessageCharacters) {
        systemPrompt += " " + SGOpenAILunaTranslateConfig.contextInstruction
        messages.append(["role": "system", "content": systemPrompt])
        messages.append(["role": "user", "content": "Recent conversation, for context only:\n" + transcript])
        messages.append(["role": "user", "content": "Message to translate:\n" + text])
    } else {
        messages.append(["role": "system", "content": systemPrompt])
        messages.append(["role": "user", "content": text])
    }

    let body: [String: Any] = [
        "model": SGOpenAILunaTranslateConfig.model,
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

        let task: URLSessionDataTask = sgOpenAILunaTranslateSession.dataTask(with: request, completionHandler: { data, response, _ in
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

public func openAILunaTranslateBatch(_ texts: [String], _ toLang: String) -> Signal<[String], OpenAILunaTranslateError> {
    if texts.isEmpty {
        return .single([])
    }
    let signals: [Signal<String, OpenAILunaTranslateError>] = texts.map { text in
        return openAILunaTranslate(text, toLang)
    }
    return combineLatest(signals)
}
