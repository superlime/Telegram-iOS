import Foundation
import Combine
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGSimpleSettings
import SGGTranslate
import SGAzureTranslate
import SGOpenAITranslate
import SGOpenAIRealtimeTranslate
import SGOpenAICasualTranslate
import SGOpenAILunaTranslate

// MARK: Swiftgram
//
// Runs one piece of text through every available translation service at once so
// the results can be compared side by side.
//
// This exists because the normal translation path falls back to GTranslate when
// the selected service errors, which makes a misconfigured backend look like a
// working one. Here each service is called directly and reports its own outcome,
// so a failure reads as a failure.
//
// The three network services are plain Signals driven from `start()`. The iOS 18
// system translator has no headless API — it is driven by the SwiftUI layer (see
// SGTranslationCompareScreen) and pushed back in through `applySystem*`.

public struct SGTranslationCompareEntry {
    public enum State {
        case pending
        case success(text: String, milliseconds: Int)
        case failure(reason: String, milliseconds: Int)
        case skipped(reason: String)
    }

    public let backend: SGSimpleSettings.TranslationBackend
    public var state: State
}

private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
    return Int(((CFAbsoluteTimeGetCurrent() - start) * 1000.0).rounded())
}

public final class SGTranslationCompareModel: ObservableObject {
    @Published public private(set) var entries: [SGTranslationCompareEntry]

    public let sourceText: String
    public let toLang: String

    private let context: AccountContext
    private var disposables: [Disposable] = []
    private var didStart: Bool = false

