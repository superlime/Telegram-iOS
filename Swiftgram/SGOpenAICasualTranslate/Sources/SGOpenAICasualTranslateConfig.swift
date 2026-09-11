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
    ///
    /// Endearments are carved out of that push. Told to prefer how people
    /// really talk, the model reaches for the most colloquial local pet name,
    /// which escalates register: "amor" came back as "babe" in 3 of 10 samples,
    /// and "babe" is markedly more familiar and more flippant than the word it
    /// is standing in for. The carve-out names that failure -- same warmth,
    /// never more familiar -- rather than pinning single words, because a rule
    /// framed as literal accuracy would turn "mi vida" into "my life".
    /// Measured on gpt-5.6-luna: "babe" went from 3/10 to 0/12 with the slangy,
    /// formal and formatting cases unchanged.
    ///
    /// The second sentence fixes the opposite flattening the first one caused.
    /// Told to preserve warmth, luna put every endearment on "love" -- cariño
    /// and corazón included, which erases a distinction the speaker made.
    /// Naming the available English endearments restores it: cariño and
    /// corazón now come back as "sweetheart" 12/12, "mi cielo" as "darling",
    /// and "amor" stays "love" 12/12.
    public static let systemPrompt: String = "Translate the user's message into the language with code \"%@\". Write it the way a native speaker would actually say it in casual conversation: natural regional phrasing, everyday idiom, contractions, relaxed register. Favour how people really talk over literal accuracy, and never sound like a textbook or a formal announcement. Endearments and terms of address are the exception to that: pick an equivalent with the same warmth, and never one more familiar or flippant than the original — amor is love, not babe. Keep distinct endearments distinct rather than rendering them all the same way: cariño and corazón are not amor, and English has sweetheart, darling and honey to tell them apart. Reply with only the translation, no quotes or notes. Keep line breaks, emoji, @mentions, #hashtags, URLs and code spans exactly as they are."

    /// Appended to the system prompt ONLY when context is actually supplied, so
    /// a context-free request is byte-identical to what shipped before.
    ///
    /// Every clause here was earned: without them gpt-4o will happily translate
    /// the whole transcript, or answer the conversation instead of translating
    /// the message.
    public static let contextInstruction: String = "You may be shown recent conversation for context. It is background only: never translate it, never quote it, never reply to it. Translate only the message given under \"Message to translate\", and output only that translation. Use the context solely to pick the right pronouns, gendered agreement, referents and level of formality. Match the register of the surrounding conversation: if it is formal, use formal address forms even though your default is casual."

    /// How many preceding messages accompany a translation. Six is enough to
    /// carry a back-and-forth - who is being addressed, what "it" refers to,
    /// whether the register is formal - without turning every translation into
    /// a bulk upload of the chat.
    public static let contextMessageCount: Int = 6

    /// Per-message clip, so one long pasted message cannot crowd out the rest of
    /// the window or the message actually being translated.
    public static let maxContextMessageCharacters: Int = 300
}
