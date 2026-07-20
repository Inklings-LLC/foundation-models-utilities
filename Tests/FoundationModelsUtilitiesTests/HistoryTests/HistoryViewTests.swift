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

/// Pure-transform coverage for the non-mutating history views. Entries are
/// constructed directly — no session, no generation. These transforms shape
/// only what a single generation would see; the input array (stored history) is
/// never altered, which the storage-intact cases assert directly.
///
/// The semantic cases mirror Agentic's `GuideHistoryPolicyTests` so the FMU
/// views carry the exact shapes Agentic hand-rolled, plus FMU-style cases in
/// the spirit of `DroppingCompletedToolCallsTests`.
@Suite
struct HistoryViewTests {

  // MARK: - Builders

  private func rolling(_ maximumEntries: Int, anchor: Bool = false) -> HistoryView.Transform {
    HistoryView.rollingWholeTurns(maximumEntries: maximumEntries, anchoringFirstUserTurn: anchor)
  }

  /// The composed default the mutating `conversational` policy mirrors: drop
  /// completed tool loops, then window whole turns.
  private func conversational(_ maximumEntries: Int) -> HistoryView.Transform {
    HistoryView.composed(
      HistoryView.droppingCompletedToolCalls(),
      HistoryView.rollingWholeTurns(maximumEntries: maximumEntries)
    )
  }

  // MARK: - Composition identity

  @Test func `an empty composition is the identity view`() {
    let entries = [prompt("a"), response("b"), prompt("c")]
    #expect(HistoryView.composed()(entries) == entries)
    #expect(HistoryView.composed([])(entries) == entries)
  }

  // MARK: - Rolling whole-turn window

  @Test func `rolling window keeps the most recent suffix`() {
    let entries = (0..<6).flatMap { [prompt("q\($0)"), response("r\($0)")] }
    let view = rolling(4)(entries)

    #expect(view.count == 4)
    #expect(view == Array(entries.suffix(4)))
  }

  @Test func `a misaligned finite window removes an old turn instead of orphaning its response`() {
    let entries = (0..<3).flatMap { [prompt("q\($0)"), response("r\($0)")] }
    let view = rolling(3)(entries)

    #expect(view == [entries[4], entries[5]])
    guard case .prompt = view.first else {
      Issue.record("finite history must begin on a prompt boundary")
      return
    }
  }

  @Test func `an in-flight turn lets an oversized older turn fall out as one unit`() {
    let olderToolTurn = [
      prompt("look that up"),
      toolCalls(),
      toolOutput(),
      response("done")
    ]
    let currentPrompt = prompt("and now?")
    let view = rolling(3)(olderToolTurn + [currentPrompt])

    #expect(view == [currentPrompt])
  }

  @Test func `the window never evicts the in-flight turn`() {
    var entries = (0..<6).flatMap { [prompt("q\($0)"), response("r\($0)")] }
    entries.append(prompt("q6"))
    entries.append(toolCalls())
    entries.append(toolOutput())
    let view = rolling(1)(entries)

    // The in-flight turn exceeds the window on its own; it still survives whole,
    // and completed history yields fully.
    #expect(view == Array(entries.suffix(3)))
  }

  // MARK: - Dropping completed tool calls

