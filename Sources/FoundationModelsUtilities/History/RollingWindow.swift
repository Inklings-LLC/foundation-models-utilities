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

extension LanguageModelSession.DynamicProfile {
  /// Returns a modified profile that keeps the most recent complete
  /// conversation turns, discarding older turns each time a new prompt is
  /// sent.
  ///
  /// Use this modifier to bound transcript growth by maintaining a
  /// soft entry ceiling over the conversation history. A turn is never split
  /// merely to meet the requested entry count; the current turn is always
  /// retained in full, and older turns are admitted newest-first only when the
  /// whole turn fits. It
  /// composes well with other history modifiers — for example, applying
  /// ``droppingCompletedToolCalls()`` before a rolling window ensures that
  /// stale tool-call entries are removed first.
  ///
  /// ```swift
  /// Profile {
  ///     Instructions("You are a helpful assistant.")
  /// }
  /// .rollingWindow(entries: 10)
  /// .droppingCompletedToolCalls()
  /// ```
  ///
  /// - Parameter entries: The preferred maximum number of transcript entries
  ///   to retain. A single current or recent turn may exceed this count so the
  ///   transcript remains structurally valid.
  /// - Returns: A profile that trims its transcript to the specified window
  ///   size before each generation.
  public func rollingWindow(entries: Int) -> some DynamicProfile {
    rollingWindow(size: .entries(entries))
  }

  /// Returns a modified profile that keeps only the most recent complete
  /// conversation turns, discarding older turns each time a new prompt is
  /// sent.
  ///
  /// Use this modifier to bound transcript growth by maintaining a sliding
  /// window over the conversation history. Unlike the similar ``FoundationModels/LanguageModelSession/DynamicProfile/rollingWindow(entries:)``  which sets the window to a fixed int number of entries,
  /// this modifier uses ``RollingWindowSize`` which allows you to choose
  /// between different strategies for measuring the window's size.
  ///
  /// It composes well with other history modifiers — for example, applying
  /// ``droppingCompletedToolCalls()`` before a rolling window ensures that
  /// stale tool-call entries are removed first.
  ///
  /// ```swift
  /// Profile {
  ///     Instructions("You are a helpful assistant.")
  /// }
  /// .rollingWindow(size: .entries(10))
  /// .droppingCompletedToolCalls()
  /// ```
  ///
  /// - Parameter size: The size of the rolling window as determined the
  /// ``RollingWindowSize`` strategy.
  /// - Returns: A profile that trims its transcript to the specified window
  ///   size before each generation.
  public func rollingWindow(size: RollingWindowSize) -> some DynamicProfile {
    modifier(RollingWindowModifier(size: size))
  }
}

private struct RollingWindowModifier: LanguageModelSession.DynamicProfileModifier {
  @SessionProperty(\.history)
  private var history

  let size: RollingWindowSize

  func body(content: Content) -> some DynamicProfile {
    content.onPrompt {
      switch size {
      case .entries(let numberOfEntries):
        history = ArraySlice(wholeTurnSuffix(
          of: Array(history),
          preferredMaximumEntries: numberOfEntries
        ))
      }
    }
  }
}

/// Applies the rolling entry ceiling without retaining an orphaned response,
/// tool call, or tool output. A Foundation Models turn starts at a `.prompt`
/// and continues through every response/tool exchange up to the next prompt.
///
/// `onPrompt` can also run while a tool continuation is active. The suffix
/// from the last prompt is therefore the current turn and is indivisible even
/// when it alone exceeds the preferred ceiling. Older turns are retained only
/// when each complete turn fits. Any malformed leading entries before the
/// oldest retained prompt are deliberately discarded rather than promoted to
/// a structurally invalid history root.
func wholeTurnSuffix(
  of entries: [Transcript.Entry],
  preferredMaximumEntries: Int
) -> [Transcript.Entry] {
  guard let currentTurnStart = entries.lastIndex(where: { entry in
    if case .prompt = entry { return true }
    return false
  }) else {
    return []
  }

  let preferredMaximumEntries = max(0, preferredMaximumEntries)
  var retained = Array(entries[currentTurnStart...])
  var nextTurnStart = currentTurnStart

  while let previousTurnStart = entries[..<nextTurnStart].lastIndex(where: { entry in
    if case .prompt = entry { return true }
    return false
  }) {
    let previousTurn = entries[previousTurnStart..<nextTurnStart]
    guard retained.count + previousTurn.count <= preferredMaximumEntries else {
      break
    }
    retained.insert(contentsOf: previousTurn, at: retained.startIndex)
    nextTurnStart = previousTurnStart
  }

  return retained
}

/// A strategy to determine how the transcript window size is measured.
public enum RollingWindowSize: Sendable {
  /// Retain a fixed number of the _most recent_ entries in the transcript.
  /// If the number of total entries in the transcript is less than this number, all entries are kept.
  case entries(Int)
}
