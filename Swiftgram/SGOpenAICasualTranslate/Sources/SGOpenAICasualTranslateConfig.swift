import Foundation

// MARK: Swiftgram
//
// Non-secret configuration for the casual/gpt-4o backend. Committed, unlike
// SGOpenAITranslateCredentials: the API key stays the single secret in that
// one gitignored file and is shared by every OpenAI backend, so filling it in
// once configures all of them.

public enum SGOpenAICasualTranslateConfig {
    public static let endpoint: String = "https://api.openai.com/v1/chat/completions"

    public static let model: String = "gpt-4o"

    /// `%@` is replaced with the target language code.
    ///
    /// Deliberately short. The two formatting sentences are not padding: without
    /// them the model strips @mentions and mangles URLs, which breaks messages
    /// rather than merely restyling them. Everything else is pushed toward
    /// register rather than literal accuracy, which is the whole point of this
    /// backend existing next to the fidelity-focused `openai` one.
    public static let systemPrompt: String = "Translate the user's message into the language with code \"%@\". Write it the way a native speaker would actually say it in casual conversation: natural regional phrasing, everyday idiom, contractions, relaxed register. Favour how people really talk over literal accuracy, and never sound like a textbook or a formal announcement. Reply with only the translation, no quotes or notes. Keep line breaks, emoji, @mentions, #hashtags, URLs and code spans exactly as they are."
}
