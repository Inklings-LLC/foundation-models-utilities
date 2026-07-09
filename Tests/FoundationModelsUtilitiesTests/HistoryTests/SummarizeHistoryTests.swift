//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
@testable import FoundationModelsUtilities
import FoundationModels
import Testing

@Suite
struct SummarizeHistoryTests {
  /// The text content of `prompt`, formed by joining its text segments. Using
  /// `joined()` (no separator) avoids the space that `textContent` inserts
  /// between segments.
  private func promptText(_ prompt: Transcript.Prompt) -> String {
    prompt.segments.compactMap { segment in
      guard case .text(let text) = segment else { return nil }
      return text.content
    }.joined()
  }

  @Test func `collapses prior entries into the surviving prompt once the threshold is exceeded`()
    async throws
  {
    let mainModel = MockModel(textResponse: "Main model response.", tokenCount: 10)
    let summarizer = MockModel(textResponse: "User asked about several topics.", tokenCount: 10)
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {}
        .summarizeHistory(entryThreshold: 2, model: summarizer)
        .FoundationModelsUtilities::model(mainModel)
    )

    let _ = try await session.respond(to: "First topic.")
    let _ = try await session.respond(to: "Second topic.")
    let _ = try await session.respond(to: "Third topic.")

    // Summarization drops all prior entries and replaces them with a single
    // prompt: the summary (under its header, followed by the default postamble)
    // immediately followed by the most recent user prompt.
    let prompts = session.transcript.compactMap(\.prompt)
    #expect(
      prompts.map(promptText) == [
        """
        Summary of the conversation so far:
        User asked about several topics.

        Do not begin with phrases like "Based on the context", "Based on the \
        facts", "Based on the summary", or any reference to a summary or the \
        facts provided. Treat the summary and facts above as things you \
        naturally remember.

        Third topic.
        """
      ]
    )
  }

  @Test func `uses a custom postamble when provided`() async throws {
    let mainModel = MockModel(textResponse: "Main model response.", tokenCount: 10)
    let summarizer = MockModel(
      textResponse: "This is a mock summary of what's discussed so far.",
      tokenCount: 10
    )
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {}
        .summarizeHistory(
          entryThreshold: 2,
          model: summarizer,
          summaryPostamble: "Continue the conversation naturally."
        )
        .FoundationModelsUtilities::model(mainModel)
    )

    let _ = try await session.respond(to: "First topic.")
    let _ = try await session.respond(to: "Second topic.")
    let _ = try await session.respond(to: "Third topic.")

    let prompts = session.transcript.compactMap(\.prompt)
    #expect(
      prompts.map(promptText) == [
        """
        Summary of the conversation so far:
        This is a mock summary of what's discussed so far.

        Continue the conversation naturally.

        Third topic.
        """
      ]
    )
  }

  @Test func `omits the postamble when given an empty string`() async throws {
    let mainModel = MockModel(textResponse: "Main model response.", tokenCount: 10)
    let summarizer = MockModel(
      textResponse: "This is a mock summary of what's discussed so far.",
      tokenCount: 10
    )
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {}
        .summarizeHistory(entryThreshold: 2, model: summarizer, summaryPostamble: "")
        .FoundationModelsUtilities::model(mainModel)
    )

    let _ = try await session.respond(to: "First topic.")
    let _ = try await session.respond(to: "Second topic.")
    let _ = try await session.respond(to: "Third topic.")

    // With an empty postamble, neither the postamble nor its blank-line
    // separator is added: just the summary block followed by the most recent
    // prompt.
    let prompts = session.transcript.compactMap(\.prompt)
    #expect(
      prompts.map(promptText) == [
        """
        Summary of the conversation so far:
        This is a mock summary of what's discussed so far.

        Third topic.
        """
      ]
    )
  }

  @Test func `preserves transcript when under threshold`() async throws {
    let mainModel = MockModel(
      textResponse: "This is a response with many tokens.",
      tokenCount: 10
    )
    let summarizer = MockModel(
      textResponse: "Summary of conversation so far.",
      tokenCount: 10
    )
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {}
        .summarizeHistory(entryThreshold: 10, model: summarizer)
        .FoundationModelsUtilities::model(mainModel)
    )

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")

    // Threshold is very high, transcript should not be compressed: both
    // prompts survive verbatim with no summary spliced in.
    let prompts = session.transcript.compactMap(\.prompt)
    #expect(prompts.map(promptText) == ["first", "second"])
  }

  @Test func `only summarizes on prompts, not on tool-output continuations`() async throws {
    let summarizer = MockModel(textResponse: "Summary of conversation so far.", tokenCount: 10)
    // The main model calls a tool on its first turn, then responds with text
    // once the tool output comes back.
    let mainModel = MockModel(
      events: [
        .toolCall(name: "activate_skill", arguments: #"{"skill":"echo"}"#),
        .text("Main model response.")
      ],
      tokenCount: 10
    )
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {
        Skills(activations: SkillActivations()) {
          Skill(name: "echo", description: "Echoes input", prompt: "echoed")
        }
      }
      .summarizeHistory(entryThreshold: 2, model: summarizer)
      .FoundationModelsUtilities::model(mainModel)
    )

    let _ = try await session.respond(to: "first")

    // The single respond produces: prompt -> tool call -> tool output ->
    // response. By the time summarization's hook runs on the tool-output
    // continuation, the history count (3) already exceeds the threshold (2),
    // but the most recent entry is a tool output rather than a prompt. Because
    // summarization only acts when the last entry is a prompt, it is skipped:
    // the original prompt and the tool call/output pair all survive instead of
    // being collapsed into a summary.
    let prompts = session.transcript.compactMap(\.prompt)
    #expect(prompts.map(promptText) == ["first"])
    #expect(session.transcript.compactMap(\.toolCalls).count == 1)
    #expect(session.transcript.compactMap(\.toolOutput).count == 1)
  }
}
