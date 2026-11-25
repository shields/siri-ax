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

import AppKit
import ApplicationServices
import Foundation
import SiriAXCore

/// The only code that calls the Accessibility API. It is not unit tested: it needs a permitted
/// terminal and a running Siri AI.
final class LiveSurface: SiriSurface {
  static let bundleIdentifier = "com.apple.campo"
  static let applicationPath = "/System/Applications/Siri AI.app"
  static let maxNodes = 5000
  static let maxDepth = 40

  func checkAvailable() throws {
    guard AXIsProcessTrusted() else {
      throw SiriFailure(
        .accessibilityNotTrusted,
        "the terminal app running siri-ax has no Accessibility permission")
    }
    guard FileManager.default.fileExists(atPath: Self.applicationPath) else {
      throw SiriFailure(.siriNotInstalled, "\(Self.applicationPath) does not exist")
    }
  }

  func ensureWindow(timeout: Double) throws {
    if window() != nil { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", Self.applicationPath]
    do {
      try open.run()
    } catch {
      throw SiriFailure(.siriNoWindow, "could not launch Siri AI: \(error.localizedDescription)")
    }
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
      throw SiriFailure(.siriNoWindow, "open exited with status \(open.terminationStatus)")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if window() != nil { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw SiriFailure(.siriNoWindow, "Siri AI has no window")
  }

  func snapshot() throws -> UINode? {
    guard let window = window() else { return nil }
    var budget = Self.maxNodes
    let tree = Self.node(window, depth: 0, budget: &budget)
    if budget <= 0 {
      throw SiriFailure(.uiChanged, "the Siri AI window has more than \(Self.maxNodes) elements")
    }
    return tree
  }

  func pressNewConversation() throws {
    let button = try element(SiriIdentifiers.newChatButton)
    try check(
      AXUIElementPerformAction(button, kAXPressAction as CFString), "pressing New Conversation")
  }

  func setPrompt(_ phrase: String) throws {
    let field = try element(SiriIdentifiers.promptField)
    try check(
      AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, phrase as CFString),
      "setting the prompt")
  }

  func confirmPrompt() throws {
    let field = try element(SiriIdentifiers.promptField)
    try check(
      AXUIElementPerformAction(field, kAXConfirmAction as CFString), "confirming the prompt")
  }

  private func check(_ error: AXError, _ doing: String) throws {
    if error != .success {
      throw SiriFailure(.axFailure, "Accessibility error \(error.rawValue) while \(doing)")
    }
  }

  private func window() -> AXUIElement? {
    guard
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: Self.bundleIdentifier
      ).first
    else { return nil }
    let application = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 5)
    let windows = Self.attribute(application, kAXWindowsAttribute) as? [AXUIElement]
    let chosen =
      windows?.first { Self.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
      ?? windows?.first
    if let chosen { AXUIElementSetMessagingTimeout(chosen, 2) }
    return chosen
  }

  private func element(_ identifier: String) throws -> AXUIElement {
    guard let window = window() else {
      throw SiriFailure(.siriNoWindow, "Siri AI has no window")
    }
    var budget = Self.maxNodes
    if let found = Self.find(identifier, in: window, depth: 0, budget: &budget) { return found }
    throw SiriFailure(.uiChanged, "no element with identifier \(identifier) in the Siri AI window")
  }

  private static func find(
    _ identifier: String, in element: AXUIElement, depth: Int, budget: inout Int
  ) -> AXUIElement? {
    guard depth <= maxDepth, budget > 0 else { return nil }
    budget -= 1
    if string(element, kAXIdentifierAttribute) == identifier { return element }
    for child in children(element) {
      if let found = find(identifier, in: child, depth: depth + 1, budget: &budget) {
        return found
      }
    }
    return nil
  }

  private static func node(_ element: AXUIElement, depth: Int, budget: inout Int) -> UINode {
    budget -= 1
    var kids: [UINode] = []
    if depth < maxDepth {
      for child in children(element) where budget > 0 {
        kids.append(node(child, depth: depth + 1, budget: &budget))
      }
    }
    return UINode(
      role: string(element, kAXRoleAttribute), identifier: string(element, kAXIdentifierAttribute),
      value: string(element, kAXValueAttribute), title: string(element, kAXTitleAttribute),
      descriptionText: string(element, kAXDescriptionAttribute), children: kids)
  }

  private static func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }

  private static func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }
}

struct LiveProbe: SystemProbe {
  func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

  func siriInstalled() -> Bool {
    FileManager.default.fileExists(atPath: LiveSurface.applicationPath)
  }

  private func running() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: LiveSurface.bundleIdentifier)
      .first
  }

  func siriRunning() -> Bool { running() != nil }

  func siriWindowCount() -> Int {
    guard AXIsProcessTrusted(), let running = running() else { return 0 }
    let application = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 5)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        == .success,
      let windows = value as? [AXUIElement]
    else { return 0 }
    return windows.count
  }

  func macOSVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }
}
