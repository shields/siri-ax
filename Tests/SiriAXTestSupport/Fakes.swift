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
import SiriAXCore

public final class FakeTime: Timekeeper {
  public private(set) var elapsed = 0.0
  public let start = Date(timeIntervalSince1970: 1_800_000_000)
  public var onSleep: (() -> Void)?

  public init() {}

  public func uptime() -> Double { elapsed }
  public func now() -> Date { start.addingTimeInterval(elapsed) }

  public func sleep(_ seconds: Double) {
    elapsed += seconds
    onSleep?()
  }
}

/// A Siri AI window that records what it is asked to do. After `confirmPrompt`, snapshots come
/// from `answerScript`, one per call, the last repeating. Before that, the conversation is empty.
public final class FakeSurface: SiriSurface {
  public var calls: [String] = []
  public var prompt: String?
  public var answerScript: [UINode?] = []
  public var failAt: String?
  public var failure = SiriFailure(.axFailure, "scripted failure")
  public var windowAppearsAfterNewConversation = true
  private var confirmed = false
  private var answerIndex = 0

  public init() {}

  private func step(_ name: String) throws {
    calls.append(name)
    if failAt == name { throw failure }
  }

  public func checkAvailable() throws { try step("checkAvailable") }
  public func ensureWindow(timeout: Double) throws { try step("ensureWindow") }

  public func snapshot() throws -> UINode? {
    try step("snapshot")
    if !confirmed {
      return windowWithPromptField
        ? FakeTrees.window(responses: [], promptValue: promptFieldValue) : nil
    }
    let node =
      answerScript.isEmpty
      ? FakeTrees.window(responses: []) : answerScript[min(answerIndex, answerScript.count - 1)]
    answerIndex += 1
    return node
  }

  public var windowWithPromptField = true
  public var promptFieldValue: String?

  public func pressNewConversation() throws {
    try step("pressNewConversation")
    confirmed = false
  }

  public func setPrompt(_ phrase: String) throws {
    try step("setPrompt")
    prompt = phrase
  }

  public func confirmPrompt() throws {
    try step("confirmPrompt")
    confirmed = true
  }
}

public enum FakeTrees {
  public static func text(_ value: String) -> UINode {
    UINode(role: "AXStaticText", value: value)
  }

  public static func button(
    title: String? = nil, description: String? = nil, children: [UINode] = []
  )
    -> UINode
  {
    UINode(role: "AXButton", title: title, descriptionText: description, children: children)
  }

  public static func response(_ children: UINode...) -> UINode {
    UINode(
      role: "AXGroup", identifier: "modelResponse",
      children: [
        UINode(role: "AXGroup", children: children)
      ])
  }

  /// A tree shaped like the observed Siri AI window.
  public static func window(responses: [UINode], prompt: String? = nil, promptValue: String? = nil)
    -> UINode
  {
    var transcript: [UINode] = []
    if let prompt {
      transcript.append(
        UINode(
          role: "AXGroup", identifier: "userPrompt", children: [text(prompt)]))
    }
    transcript += responses
    return UINode(
      role: "AXWindow",
      children: [
        UINode(
          role: "AXToolbar",
          children: [
            UINode(
              role: "AXButton", identifier: "newChatButton", descriptionText: "New Conversation")
          ]),
        UINode(
          role: "AXGroup",
          children: [
            UINode(
              role: "AXScrollArea", identifier: "transcriptScrollView", children: transcript),
            UINode(role: "AXTextField", identifier: "promptViewTextField", value: promptValue),
          ]),
      ])
  }
}

public struct FakeProbe: SystemProbe {
  public var trusted = true
  public var installed = true
  public var running = true
  public var windows = 1
  public var version = "27.2.1"

  public init() {}

  public func accessibilityTrusted() -> Bool { trusted }
  public func siriInstalled() -> Bool { installed }
  public func siriRunning() -> Bool { running }
  public func siriWindowCount() -> Int { windows }
  public func macOSVersion() -> String { version }
}

public func temporaryDirectory() throws -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appending(path: "siri-ax-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
