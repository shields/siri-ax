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

public struct AskOptions: Sendable {
  public var timeout: Double
  public var settle: Double

  public init(timeout: Double = defaultTimeout, settle: Double = defaultSettle) {
    self.timeout = timeout
    self.settle = settle
  }
}

public let defaultTimeout = 20.0
public let timeoutRange = 1.0...120.0
public let defaultSettle = 1.2
public let settleRange = 0.4...30.0

public struct Asker {
  static let pollInterval = 0.4
  static let windowTimeout = 10.0
  static let newConversationTimeout = 5.0

  public let phraseGuard: PhraseGuard
  public let surface: any SiriSurface
  public let time: any Timekeeper

  public init(phraseGuard: PhraseGuard, surface: any SiriSurface, time: any Timekeeper) {
    self.phraseGuard = phraseGuard
    self.surface = surface
    self.time = time
  }

  /// Runs one request to completion. Never throws: every outcome is a result.
  public func ask(_ phrase: String, id: String? = nil, options: AskOptions = .init()) -> AskResult {
    let startedAt = time.now()
    let start = time.uptime()
    func finish(
      _ status: Status, parts: [AnswerPart] = [], settled: Bool = false, error: ErrorInfo? = nil
    ) -> AskResult {
      AskResult(
        id: id, status: status, phrase: phrase, answerParts: parts, settled: settled, error: error,
        startedAt: startedAt, finishedAt: time.now(),
        elapsedMilliseconds: Int(((time.uptime() - start) * 1000).rounded()))
    }

    let toSend: String
    switch phraseGuard.check(phrase) {
    case .refuse(let info): return finish(.refused, error: info)
    case .allow(let allowed): toSend = allowed
    }

    do {
      try surface.checkAvailable()
      try surface.ensureWindow(timeout: Self.windowTimeout)
      try surface.pressNewConversation()
      try waitForEmptyConversation()
      try surface.setPrompt(toSend)
      time.sleep(0.3)
      try surface.confirmPrompt()
      let (parts, settled) = try waitForAnswer(options: options)
      return finish(parts.isEmpty ? .noAnswer : .answered, parts: parts, settled: settled)
    } catch let failure as SiriFailure {
      return finish(.error, error: failure.info)
    } catch {
      return finish(.error, error: ErrorInfo(code: .axFailure, message: "\(error)"))
    }
  }

  private func waitForEmptyConversation() throws {
    let deadline = time.uptime() + Self.newConversationTimeout
    while true {
      if let tree = try surface.snapshot(),
        !tree.all(identifier: SiriIdentifiers.promptField).isEmpty,
        tree.all(identifier: SiriIdentifiers.modelResponse).isEmpty
      {
        return
      }
      if time.uptime() >= deadline {
        throw SiriFailure(
          .uiChanged, "no empty prompt field after pressing New Conversation")
      }
      time.sleep(0.1)
    }
  }

  private func waitForAnswer(options: AskOptions) throws -> ([AnswerPart], Bool) {
    var settler = AnswerSettler(quiet: options.settle)
    let deadline = time.uptime() + options.timeout
    while true {
      time.sleep(Self.pollInterval)
      let parts = try surface.snapshot().flatMap(AnswerReader.parts(in:)) ?? []
      if settler.observe(parts, at: time.uptime()) { return (parts, true) }
      if time.uptime() >= deadline { return (settler.current, false) }
    }
  }
}
