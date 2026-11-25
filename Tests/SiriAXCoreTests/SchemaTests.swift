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
import Testing

@testable import SiriAXCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000.125)
private let t1 = Date(timeIntervalSince1970: 1_800_000_003.5)

private func object(_ value: some Encodable) throws -> [String: Any] {
  let data = Data(JSON.line(value).utf8)
  return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let resultKeys: Set = [
  "schema", "command", "id", "status", "phrase", "answer_text", "answer_parts", "settled", "error",
  "started_at", "finished_at", "elapsed_ms",
]

@Suite struct SchemaTests {
  @Test func answered() throws {
    let result = AskResult(
      id: "a1", status: .answered, phrase: "set lamp to red",
      answerParts: [
        AnswerPart(kind: .text, text: "Done"), AnswerPart(kind: .button, text: "Lamp, Red"),
      ], settled: true, startedAt: t0, finishedAt: t1, elapsedMilliseconds: 3333)
    #expect(
      JSON.line(result)
        == #"{"answer_parts":[{"kind":"text","text":"Done"},{"kind":"button","text":"Lamp, Red"}],"answer_text":"Done\nLamp, Red","command":"ask","elapsed_ms":3333,"error":null,"finished_at":"2027-01-15T08:00:03.500Z","id":"a1","phrase":"set lamp to red","schema":1,"settled":true,"started_at":"2027-01-15T08:00:00.125Z","status":"answered"}"#
    )
    #expect(result.exitCode == 0)
  }

  @Test func noAnswer() throws {
    let result = AskResult(
      status: .noAnswer, phrase: "set lamp to red", startedAt: t0, finishedAt: t1,
      elapsedMilliseconds: 20000)
    let json = try object(result)
    #expect(Set(json.keys) == resultKeys)
    #expect(json["status"] as? String == "no_answer")
    #expect(json["id"] is NSNull)
    #expect(json["error"] is NSNull)
    #expect(json["answer_text"] as? String == "")
    #expect((json["answer_parts"] as? [Any])?.isEmpty == true)
    #expect(result.exitCode == 1)
  }

  @Test func refused() throws {
    let result = AskResult(
      status: .refused, phrase: "call mom",
      error: ErrorInfo(code: .notAllowed, message: "the phrase matches no allow pattern"),
      startedAt: t0, finishedAt: t0, elapsedMilliseconds: 0)
    let json = try object(result)
    #expect(Set(json.keys) == resultKeys)
    #expect(json["status"] as? String == "refused")
    let error = try #require(json["error"] as? [String: String])
    #expect(error["code"] == "not_allowed")
    #expect(result.exitCode == 2)
  }

  @Test func errorAndUsage() throws {
    let failed = AskResult(
      status: .error, phrase: nil,
      error: ErrorInfo(code: .accessibilityNotTrusted, message: "m"), startedAt: t0,
      finishedAt: t0, elapsedMilliseconds: 0)
    #expect(try object(failed)["phrase"] is NSNull)
    #expect(failed.exitCode == 3)
    var usage = failed
    usage.error = ErrorInfo(code: .usage, message: "m")
    #expect(usage.exitCode == 64)
  }

  @Test func roundTrips() throws {
    let result = AskResult(
      id: "x", status: .answered, phrase: "p", answerParts: [AnswerPart(kind: .text, text: "t")],
      settled: true, error: nil, startedAt: t0, finishedAt: t1, elapsedMilliseconds: 5)
    let decoded = try JSON.decoder().decode(AskResult.self, from: Data(JSON.line(result).utf8))
    #expect(decoded == result)
  }

  @Test func timestampsDecodeOnlyInTheDocumentedForm() {
    let json = Data(
      JSON.line(
        AskResult(
          status: .noAnswer, phrase: nil, startedAt: t0, finishedAt: t0, elapsedMilliseconds: 0)
      )
      .replacingOccurrences(of: "2027-01-15T08:00:00.125Z", with: "yesterday").utf8)
    #expect(throws: DecodingError.self) { try JSON.decoder().decode(AskResult.self, from: json) }
  }

  @Test func outputIsOneLineWithEscapedControlCharacters() {
    let result = AskResult(
      status: .answered, phrase: "a\nb\u{2028}\"c\"/",
      answerParts: [AnswerPart(kind: .text, text: "x\ny")],
      startedAt: t0, finishedAt: t0, elapsedMilliseconds: 0)
    let line = JSON.line(result)
    #expect(!line.contains("\n"))
    #expect(line.contains(#"\"c\"/"#))
  }

  @Test func doctor() throws {
    let report = DoctorReport(
      status: .notReady,
      checks: DoctorChecks(
        accessibilityTrusted: false, siriInstalled: true, siriRunning: false, siriHasWindow: false,
        macOSVersion: "27.2.1"),
      problems: [ErrorInfo(code: .accessibilityNotTrusted, message: "m")], checkedAt: t0)
    let json = try object(report)
    #expect(Set(json.keys) == ["schema", "command", "status", "checks", "problems", "checked_at"])
    #expect(json["status"] as? String == "not_ready")
    #expect(
      Set((json["checks"] as! [String: Any]).keys) == [
        "accessibility_trusted", "siri_installed", "siri_running", "siri_has_window",
        "macos_version",
      ])
    #expect(report.exitCode == 1)
    #expect(
      try JSON.decoder().decode(DoctorReport.self, from: Data(JSON.line(report).utf8)) == report)
    var ready = report
    ready.status = .ready
    #expect(ready.exitCode == 0)
  }

  @Test func serveEvents() throws {
    let event = ServeEvent(event: .result, time: t0, id: "a", status: .refused)
    let json = try object(event)
    #expect(Set(json.keys) == ["schema", "event", "time", "id", "status", "detail"])
    #expect(json["detail"] is NSNull)
    #expect(try JSON.decoder().decode(ServeEvent.self, from: Data(JSON.line(event).utf8)) == event)
  }

  @Test func everyStatusAndCodeHasAStableName() {
    #expect(Status.allCases.map(\.rawValue) == ["answered", "no_answer", "refused", "error"])
    for code in ErrorCode.allCases {
      #expect(code.rawValue == code.rawValue.lowercased())
      #expect(!code.rawValue.contains(" "))
    }
  }
}
