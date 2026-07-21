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

extension ChatCompletionsTests {
  @Suite struct ErrorHandling {
    init() { MockSSEProtocol.reset() }

    @Test func `throws on HTTP error`() async throws {
      // Also a regression test for the error-body accumulation: the raw
      // response body used to be gathered with `reduce(Data(), { $0 + [$1] })`,
      // which re-copies the accumulated prefix for every byte (quadratic), so
      // a large non-200 payload stalled the streaming task. The accumulation
      // is now linear; assert the surfaced error carries the status code and
      // the byte-identical body.
      let body = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
      MockSSEProtocol.handler = { _ in
        (429, body)
      }

      let session = LanguageModelSession(model: makeMockModel())
      await #expect(throws: ChatCompletionsLanguageModel.RequestError.self) {
        do {
          let _ = try await session.respond(to: "test")
        } catch let error as ChatCompletionsLanguageModel.RequestError {
          guard case .httpError(let statusCode, let data) = error else {
            throw error
          }
          #expect(statusCode == 429)
          #expect(data == body)
          throw error
        }
      }
    }

    @Test func `throws on API error embedded in SSE stream`() async throws {
      MockSSEProtocol.handler = { _ in
        (200, MockSSE.apiError(message: "Rate limit exceeded"))
      }

      let session = LanguageModelSession(model: makeMockModel())
      await #expect(throws: (any Error).self) {
        try await session.respond(to: "test")
      }
    }

    @Test func `throws instead of trapping on a non-HTTP response`() async throws {
      MockSSEProtocol.handler = { _ in
        (200, MockSSE.text("OK"))
      }
      MockSSEProtocol.responseFactory = { request in
        URLResponse(
          url: request.url ?? URL.temporaryDirectory,
          mimeType: "text/event-stream",
          expectedContentLength: 0,
          textEncodingName: nil
        )
      }

      let session = LanguageModelSession(model: makeMockModel())
      await #expect(throws: ChatCompletionsLanguageModel.RequestError.self) {
        do {
          let _ = try await session.respond(to: "test")
        } catch let error as ChatCompletionsLanguageModel.RequestError {
          guard case .invalidStreamData = error else {
            throw error
          }
          throw error
        }
      }
    }
  }
}
