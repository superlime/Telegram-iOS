import Foundation

// MARK: Swiftgram
//
// Non-secret configuration for the realtime backend. Unlike the credentials
// file in SGOpenAITranslate this one is committed: it holds no key. The key
// itself is read from SGOpenAITranslateCredentials, so a build is configured
// for both OpenAI backends by filling in that one file.

public enum SGOpenAIRealtimeTranslateConfig {
    /// GA realtime endpoint. The model is a query parameter, not a body field.
    public static let endpoint: String = "wss://api.openai.com/v1/realtime"

    public static let model: String = "gpt-realtime-2"

    /// Items are never removable from a realtime conversation, so context grows
    /// for the life of the connection. Capping items per socket bounds both the
    /// token cost and the chance of one message bleeding into the next; longer
    /// batches are split across parallel connections.
    public static let maxMessagesPerConnection: Int = 16

    /// Watchdog, rearmed on every event received. A realtime turn takes well
    /// under a second in practice, so this only fires on a stalled socket.
    public static let idleTimeout: Double = 30.0

    /// `%@` is replaced with the target language code. The independence clause
    /// matters here and not in the chat-completions backend: every message in a
    /// batch shares one conversation, and without it the model starts treating
    /// earlier turns as context to continue rather than text to translate.
    public static let instructions: String = "You are a translation engine. Translate each user message into the language with code \"%@\". Reply with the translation and nothing else: no quotes, no notes, no explanation, no romanisation. Preserve the original line breaks, emoji, @mentions, #hashtags, URLs and code spans exactly. If the message is already in the target language, repeat it unchanged. Each user message is an independent document: translate it on its own and never merge it with, or refer to, an earlier message in this conversation."
}
