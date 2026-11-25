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
import SiriAXCore

/// Everything the commands reach outside the process for, so tests can supply fakes.
public struct Environment {
  public var surface: () -> any SiriSurface
  public var probe: any SystemProbe
  public var time: any Timekeeper
  public var readFile: (String) throws -> Data
  /// Writes one line to stdout.
  public var out: (String) -> Void
  /// Writes one line to stderr.
  public var err: (String) -> Void
  /// Starts watching for SIGINT and SIGTERM and returns a check for whether one has arrived.
  public var watchStopSignals: () -> () -> Bool

  public init(
    surface: @escaping () -> any SiriSurface, probe: any SystemProbe, time: any Timekeeper,
    readFile: @escaping (String) throws -> Data, out: @escaping (String) -> Void,
    err: @escaping (String) -> Void, watchStopSignals: @escaping () -> () -> Bool
  ) {
    self.surface = surface
    self.probe = probe
    self.time = time
    self.readFile = readFile
    self.out = out
    self.err = err
    self.watchStopSignals = watchStopSignals
  }
}
