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

public protocol SystemProbe {
  func accessibilityTrusted() -> Bool
  func siriInstalled() -> Bool
  func siriRunning() -> Bool
  func siriWindowCount() -> Int
  func macOSVersion() -> String
}

public enum Doctor {
  public static func report(_ probe: any SystemProbe, now: Date) -> DoctorReport {
    let trusted = probe.accessibilityTrusted()
    let installed = probe.siriInstalled()
    let running = probe.siriRunning()
    let windows = running ? probe.siriWindowCount() : 0
    var problems: [ErrorInfo] = []
    if !trusted {
      problems.append(
        ErrorInfo(
          code: .accessibilityNotTrusted,
          message: "the terminal app running siri-ax has no Accessibility permission"))
    }
    if !installed {
      problems.append(
        ErrorInfo(code: .siriNotInstalled, message: "Siri AI.app is not in /System/Applications"))
    }
    return DoctorReport(
      status: problems.isEmpty ? .ready : .notReady,
      checks: DoctorChecks(
        accessibilityTrusted: trusted, siriInstalled: installed, siriRunning: running,
        siriHasWindow: windows > 0, macOSVersion: probe.macOSVersion()),
      problems: problems, checkedAt: now)
  }
}
