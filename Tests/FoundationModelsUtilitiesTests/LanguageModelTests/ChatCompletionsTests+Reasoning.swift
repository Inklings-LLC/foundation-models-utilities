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
#if canImport(Darwin)
import Foundation
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

extension ChatCompletionsTests {
  @Suite struct Reasoning {
    init() { MockSSEProtocol.reset() }

    struct MockWeatherTool: Tool {
      let name = "get_weather"
      let description = "Get the weather for a location"

      @Generable
      struct Arguments {
        var location: String
      }

      func call(arguments: Arguments) async throws -> String {
        "Sunny in \(arguments.location)"
      }
    }

    @Test func `maps framework reasoning levels to OpenAI effort`() async throws {
      let cases: [(ContextOptions.ReasoningLevel, String)] = [
        (.light, "low"),
        (.moderate, "medium"),
        (.deep, "high"),
        (.custom("xhigh"), "xhigh")
      ]

      for (level, expectedEffort) in cases {
        MockSSEProtocol.reset()
        MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }
        let session = LanguageModelSession(model: makeMockModel())
        let _ = try await session.respond(
          to: "test",
          contextOptions: ContextOptions(reasoningLevel: level)
        )

        let body = try requestBody()
        #expect(body["reasoning_effort"] as? String == expectedEffort)
      }
    }

    @Test func `omits reasoning effort when no level is requested`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }
      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      let body = try requestBody()
      #expect(body["reasoning_effort"] == nil)
    }

    @Test func `forwards reasoning_content as a reasoning transcript entry`() async throws {
      MockSSEProtocol.handler = { _ in
        (
          200,
          MockSSE.chunks([
            MockSSE.Chunk(reasoning: "Let me think"),
            MockSSE.Chunk(reasoning: " about this..."),
            MockSSE.Chunk(text: "The answer is 42.")
          ])
        )
      }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "What is the answer?")

      let reasoningEntries = session.transcript.compactMap(\.reasoning)
      #expect(reasoningEntries.count == 1)

      let reasoningText =
        reasoningEntries.first?.segments.compactMap { segment -> String? in
          if case .text(let text) = segment { return text.content }
          return nil
        }.joined() ?? ""
      #expect(reasoningText == "Let me think about this...")

      #expect(session.transcript.responseText == "The answer is 42.")
    }

    @Test func `interleaves reasoning and content chunks`() async throws {
      MockSSEProtocol.handler = { _ in
        (
          200,
          MockSSE.chunks([
            MockSSE.Chunk(reasoning: "First "),
            MockSSE.Chunk(text: "Hello"),
            MockSSE.Chunk(reasoning: "thought"),
            MockSSE.Chunk(text: " world")
          ])
        )
      }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      let reasoningEntries = session.transcript.compactMap(\.reasoning)
      #expect(reasoningEntries.count == 1)
      let reasoningText =
        reasoningEntries
        .flatMap(\.segments)
        .compactMap { segment -> String? in
          if case .text(let text) = segment { return text.content }
          return nil
        }
        .joined()
      #expect(reasoningText == "First thought")

      let responseEntries = session.transcript.compactMap(\.response)
      #expect(responseEntries.count == 1)
      #expect(session.transcript.responseText == "Hello world")
    }

    @Test func `echoes prior reasoning back as reasoning_content on assistant message`()
      async throws
    {
      // Round 1: model emits reasoning + response.
      // Round 2: send a follow-up; verify the prior reasoning is echoed
      // back in the assistant message that precedes the new prompt.
      var roundCount = 0
      MockSSEProtocol.handler = { _ in
        defer { roundCount += 1 }
        if roundCount == 0 {
          return (
            200,
            MockSSE.chunks([
              MockSSE.Chunk(reasoning: "Carefully considering"),
              MockSSE.Chunk(text: "First answer")
            ])
          )
        } else {
          return (200, MockSSE.text("Second answer"))
        }
      }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "First question")
      let _ = try await session.respond(to: "Follow up")

      let body = try requestBody()
      let messages = try #require(body["messages"] as? [[String: Any]])
      let assistantMessage = try #require(
        messages.first { $0["role"] as? String == "assistant" }
      )
      #expect(assistantMessage["reasoning_content"] as? String == "Carefully considering")
      #expect(assistantMessage["content"] as? String == "First answer")
    }

    @Test func `attaches reasoning to following tool calls message`() async throws {
      // Reasoning that arrives before tool calls should be echoed via
      // `reasoning_content` on the assistant tool-calls message.
      var roundCount = 0
      MockSSEProtocol.handler = { _ in
        defer { roundCount += 1 }
        if roundCount == 0 {
          var lines = [String]()
          lines.append(
            #"data: {"id":"1","model":"mock","choices":[{"delta":{"reasoning_content":"Need to look up the weather"}}]}"#
          )
          lines.append("")
          lines.append(
            #"data: {"id":"1","model":"mock","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"NYC\"}"}}]}}]}"#
          )
          lines.append("")
          lines.append("data: [DONE]")
          lines.append("")
          return (200, Data(lines.joined(separator: "\n").utf8))
        } else {
          return (200, MockSSE.text("It is sunny"))
        }
      }

      let session = LanguageModelSession(
        model: makeMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather in NYC?")

      // Inspect the second request: the assistant tool-calls message
      // should carry the reasoning_content from before the tool calls.
      let body = try requestBody()
      let messages = try #require(body["messages"] as? [[String: Any]])
      let toolCallsMessage = try #require(
        messages.first { ($0["tool_calls"] as? [[String: Any]])?.isEmpty == false }
      )
      #expect(toolCallsMessage["reasoning_content"] as? String == "Need to look up the weather")
    }
  }
}

#endif
