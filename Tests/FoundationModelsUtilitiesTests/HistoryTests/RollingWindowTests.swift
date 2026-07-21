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
  func `splits a prompt-response pair when the window is even`() async throws {
    let model = MockModel(textResponse: "OK", tokenCount: 1)
    let session = LanguageModelSession(profile: WindowedProfile(windowSize: 2).model(model))

    let _ = try await session.respond(to: "first")
    let _ = try await session.respond(to: "second")
    let _ = try await session.respond(to: "third")
    let _ = try await session.respond(to: "fourth")

    // The naive suffix(2) trim repeatedly cuts between a prompt and its
    // response, so the window starts with an orphaned response. This documents
    // the (buggy) naive outcome; in practice it crashes partway through.
    #expect(
      session.transcriptSummary == [
        .instructions,
        .response("OK"),
        .prompt("fourth"),
        .response("OK")
      ]
    )
  }

  @Test func `clamps nonpositive windows to preserve the active prompt`() async throws {
    for windowSize in [0, -1] {
      let model = MockModel(textResponse: "OK", tokenCount: 1)
      let session = LanguageModelSession(profile: WindowedProfile(windowSize: windowSize).model(model))

      let _ = try await session.respond(to: "first")

      #expect(session.transcriptSummary.contains(.prompt("first")))
      #expect(session.transcriptSummary.contains(.response("OK")))
    }
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
