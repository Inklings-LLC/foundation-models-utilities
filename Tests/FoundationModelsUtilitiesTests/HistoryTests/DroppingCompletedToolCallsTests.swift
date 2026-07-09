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
struct DroppingCompletedToolCallsTests {
  /// A model that calls the skill-activation tool on its first turn, then
  /// responds with text once the tool output returns.
  private func toolCallingModel() -> MockModel {
    MockModel(
      events: [
        .toolCall(name: "activate_skill", arguments: #"{"skill":"echo"}"#),
        .text("OK")
      ],
      tokenCount: 1
    )
  }

  @Test func `keeps an incomplete tool-call exchange`() async throws {
    let session = LanguageModelSession(profile: DropToolCallsProfile().FoundationModelsUtilities::model(toolCallingModel()))

    let _ = try await session.respond(to: "first")

    // The tool call/output for this prompt are not followed by a later prompt,
    // so they are still "incomplete" and are preserved.
    #expect(
      session.transcriptSummary == [
        .instructions,
        .prompt("first"),
        .toolCall("activate_skill"),
        .toolOutput("echoed"),
        .response("OK")
      ]
    )
  }

  @Test func `drops the completed tool-call exchange once a new prompt arrives`() async throws {
    let session = LanguageModelSession(profile: DropToolCallsProfile().FoundationModelsUtilities::model(toolCallingModel()))

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")

    // The first exchange's tool call/output now sit before a later prompt, so
    // they are dropped. Only the most recent tool call/output pair remains, and
    // every prompt/response entry is preserved.
    #expect(
      session.transcriptSummary == [
        .instructions,
        .prompt("first"),
        .response("OK"),
        .prompt("second"),
        .toolCall("activate_skill"),
        .toolOutput("echoed"),
        .response("OK")
      ]
    )
  }
}

private struct DropToolCallsProfile: LanguageModelSession.DynamicProfile {
  var body: some DynamicProfile {
    Profile {
      Skills(activations: SkillActivations()) {
        Skill(name: "echo", description: "Echoes input", prompt: "echoed")
      }
    }
    .droppingCompletedToolCalls()
  }
}
