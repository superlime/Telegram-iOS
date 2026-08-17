import Foundation
import SwiftSignalKit

// MARK: Swiftgram
//
// Azure AI Translator (Text translation REST API v3.0) backend.
//
// Mirrors the shape of SGGTranslate so it can be swapped in at the same call
// sites, but unlike the scraped Google endpoint this one translates a whole
// batch of texts in a single request, which is what the multi-message chat
// translation path wants.

public enum AzureTranslateError {
    case notConfigured
    case network
    case api(Int)
}

public var isAzureTranslateConfigured: Bool {
    return !SGAzureTranslateCredentials.key.isEmpty
}

private let sgAzureTranslateSession: URLSession = {
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = 30.0
    configuration.timeoutIntervalForResource = 60.0
    return URLSession(configuration: configuration)
}()

// Service limits for the translate operation: 50,000 characters and 1,000
// array elements per request. Both are kept well under the cap.
private let azureMaxCharactersPerRequest: Int = 45000
private let azureMaxElementsPerRequest: Int = 100

// MARK: - Language codes

// Azure expects BCP-47 codes and is stricter than Google about scripts: it
// wants "zh-Hans" rather than "zh-CN", and "he" rather than the legacy "iw".
private let azureScriptedLanguages: [String: String] = [
    "zh": "zh-Hans",
    "zh-hans": "zh-Hans",
    "zh-cn": "zh-Hans",
    "zh-sg": "zh-Hans",
    "zh-hant": "zh-Hant",
    "zh-tw": "zh-Hant",
    "zh-hk": "zh-Hant",
    "zh-mo": "zh-Hant",
    "sr": "sr-Cyrl",
    "sr-cyrl": "sr-Cyrl",
    "sr-latn": "sr-Latn",
    "mn": "mn-Cyrl",
    "mn-cyrl": "mn-Cyrl",
    "mn-mong": "mn-Mong",
    "iu-latn": "iu-Latn",
    "ku": "ku",
    "pt": "pt",
    "pt-br": "pt",
    "pt-pt": "pt-PT",
    "no": "nb",
    "nb": "nb",
    "nn": "nb",
    "tl": "fil",
    "fil": "fil",
    "iw": "he",
    "he": "he",
    "in": "id",
    "id": "id",
    "ji": "yi",
    "yi": "yi"
]

public func getAzureTranslateLang(_ userLang: String) -> String {
    var lang: String = userLang
    let rawSuffix: String = "-raw"
    if lang.hasSuffix(rawSuffix) {
        lang = String(lang.dropLast(rawSuffix.count))
    }
    lang = lang.replacingOccurrences(of: "_", with: "-").lowercased()

    if let mapped: String = azureScriptedLanguages[lang] {
        return mapped
    }

    let base: String = lang.components(separatedBy: "-")[0]
    if let mapped: String = azureScriptedLanguages[base] {
        return mapped
    }

    return base
}

// MARK: - Segmentation

// A text too long for one request is broken into segments that are translated
// as separate array elements and rejoined afterwards. Telegram messages cap out
// well below the service limit, so in practice every text is a single segment.
private struct AzureTextSegments {
    let segments: [String]
    let separator: String
}

private func azureSegments(for text: String) -> AzureTextSegments {
    if text.count <= azureMaxCharactersPerRequest {
        return AzureTextSegments(segments: [text], separator: "")
    }

    let lines: [String] = text.components(separatedBy: "\n")
    if lines.allSatisfy({ $0.count <= azureMaxCharactersPerRequest }) {
        return AzureTextSegments(segments: lines, separator: "\n")
    }

    var chunks: [String] = []
    var remainder: Substring = Substring(text)
    while !remainder.isEmpty {
        let end: String.Index = remainder.index(remainder.startIndex, offsetBy: azureMaxCharactersPerRequest, limitedBy: remainder.endIndex) ?? remainder.endIndex
        chunks.append(String(remainder[remainder.startIndex ..< end]))
        remainder = remainder[end...]
    }
    return AzureTextSegments(segments: chunks, separator: "")
}

// MARK: - Requests

