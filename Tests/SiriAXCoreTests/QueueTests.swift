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

private final class Harness {
  let root: URL
  let surface = FakeSurface()
  let time = FakeTime()
  var events: [ServeEvent] = []
  var runner: QueueRunner!

  init(patterns: [String] = ["set lamp to [a-z ]+"], matchTimeout: Double = 2) throws {
    root = try temporaryDirectory().appending(path: "queue", directoryHint: .isDirectory)
    surface.answerScript = [T.window(responses: [T.response(T.text("Done"))])]
    let asker = Asker(
      phraseGuard: try PhraseGuard(GuardSettings(patterns: patterns), matchTimeout: matchTimeout),
      surface: surface, time: time)
    runner = QueueRunner(
      root: root, asker: asker, settle: 0.4, log: { [unowned self] in events.append($0) })
  }

  deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

  func submit(_ id: String, _ body: String) throws {
    let temporary = root.appending(path: "requests/.tmp-\(id)")
    try Data(body.utf8).write(to: temporary)
    try FileManager.default.moveItem(
      at: temporary, to: root.appending(path: "requests/\(id).json"))
  }

  func put(_ name: String, _ body: String) throws {
    try Data(body.utf8).write(to: root.appending(path: "requests/\(name)"))
  }

  func result(_ id: String) throws -> AskResult? {
    let url = root.appending(path: "results/\(id).json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try JSON.decoder().decode(AskResult.self, from: data)
  }

  func drain() throws {
    while try runner.processNext() {}
  }
}

@Suite struct QueueTests {
  @Test func preparesPrivateDirectories() throws {
    let h = try Harness()
    try h.runner.prepare()
    for name in ["requests", "claimed", "results"] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: h.root.appending(path: name).path)
      #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }
    try h.runner.prepare()
  }

