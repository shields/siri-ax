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

/// A snapshot of one accessibility element and its descendants. The live layer builds these
/// from the Siri AI window; tests build them by hand.
public struct UINode: Equatable, Sendable {
  public var role: String?
  public var identifier: String?
  public var value: String?
  public var title: String?
  public var descriptionText: String?
  public var children: [UINode]

  public init(
    role: String? = nil, identifier: String? = nil, value: String? = nil, title: String? = nil,
    descriptionText: String? = nil, children: [UINode] = []
  ) {
    self.role = role
    self.identifier = identifier
    self.value = value
    self.title = title
    self.descriptionText = descriptionText
    self.children = children
  }

  /// Every node with the identifier, in document order.
  public func all(identifier wanted: String) -> [UINode] {
    var found: [UINode] = []
    if identifier == wanted { found.append(self) }
    for child in children { found += child.all(identifier: wanted) }
    return found
  }
}

public struct SiriFailure: Error, Equatable, CustomStringConvertible {
  public var info: ErrorInfo
  public var description: String { info.message }

  public init(_ code: ErrorCode, _ message: String) {
    info = ErrorInfo(code: code, message: message)
  }
}

/// The few operations the tool needs from the Siri AI window. The live implementation is the
/// only code that calls the Accessibility API.
public protocol SiriSurface {
  /// Throws `accessibility_not_trusted` or `siri_not_installed`.
  func checkAvailable() throws
  /// Returns once Siri AI is running with a window, launching it if needed. Throws
  /// `siri_no_window` after `timeout` seconds.
  func ensureWindow(timeout: Double) throws
  /// The window's tree, or nil when there is no window.
  func snapshot() throws -> UINode?
  func pressNewConversation() throws
  func setPrompt(_ phrase: String) throws
  func confirmPrompt() throws
}

public protocol Timekeeper {
  /// Monotonic seconds.
  func uptime() -> Double
  func now() -> Date
  func sleep(_ seconds: Double)
}

public struct SystemTime: Timekeeper {
  public init() {}

  public func uptime() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
  }

  public func now() -> Date { Date() }

  public func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

public enum SiriIdentifiers {
  public static let newChatButton = "newChatButton"
  public static let promptField = "promptViewTextField"
  public static let modelResponse = "modelResponse"
}
