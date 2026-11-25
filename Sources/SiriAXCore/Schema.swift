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

public let schemaVersion = 1

public enum ErrorCode: String, Codable, Sendable, CaseIterable {
  // Guard refusals (status "refused").
  case noPatterns = "no_patterns"
  case emptyPhrase = "empty_phrase"
  case tooLong = "too_long"
  case controlCharacter = "control_character"
  case nonASCII = "non_ascii"
  case notAllowed = "not_allowed"
  // Failures (status "error").
  case usage
  case configInvalid = "config_invalid"
  case invalidRequest = "invalid_request"
  case interrupted
  case accessibilityNotTrusted = "accessibility_not_trusted"
  case siriNotInstalled = "siri_not_installed"
  case siriNoWindow = "siri_no_window"
  case uiChanged = "ui_changed"
  case axFailure = "ax_failure"
  case queueFailure = "queue_failure"
  case guardTimeout = "guard_timeout"
}

public enum Status: String, Codable, Sendable, CaseIterable {
  case answered
  case noAnswer = "no_answer"
  case refused
  case error
}

public struct ErrorInfo: Codable, Equatable, Sendable {
  public var code: ErrorCode
  public var message: String

  public init(code: ErrorCode, message: String) {
    self.code = code
    self.message = message
  }
}

public struct AnswerPart: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case text
    case button
  }

  public var kind: Kind
  public var text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// The result of one request. Every key is always present; absent values are `null`.
public struct AskResult: Codable, Equatable, Sendable {
  public var id: String?
  public var status: Status
  public var phrase: String?
  public var answerParts: [AnswerPart]
  public var settled: Bool
  public var error: ErrorInfo?
  public var startedAt: Date
  public var finishedAt: Date
  public var elapsedMilliseconds: Int

  public init(
    id: String? = nil, status: Status, phrase: String?, answerParts: [AnswerPart] = [],
    settled: Bool = false, error: ErrorInfo? = nil, startedAt: Date, finishedAt: Date,
    elapsedMilliseconds: Int
  ) {
    self.id = id
    self.status = status
    self.phrase = phrase
    self.answerParts = answerParts
    self.settled = settled
    self.error = error
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.elapsedMilliseconds = elapsedMilliseconds
  }

  public var answerText: String {
    answerParts.map(\.text).joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schema, command, id, status, phrase
    case answerText = "answer_text"
    case answerParts = "answer_parts"
    case settled, error
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case elapsedMilliseconds = "elapsed_ms"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schema)
    try container.encode("ask", forKey: .command)
    try container.encode(id, forKey: .id)
    try container.encode(status, forKey: .status)
    try container.encode(phrase, forKey: .phrase)
    try container.encode(answerText, forKey: .answerText)
    try container.encode(answerParts, forKey: .answerParts)
    try container.encode(settled, forKey: .settled)
    try container.encode(error, forKey: .error)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(finishedAt, forKey: .finishedAt)
    try container.encode(elapsedMilliseconds, forKey: .elapsedMilliseconds)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String?.self, forKey: .id)
    status = try container.decode(Status.self, forKey: .status)
    phrase = try container.decode(String?.self, forKey: .phrase)
    answerParts = try container.decode([AnswerPart].self, forKey: .answerParts)
    settled = try container.decode(Bool.self, forKey: .settled)
    error = try container.decode(ErrorInfo?.self, forKey: .error)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    finishedAt = try container.decode(Date.self, forKey: .finishedAt)
    elapsedMilliseconds = try container.decode(Int.self, forKey: .elapsedMilliseconds)
  }

  /// Process exit code for this status: 0 answered, 1 no_answer, 2 refused, 3 error. A usage
  /// error is status "error" and exits 64.
  public var exitCode: Int32 {
    if status == .error && error?.code == .usage { return 64 }
    switch status {
    case .answered: return 0
    case .noAnswer: return 1
    case .refused: return 2
    case .error: return 3
    }
  }
}

public struct DoctorChecks: Codable, Equatable, Sendable {
  public var accessibilityTrusted: Bool
  public var siriInstalled: Bool
  public var siriRunning: Bool
  public var siriHasWindow: Bool
  public var macOSVersion: String

  public init(
    accessibilityTrusted: Bool, siriInstalled: Bool, siriRunning: Bool, siriHasWindow: Bool,
    macOSVersion: String
  ) {
    self.accessibilityTrusted = accessibilityTrusted
    self.siriInstalled = siriInstalled
    self.siriRunning = siriRunning
    self.siriHasWindow = siriHasWindow
    self.macOSVersion = macOSVersion
  }

  enum CodingKeys: String, CodingKey {
    case accessibilityTrusted = "accessibility_trusted"
    case siriInstalled = "siri_installed"
    case siriRunning = "siri_running"
    case siriHasWindow = "siri_has_window"
    case macOSVersion = "macos_version"
  }
}

public struct DoctorReport: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case ready
    case notReady = "not_ready"
  }

  public var status: State
  public var checks: DoctorChecks
  public var problems: [ErrorInfo]
  public var checkedAt: Date

  public init(status: State, checks: DoctorChecks, problems: [ErrorInfo], checkedAt: Date) {
    self.status = status
    self.checks = checks
    self.problems = problems
    self.checkedAt = checkedAt
  }

  enum CodingKeys: String, CodingKey {
    case schema, command, status, checks, problems
    case checkedAt = "checked_at"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schema)
    try container.encode("doctor", forKey: .command)
    try container.encode(status, forKey: .status)
    try container.encode(checks, forKey: .checks)
    try container.encode(problems, forKey: .problems)
    try container.encode(checkedAt, forKey: .checkedAt)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(State.self, forKey: .status)
    checks = try container.decode(DoctorChecks.self, forKey: .checks)
    problems = try container.decode([ErrorInfo].self, forKey: .problems)
    checkedAt = try container.decode(Date.self, forKey: .checkedAt)
  }

  public var exitCode: Int32 { status == .ready ? 0 : 1 }
}

/// A status line from `serve`, written to stdout as JSON Lines.
public struct ServeEvent: Codable, Equatable, Sendable {
  public enum Name: String, Codable, Sendable {
    case started
    case request
    case result
    case ignored
    case recovered
    case stopped
  }

  public var event: Name
  public var time: Date
  public var id: String?
  public var status: Status?
  public var detail: String?

  public init(
    event: Name, time: Date, id: String? = nil, status: Status? = nil, detail: String? = nil
  ) {
    self.event = event
    self.time = time
    self.id = id
    self.status = status
    self.detail = detail
  }

  enum CodingKeys: String, CodingKey {
    case schema, event, time, id, status, detail
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schema)
    try container.encode(event, forKey: .event)
    try container.encode(time, forKey: .time)
    try container.encode(id, forKey: .id)
    try container.encode(status, forKey: .status)
    try container.encode(detail, forKey: .detail)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    event = try container.decode(Name.self, forKey: .event)
    time = try container.decode(Date.self, forKey: .time)
    id = try container.decode(String?.self, forKey: .id)
    status = try container.decode(Status?.self, forKey: .status)
    detail = try container.decode(String?.self, forKey: .detail)
  }
}

public enum JSON {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(timestamp(date))
    }
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      guard let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
      else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "bad timestamp"))
      }
      return date
    }
    return decoder
  }

  public static func timestamp(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }

  public static func line(_ value: some Encodable) -> String {
    // These types hold only strings, numbers, and dates, which always encode.
    String(decoding: try! encoder().encode(value), as: UTF8.self)
  }
}