  @Test func `tool loops drop from the view, conversation survives`() {
    let entries = [
      prompt("what's the weather"),
      toolCalls(),
      response("Sunny and mild."),
      prompt("and tomorrow?")
    ]
    let view = HistoryView.droppingCompletedToolCalls()(entries)

    #expect(view.count == 3)
    #expect(view.allSatisfy { entry in
      if case .toolCalls = entry { return false }
      if case .toolOutput = entry { return false }
      return true
    })
  }

  @Test func `an in-flight tool loop survives the drop untouched`() {
    // A history view re-evaluates DURING a tool-calling turn: the suffix from
    // the last prompt is still feeding the model, so dropping its tool entries
    // would invalidate the transcript.
    let entries = [
      prompt("plan me a lesson"),
      toolCalls(),
      toolOutput()
    ]
    let view = conversational(40)(entries)

    #expect(view == entries)
  }

  @Test func `pre-tool-call commentary does not mark the turn completed`() {
    // A model can record text BEFORE its tool call as a `.response` inside the
    // turn, so "a response exists" is not a completion signal — only the next
    // prompt is.
    let entries = [
      prompt("plan me a lesson"),
      response("One moment."),
      toolCalls(),
      toolOutput()
    ]
    let view = conversational(40)(entries)

    #expect(view == entries)
  }

  @Test func `the previous turn's loop drops once its response lands`() {
    let completedTurn = [
      prompt("what's the weather"),
      toolCalls(),
      toolOutput(),
      response("Sunny and mild.")
    ]
    let entries = completedTurn + [prompt("and tomorrow?")]
    let view = HistoryView.droppingCompletedToolCalls()(entries)

    #expect(view == [entries[0], entries[3], entries[4]])
  }

  // MARK: - Composition (drop + roll)

  @Test func `the composed view windows AND drops tool loops`() {
    var entries: [Transcript.Entry] = []
    for index in 0..<30 {
      entries.append(prompt("q\(index)"))
      entries.append(toolCalls())
      entries.append(response("r\(index)"))
    }
    // The new prompt is already appended when the framework evaluates the view.
    entries.append(prompt("q30"))
    let view = conversational(40)(entries)

    // The soft ceiling never retains half of the oldest completed turn.
    #expect(view.count == 39)
    #expect(view.allSatisfy { entry in
      if case .toolCalls = entry { return false }
      return true
    })
  }

  // MARK: - Instructions always survive

  @Test func `instructions always survive every view`() {
    let entries =
      [instructions()]
      + (0..<6).flatMap { [prompt("q\($0)"), response("r\($0)")] }
    let view = conversational(4)(entries)

    #expect(view.first == instructions())
    // Instructions do not count against the entry budget: the four newest
    // conversational entries survive alongside the instructions.
    #expect(Array(view.dropFirst()) == Array(entries.suffix(4)))
  }

  // MARK: - First-user-turn anchor

  @Test func `anchoring keeps the first user turn verbatim and drops the middle`() {
    let entries = [
      prompt("first"),
      response("a"),
      prompt("q1"),
      response("b"),
      prompt("q2"),
      response("c"),
      prompt("current")
    ]
    let view = rolling(4, anchor: true)(entries)

    // Budget 4 minus the in-flight prompt leaves 3; the two-entry anchor plus
    // the in-flight prompt survive, the middle turns fall out.
    #expect(view == [prompt("first"), response("a"), prompt("current")])
    #expect(view.first == prompt("first"))
  }

  @Test func `without the anchor the first turn is not privileged`() {
    let entries = [
      prompt("first"),
      response("a"),
      prompt("q1"),
      response("b"),
      prompt("q2"),
      response("c"),
      prompt("current")
    ]
    let view = rolling(4, anchor: false)(entries)

    // Plain recency keeps the newest turns; the opening turn is not retained.
    #expect(view.first != prompt("first"))
    #expect(view.last == prompt("current"))
  }

  // MARK: - wholeTurnSuffix public helper

  @Test func `a completed tool turn is retained whole when it alone exceeds the ceiling`() {
    let toolTurn = [
      prompt("look that up"),
      response("one moment"),
      toolCalls(),
      toolOutput(),
      response("done")
    ]

    // Settled history: the newest completed turn is indivisible.
    #expect(
      wholeTurnSuffix(
        of: toolTurn,
        preferredMaximumEntries: toolTurn.count - 1,
        allowsNewestTurnToExceedMaximum: true
      ) == toolTurn
    )
    // A live view's completed portion, whose in-flight suffix carries the floor,
    // instead drops an oversized older turn entirely.
    #expect(
      wholeTurnSuffix(
        of: toolTurn,
        preferredMaximumEntries: toolTurn.count - 1,
        allowsNewestTurnToExceedMaximum: false
      ).isEmpty
    )
  }

  @Test func `wholeTurnSuffix admits older turns only as complete units`() {
    let history = [
      prompt("first"),
      toolCalls(),
      toolOutput(),
      response("done"),
      prompt("second")
    ]

    #expect(wholeTurnSuffix(of: history, preferredMaximumEntries: 5) == history)
    #expect(wholeTurnSuffix(of: history, preferredMaximumEntries: 4) == [history[4]])
  }

  // MARK: - Storage-intact view (FMU-style humidity case)

  @Test func `the humidity tool output is visible while newest, filtered after a new prompt, storage unchanged`() {
    // A completed exchange: the model has answered using the tool output.
    let firstTurn = [
      prompt("what's the humidity"),
      toolCalls(),
      toolOutput(),
      response("It's 62% right now.")
    ]
    let drop = HistoryView.droppingCompletedToolCalls()

    // While the exchange is the newest thing in the transcript there is no later
    // prompt, so the whole turn is in flight and the tool output stays visible.
    let firstTurnStorage = firstTurn
    let viewWhileNewest = drop(firstTurn)
    #expect(viewWhileNewest == firstTurn)
    #expect(viewWhileNewest.contains { if case .toolOutput = $0 { return true }; return false })
    #expect(firstTurn == firstTurnStorage) // storage untouched

    // Once a new prompt arrives the earlier exchange is completed, so its tool
    // loop drops FROM THE VIEW — but the stored transcript is unchanged.
    let storage = firstTurn + [prompt("and tomorrow?")]
    let storageBefore = storage
    let view = drop(storage)

    #expect(view == [firstTurn[0], firstTurn[3], storage[4]])
    #expect(!view.contains { if case .toolCalls = $0 { return true }; return false })
    #expect(!view.contains { if case .toolOutput = $0 { return true }; return false })
    // The whole point: the transform is a lossless view; storage is intact and
    // still holds the completed tool call and output.
    #expect(storage == storageBefore)
    #expect(storage.contains { if case .toolCalls = $0 { return true }; return false })
    #expect(storage.contains { if case .toolOutput = $0 { return true }; return false })
  }

  // MARK: - Entry constructors

  private func instructions() -> Transcript.Entry {
    .instructions(Transcript.Instructions(
      segments: [.text(Transcript.TextSegment(content: "system"))],
      toolDefinitions: []
    ))
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
