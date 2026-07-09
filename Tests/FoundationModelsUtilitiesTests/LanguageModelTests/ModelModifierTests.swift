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
import Foundation
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

@Suite
struct ModelModifierTests {
  @Test func `existential model is opened and used for generation`() async throws {
    let model: any LanguageModel = MockModel(textResponse: "hello", tokenCount: 1)
    let session = LanguageModelSession(profile: BareProfile(model: model))
    let response = try await session.respond(to: "...")
    #expect(response.content == "hello")
  }

  @Test func `switching profile resolves the singly-wrapped branch`() async throws {
    let primary: any LanguageModel = MockModel(textResponse: "primary", tokenCount: 1)
    let fallback: any LanguageModel = MockModel(textResponse: "fallback", tokenCount: 1)
    let counter = SwitchCounter(count: 1)
    let session = LanguageModelSession(
      profile: SwitchingProfile(
        primaryModel: primary,
        fallbackModel: fallback,
        counter: counter
      )
    )
    let response = try await session.respond(to: "...")
    #expect(response.content == "primary")
  }

  @Test func `switching profile resolves the doubly-wrapped branch`() async throws {
    let primary: any LanguageModel = MockModel(textResponse: "primary", tokenCount: 1)
    let fallback: any LanguageModel = MockModel(textResponse: "fallback", tokenCount: 1)
    let counter = SwitchCounter(count: 0)
    let session = LanguageModelSession(
      profile: SwitchingProfile(
        primaryModel: primary,
        fallbackModel: fallback,
        counter: counter
      )
    )
    let response = try await session.respond(to: "...")
    #expect(response.content == "fallback")
  }

  @Test func `switch profile tool swaps the active model between responses`() async throws {
    let primary: any LanguageModel = MockModel(
      events: [
        .toolCall(name: "switch_profile", arguments: "{}"),
        .text("primary"),
      ],
      tokenCount: 1
    )
    let fallback: any LanguageModel = MockModel(
      events: [
        .toolCall(name: "switch_profile", arguments: "{}"),
        .text("fallback"),
      ],
      tokenCount: 1
    )
    let counter = SwitchCounter(count: 1)
    let session = LanguageModelSession(
      profile: SwitchingProfile(
        primaryModel: primary,
        fallbackModel: fallback,
        counter: counter
      )
    )

    let first = try await session.respond(to: "go")
    #expect(first.content == "fallback")
    #expect(counter.count == 0)

    let second = try await session.respond(to: "go again")
    #expect(second.content == "primary")
    #expect(counter.count == 1)

    let third = try await session.respond(to: "and back")
    #expect(third.content == "fallback")
    #expect(counter.count == 0)

    let toolNames = session.transcript.compactMap(\.toolCalls)
      .flatMap { Array($0) }
      .map(\.toolName)
    #expect(toolNames == ["switch_profile", "switch_profile", "switch_profile"])
  }
}

private struct EchoTool: Tool {
  let name = "echo"
  let description = "Echoes back the provided text."

  @Generable
  struct Arguments {
    var text: String
  }

  func call(arguments: Arguments) async throws -> String {
    arguments.text
  }
}

private struct SwitchProfileTool: Tool {
  let name = "switch_profile"
  let description = "Flips the active profile branch by toggling the counter."

  let counter: SwitchCounter

  @Generable
  struct Arguments {}

  func call(arguments: Arguments) async throws -> String {
    counter.count = counter.count > 0 ? 0 : 1
    return "switched"
  }
}

private struct BareProfile: LanguageModelSession.DynamicProfile {
  let model: any LanguageModel
  var body: some DynamicProfile {
    Profile {
      Instructions("You are a helpful assistant.")
    }
    .FoundationModelsUtilities::model(model)
  }
}

final class SwitchCounter: @unchecked Sendable {
  var count: Int

  init(count: Int) {
    self.count = count
  }
}

private struct SwitchingProfile: LanguageModelSession.DynamicProfile {
  let primaryModel: any LanguageModel
  let fallbackModel: any LanguageModel

  let counter: SwitchCounter

  var body: some DynamicProfile {
    if counter.count > 0 {
      Profile {
        Instructions("You are a helpful assistant.")
        EchoTool()
        SwitchProfileTool(counter: counter)
      }
      .FoundationModelsUtilities::model(primaryModel)
    } else {
      Profile {
        Instructions("You are a helpful assistant 2.")
        EchoTool()
        SwitchProfileTool(counter: counter)
      }
      .FoundationModelsUtilities::model(
        fallbackModel
      )
    }
  }
}
