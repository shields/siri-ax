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

@Suite struct DoctorTests {
  private let now = Date(timeIntervalSince1970: 0)

  @Test func ready() {
    let report = Doctor.report(FakeProbe(), now: now)
    #expect(report.status == .ready)
    #expect(report.problems.isEmpty)
    #expect(report.checks.siriHasWindow)
    #expect(report.checks.macOSVersion == "27.2.1")
  }

  @Test func untrustedAndMissing() {
    var probe = FakeProbe()
    probe.trusted = false
    probe.installed = false
    probe.running = false
    let report = Doctor.report(probe, now: now)
    #expect(report.status == .notReady)
    #expect(report.problems.map(\.code) == [.accessibilityNotTrusted, .siriNotInstalled])
    #expect(!report.checks.siriRunning)
    #expect(!report.checks.siriHasWindow)
  }

  @Test func runningWithoutWindowIsStillReady() {
    var probe = FakeProbe()
    probe.windows = 0
    let report = Doctor.report(probe, now: now)
    #expect(report.status == .ready)
    #expect(!report.checks.siriHasWindow)
  }
}

@Suite struct SystemTimeTests {
  @Test func sleepAdvancesTheMonotonicClock() {
    let time = SystemTime()
    let before = time.uptime()
    time.sleep(0.05)
    #expect(time.uptime() - before >= 0.04)
    #expect(abs(time.now().timeIntervalSinceNow) < 5)
  }
}
