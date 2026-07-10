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
import FoundationModels
import FoundationModelsUtilities
import Testing

/// Live integration tests that drive `ChatCompletionsLanguageModel` against a
/// real OpenAI-compatible endpoint. Configure with environment variables:
///   - FMU_TEST_ENDPOINT (required) — base URL, e.g. http://127.0.0.1:11434/v1
///   - FMU_TEST_MODEL    (required) — model name, e.g. smollm2:135m
///   - FMU_TEST_API_KEY (optional) — sent as `Authorization: Bearer <key>`
@Suite(
  "ChatCompletionsLive",
  .enabled(
    if: ProcessInfo.processInfo.environment["FMU_TEST_ENDPOINT"] != nil,
    "Set FMU_TEST_ENDPOINT to run."
  )
)
struct ChatCompletionsLiveTests {
  @Test func `responds to a real chat completions endpoint`() async throws {
    let env = ProcessInfo.processInfo.environment
    let urlString = try #require(env["FMU_TEST_ENDPOINT"])
    let url = try #require(URL(string: urlString))
    let modelName = try #require(env["FMU_TEST_MODEL"])

    var headers: [String: String] = [:]
    if let key = env["FMU_TEST_API_KEY"] {
      headers["Authorization"] = "Bearer \(key)"
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 300
    configuration.timeoutIntervalForResource = 600

    let model = ChatCompletionsLanguageModel(
      name: modelName,
      url: url,
      additionalHeaders: headers,
      supportsGuidedGeneration: false,
      urlSessionConfiguration: configuration
    )

    let session = LanguageModelSession(model: model)
    let response = try await session.respond(to: "Reply with a short greeting.")

    #expect(!response.content.isEmpty)
  }
}
