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

@testable import SiriAXCLI
@testable import SiriAXCore

private typealias T = FakeTrees

private final class Capture {
  var out: [String] = []
  var err: [String] = []
  let surface = FakeSurface()
  let time = FakeTime()
  var probe = FakeProbe()
  var files: [String: Data] = [:]
  var stopAfterPolls = 3

  init() {
    surface.answerScript = [T.window(responses: [T.response(T.text("Done"))])]
  }

  var environment: Environment {
    Environment(
      surface: { self.surface }, probe: probe, time: time,
      readFile: { path in
        guard let data = self.files[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
      },
      out: { self.out.append($0) }, err: { self.err.append($0) },
      watchStopSignals: {
        var polls = 0
        return {
          polls += 1
          return polls > self.stopAfterPolls
        }
      })
  }

  func run(_ arguments: String...) -> Int32 {
    CLI.run(arguments, environment: environment)
  }

  /// Every stdout line parsed as a JSON object.
  func lines() throws -> [[String: Any]] {
    try out.map {
      try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }

  func only() throws -> [String: Any] {
    let all = try lines()
    #expect(all.count == 1)
    return all[0]
  }
}

private let allowRed = ["--allow", "set lamp to (red|blue)"]

@Suite struct AskCommandTests {
  @Test func answers() throws {
    let c = Capture()
    #expect(c.run("ask", allowRed[0], allowRed[1], "set lamp to red") == 0)
    let json = try c.only()
    #expect(json["status"] as? String == "answered")
    #expect(json["answer_text"] as? String == "Done")
    #expect(json["phrase"] as? String == "set lamp to red")
    #expect(json["id"] is NSNull)
    #expect(c.err.isEmpty)
  }

  @Test func refusesWithoutAnyPattern() throws {
    let c = Capture()
    #expect(c.run("ask", "set lamp to red") == 2)
    let json = try c.only()
    #expect(json["status"] as? String == "refused")
    #expect((json["error"] as? [String: String])?["code"] == "no_patterns")
    #expect(c.surface.calls.isEmpty)
  }

  @Test func refusesPhraseOutsideTheAllowlist() throws {
    let c = Capture()
    #expect(c.run("ask", allowRed[0], allowRed[1], "call mom") == 2)
    #expect(try c.only()["status"] as? String == "refused")
  }

  @Test func readsTheGuardFile() throws {
    let c = Capture()
    c.files["g.conf"] = Data("allow = set lamp to red\nmax_length = 10\n".utf8)
    #expect(c.run("ask", "--guard", "g.conf", "set lamp to red") == 2)
    #expect((try c.only()["error"] as? [String: String])?["code"] == "too_long")
  }

  @Test func guardFileAndAllowCombine() throws {
    let c = Capture()
    c.files["g.conf"] = Data("allow = set lamp to red\n".utf8)
    #expect(c.run("ask", "--guard", "g.conf", "--allow", "hello", "hello") == 0)
  }

  @Test func missingOrBadGuardIsAConfigError() throws {
    let c = Capture()
    #expect(c.run("ask", "--guard", "nope.conf", "x") == 3)
    var json = try c.only()
    #expect((json["error"] as? [String: String])?["code"] == "config_invalid")
    #expect(json["phrase"] as? String == "x")

    let d = Capture()
    d.files["bad.conf"] = Data("bogus = 1".utf8)
    #expect(d.run("ask", "--guard", "bad.conf", "x") == 3)
    #expect((try d.only()["error"] as? [String: String])?["code"] == "config_invalid")

    let e = Capture()
    #expect(e.run("ask", "--allow", "(", "x") == 3)
    json = try e.only()
    #expect(json["status"] as? String == "error")
    #expect(e.surface.calls.isEmpty)
  }

  @Test func timeoutAndSettleOptionsAreUsed() throws {
    let c = Capture()
    c.surface.answerScript = [nil]
    #expect(c.run("ask", "--allow", ".+", "--timeout", "2", "--settle", "0.5", "x") == 1)
    let json = try c.only()
    #expect(json["status"] as? String == "no_answer")
    #expect((json["elapsed_ms"] as? Int ?? 0) >= 2000)
  }

  @Test func dashPhraseAfterSeparator() throws {
    let c = Capture()
    #expect(c.run("ask", "--allow", ".+", "--", "-5") == 0)
    #expect(c.surface.prompt == "-5")
  }

  @Test(arguments: [
    ["ask"], ["ask", "--timeout", "0", "x"], ["ask", "--timeout", "121", "x"],
    ["ask", "--settle", "0.1", "x"], ["ask", "--bogus", "x"], ["ask", "a", "b"],
    ["ask", "--timeout", "abc", "x"],
  ])
  func usageErrorsAreJSONOnStdout(arguments: [String]) throws {
    let c = Capture()
    #expect(CLI.run(arguments, environment: c.environment) == 64)
    let json = try c.only()
    #expect(json["status"] as? String == "error")
    #expect(json["command"] as? String == "ask")
    #expect((json["error"] as? [String: String])?["code"] == "usage")
    #expect(c.err.isEmpty)
  }
}

@Suite struct OtherCommandTests {
  @Test func helpGoesToStderrOnly() throws {
    for arguments in [["--help"], ["ask", "--help"], ["serve", "-h"], ["doctor", "--help"]] {
      let c = Capture()
      #expect(CLI.run(arguments, environment: c.environment) == 0)
      #expect(c.out.isEmpty)
      #expect(c.err.joined().contains("USAGE"))
    }
  }

  @Test(arguments: [[], ["bogus"], ["--bogus"]])
  func rootUsageErrors(arguments: [String]) throws {
    let c = Capture()
    #expect(CLI.run(arguments, environment: c.environment) == 64)
    let json = try c.only()
    #expect(json["status"] as? String == "error")
    #expect(json["command"] is NSNull)
    #expect(json["schema"] as? Int == 1)
  }

  @Test func serveUsageErrorNamesTheCommand() throws {
    let c = Capture()
    #expect(c.run("serve") == 64)
    #expect(try c.only()["command"] as? String == "serve")
    let e = Capture()
    #expect(e.run("serve", "--settle", "99", "/q") == 64)
    #expect(try e.only()["command"] as? String == "serve")
    let d = Capture()
    #expect(d.run("doctor", "extra") == 64)
    #expect(try d.only()["command"] as? String == "doctor")
  }

  @Test func doctorReady() throws {
    let c = Capture()
    #expect(c.run("doctor") == 0)
    let json = try c.only()
    #expect(json["status"] as? String == "ready")
    #expect(json["command"] as? String == "doctor")
  }

  @Test func doctorNotReady() throws {
    let c = Capture()
    c.probe.trusted = false
    #expect(c.run("doctor") == 1)
    let json = try c.only()
    #expect(json["status"] as? String == "not_ready")
    #expect(
      (json["problems"] as? [[String: String]])?.first?["code"] == "accessibility_not_trusted")
  }

  @Test func serveAnswersTheQueueAndStops() throws {
    let c = Capture()
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queue = dir.appending(path: "q")
    let requests = queue.appending(path: "requests")
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    try Data(#"{"phrase":"set lamp to red"}"#.utf8).write(
      to: requests.appending(path: "one.json"))
    #expect(c.run("serve", "--allow", "set lamp to red", queue.path) == 0)
    let events = try c.lines()
    #expect(events.map { $0["event"] as? String } == ["started", "request", "result", "stopped"])
    #expect(events[2]["status"] as? String == "answered")
    #expect(events[2]["id"] as? String == "one")
    #expect(
      events[0]["detail"] as? String
        == "queue \(queue.standardizedFileURL.path); 1 patterns; max length 100")
    let result = try Data(contentsOf: queue.appending(path: "results/one.json"))
    #expect(try JSON.decoder().decode(AskResult.self, from: result).answerText == "Done")
  }

