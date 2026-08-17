import Foundation
import SwiftUI
import Display
import LegacyUI
import TelegramPresentationData
import AccountContext
import SGSwiftUI
import SGStrings
import SGSimpleSettings

#if canImport(Translation)
import Translation
#endif

// MARK: Swiftgram
// Side-by-side translation comparison screen. See SGTranslationCompare.swift for
// the model; this file is the SwiftUI presentation plus the iOS 18 system
// translator, which can only run from a SwiftUI view hierarchy.

public func sgTranslationCompareController(
    context: AccountContext,
    presentationData: PresentationData,
    text: String,
    toLang: String
) -> ViewController {
    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: presentationData.theme,
        strings: presentationData.strings
    )
    legacyController.title = i18n("Translation.Compare.Title", presentationData.strings.baseLanguageCode)

    let model = SGTranslationCompareModel(context: context, sourceText: text, toLang: toLang)

    let swiftUIView = SGSwiftUIView<SGTranslationCompareView>(
        legacyController: legacyController,
        content: {
            SGTranslationCompareView(model: model, theme: presentationData.theme)
        }
    )
    let controller = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: controller)

    return legacyController
}

struct SGTranslationCompareView: View {
    @ObservedObject var model: SGTranslationCompareModel
    let theme: PresentationTheme

    @Environment(\.lang) var lang: String

    private var backgroundColor: Color { Color(self.theme.list.blocksBackgroundColor) }
    private var cardColor: Color { Color(self.theme.list.itemBlocksBackgroundColor) }
    private var primaryColor: Color { Color(self.theme.list.itemPrimaryTextColor) }
    private var secondaryColor: Color { Color(self.theme.list.itemSecondaryTextColor) }
    private var destructiveColor: Color { Color(self.theme.list.itemDestructiveColor) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14.0) {
                Text(String(format: i18n("Translation.Compare.TargetLanguage", self.lang), self.model.toLang))
                    .font(.footnote)
                    .foregroundColor(self.secondaryColor)
                    .padding(.horizontal, 4.0)

                self.card(
                    title: i18n("Translation.Compare.Original", self.lang),
                    detail: nil,
                    body: Text(self.model.sourceText).foregroundColor(self.primaryColor)
                )

                ForEach(self.model.entries.indices, id: \.self) { index in
                    self.entryCard(self.model.entries[index])
                }
            }
            .padding(16.0)
        }
        .background(self.backgroundColor.edgesIgnoringSafeArea(.all))
        .onAppear {
            self.model.start()
        }
        .sgSystemTranslation(model: self.model)
    }

    private func entryCard(_ entry: SGTranslationCompareEntry) -> some View {
        let name = i18n("Settings.Translation.Backend.\(entry.backend.rawValue)", self.lang)
        switch entry.state {
        case .pending:
            return AnyView(self.card(
                title: name,
                detail: nil,
                body: Text(i18n("Translation.Compare.Pending", self.lang)).foregroundColor(self.secondaryColor)
            ))
        case let .success(text, milliseconds):
            return AnyView(self.card(
                title: name,
                detail: "\(milliseconds) ms",
                body: Text(text).foregroundColor(self.primaryColor)
            ))
        case let .failure(reason, milliseconds):
            return AnyView(self.card(
                title: name,
                detail: "\(milliseconds) ms",
                body: Text(reason).foregroundColor(self.destructiveColor)
            ))
        case let .skipped(reason):
            return AnyView(self.card(
                title: name,
                detail: nil,
                body: Text(reason).foregroundColor(self.secondaryColor)
            ))
        }
    }

    private func card(title: String, detail: String?, body: Text) -> some View {
        VStack(alignment: .leading, spacing: 6.0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(self.primaryColor)
                Spacer()
                if let detail = detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(self.secondaryColor)
                }
            }
            body
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12.0)
        .background(RoundedRectangle(cornerRadius: 10.0).fill(self.cardColor))
    }
}

// MARK: - iOS 18 system translator
//
// Apple's Translation framework has no headless entry point: a TranslationSession
// is only vended to a SwiftUI view through `.translationTask`. So the system row
// is driven from here and handed back to the model, rather than started in
// `SGTranslationCompareModel.start()` alongside the network services.

extension View {
    @ViewBuilder
    func sgSystemTranslation(model: SGTranslationCompareModel) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *), model.needsSystemTranslation {
            self.modifier(SGSystemTranslationModifier(model: model))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct SGSystemTranslationModifier: ViewModifier {
    let model: SGTranslationCompareModel

    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(self.configuration) { session in
                let started = CFAbsoluteTimeGetCurrent()
                let sourceText = self.model.sourceText
                do {
                    let response = try await session.translate(sourceText)
                    let elapsed = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000.0).rounded())
                    let translated = response.targetText
                    await MainActor.run {
                        self.model.applySystemSuccess(text: translated, milliseconds: elapsed)
                    }
                } catch {
                    let elapsed = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000.0).rounded())
                    let reason = error.localizedDescription
                    await MainActor.run {
                        self.model.applySystemFailure(reason: reason, milliseconds: elapsed)
                    }
                }
            }
            .onAppear {
                if self.configuration == nil {
                    // A nil source lets the framework detect the input language,
                    // matching how the other services are called.
                    self.configuration = TranslationSession.Configuration(
                        source: nil,
                        target: Locale.Language(identifier: self.model.toLang)
                    )
                }
            }
    }
}
#endif
