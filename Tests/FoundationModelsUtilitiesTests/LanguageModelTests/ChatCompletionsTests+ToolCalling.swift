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
  @Suite struct ToolCalling {
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

    @Test func `parses tool call with streamed arguments`() async throws {
      MockSSEProtocol.handler = MockSSE.toolCallThenText(
        toolCallData: MockSSE.toolCall(
          id: "call_abc123",
          name: "get_weather",
          argumentChunks: [
            #"{"loc"#, #"ation""#, #":"New"#, #" York"}"#
          ]
        ),
        textResponse: "The weather is sunny"
      )

      let session = LanguageModelSession(
        model: makeMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "What's the weather?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count == 1)

      let calls = Array(toolCallEntries[0])
      #expect(calls.count == 1)
      #expect(calls[0].toolName == "get_weather")

      #expect(session.transcript.responseText == "The weather is sunny")
    }

    @Test func `parses tool call arguments from many small chunks`() async throws {
      MockSSEProtocol.handler = MockSSE.toolCallThenText(
        toolCallData: MockSSE.toolCall(
          id: "call_granular",
          name: "get_weather",
          argumentChunks: [
            "{", #""l"#, #"oc"#, #"at"#, #"io"#, #"n""#, #":"#,
            #"""#, "S", "F", #"""#, "}"
          ]
        ),
        textResponse: "Done"
      )

      let session = LanguageModelSession(
        model: makeMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count == 1)
      let calls = Array(toolCallEntries[0])
      #expect(calls[0].toolName == "get_weather")
    }

    @Test func `parses a tool call when the stream omits its identifier`() async throws {
      MockSSEProtocol.handler = MockSSE.toolCallThenText(
        toolCallData: MockSSE.toolCallWithoutIdentifier(
          name: "get_weather",
          argumentChunks: [#"{"location":"San Francisco"}"#]
        ),
        textResponse: "Done"
      )

      let session = LanguageModelSession(
        model: makeMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather?")

      let calls = try #require(session.transcript.compactMap(\.toolCalls).first)
      #expect(calls.count == 1)
      #expect(calls.first?.toolName == "get_weather")
      #expect(session.transcript.responseText == "Done")
    }

    @Test func `parses parallel tool calls`() async throws {
      MockSSEProtocol.handler = MockSSE.toolCallThenText(
        toolCallData: MockSSE.parallelToolCalls([
          (
            id: "call_1", name: "get_weather",
            arguments: #"{"location":"NYC"}"#
          ),
          (
            id: "call_2", name: "get_weather",
            arguments: #"{"location":"LA"}"#
          )
        ]),
        textResponse: "Both done"
      )

      let session = LanguageModelSession(
        model: makeMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather in NYC and LA?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count >= 1)

      #expect(session.transcript.responseText == "Both done")
    }

    @Test func `includes tool definitions in request`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(
        model: makeMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "test")

      let body = try requestBody()
      let tools = body["tools"] as? [[String: Any]]
      #expect(tools != nil)
      #expect((tools?.count ?? 0) >= 1)

      let function = tools?.first?["function"] as? [String: Any]
      #expect(function?["name"] as? String == "get_weather")
    }
  }
}
#endif
