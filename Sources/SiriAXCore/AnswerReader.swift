// Copyright © 2026 Michael Shields
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

public enum AnswerReader {
  static let maxDepth = 40

  /// The parts of the last `modelResponse` in the tree, in document order: each non-empty static
  /// text is a text part, and each button is a button part labelled by its title or, failing
  /// that, its description. A button that has a label is not searched further, so text inside it
  /// is not repeated. Returns nil when there is no response yet.
  public static func parts(in tree: UINode) -> [AnswerPart]? {
    guard let response = tree.all(identifier: SiriIdentifiers.modelResponse).last else {
      return nil
    }
    var parts: [AnswerPart] = []
    collect(response, into: &parts, depth: 0)
    return parts
  }

  private static func collect(_ node: UINode, into parts: inout [AnswerPart], depth: Int) {
    if depth > maxDepth { return }
    if node.role == "AXStaticText", let text = clean(node.value) {
      parts.append(AnswerPart(kind: .text, text: text))
    } else if node.role == "AXButton", let label = clean(node.title) ?? clean(node.descriptionText)
    {
      parts.append(AnswerPart(kind: .button, text: label))
      return
    }
    for child in node.children { collect(child, into: &parts, depth: depth + 1) }
  }

  private static func clean(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

/// Decides when a streaming answer has stopped changing: when the parts are non-empty and have
/// been the same for at least `quiet` seconds.
public struct AnswerSettler {
  public let quiet: Double
  private var last: [AnswerPart] = []
  private var since = 0.0

  public init(quiet: Double) { self.quiet = quiet }

  /// Records a read at `time` (monotonic seconds) and returns whether the answer is settled.
  public mutating func observe(_ parts: [AnswerPart], at time: Double) -> Bool {
    if parts != last {
      last = parts
      since = time
    }
    return !parts.isEmpty && time - since >= quiet
  }

  public var current: [AnswerPart] { last }
}
