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

@Suite struct AnswerReaderTests {
  @Test func noResponseYet() {
    #expect(AnswerReader.parts(in: T.window(responses: [], prompt: "set lamp to red")) == nil)
  }

  @Test func interimText() {
    let tree = T.window(responses: [T.response(T.text("Searching for red"))], prompt: "x")
    #expect(AnswerReader.parts(in: tree) == [AnswerPart(kind: .text, text: "Searching for red")])
  }

  @Test func buttonOnlyAnswer() {
    let tree = T.window(responses: [T.response(T.button(description: "Lamp, Red"))])
    #expect(AnswerReader.parts(in: tree) == [AnswerPart(kind: .button, text: "Lamp, Red")])
  }

  @Test func textThenButtonInOrder() {
    let tree = T.window(responses: [
      T.response(
        T.text("Opening the Home app."),
        T.button(title: "Open the Home app", description: "ignored"))
    ])
    #expect(
      AnswerReader.parts(in: tree) == [
        AnswerPart(kind: .text, text: "Opening the Home app."),
        AnswerPart(kind: .button, text: "Open the Home app"),
      ])
  }

  @Test func usesTheLastResponse() {
    let tree = T.window(responses: [
      T.response(T.text("old")), T.response(T.text("Your Lamp can't do that.")),
    ])
    #expect(
      AnswerReader.parts(in: tree) == [
        AnswerPart(kind: .text, text: "Your Lamp can't do that.")
      ])
  }

  @Test func ignoresTheUserPromptAndBlankText() {
    let tree = T.window(
      responses: [T.response(T.text("  "), T.text(" Done \n"), T.button())], prompt: "set lamp")
    #expect(AnswerReader.parts(in: tree) == [AnswerPart(kind: .text, text: "Done")])
  }

  @Test func doesNotRepeatTextInsideALabelledButton() {
    let button = T.button(title: "Lamp, Red", children: [T.text("Lamp"), T.text("Red")])
    let tree = T.window(responses: [T.response(button)])
    #expect(AnswerReader.parts(in: tree) == [AnswerPart(kind: .button, text: "Lamp, Red")])
  }

  @Test func readsTextInsideAnUnlabelledButton() {
    let tree = T.window(responses: [T.response(T.button(children: [T.text("Inside")]))])
    #expect(AnswerReader.parts(in: tree) == [AnswerPart(kind: .text, text: "Inside")])
  }

  @Test func emptyResponseHasNoParts() {
    #expect(AnswerReader.parts(in: T.window(responses: [T.response()])) == [])
  }

  @Test func veryDeepTreesAreCut() {
    var node = T.text("deep")
    for _ in 0..<60 { node = UINode(role: "AXGroup", children: [node]) }
    let tree = UINode(identifier: "modelResponse", children: [node])
    #expect(AnswerReader.parts(in: tree) == [])
  }
}

@Suite struct AnswerSettlerTests {
  private let a = [AnswerPart(kind: .text, text: "a")]
  private let ab = [AnswerPart(kind: .text, text: "ab")]

  @Test func settlesAfterTheQuietPeriod() {
    var settler = AnswerSettler(quiet: 1.2)
    let r1 = settler.observe(a, at: 0)
    #expect(!r1)
    let r2 = settler.observe(a, at: 0.4)
    #expect(!r2)
    let r3 = settler.observe(a, at: 0.8)
    #expect(!r3)
    let r4 = settler.observe(a, at: 1.2)
    #expect(r4)
  }

  @Test func aChangeRestartsTheClock() {
    var settler = AnswerSettler(quiet: 1)
    _ = settler.observe(a, at: 0)
    let r5 = settler.observe(ab, at: 0.9)
    #expect(!r5)
    let r6 = settler.observe(ab, at: 1.5)
    #expect(!r6)
    let r7 = settler.observe(ab, at: 2.0)
    #expect(r7)
    #expect(settler.current == ab)
  }

  @Test func emptyNeverSettles() {
    var settler = AnswerSettler(quiet: 0.4)
    let r8 = settler.observe([], at: 0)
    #expect(!r8)
    let r9 = settler.observe([], at: 100)
    #expect(!r9)
  }
}

@Suite struct InterimTests {
  @Test func searchingTextIsNeverSettled() {
    var settler = AnswerSettler(quiet: 1)
    let parts = [AnswerPart(kind: .text, text: "Searching for red")]
    let first = settler.observe(parts, at: 0)
    let later = settler.observe(parts, at: 30)
    #expect(!first && !later)
  }

  @Test func otherTextSettles() {
    var settler = AnswerSettler(quiet: 1)
    let parts = [AnswerPart(kind: .text, text: "Your Lamp can't do that.")]
    let first = settler.observe(parts, at: 0)
    let later = settler.observe(parts, at: 1)
    #expect(!first && later)
  }
}
