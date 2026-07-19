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
struct RollingWindowTests {
  @Test func `preserves entries when under limit`() async throws {
    let model = MockModel(textResponse: "OK", tokenCount: 1)
    let session = LanguageModelSession(profile: WindowedProfile(windowSize: 10).model(model))

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")

    // Window is larger than the transcript, so nothing is trimmed.
    #expect(
      session.transcriptSummary == [
        .instructions,
        .prompt("first"),
        .response("OK"),
        .prompt("second"),
        .response("OK")
      ]
    )
  }

  @Test func `trims to the most recent entries`() async throws {
    let model = MockModel(textResponse: "OK", tokenCount: 1)
    let session = LanguageModelSession(profile: WindowedProfile(windowSize: 3).model(model))

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")
    let _ = try await session.respond(to: "third")

    // On the third prompt the history exceeds the window of 3 and is trimmed to
    // its most recent entries, dropping the first prompt/response pair. The
    // window lands on a prompt boundary, so the surviving transcript stays
    // well-formed.
    #expect(
      session.transcriptSummary == [
        .instructions,
        .prompt("second"),
        .response("OK"),
        .prompt("third"),
        .response("OK")
      ]
    )
  }

  @Test
  func `keeps a complete newest turn when the raw suffix would orphan a response`() async throws {
    let model = MockModel(textResponse: "OK", tokenCount: 1)
    let session = LanguageModelSession(profile: WindowedProfile(windowSize: 2).model(model))

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")
    let _ = try await session.respond(to: "third")
    let _ = try await session.respond(to: "fourth")

    // The rolling ceiling admits only complete turns. A raw suffix(2) would
    // retain the prior response plus the current prompt at the fourth onPrompt
    // hook, creating an orphaned response. Instead that old turn is removed as
    // a unit and the current prompt/response pair stays valid.
    #expect(
      session.transcriptSummary == [
        .instructions,
        .prompt("fourth"),
        .response("OK")
      ]
    )
  }

  @Test
  func `whole-turn suffix keeps a complete tool loop or removes it as a unit`() {
    let first = prompt("first")
    let toolCall = toolCalls()
    let toolResult = toolOutput()
    let answer = response("done")
    let current = prompt("second")
    let history = [first, toolCall, toolResult, answer, current]

    #expect(
      wholeTurnSuffix(of: history, preferredMaximumEntries: 5) == history
    )
    #expect(
      wholeTurnSuffix(of: history, preferredMaximumEntries: 4) == [current]
    )
  }

  @Test
  func `current tool continuation is indivisible even above the preferred ceiling`() {
    let currentTurn = [
      prompt("look this up"),
      response("one moment"),
      toolCalls(),
      toolOutput()
    ]

    #expect(
      wholeTurnSuffix(of: currentTurn, preferredMaximumEntries: 1) == currentTurn
    )
  }

  private func prompt(_ text: String) -> Transcript.Entry {
    .prompt(Transcript.Prompt(
      segments: [.text(Transcript.TextSegment(content: text))]
    ))
  }

  private func response(_ text: String) -> Transcript.Entry {
    .response(Transcript.Response(
      assetIDs: [],
      segments: [.text(Transcript.TextSegment(content: text))]
    ))
  }

  private func toolCalls() -> Transcript.Entry {
    .toolCalls(Transcript.ToolCalls(
      [Transcript.ToolCall(
        id: "call-1",
        toolName: "probe",
        arguments: GeneratedContent(properties: [:])
      )]
    ))
  }

  private func toolOutput() -> Transcript.Entry {
    .toolOutput(Transcript.ToolOutput(
      id: "call-1",
      toolName: "probe",
      segments: [.text(Transcript.TextSegment(content: "result"))]
    ))
  }
}

private struct WindowedProfile: LanguageModelSession.DynamicProfile {
  let windowSize: Int

  var body: some DynamicProfile {
    Profile {
      Instructions("You are a helpful assistant.")
    }
    .rollingWindow(entries: windowSize)
  }
}
