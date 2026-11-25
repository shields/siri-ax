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
import Synchronization

private final class StopFlag: Sendable {
  private let raised = Mutex(false)
  var isRaised: Bool { raised.withLock { $0 } }
  func raise() { raised.withLock { $0 = true } }
}

extension Environment {
  public static var live: Environment {
    Environment(
      surface: { LiveSurface() }, probe: LiveProbe(), time: SystemTime(),
      readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
      out: { write($0, to: .standardOutput) }, err: { write($0, to: .standardError) },
      watchStopSignals: {
        let flag = StopFlag()
        let sources = [SIGINT, SIGTERM].map { number in
          signal(number, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
          source.setEventHandler {
            flag.raise()
            // A second signal ends the process even while a request is in flight.
            signal(number, SIG_DFL)
          }
          source.resume()
          return source
        }
        return {
          _ = sources
          return flag.isRaised
        }
      })
  }

  private static func write(_ line: String, to handle: FileHandle) {
    handle.write(Data((line + "\n").utf8))
  }
}
