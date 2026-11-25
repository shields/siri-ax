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

public let defaultMaxLength = 100
public let hardMaxLength = 200
let maxPatternLength = 500
let maxPatterns = 100
let maxConfigBytes = 64 * 1024

public struct GuardConfigError: Error, Equatable, CustomStringConvertible {
  public var message: String
  public var description: String { message }

  public init(_ message: String) { self.message = message }
}

/// The parsed guard configuration: what the human who starts `ask` or `serve` allows.
public struct GuardSettings: Equatable, Sendable {
  public var patterns: [String] = []
  public var maxLength = defaultMaxLength
  public var allowNonASCII = false

  public init(
    patterns: [String] = [], maxLength: Int = defaultMaxLength, allowNonASCII: Bool = false
  ) {
    self.patterns = patterns
    self.maxLength = maxLength
    self.allowNonASCII = allowNonASCII
  }

  /// Parses the configuration file format: one `key = value` per line; blank lines and lines
  /// starting with `#` are ignored. Keys are `allow` (repeatable), `max_length`, and `non_ascii`.
  public static func parse(_ data: Data) throws -> GuardSettings {
    guard data.count <= maxConfigBytes else {
      throw GuardConfigError("guard file is larger than \(maxConfigBytes) bytes")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw GuardConfigError("guard file is not valid UTF-8")
    }
    var settings = GuardSettings()
    var seen: Set<String> = []
    for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let number = index + 1
      guard let equals = line.firstIndex(of: "=") else {
        throw GuardConfigError("line \(number): expected key = value")
      }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.isEmpty { throw GuardConfigError("line \(number): empty value for \(key)") }
      switch key {
      case "allow":
        settings.patterns.append(value)
      case "max_length":
        guard seen.insert(key).inserted else {
          throw GuardConfigError("line \(number): max_length is set twice")
        }
        guard let length = Int(value), (1...hardMaxLength).contains(length) else {
          throw GuardConfigError("line \(number): max_length must be 1 to \(hardMaxLength)")
        }
        settings.maxLength = length
      case "non_ascii":
        guard seen.insert(key).inserted else {
          throw GuardConfigError("line \(number): non_ascii is set twice")
        }
        switch value {
        case "allow": settings.allowNonASCII = true
        case "deny": settings.allowNonASCII = false
        default: throw GuardConfigError("line \(number): non_ascii must be allow or deny")
        }
      default:
        throw GuardConfigError("line \(number): unknown key \(key)")
      }
    }
    return settings
  }
}

public enum GuardDecision: Equatable, Sendable {
  case allow(String)
  case refuse(ErrorInfo)
  case timedOut(ErrorInfo)
}

final class MatchBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?
  func set(_ matched: Bool) {
    lock.lock()
    value = matched
    lock.unlock()
  }
  func get() -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Decides whether a phrase may be sent to Siri. Fails closed: with no patterns, nothing passes.
public struct PhraseGuard: Sendable {
  private let expressions: [NSRegularExpression]
  public let maxLength: Int
  public let allowNonASCII: Bool
  public let matchTimeout: Double

  public var patternCount: Int { expressions.count }

  public init(_ settings: GuardSettings, matchTimeout: Double = 2) throws {
    self.matchTimeout = matchTimeout
    guard settings.patterns.count <= maxPatterns else {
      throw GuardConfigError("more than \(maxPatterns) patterns")
    }
    guard (1...hardMaxLength).contains(settings.maxLength) else {
      throw GuardConfigError("max_length must be 1 to \(hardMaxLength)")
    }
    maxLength = settings.maxLength
    allowNonASCII = settings.allowNonASCII
    expressions = try settings.patterns.map { pattern in
      guard pattern.unicodeScalars.count <= maxPatternLength else {
        throw GuardConfigError("a pattern is longer than \(maxPatternLength) characters")
      }
      // A pattern that is not a well-formed expression on its own cannot be wrapped safely:
      // "x)|(y" would otherwise escape the anchors.
      do {
        _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return try NSRegularExpression(
          pattern: "\\A(?:\(pattern))\\z", options: [.caseInsensitive])
      } catch {
        throw GuardConfigError("invalid pattern \(JSON.line(pattern))")
      }
    }
  }

  public func check(_ phrase: String) -> GuardDecision {
    if expressions.isEmpty {
      return refuse(.noPatterns, "no allow patterns are configured")
    }
    if phrase.unicodeScalars.contains(where: Self.isForbidden) {
      return refuse(
        .controlCharacter, "the phrase has a control, format, or unusual space character")
    }
    let trimmed = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    if trimmed.isEmpty { return refuse(.emptyPhrase, "the phrase is empty") }
    if trimmed.unicodeScalars.count > maxLength {
      return refuse(.tooLong, "the phrase is longer than \(maxLength) characters")
    }
    if !allowNonASCII && !trimmed.unicodeScalars.allSatisfy(\.isASCII) {
      return refuse(.nonASCII, "the phrase has non-ASCII characters")
    }
    let full = NSRange(location: 0, length: trimmed.utf16.count)
    for expression in expressions {
      let box = MatchBox()
      let done = DispatchSemaphore(value: 0)
      let worker = Thread {
        let match = expression.firstMatch(in: trimmed, options: [], range: full)
        box.set(match?.range == full)
        done.signal()
      }
      worker.start()
      // ICU cannot be interrupted, so a pattern that backtracks without end leaves its thread
      // spinning; callers must stop the process after a timeout.
      if done.wait(timeout: .now() + matchTimeout) == .timedOut {
        return .timedOut(
          ErrorInfo(
            code: .guardTimeout,
            message: "an allow pattern took too long to match; it backtracks too much"))
      }
      if box.get() == true { return .allow(trimmed) }
    }
    return refuse(.notAllowed, "the phrase matches no allow pattern")
  }

  private func refuse(_ code: ErrorCode, _ message: String) -> GuardDecision {
    .refuse(ErrorInfo(code: code, message: message))
  }

  private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
      .unassigned:
      return true
    case .spaceSeparator:
      return scalar != " "
    default:
      return false
    }
  }
}
