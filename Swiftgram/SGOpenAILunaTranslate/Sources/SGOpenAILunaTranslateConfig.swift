import Foundation
import SGOpenAICasualTranslate

// MARK: Swiftgram
//
// Non-secret configuration for the gpt-5.6-luna provider. Committed: the API
// key stays the single secret in SGOpenAITranslate's gitignored credentials
// file and is shared by every OpenAI backend.

public enum SGOpenAILunaTranslateConfig {
    public static let endpoint: String = "https://api.openai.com/v1/chat/completions"

    /// Verified present on the account via GET /v1/models alongside
    /// gpt-5.6-sol and gpt-5.6-terra.
    public static let model: String = "gpt-5.6-luna"

    /// Deliberately the casual provider's prompts, not copies. Holding the
    /// wording identical is what makes a side-by-side against gpt-4o a test of
    /// the model rather than of two prompts that quietly drifted apart.
    public static let systemPrompt: String = SGOpenAICasualTranslateConfig.systemPrompt
    public static let contextInstruction: String = SGOpenAICasualTranslateConfig.contextInstruction

    /// 20 messages, against the casual provider's six. A wider window resolves
    /// referents further back in a thread, at the cost of more of the chat
    /// leaving the device per translation and more tokens per request.
    public static let contextMessageCount: Int = 20

    public static let maxContextMessageCharacters: Int = SGOpenAICasualTranslateConfig.maxContextMessageCharacters
}
