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
import SiriAXTestSupport
import Testing

@testable import SiriAXCore

private typealias T = FakeTrees

private func asker(_ surface: FakeSurface, _ time: FakeTime, patterns: [String] = [".+"]) throws
  -> Asker
{
  Asker(
    phraseGuard: try PhraseGuard(GuardSettings(patterns: patterns)), surface: surface, time: time)
}

@Suite struct AskerTests {
  @Test func answeredAndSettled() throws {
    let surface = FakeSurface()
    let time = FakeTime()
    surface.answerScript = [
      T.window(responses: []),
      T.window(responses: [T.response(T.text("Searching for red"))]),
      T.window(responses: [T.response(T.button(description: "Lamp, Red"))]),
    ]
    let result = try asker(surface, time).ask("set lamp to red")
    #expect(result.status == .answered)
    #expect(result.settled)
    #expect(result.answerParts == [AnswerPart(kind: .button, text: "Lamp, Red")])
    #expect(result.answerText == "Lamp, Red")
    #expect(result.phrase == "set lamp to red")
    #expect(result.error == nil)
    #expect(result.exitCode == 0)
    #expect(result.elapsedMilliseconds > 0)
    #expect(surface.prompt == "set lamp to red")
    #expect(
      surface.calls.filter { $0 != "snapshot" } == [
        "checkAvailable", "ensureWindow", "pressNewConversation", "setPrompt", "confirmPrompt",
      ])
  }

  @Test func sendsTheTrimmedPhrase() throws {
    let surface = FakeSurface()
    let result = try asker(surface, FakeTime()).ask("  hello  ")
    #expect(surface.prompt == "hello")
    #expect(result.phrase == "  hello  ")
  }

  @Test func timeoutWithPartialAnswerIsAnsweredButNotSettled() throws {
    let surface = FakeSurface()
    var step = 0
    surface.answerScript = (0..<200).map { _ in
      step += 1
      return T.window(responses: [T.response(T.text("part \(step)"))])
    }
    let result = try asker(surface, FakeTime()).ask(
      "x", options: AskOptions(timeout: 3, settle: 1.2))
    #expect(result.status == .answered)
    #expect(!result.settled)
    #expect(result.exitCode == 0)
  }

  @Test func noAnswerAtTimeout() throws {
    let surface = FakeSurface()
    let result = try asker(surface, FakeTime()).ask("x", options: AskOptions(timeout: 2))
    #expect(result.status == .noAnswer)
    #expect(result.answerParts.isEmpty)
    #expect(result.answerText == "")
    #expect(result.exitCode == 1)
    #expect(result.elapsedMilliseconds >= 2000)
  }

  @Test func windowVanishingMidAnswerCountsAsNoAnswer() throws {
    let surface = FakeSurface()
    surface.answerScript = [nil]
    #expect(
      try asker(surface, FakeTime()).ask("x", options: AskOptions(timeout: 1)).status == .noAnswer)
  }

  @Test func refusedNeverTouchesSiri() throws {
    let surface = FakeSurface()
    let result = try asker(surface, FakeTime(), patterns: ["set lamp to red"]).ask(
      "call mom", id: "r1")
    #expect(result.status == .refused)
    #expect(result.error?.code == .notAllowed)
    #expect(result.id == "r1")
    #expect(result.exitCode == 2)
    #expect(surface.calls.isEmpty)
  }

  @Test(arguments: [
    "checkAvailable", "ensureWindow", "pressNewConversation", "setPrompt", "confirmPrompt",
  ])
  func failuresBecomeErrorResults(step: String) throws {
    let surface = FakeSurface()
    surface.failAt = step
    surface.failure = SiriFailure(.accessibilityNotTrusted, "no permission")
    let result = try asker(surface, FakeTime()).ask("x")
    #expect(result.status == .error)
    #expect(result.error == ErrorInfo(code: .accessibilityNotTrusted, message: "no permission"))
    #expect(result.exitCode == 3)
    #expect(result.answerParts.isEmpty)
  }

  @Test func snapshotFailureDuringTheAnswer() throws {
    let surface = FakeSurface()
    surface.failAt = "snapshot"
    #expect(try asker(surface, FakeTime()).ask("x").status == .error)
  }

  @Test func otherErrorsBecomeAxFailure() throws {
    struct Odd: Error {}
    final class Throwing: SiriSurface {
      func checkAvailable() throws { throw Odd() }
      func ensureWindow(timeout: Double) throws {}
      func snapshot() throws -> UINode? { nil }
      func pressNewConversation() throws {}
      func setPrompt(_ phrase: String) throws {}
      func confirmPrompt() throws {}
    }
    let result = Asker(
      phraseGuard: try PhraseGuard(GuardSettings(patterns: [".+"])), surface: Throwing(),
      time: FakeTime()
    ).ask("x")
    #expect(result.error?.code == .axFailure)
  }

  @Test func staleConversationIsAUiChange() throws {
    let surface = FakeSurface()
    surface.windowWithPromptField = false
    let result = try asker(surface, FakeTime()).ask("x")
    #expect(result.error?.code == .uiChanged)
    #expect(!surface.calls.contains("setPrompt"))
  }
}