    public init(context: AccountContext, sourceText: String, toLang: String) {
        self.context = context
        self.sourceText = sourceText
        self.toLang = toLang

        var initialEntries: [SGTranslationCompareEntry] = []
        for backend in SGSimpleSettings.TranslationBackend.allCases {
            var state: SGTranslationCompareEntry.State = .pending
            switch backend {
            case .azure:
                if !isAzureTranslateConfigured {
                    state = .skipped(reason: "no Azure key in this build")
                }
            case .openai:
                if !isOpenAITranslateConfigured {
                    state = .skipped(reason: "no OpenAI key in this build")
                }
            case .openaiRealtime:
                if !isOpenAIRealtimeTranslateConfigured {
                    state = .skipped(reason: "no OpenAI key in this build")
                }
            case .openaiCasual:
                if !isOpenAICasualTranslateConfigured {
                    state = .skipped(reason: "no OpenAI key in this build")
                }
            case .openaiLuna:
                if !isOpenAILunaTranslateConfigured {
                    state = .skipped(reason: "no OpenAI key in this build")
                }
            case .system:
                if #available(iOS 18.0, *) {
                } else {
                    state = .skipped(reason: "requires iOS 18")
                }
            default:
                break
            }
            initialEntries.append(SGTranslationCompareEntry(backend: backend, state: state))
        }
        self.entries = initialEntries
    }

    deinit {
        for disposable in self.disposables {
            disposable.dispose()
        }
    }

    /// True when the SwiftUI layer should drive the iOS 18 system translator.
    public var needsSystemTranslation: Bool {
        guard let index = self.index(of: .system) else {
            return false
        }
        if case .pending = self.entries[index].state {
            return true
        }
        return false
    }

    public func start() {
        if self.didStart {
            return
        }
        self.didStart = true

        for index in self.entries.indices {
            guard case .pending = self.entries[index].state else {
                continue
            }
            switch self.entries[index].backend {
            case .default:
                self.startTelegram(index: index)
            case .gtranslate:
                self.startGTranslate(index: index)
            case .azure:
                self.startAzure(index: index)
            case .openai:
                self.startOpenAI(index: index)
            case .openaiRealtime:
                self.startOpenAIRealtime(index: index)
            case .openaiCasual:
                self.startOpenAICasual(index: index)
            case .openaiLuna:
                self.startOpenAILuna(index: index)
            case .system:
                break // driven by the SwiftUI layer
            }
        }
    }

    public func applySystemSuccess(text: String, milliseconds: Int) {
        guard let index = self.index(of: .system) else {
            return
        }
        self.update(index, .success(text: text, milliseconds: milliseconds))
    }

    public func applySystemFailure(reason: String, milliseconds: Int) {
        guard let index = self.index(of: .system) else {
            return
        }
        self.update(index, .failure(reason: reason, milliseconds: milliseconds))
    }

    private func index(of backend: SGSimpleSettings.TranslationBackend) -> Int? {
        return self.entries.firstIndex(where: { $0.backend == backend })
    }

    private func update(_ index: Int, _ state: SGTranslationCompareEntry.State) {
        if index < self.entries.count {
            self.entries[index].state = state
        }
    }

    private func startTelegram(index: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        let signal = self.context.engine.messages.translateViaTelegram(text: self.sourceText, toLang: self.toLang)
        |> deliverOnMainQueue
        let disposable = signal.start(next: { [weak self] result in
            guard let strongSelf = self else {
                return
            }
            if let text = result?.0, !text.isEmpty {
                strongSelf.update(index, .success(text: text, milliseconds: elapsedMilliseconds(since: started)))
            } else {
                strongSelf.update(index, .failure(reason: "empty response", milliseconds: elapsedMilliseconds(since: started)))
            }
        }, error: { [weak self] _ in
            self?.update(index, .failure(reason: "request failed", milliseconds: elapsedMilliseconds(since: started)))
        })
        self.disposables.append(disposable)
    }

    private func startGTranslate(index: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        let signal = gtranslate(self.sourceText, self.toLang)
        |> deliverOnMainQueue
        let disposable = signal.start(next: { [weak self] text in
            guard let strongSelf = self else {
                return
            }
            if text.isEmpty {
                strongSelf.update(index, .failure(reason: "empty response", milliseconds: elapsedMilliseconds(since: started)))
            } else {
                strongSelf.update(index, .success(text: text, milliseconds: elapsedMilliseconds(since: started)))
            }
        }, error: { [weak self] error in
            let reason: String
            switch error {
            case .network:
                reason = "network error"
            case let .api(statusCode):
                reason = statusCode == 429 ? "HTTP 429 (rate limited)" : "HTTP \(statusCode)"
            case .parseFailed:
                reason = "scrape failed (markup changed or interstitial)"
            }
            self?.update(index, .failure(reason: reason, milliseconds: elapsedMilliseconds(since: started)))
        })
        self.disposables.append(disposable)
    }

    private func startOpenAI(index: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        let signal = openAITranslate(self.sourceText, self.toLang)
        |> deliverOnMainQueue
        let disposable = signal.start(next: { [weak self] text in
            guard let strongSelf = self else {
                return
            }
            if text.isEmpty {
                strongSelf.update(index, .failure(reason: "empty response", milliseconds: elapsedMilliseconds(since: started)))
            } else {
                strongSelf.update(index, .success(text: text, milliseconds: elapsedMilliseconds(since: started)))
            }
        }, error: { [weak self] error in
            let reason: String
            switch error {
            case .notConfigured:
                reason = "no credentials in this build"
            case .network:
                reason = "network error"
            case let .api(statusCode, message):
                if let message = message {
                    reason = "HTTP \(statusCode): \(message)"
                } else {
                    reason = "HTTP \(statusCode)"
                }
            }
            self?.update(index, .failure(reason: reason, milliseconds: elapsedMilliseconds(since: started)))
        })
        self.disposables.append(disposable)
    }

    private func startOpenAILuna(index: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        let signal = openAILunaTranslate(self.sourceText, self.toLang)
        |> deliverOnMainQueue
        let disposable = signal.start(next: { [weak self] text in
            guard let strongSelf = self else {
                return
            }
            if text.isEmpty {
                strongSelf.update(index, .failure(reason: "empty response", milliseconds: elapsedMilliseconds(since: started)))
            } else {
                strongSelf.update(index, .success(text: text, milliseconds: elapsedMilliseconds(since: started)))
            }
        }, error: { [weak self] error in
            let reason: String
            switch error {
            case .notConfigured:
                reason = "no credentials in this build"
            case .network:
                reason = "network error"
            case let .api(statusCode, message):
                if let message = message {
                    reason = "HTTP \(statusCode): \(message)"
                } else {
                    reason = "HTTP \(statusCode)"
                }
            }
            self?.update(index, .failure(reason: reason, milliseconds: elapsedMilliseconds(since: started)))
        })
        self.disposables.append(disposable)
    }

    private func startOpenAICasual(index: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        let signal = openAICasualTranslate(self.sourceText, self.toLang)
        |> deliverOnMainQueue
        let disposable = signal.start(next: { [weak self] text in
            guard let strongSelf = self else {
                return
            }
            if text.isEmpty {
                strongSelf.update(index, .failure(reason: "empty response", milliseconds: elapsedMilliseconds(since: started)))
            } else {
                strongSelf.update(index, .success(text: text, milliseconds: elapsedMilliseconds(since: started)))
            }
        }, error: { [weak self] error in
            let reason: String
            switch error {
            case .notConfigured:
                reason = "no credentials in this build"
            case .network:
                reason = "network error"
            case let .api(statusCode, message):
                if let message = message {
                    reason = "HTTP \(statusCode): \(message)"
                } else {
                    reason = "HTTP \(statusCode)"
                }
            }
            self?.update(index, .failure(reason: reason, milliseconds: elapsedMilliseconds(since: started)))
        })
        self.disposables.append(disposable)
    }

    private func startOpenAIRealtime(index: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        let signal = openAIRealtimeTranslate(self.sourceText, self.toLang)
        |> deliverOnMainQueue
        let disposable = signal.start(next: { [weak self] text in
            guard let strongSelf = self else {
                return
            }
            if text.isEmpty {
                strongSelf.update(index, .failure(reason: "empty response", milliseconds: elapsedMilliseconds(since: started)))
            } else {
                strongSelf.update(index, .success(text: text, milliseconds: elapsedMilliseconds(since: started)))
            }
        }, error: { [weak self] error in
            let reason: String
            switch error {
            case .notConfigured:
                reason = "no credentials in this build"
            case .network:
                reason = "socket error"
            case let .handshake(statusCode):
                reason = "handshake failed: HTTP \(statusCode)"
            case let .api(code, message):
                // The realtime API reports string codes, not HTTP statuses.
                let parts = [code, message].compactMap({ $0 })
                reason = parts.isEmpty ? "server error" : parts.joined(separator: ": ")
            case .timeout:
                reason = "timed out"
            }
            self?.update(index, .failure(reason: reason, milliseconds: elapsedMilliseconds(since: started)))
        })
        self.disposables.append(disposable)
    }

    private func startAzure(index: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        let signal = azureTranslate(self.sourceText, self.toLang)
        |> deliverOnMainQueue
        let disposable = signal.start(next: { [weak self] text in
            guard let strongSelf = self else {
                return
            }
            if text.isEmpty {
                strongSelf.update(index, .failure(reason: "empty response", milliseconds: elapsedMilliseconds(since: started)))
            } else {
                strongSelf.update(index, .success(text: text, milliseconds: elapsedMilliseconds(since: started)))
            }
        }, error: { [weak self] error in
            let reason: String
            switch error {
            case .notConfigured:
                reason = "no credentials in this build"
            case .network:
                reason = "network error"
            case let .api(statusCode):
                reason = "HTTP \(statusCode)"
            }
            self?.update(index, .failure(reason: reason, milliseconds: elapsedMilliseconds(since: started)))
        })
        self.disposables.append(disposable)
    }
}
