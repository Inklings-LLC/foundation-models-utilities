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
public import FoundationModels

/// Non-mutating, composable **views** over a session's stored transcript.
///
/// Every builder here returns a pure ``HistoryView/Transform`` — an
/// `[Transcript.Entry] -> [Transcript.Entry]` function suitable for
/// `DynamicProfile.historyTransform(_:)`. Unlike the modifiers
/// ``droppingCompletedToolCalls()``, ``rollingWindow(entries:)``, and
/// ``summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)``,
/// which **mutate** the session's stored `\.history` from `onPrompt`, these
/// transforms leave storage untouched. They shape only what a single generation
/// sees. The same stored transcript can therefore be projected differently by
/// different profiles (for example, phases with different context budgets) while
/// remaining fully available to every other phase — the shaping is lossless.
///
/// The shapes mirror the mutating modifiers exactly:
///
/// - ``droppingCompletedToolCalls()`` reproduces the shape of the
///   ``FoundationModels/DynamicProfile/droppingCompletedToolCalls()`` modifier:
///   completed tool-call/tool-output entries are removed while the most recent
///   in-flight exchange is exempt.
/// - ``rollingWholeTurns(maximumEntries:anchoringFirstUserTurn:)`` reproduces
///   the shape of ``FoundationModels/DynamicProfile/rollingWindow(entries:)``: a
///   soft entry ceiling admitting only complete turns, built on the shared
///   ``wholeTurnSuffix(of:preferredMaximumEntries:allowsNewestTurnToExceedMaximum:)``
///   helper.
///
/// Instructions always survive every transform, and the in-flight turn — the
/// suffix from the most recent `.prompt` — always passes through untouched so a
/// live tool loop is never orphaned. A turn completes only when the *next*
/// prompt lands, never merely because a `.response` exists (a model can emit
/// pre-tool-call commentary as a `.response` inside a turn).
///
/// Attach a composed view to a profile through the framework's
/// `historyTransform(_:)`:
///
/// ```swift
/// profile.historyTransform(
///     HistoryView.composed(
///         HistoryView.droppingCompletedToolCalls(),
///         HistoryView.rollingWholeTurns(maximumEntries: 10)
///     )
/// )
/// ```
public enum HistoryView {

  /// A pure, non-mutating projection of a session's stored transcript. The same
  /// shape `DynamicProfile.historyTransform(_:)` accepts.
  public typealias Transform = @Sendable ([Transcript.Entry]) -> [Transcript.Entry]

  /// A view that removes completed tool-call and tool-output entries, keeping
  /// every prompt, response, and instruction.
  ///
  /// Fulfilled tool loops add bulk without adding context a later turn needs —
  /// the model's responses already incorporate what the tools returned. This
  /// transform drops those loops from the **view** only; the entries remain in
  /// stored history.
  ///
  /// The most recent in-flight exchange is exempt: a history view re-evaluates
  /// *during* a tool-calling turn (at every post-tool-output continuation), and
  /// dropping the loop still feeding the model would hand the framework a
  /// transcript that no longer ends on a `.prompt` or `.toolOutput`. Only the
  /// portion before the most recent `.prompt` is treated as completed and
  /// eligible for dropping — matching both the mutating modifier's exemption of
  /// the most recent tool exchange and the guarantee that an in-flight loop
  /// survives untouched.
  ///
  /// - Returns: A transform that prunes completed tool loops from the view.
  public static func droppingCompletedToolCalls() -> Transform {
    { entries in
      let split = splitInFlight(entries)
      let (instructions, conversation) = partition(
        split.completed,
        droppingCompletedToolCalls: true
      )
      return instructions + conversation + Array(split.inFlight)
    }
  }

  /// A view that keeps only the most recent complete conversation turns within
  /// a soft entry ceiling, optionally anchoring the first user turn verbatim.
  ///
  /// A turn is never split to meet the count: the in-flight turn (the suffix
  /// from the most recent `.prompt`) always survives whole, and older complete
  /// turns are admitted newest-first only while they fit. The ceiling counts the
  /// in-flight entries, so `maximumEntries` remains the total conversational cap
  /// — the completed portion is windowed against the room the in-flight turn
  /// leaves. Instructions always survive and never count against the ceiling.
  ///
  /// When `anchoringFirstUserTurn` is `true`, the conversation's first user turn
  /// is preserved verbatim through every roll; the newest turns fill whatever
  /// budget remains and the middle falls away. If the first turn alone meets the
  /// budget it still survives whole, so the window floors at the opening turn
  /// rather than forgetting it. This both matches the owner's "keep the first
  /// turn and the last turn or two" shape and stabilizes the KV-cache prefix
  /// across rolls.
  ///
  /// - Parameters:
  ///   - maximumEntries: The preferred maximum number of non-instruction
  ///     entries to retain. A single current or recent turn may exceed this so
  ///     the projection stays structurally valid.
  ///   - anchoringFirstUserTurn: Keep the first user turn verbatim through every
  ///     roll. Defaults to `false`.
  /// - Returns: A transform that windows the view to whole turns.
  public static func rollingWholeTurns(
    maximumEntries: Int,
    anchoringFirstUserTurn: Bool = false
  ) -> Transform {
    { entries in
      let split = splitInFlight(entries)
      let (instructions, conversation) = partition(
        split.completed,
        droppingCompletedToolCalls: false
      )
      let windowed = windowedConversation(
        conversation,
        maximumEntries: maximumEntries,
        inFlightCount: split.inFlight.count,
        allowsNewestTurnToExceedMaximum: split.inFlight.isEmpty,
        anchoringFirstUserTurn: anchoringFirstUserTurn
      )
      return instructions + windowed + Array(split.inFlight)
    }
  }

