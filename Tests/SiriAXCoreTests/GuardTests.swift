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

private func make(_ patterns: [String], maxLength: Int = 100, nonASCII: Bool = false) throws
  -> PhraseGuard
{
  try PhraseGuard(GuardSettings(patterns: patterns, maxLength: maxLength, allowNonASCII: nonASCII))
}

private func code(_ decision: GuardDecision) -> ErrorCode? {
  if case .refuse(let info) = decision { return info.code }
  return nil
}

private let lamp = #"set (the )?lamp to (red|blue|(cool |warm )?white|[0-9]{1,3}%)"#

@Suite struct GuardTests {
  @Test func noPatternsRefusesEverything() throws {
    let guardian = try make([])
    #expect(code(guardian.check("set lamp to red")) == .noPatterns)
    #expect(code(guardian.check("")) == .noPatterns)
  }

  @Test func matchesWholePhraseCaseInsensitively() throws {
    let guardian = try make([lamp])
    #expect(guardian.check("set lamp to red") == .allow("set lamp to red"))
    #expect(
      guardian.check("SET The Lamp TO Cool White") == .allow("SET The Lamp TO Cool White"))
    #expect(guardian.check("  set lamp to 50%  ") == .allow("set lamp to 50%"))
  }

  @Test func patternsAreAnchored() throws {
    let guardian = try make([lamp])
    for phrase in [
      "please set lamp to red", "set lamp to red; call mom", "set lamp to red and text Bob",
      "set lamp to", "set lamp to red.", "turn on the lights", "set lamp to red or text Bob",
    ] {
      #expect(code(guardian.check(phrase)) == .notAllowed, "\(phrase)")
    }
  }

  @Test func alternationCannotMatchAPrefix() throws {
    let guardian = try make(["a|ab"])
    #expect(guardian.check("ab") == .allow("ab"))
    #expect(code(guardian.check("abc")) == .notAllowed)
  }

  @Test func anyPatternMayAllow() throws {
    let guardian = try make([lamp, "what time is it"])
    #expect(guardian.check("what time is it") == .allow("what time is it"))
    #expect(guardian.patternCount == 2)
  }

  @Test func controlAndFormatCharactersAreRefused() throws {
    let guardian = try make([".*"])
    let hostile = [
      "set lamp to red\n", "set lamp to red\nCall Mom", "set lamp to red\r", "\tset lamp",
      "set\u{0}lamp", "set lamp to red\u{1B}[0m", "set\u{200B}lamp", "set \u{202E}lamp",
      "set\u{00A0}lamp", "set\u{2028}lamp", "set\u{2029}lamp", "set\u{E000}lamp",
      "\u{FEFF}set lamp", "set lamp\u{7F}",
    ]
    for phrase in hostile {
      #expect(code(guardian.check(phrase)) == .controlCharacter, "\(phrase.debugDescription)")
    }
  }

  @Test func emptyAndSpacesAreRefused() throws {
    let guardian = try make([".*"])
    #expect(code(guardian.check("")) == .emptyPhrase)
    #expect(code(guardian.check("   ")) == .emptyPhrase)
  }

  @Test func lengthIsEnforcedAfterTrimming() throws {
    let guardian = try make([".*"], maxLength: 10)
    #expect(guardian.check("  1234567890  ") == .allow("1234567890"))
    #expect(code(guardian.check("12345678901")) == .tooLong)
    #expect(code(guardian.check(String(repeating: "a", count: 1_000_000))) == .tooLong)
  }

  @Test func nonASCIIIsRefusedByDefault() throws {
    let guardian = try make([".*"])
    #expect(code(guardian.check("set lamp to café")) == .nonASCII)
    // U+212A KELVIN SIGN case-folds to "k".
    #expect(code(guardian.check("set \u{212A}itchen to red")) == .nonASCII)
    #expect(
      try make([".*"], nonASCII: true).check("set lamp to café") == .allow("set lamp to café"))
  }

  @Test func malformedPatternsAreRejectedWhenBuilt() {
    for pattern in ["(", "x)|(y", "[a-", #"\Qabc"#, "(?x) a #", "a{2,1}"] {
      #expect(throws: GuardConfigError.self, "\(pattern)") { try make([pattern]) }
    }
  }

  @Test func limitsOnPatternsAreEnforced() {
    #expect(throws: GuardConfigError.self) { try make(Array(repeating: "a", count: 101)) }
    #expect(throws: GuardConfigError.self) { try make([String(repeating: "a", count: 501)]) }
    #expect(throws: GuardConfigError.self) { try make(["a"], maxLength: 0) }
    #expect(throws: GuardConfigError.self) { try make(["a"], maxLength: 201) }
  }

  @Test func refusalMessagesNeverEchoThePhrase() throws {
    let guardian = try make([lamp])
    for phrase in [
      "secret-token-123", "\u{0}secret-token-123", String(repeating: "secret-token-123", count: 20),
    ] {
      guard case .refuse(let info) = guardian.check(phrase) else {
        Issue.record("allowed")
        continue
      }
      #expect(!info.message.contains("secret-token"))
    }
  }
}

@Suite struct GuardConfigTests {
  private func parse(_ text: String) throws -> GuardSettings {
    try GuardSettings.parse(Data(text.utf8))
  }

  @Test func parsesTheDocumentedFormat() throws {
    let settings = try parse(
      """
      # Allow one accessory.
      max_length = 60

      non_ascii = allow
      allow = set lamp to [a-z ]+
        allow=what is the weather
      """)
    #expect(
      settings
        == GuardSettings(
          patterns: ["set lamp to [a-z ]+", "what is the weather"], maxLength: 60,
          allowNonASCII: true))
  }

  @Test func emptyFileHasNoPatterns() throws {
    #expect(try parse("") == GuardSettings())
    #expect(try parse("# nothing\r\n\r\n") == GuardSettings())
  }

  @Test func patternMayContainEqualsAndHash() throws {
    #expect(try parse("allow = a=b#c").patterns == ["a=b#c"])
  }

  @Test func acceptsCRLF() throws {
    #expect(try parse("allow = a\r\nallow = b\r\n").patterns == ["a", "b"])
  }

  @Test func rejectsBadFiles() {
    let bad = [
      "allow", "allow =", "= a", "unknown = 1", "max_length = 0", "max_length = 201",
      "max_length = x", "max_length = 5\nmax_length = 6", "non_ascii = maybe",
      "non_ascii = allow\nnon_ascii = deny",
    ]
    for text in bad {
      #expect(throws: GuardConfigError.self, "\(text)") { try parse(text) }
    }
    #expect(throws: GuardConfigError.self) { try GuardSettings.parse(Data([0xFF, 0xFE])) }
    #expect(throws: GuardConfigError.self) {
      try GuardSettings.parse(Data(repeating: 0x23, count: 70_000))
    }
  }

  @Test func theShippedExampleLoads() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../examples/guard.conf").standardized
    let guardian = try PhraseGuard(GuardSettings.parse(Data(contentsOf: url)))
    #expect(guardian.check("set lamp to cool white") == .allow("set lamp to cool white"))
    #expect(code(guardian.check("set lamp to red and call mom")) == .notAllowed)
    #expect(code(guardian.check("set front door to unlocked")) == .notAllowed)
  }
}
