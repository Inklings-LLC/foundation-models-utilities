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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Intercepts requests to "mock-llm.test" and returns canned SSE responses,
// letting us test the full ChatCompletionsLanguageModel pipeline without a network.
final class MockSSEProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (statusCode: Int, data: Data))?
  nonisolated(unsafe) static var lastRequest: URLRequest?
  nonisolated(unsafe) static var responseFactory: ((URLRequest) -> URLResponse)?

  static func reset() {
    handler = nil
    lastRequest = nil
    responseFactory = nil
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "mock-llm.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    // URLSession converts httpBody to httpBodyStream before passing to protocol handlers;
    // drain it back into httpBody so handlers and lastRequest see consistent data.
    var normalizedRequest = request
    if let stream = request.httpBodyStream {
      stream.open()
      var bodyData = Data()
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let n = stream.read(buffer, maxLength: 4096)
        if n > 0 { bodyData.append(buffer, count: n) }
      }
      stream.close()
      normalizedRequest.httpBody = bodyData
    }
    Self.lastRequest = normalizedRequest
    let (statusCode, data) = Self.handler?(normalizedRequest) ?? (200, Data())
    let response = Self.responseFactory?(request) ?? HTTPURLResponse(
      url: request.url ?? URL.temporaryDirectory,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"],
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

enum MockSSE {
  static func text(_ chunks: String...) -> Data {
    var lines = [String]()
    for chunk in chunks {
      let escaped = jsonEscape(chunk)
      lines.append(
        #"data: {"id":"1","model":"mock","choices":[{"delta":{"content":"\#(escaped)"}}]}"#
      )
      lines.append("")
    }
    lines.append("data: [DONE]")
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
  }

  // A single SSE chunk with optional text content, optional reasoning
  // content, and optional usage snapshot.
  struct Chunk {
    var text: String? = nil
    var reasoning: String? = nil
    var usage: Usage? = nil

    struct Usage {
      var promptTokens: Int
      var completionTokens: Int
      var cachedTokens: Int? = nil
      var reasoningTokens: Int? = nil
    }
  }

  // Builds an SSE response from a sequence of chunks, each carrying optional
  // text and/or a usage snapshot. Use this for both trailing-usage streams
  // (where the final chunk has only `usage`) and per-chunk-usage streams
  // (where every chunk has both `text` and `usage`).
  static func chunks(_ chunks: [Chunk]) -> Data {
    var lines = [String]()
    for chunk in chunks {
      lines.append("data: " + chunkJSON(chunk))
      lines.append("")
    }
    lines.append("data: [DONE]")
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
  }

  private static func chunkJSON(_ chunk: Chunk) -> String {
    var deltaFields = [String]()
    if let text = chunk.text {
      deltaFields.append(#""content":"\#(jsonEscape(text))""#)
    }
    if let reasoning = chunk.reasoning {
      deltaFields.append(#""reasoning_content":"\#(jsonEscape(reasoning))""#)
    }
    let choices: String
    if deltaFields.isEmpty {
      choices = "[]"
    } else {
      let delta = "{" + deltaFields.joined(separator: ",") + "}"
      choices = #"[{"delta":\#(delta)}]"#
    }

    guard let usage = chunk.usage else {
      return #"{"id":"1","model":"mock","choices":\#(choices)}"#
    }

    var usageFields = [
      #""prompt_tokens":\#(usage.promptTokens)"#,
      #""completion_tokens":\#(usage.completionTokens)"#,
      #""total_tokens":\#(usage.promptTokens + usage.completionTokens)"#
    ]
    if let cachedTokens = usage.cachedTokens {
      usageFields.append(
        #""prompt_tokens_details":{"cached_tokens":\#(cachedTokens)}"#
      )
    }
    if let reasoningTokens = usage.reasoningTokens {
      usageFields.append(
        #""completion_tokens_details":{"reasoning_tokens":\#(reasoningTokens)}"#
      )
    }
    let usageJSON = "{" + usageFields.joined(separator: ",") + "}"
    return #"{"id":"1","model":"mock","choices":\#(choices),"usage":\#(usageJSON)}"#
  }

  static func toolCall(
    id: String,
    name: String,
    argumentChunks: [String]
  ) -> Data {
    var lines = [String]()
    lines.append(
      #"data: {"id":"1","model":"mock","choices":[{"delta":{"tool_calls":[{"index":0,"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":""}}]}}]}"#
    )
    lines.append("")
    for chunk in argumentChunks {
      let escaped = jsonEscape(chunk)
      lines.append(
        #"data: {"id":"1","model":"mock","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\#(escaped)"}}]}}]}"#
      )
      lines.append("")
    }
    lines.append("data: [DONE]")
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
  }

  static func toolCallWithoutIdentifier(
    name: String,
    argumentChunks: [String]
  ) -> Data {
    var lines = [String]()
    lines.append(
      #"data: {"id":"1","model":"mock","choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"\#(name)","arguments":""}}]}}]}"#
    )
    lines.append("")
    for chunk in argumentChunks {
      let escaped = jsonEscape(chunk)
      lines.append(
        #"data: {"id":"1","model":"mock","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\#(escaped)"}}]}}]}"#
      )
      lines.append("")
    }
    lines.append("data: [DONE]")
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
  }

  static func parallelToolCalls(
    _ calls: [(id: String, name: String, arguments: String)]
  ) -> Data {
    var lines = [String]()
    for (index, call) in calls.enumerated() {
      lines.append(
        #"data: {"id":"1","model":"mock","choices":[{"delta":{"tool_calls":[{"index":\#(index),"id":"\#(call.id)","type":"function","function":{"name":"\#(call.name)","arguments":"\#(jsonEscape(call.arguments))"}}]}}]}"#
      )
      lines.append("")
    }
    lines.append("data: [DONE]")
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
  }

  static func apiError(message: String) -> Data {
    let escaped = jsonEscape(message)
    return Data(
      [
        #"data: {"error":{"message":"\#(escaped)","type":"server_error"}}"#,
        ""
      ].joined(separator: "\n").utf8
    )
  }

  static func toolCallThenText(
    toolCallData: Data,
    textResponse: String
  ) -> (URLRequest) -> (statusCode: Int, data: Data) {
    { request in
      let body = request.httpBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      }
      let messages = body?["messages"] as? [[String: Any]]
      let hasToolOutput =
        messages?.contains {
          $0["role"] as? String == "tool"
        } ?? false

      if hasToolOutput {
        return (200, MockSSE.text(textResponse))
      } else {
        return (200, toolCallData)
      }
    }
  }

  private static func jsonEscape(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}