  /// Composes the given transforms into one, applied in order: the first is
  /// applied first (innermost), each subsequent transform sees the previous
  /// one's output.
  ///
  /// Because every ``HistoryView`` transform preserves instructions and the
  /// in-flight suffix, a composition does too. To clean up completed tool loops
  /// before windowing — the recommended order — list
  /// ``droppingCompletedToolCalls()`` first:
  ///
  /// ```swift
  /// HistoryView.composed(
  ///     HistoryView.droppingCompletedToolCalls(),
  ///     HistoryView.rollingWholeTurns(maximumEntries: 10)
  /// )
  /// ```
  ///
  /// - Parameter transforms: The transforms to compose, in application order.
  /// - Returns: A single transform equivalent to applying each in sequence.
  public static func composed(_ transforms: Transform...) -> Transform {
    composed(transforms)
  }

  /// Composes an array of transforms into one, applied in order. See
  /// ``composed(_:)-(Transform...)``.
  ///
  /// - Parameter transforms: The transforms to compose, in application order.
  ///   An empty array yields the identity transform.
  /// - Returns: A single transform equivalent to applying each in sequence.
  public static func composed(_ transforms: [Transform]) -> Transform {
    { entries in
      transforms.reduce(entries) { partial, transform in transform(partial) }
    }
  }

  // MARK: - Internal machinery

  /// Splits `entries` at the most recent `.prompt` into the completed history
  /// and the in-flight turn. A turn completes only when the next prompt lands,
  /// so everything from the last prompt onward is in flight and is never
  /// reshaped. When no prompt is present the whole input is treated as
  /// completed history.
  static func splitInFlight(
    _ entries: [Transcript.Entry]
  ) -> (completed: ArraySlice<Transcript.Entry>, inFlight: ArraySlice<Transcript.Entry>) {
    guard let lastPromptIndex = entries.lastIndex(where: { entry in
      if case .prompt = entry { return true }
      return false
    }) else {
      return (entries[...], [])
    }
    return (entries[..<lastPromptIndex], entries[lastPromptIndex...])
  }

  /// Separates the completed portion into surviving instruction entries and the
  /// conversation stream, optionally filtering completed tool loops. Instruction
  /// entries always survive and are lifted to the front of the eventual view.
  static func partition(
    _ completed: ArraySlice<Transcript.Entry>,
    droppingCompletedToolCalls: Bool
  ) -> (instructions: [Transcript.Entry], conversation: [Transcript.Entry]) {
    var instructions: [Transcript.Entry] = []
    var conversation: [Transcript.Entry] = []
    for entry in completed {
      switch entry {
      case .instructions:
        instructions.append(entry)
      case .toolCalls, .toolOutput:
        if !droppingCompletedToolCalls {
          conversation.append(entry)
        }
      default:
        conversation.append(entry)
      }
    }
    return (instructions, conversation)
  }

  /// Applies the whole-turn ceiling to the completed conversation stream,
  /// honoring the in-flight turn's claim on the budget and the optional
  /// first-user-turn anchor. Returns the conversation unchanged when it already
  /// fits.
  static func windowedConversation(
    _ conversation: [Transcript.Entry],
    maximumEntries: Int,
    inFlightCount: Int,
    allowsNewestTurnToExceedMaximum: Bool,
    anchoringFirstUserTurn: Bool
  ) -> [Transcript.Entry] {
    let budget = max(0, maximumEntries - inFlightCount)
    guard conversation.count > budget else {
      return conversation
    }
    if anchoringFirstUserTurn,
       let anchorLength = firstUserTurnPrefixLength(in: conversation),
       anchorLength < conversation.count {
      let anchor = Array(conversation[..<anchorLength])
      let rest = Array(conversation[anchorLength...])
      let tailBudget = max(0, budget - anchor.count)
      return anchor + wholeTurnSuffix(
        of: rest,
        preferredMaximumEntries: tailBudget,
        allowsNewestTurnToExceedMaximum: allowsNewestTurnToExceedMaximum
      )
    }
    return wholeTurnSuffix(
      of: conversation,
      preferredMaximumEntries: budget,
      allowsNewestTurnToExceedMaximum: allowsNewestTurnToExceedMaximum
    )
  }

  /// The entry count of the conversation's first user turn — the leading
  /// `.prompt` and everything through the entry before the second `.prompt`.
  /// This is the anchor `anchoringFirstUserTurn` preserves. Returns `nil` when
  /// the conversation does not begin at a prompt (no unambiguous first turn, so
  /// callers fall back to plain recency) or holds no second prompt (the whole
  /// conversation *is* the first turn; there is nothing to anchor against).
  static func firstUserTurnPrefixLength(
    in conversation: [Transcript.Entry]
  ) -> Int? {
    guard case .prompt = conversation.first else { return nil }
    return conversation.dropFirst().firstIndex { entry in
      if case .prompt = entry { return true }
      return false
    }
  }
}
