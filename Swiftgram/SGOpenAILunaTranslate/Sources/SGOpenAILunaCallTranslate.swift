import Foundation
import SwiftSignalKit
import SGOpenAITranslate
import SGOpenAICasualTranslate

// MARK: Swiftgram
//
// Live call translation on gpt-5.6-luna.
//
// Kept separate from openAILunaTranslate because the two jobs differ in ways
// that matter to the prompt: speech has no punctuation to lean on, comes with
// recogniser metadata worth passing along as hints, and its "conversation
// history" is the running transcript of the call rather than a chat thread.
// Sharing one function would mean one prompt hedging between both.

/// Speech signals from the recogniser, passed to the model as hints.
public struct SGCallTranslationHints {
    /// Detected language of the utterance, as reported by the recogniser.
    public let language: String?
    /// Detected accent, where the recogniser had an opinion.
    public let accent: String?

    public init(language: String?, accent: String?) {
        self.language = language
        self.accent = accent
    }
}

public enum SGOpenAILunaCallTranslateConfig {
    /// The running transcript given to the model as context.
    public static let contextUtteranceCount: Int = 20

    public static let systemPrompt: String = """
    You translate live speech during a phone call into %@. The text you receive \
    is the output of a speech recogniser, so it may lack punctuation, contain \
    disfluencies, or mis-hear a word. Translate what the speaker plainly meant. \
    Keep the speaker's register: casual speech stays casual, formal speech stays \
    formal. Preserve names, numbers and units exactly. Do not answer, explain, \
    summarise, or add anything — return only the translation. If the text is too \
    garbled to translate, return it unchanged.
    """

    public static let hintsInstruction: String = """
    The recogniser reported the following about this utterance. Treat it as a \
    hint that may be wrong, not as fact: prefer the evidence of the words \
    themselves where the two disagree.
    """

    public static let contextInstruction: String = """
    Earlier utterances from this same call follow, oldest first. Use them only \
    to resolve pronouns, referents, names and continuing topics. Do not \
    translate them again and do not let them change what the current utterance \
    says.
    """
}

/// Its own session rather than URLSession.shared: shared carries a global cache
/// and cookie store, which has no business touching bearer-authenticated API
/// traffic. The timeout is short because a translation that arrives after the
/// speaker has moved on is worse than no translation.
private let sgOpenAILunaCallSession: URLSession = {
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = 20.0
    configuration.timeoutIntervalForResource = 30.0
    return URLSession(configuration: configuration)
}()

/// Translate one utterance from a call.
///
/// Returns the transcription unchanged, without a network round trip, when the
/// detected language already matches the target — there is nothing to translate
/// and a call is the wrong place to spend a second proving it.
public func openAILunaCallTranslate(
    _ text: String,
    to targetLanguage: String,
    hints: SGCallTranslationHints,
    previousUtterances: [String] = []
) -> Signal<String, OpenAILunaTranslateError> {
    if SGOpenAITranslateCredentials.key.isEmpty {
        return .fail(.notConfigured)
    }
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return .single(text)
    }
    if sgLanguagesMatch(hints.language, targetLanguage) {
        return .single(text)
    }
    guard let url: URL = URL(string: SGOpenAILunaTranslateConfig.endpoint) else {
        return .fail(.notConfigured)
    }

    var messages: [[String: Any]] = [
        ["role": "system", "content": String(format: SGOpenAILunaCallTranslateConfig.systemPrompt, targetLanguage)]
    ]

    var hintParts: [String] = []
    if let language = hints.language, !language.isEmpty {
        hintParts.append("Detected language: \(language)")
    }
    if let accent = hints.accent, !accent.isEmpty {
        hintParts.append("Detected accent: \(accent)")
    }
    if !hintParts.isEmpty {
        messages.append([
            "role": "system",
            "content": SGOpenAILunaCallTranslateConfig.hintsInstruction + "\n" + hintParts.joined(separator: "\n")
        ])
    }

    let window: [String] = previousUtterances.suffix(SGOpenAILunaCallTranslateConfig.contextUtteranceCount)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if !window.isEmpty {
        messages.append([
            "role": "system",
            "content": SGOpenAILunaCallTranslateConfig.contextInstruction + "\n" + window.joined(separator: "\n")
        ])
    }

    messages.append(["role": "user", "content": trimmed])

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

        let task: URLSessionDataTask = sgOpenAILunaCallSession.dataTask(with: request, completionHandler: { data, response, _ in
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

            let result: String = sgStripModelQuoting(content, original: trimmed)
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

/// True when two language tags name the same language.
///
/// Compares primary subtags only, so the recogniser's "pt" satisfies a target
/// of "pt-BR". That is the right call here: the alternative is round-tripping
/// Brazilian Portuguese speech through a translator to produce Brazilian
/// Portuguese, which costs a second of latency to change nothing. Regional
/// rewriting is not what this feature is for.
public func sgLanguagesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = sgPrimarySubtag(lhs), let rhs = sgPrimarySubtag(rhs) else {
        return false
    }
    return lhs == rhs
}

private func sgPrimarySubtag(_ tag: String?) -> String? {
    guard let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
        return nil
    }
    let primary: String = tag.split(separator: "-").first.map(String.init) ?? tag
    return primary.isEmpty ? nil : primary.lowercased()
}
