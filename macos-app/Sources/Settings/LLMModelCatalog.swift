import Foundation

/// A small curated list of OpenRouter model slugs surfaced as Picker options
/// in Settings → Post-Processing. The catalog is split into two groups so the
/// Picker can render them under section headers:
///
/// * **`toneAware`** – the top picks when the post-processing prompt depends on
///   nuance, emotional tone, and instruction following (notes, sentiment,
///   per-type insights). Ranked roughly by tone fidelity, highest first.
/// * **`fastAndCheap`** – smaller / cheaper models for high-volume runs where
///   tone-perfect output is not required. Multilingual coverage prioritised.
///
/// Anything not in either group is still reachable via the `custom` sentinel
/// (the user types the raw slug into a text field). The worker accepts any
/// valid OpenRouter slug via `LLM_MODEL`, so exotic choices keep working.
struct LLMModelOption: Identifiable, Hashable, Sendable {
    let slug: String                 // empty string == `.custom`
    let displayName: String
    let blurb: String

    var id: String { slug.isEmpty ? "__custom__" : slug }
    var isCustom: Bool { slug.isEmpty }
}

enum LLMModelCatalog {
    /// Default slug used the first time the app launches and as the fallback
    /// when a persisted slug is invalid. Matches the worker's default.
    static let defaultSlug = "google/gemini-2.5-flash"

    /// Top 5 models when the prompt depends on tone / nuance / emotional
    /// reasoning. Best first.
    static let toneAware: [LLMModelOption] = [
        .init(slug: "anthropic/claude-sonnet-4",
              displayName: "Claude Sonnet 4",
              blurb: "Best instruction-following + nuanced tone (recommended)"),
        .init(slug: "anthropic/claude-opus-4",
              displayName: "Claude Opus 4",
              blurb: "Deepest reasoning + most expressive emotional read"),
        .init(slug: "openai/gpt-4o",
              displayName: "GPT-4o",
              blurb: "Strong tone, multimodal background"),
        .init(slug: "google/gemini-2.5-pro",
              displayName: "Gemini 2.5 Pro",
              blurb: "Strongest multilingual tone (great for non-English calls)"),
        .init(slug: "anthropic/claude-3.5-sonnet",
              displayName: "Claude 3.5 Sonnet",
              blurb: "Previous Anthropic gen — still strong, cheaper than 4"),
    ]

    /// Cheaper / faster picks where tone-perfect output isn't required.
    static let fastAndCheap: [LLMModelOption] = [
        .init(slug: "google/gemini-2.5-flash",
              displayName: "Gemini 2.5 Flash",
              blurb: "Default. Fast, cheap, ~20× cheaper than Sonnet"),
        .init(slug: "anthropic/claude-3.5-haiku",
              displayName: "Claude 3.5 Haiku",
              blurb: "Anthropic's fast/cheap option"),
        .init(slug: "openai/gpt-4o-mini",
              displayName: "GPT-4o-mini",
              blurb: "OpenAI small model"),
        .init(slug: "qwen/qwen-2.5-72b-instruct",
              displayName: "Qwen 2.5 72B",
              blurb: "Open-weights, strong multilingual"),
        .init(slug: "deepseek/deepseek-chat",
              displayName: "DeepSeek Chat",
              blurb: "Strong reasoner, weaker on Cyrillic"),
    ]

    /// Custom-slug escape hatch — shown after both groups.
    static let custom = LLMModelOption(
        slug: "", displayName: "Custom slug…",
        blurb: "Enter any OpenRouter model id"
    )

    /// All options, flat, in the order they appear in the Picker.
    static var all: [LLMModelOption] { toneAware + fastAndCheap + [custom] }

    /// Curated alias used by older callers / tests.
    static var curated: [LLMModelOption] { all }

    /// The catalog option matching `slug`, falling back to the custom sentinel
    /// when the slug isn't curated (so persisted exotic slugs round-trip cleanly).
    static func option(for slug: String) -> LLMModelOption {
        all.first(where: { $0.slug == slug }) ?? custom
    }
}