private func azureTranslateRequest(elements: [String], toLang: String) -> Signal<[String], AzureTranslateError> {
    if elements.isEmpty {
        return .single([])
    }

    let key: String = SGAzureTranslateCredentials.key
    if key.isEmpty {
        return .fail(.notConfigured)
    }

    var components: URLComponents? = URLComponents(string: SGAzureTranslateCredentials.endpoint.hasSuffix("/") ? String(SGAzureTranslateCredentials.endpoint.dropLast()) + "/translate" : SGAzureTranslateCredentials.endpoint + "/translate")
    var queryItems: [URLQueryItem] = [
        URLQueryItem(name: "api-version", value: "3.0"),
        URLQueryItem(name: "to", value: toLang),
        URLQueryItem(name: "textType", value: "plain")
    ]
    if !SGAzureTranslateCredentials.category.isEmpty {
        queryItems.append(URLQueryItem(name: "category", value: SGAzureTranslateCredentials.category))
    }
    components?.queryItems = queryItems

    guard let url: URL = components?.url else {
        return .fail(.notConfigured)
    }

    let body: [[String: String]] = elements.map { ["text": $0] }
    guard let bodyData: Data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
        return .fail(.network)
    }

    return Signal { subscriber in
        let completed: Atomic<Bool> = Atomic(value: false)
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if !SGAzureTranslateCredentials.region.isEmpty {
            request.setValue(SGAzureTranslateCredentials.region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-ClientTraceId")

        let task: URLSessionDataTask = sgAzureTranslateSession.dataTask(with: request, completionHandler: { data, response, _ in
            let _ = completed.swap(true)

            guard let response: HTTPURLResponse = response as? HTTPURLResponse else {
                subscriber.putError(.network)
                return
            }
            guard response.statusCode == 200 else {
                subscriber.putError(.api(response.statusCode))
                return
            }
            guard let data: Data = data, let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
                subscriber.putError(.network)
                return
            }

            var results: [String] = []
            for entry in parsed {
                guard let translations = entry["translations"] as? [[String: Any]] else {
                    subscriber.putError(.network)
                    return
                }
                guard let first = translations.first, let text = first["text"] as? String else {
                    subscriber.putError(.network)
                    return
                }
                results.append(text)
            }

            guard results.count == elements.count else {
                subscriber.putError(.network)
                return
            }

            subscriber.putNext(results)
            subscriber.putCompletion()
        })
        task.resume()

        return ActionDisposable {
            if !completed.with({ $0 }) {
                task.cancel()
            }
        }
    }
}

// MARK: - Public API

public func azureTranslateBatch(_ texts: [String], _ toLang: String) -> Signal<[String], AzureTranslateError> {
    if texts.isEmpty {
        return .single([])
    }
    if SGAzureTranslateCredentials.key.isEmpty {
        return .fail(.notConfigured)
    }

    let targetLang: String = getAzureTranslateLang(toLang)

    // Flatten every text into translatable elements, remembering where each one
    // came from so the results can be stitched back together in order. Blank
    // texts are passed through untouched rather than billed to the service.
    var elements: [String] = []
    var layout: [(range: Range<Int>, separator: String)] = []
    for text in texts {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            layout.append((range: elements.count ..< elements.count, separator: ""))
            continue
        }
        let split: AzureTextSegments = azureSegments(for: text)
        let start: Int = elements.count
        elements.append(contentsOf: split.segments)
        layout.append((range: start ..< elements.count, separator: split.separator))
    }

    if elements.isEmpty {
        return .single(texts)
    }

    // Group elements into requests that respect both service limits.
    var groups: [[String]] = []
    var currentGroup: [String] = []
    var currentCharacters: Int = 0
    for element in elements {
        let elementCharacters: Int = element.count
        if !currentGroup.isEmpty && (currentGroup.count >= azureMaxElementsPerRequest || currentCharacters + elementCharacters > azureMaxCharactersPerRequest) {
            groups.append(currentGroup)
            currentGroup = []
            currentCharacters = 0
        }
        currentGroup.append(element)
        currentCharacters += elementCharacters
    }
    if !currentGroup.isEmpty {
        groups.append(currentGroup)
    }

    let requests: [Signal<[String], AzureTranslateError>] = groups.map { group in
        azureTranslateRequest(elements: group, toLang: targetLang)
    }

    return combineLatest(requests)
    |> map { groupedResults -> [String] in
        let translatedElements: [String] = groupedResults.flatMap { $0 }
        return texts.enumerated().map { index, original in
            let entry = layout[index]
            if entry.range.isEmpty {
                return original
            }
            let pieces: [String] = Array(translatedElements[entry.range])
            let joined: String = pieces.joined(separator: entry.separator)
            return joined.isEmpty ? original : joined
        }
    }
}

public func azureTranslate(_ text: String, _ toLang: String) -> Signal<String, AzureTranslateError> {
    return azureTranslateBatch([text], toLang)
    |> map { results -> String in
        return results.first ?? text
    }
}