  @Test func answersARequest() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("a1", #"{"phrase":"set lamp to red"}"#)
    #expect(try h.runner.processNext())
    let result = try #require(try h.result("a1"))
    #expect(result.status == .answered)
    #expect(result.id == "a1")
    #expect(result.answerText == "Done")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: h.root.appending(path: "requests").path)
        .isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: h.root.appending(path: "claimed").path)
        .isEmpty)
    #expect(!(try h.runner.processNext()))
    #expect(h.events.map(\.event) == [.request, .result])
    #expect(h.events.last?.status == .answered)
  }

  @Test func handlesRequestsInNameOrderOneAtATime() throws {
    let h = try Harness()
    try h.runner.prepare()
    for id in ["b", "10", "a", "2", "c"] {
      try h.submit(id, #"{"phrase":"set lamp to \#(id == "b" ? "blue" : "red")"}"#)
    }
    var order: [String] = []
    while try h.runner.processNext() { order.append(h.events.last!.id!) }
    #expect(order == ["10", "2", "a", "b", "c"])
    let started = try order.map { try #require(try h.result($0)).startedAt }
    #expect(started == started.sorted())
    #expect(h.surface.calls.filter { $0 == "confirmPrompt" }.count == 5)
  }

  @Test func ignoresPartialAndForeignFiles() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.put(".tmp-x", #"{"phrase":"set lamp to red"}"#)
    try h.put("x.json.tmp", #"{"phrase":"set lamp to red"}"#)
    try h.put("notes.txt", "hello")
    #expect(!(try h.runner.processNext()))
    #expect(h.surface.calls.isEmpty)
    #expect(h.events.isEmpty)
  }

  @Test(arguments: [
    "../x.json", "a b.json", ".json", "-a.json", "a.b.json", "A\u{0301}.json", "é.json", "a;b.json",
  ])
  func namesThatAreNotIdsAreIgnoredOnceAndNeverUsed(name: String) throws {
    let h = try Harness()
    try h.runner.prepare()
    if name.contains("/") {
      #expect(!QueueLayout.isValid(id: "../x"))
      return
    }
    try h.put(name, #"{"phrase":"set lamp to red"}"#)
    #expect(!(try h.runner.processNext()))
    #expect(!(try h.runner.processNext()))
    #expect(h.surface.calls.isEmpty)
    #expect(h.events.count == 1)
    #expect(h.events[0].event == .ignored)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: h.root.appending(path: "results").path)
        .isEmpty)
  }

  @Test func idValidity() {
    #expect(QueueLayout.isValid(id: "a"))
    #expect(QueueLayout.isValid(id: "20260101T120000-ab_c"))
    #expect(QueueLayout.isValid(id: String(repeating: "a", count: 64)))
    #expect(!QueueLayout.isValid(id: String(repeating: "a", count: 65)))
    #expect(!QueueLayout.isValid(id: ""))
    #expect(!QueueLayout.isValid(id: "_a"))
    #expect(!QueueLayout.isValid(id: "a/b"))
    #expect(!QueueLayout.isValid(id: ".."))
    #expect(QueueLayout.id(fromFileName: "a.json") == "a")
    #expect(QueueLayout.id(fromFileName: "a.txt") == nil)
  }

  @Test(arguments: [
    "not json", "", "[]", "{}", #"{"phrase":1}"#, #"{"phrase":"x","extra":1}"#,
    #"{"phrase":"x","timeout_seconds":"5"}"#, #"{"phrase":"x","timeout_seconds":true}"#,
    #"{"phrase":"x","path":"/etc/passwd"}"#, #"{"phrase":"x","id":"../y"}"#,
  ])
  func malformedRequestsGetAnErrorResult(body: String) throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("m", body)
    #expect(try h.runner.processNext())
    let result = try #require(try h.result("m"))
    #expect(result.status == .error)
    #expect(result.error?.code == .invalidRequest)
    #expect(result.id == "m")
    #expect(h.surface.calls.isEmpty)
  }

  @Test func theErrorForABadRequestDoesNotEchoItsContent() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("m", #"{"phrase":"x","secret-field":1}"#)
    _ = try h.runner.processNext()
    #expect(try !#require(try h.result("m")).error!.message.contains("secret-field"))
  }

  @Test func invalidUTF8IsMalformed() throws {
    let h = try Harness()
    try h.runner.prepare()
    try Data([0x7B, 0xFF, 0x7D]).write(to: h.root.appending(path: "requests/u.json"))
    _ = try h.runner.processNext()
    #expect(try h.result("u")?.error?.code == .invalidRequest)
  }

  @Test func oversizeRequestsAreRejected() throws {
    let h = try Harness()
    try h.runner.prepare()
    let padding = String(repeating: " ", count: 20_000)
    try h.submit("big", #"{"phrase":"set lamp to red"\#(padding)}"#)
    _ = try h.runner.processNext()
    #expect(try h.result("big")?.error?.code == .invalidRequest)
    #expect(h.surface.calls.isEmpty)
  }

  @Test(arguments: ["0", "0.5", "121", "-1", "1e9"])
  func timeoutOutsideBoundsIsRejected(timeout: String) throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("t", #"{"phrase":"set lamp to red","timeout_seconds":\#(timeout)}"#)
    _ = try h.runner.processNext()
    let result = try #require(try h.result("t"))
    #expect(result.error?.code == .invalidRequest)
    #expect(result.phrase == "set lamp to red")
    #expect(h.surface.calls.isEmpty)
  }

  @Test func timeoutWithinBoundsIsUsed() throws {
    let h = try Harness()
    h.surface.answerScript = [FakeTrees.window(responses: [])]
    try h.runner.prepare()
    try h.submit("t", #"{"phrase":"set lamp to red","timeout_seconds":3}"#)
    _ = try h.runner.processNext()
    let result = try #require(try h.result("t"))
    #expect(result.status == .noAnswer)
    #expect(result.elapsedMilliseconds >= 3000 && result.elapsedMilliseconds < 4000)
  }

  @Test func theGuardAppliesToQueuedPhrases() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("g", #"{"phrase":"call mom"}"#)
    _ = try h.runner.processNext()
    #expect(try h.result("g")?.status == .refused)
    #expect(h.surface.calls.isEmpty)
  }

  @Test func symlinkRequestsAreNeverFollowed() throws {
    let h = try Harness()
    try h.runner.prepare()
    let target = h.root.deletingLastPathComponent().appending(path: "secret.json")
    try Data(#"{"phrase":"set lamp to red"}"#.utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: h.root.appending(path: "requests/s.json"), withDestinationURL: target)
    _ = try h.runner.processNext()
    #expect(try h.result("s")?.error?.code == .invalidRequest)
    #expect(h.surface.calls.isEmpty)
    #expect(FileManager.default.fileExists(atPath: target.path))
  }

  @Test func nonRegularRequestsAreRejected() throws {
    let h = try Harness()
    try h.runner.prepare()
    #expect(mkfifo(h.root.appending(path: "requests/f.json").path, 0o600) == 0)
    try FileManager.default.createDirectory(
      at: h.root.appending(path: "requests/d.json"), withIntermediateDirectories: false)
    try h.drain()
    #expect(try h.result("f")?.error?.code == .invalidRequest)
    #expect(try h.result("d")?.error?.code == .invalidRequest)
  }

  @Test func aReusedIdIsNotAnsweredTwice() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("dup", #"{"phrase":"set lamp to red"}"#)
    _ = try h.runner.processNext()
    let first = try #require(try h.result("dup"))
    try h.submit("dup", #"{"phrase":"set lamp to blue"}"#)
    #expect(!(try h.runner.processNext()))
    #expect(try h.result("dup") == first)
    #expect(h.events.last?.event == .ignored)
    #expect(h.surface.calls.filter { $0 == "confirmPrompt" }.count == 1)
  }

  @Test func claimedRequestsFromACrashAreAnsweredAsInterrupted() throws {
    let h = try Harness()
    try h.runner.prepare()
    try Data(#"{"phrase":"set lamp to red"}"#.utf8).write(
      to: h.root.appending(path: "claimed/c.json"))
    try Data("junk".utf8).write(to: h.root.appending(path: "claimed/not an id"))
    try h.runner.prepare()
    let result = try #require(try h.result("c"))
    #expect(result.error?.code == .interrupted)
    #expect(h.surface.calls.isEmpty)
    #expect(h.events.map(\.event) == [.recovered])
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: h.root.appending(path: "claimed").path)
        .isEmpty)
  }

  @Test func aFinishedRequestLeftInClaimedIsJustRemoved() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("r", #"{"phrase":"set lamp to red"}"#)
    _ = try h.runner.processNext()
    let first = try #require(try h.result("r"))
    try Data("{}".utf8).write(to: h.root.appending(path: "claimed/r.json"))
    try h.runner.prepare()
    #expect(try h.result("r") == first)
  }

  @Test func runLoopStopsOnSignalAndPicksUpNewRequests() throws {
    let h = try Harness()
    var polls = 0
    h.time.onSleep = {
      polls += 1
      if polls == 2 { try? h.submit("late", #"{"phrase":"set lamp to red"}"#) }
    }
    try h.runner.prepare()
    var stopAfterResult = false
    try h.runner.run(shouldStop: {
      if (try? h.result("late")) != nil { stopAfterResult = true }
      return stopAfterResult
    })
    #expect(try h.result("late")?.status == .answered)
  }

  @Test func stopFlagIsCheckedBetweenRequests() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("a", #"{"phrase":"set lamp to red"}"#)
    try h.submit("b", #"{"phrase":"set lamp to red"}"#)
    var checks = 0
    try h.runner.run(shouldStop: {
      checks += 1
      return checks > 2
    })
    #expect(try h.result("a") != nil)
    #expect(try h.result("b") == nil)
  }

  @Test func unwritableQueueIsAFailure() throws {
    let h = try Harness()
    try Data().write(to: h.root.deletingLastPathComponent().appending(path: "file"))
    let blocked = QueueRunner(
      root: h.root.deletingLastPathComponent().appending(path: "file/queue"),
      asker: Asker(phraseGuard: try PhraseGuard(GuardSettings()), surface: h.surface, time: h.time),
      settle: 0.4, log: { _ in })
    #expect(throws: QueueFailure.self) { try blocked.prepare() }
  }

  @Test func resultWriteFailureStopsTheRunner() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("w", #"{"phrase":"set lamp to red"}"#)
    try FileManager.default.removeItem(at: h.root.appending(path: "results"))
    #expect(throws: QueueFailure.self) { _ = try h.runner.processNext() }
  }

  @Test func listingFailureStopsTheRunner() throws {
    let h = try Harness()
    #expect(throws: QueueFailure.self) { _ = try h.runner.processNext() }
  }

  @Test func reusedIdGetsARejectedFileAndKeepsTheOldResult() throws {
    let h = try Harness()
    try h.runner.prepare()
    try h.submit("a", #"{"phrase":"set lamp to red"}"#)
    try h.drain()
    try h.submit("a", #"{"phrase":"set lamp to blue"}"#)
    try h.drain()
    #expect(try h.result("a")?.phrase == "set lamp to red")
    let data = try Data(contentsOf: h.root.appending(path: "results/a.rejected.json"))
    let rejected = try JSON.decoder().decode(AskResult.self, from: data)
    #expect(rejected.error?.code == .invalidRequest)
    #expect(rejected.phrase == "set lamp to blue")
    #expect(h.surface.calls.filter { $0 == "confirmPrompt" }.count == 1)
  }

  @Test func guardTimeoutStopsTheRunner() throws {
    let h = try Harness(patterns: ["(a+)+$"], matchTimeout: 0.3)
    try h.runner.prepare()
    try h.submit("p", #"{"phrase":"\#(String(repeating: "a", count: 36))!"}"#)
    #expect(throws: QueueFailure.self) { _ = try h.runner.processNext() }
    #expect(try h.result("p")?.error?.code == .guardTimeout)
  }
}