  @Test func serveRefusesToStartWithoutAccessibility() throws {
    let c = Capture()
    c.surface.failAt = "checkAvailable"
    c.surface.failure = SiriFailure(.accessibilityNotTrusted, "no permission")
    #expect(c.run("serve", "--allow", ".+", "/nonexistent-queue") == 3)
    let json = try c.only()
    #expect(json["command"] as? String == "serve")
    #expect((json["error"] as? [String: String])?["code"] == "accessibility_not_trusted")
  }

  @Test func serveReportsOtherStartupFailureAsAxFailure() throws {
    struct Odd: Error {}
    final class Throwing: SiriSurface {
      func checkAvailable() throws { throw Odd() }
      func ensureWindow(timeout: Double) throws {}
      func snapshot() throws -> UINode? { nil }
      func pressNewConversation() throws {}
      func setPrompt(_ phrase: String) throws {}
      func confirmPrompt() throws {}
    }
    let c = Capture()
    var environment = c.environment
    environment.surface = { Throwing() }
    #expect(CLI.run(["serve", "--allow", ".+", "/q"], environment: environment) == 3)
    #expect((try c.only()["error"] as? [String: String])?["code"] == "ax_failure")
  }

  @Test func serveReportsBadGuardAndBadQueue() throws {
    let c = Capture()
    #expect(c.run("serve", "--guard", "missing", "/q") == 3)
    #expect((try c.only()["error"] as? [String: String])?["code"] == "config_invalid")

    let d = Capture()
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appending(path: "file"))
    #expect(d.run("serve", "--allow", ".+", dir.appending(path: "file/q").path) == 3)
    let json = try d.only()
    #expect((json["error"] as? [String: String])?["code"] == "queue_failure")
  }

  @Test func serveWithNoPatternsStartsAndRefuses() throws {
    let c = Capture()
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requests = dir.appending(path: "q/requests")
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    try Data(#"{"phrase":"set lamp to red"}"#.utf8).write(
      to: requests.appending(path: "one.json"))
    #expect(c.run("serve", dir.appending(path: "q").path) == 0)
    #expect(try c.lines()[2]["status"] as? String == "refused")
  }
}
