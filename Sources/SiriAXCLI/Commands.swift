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

import ArgumentParser
import Foundation
import SiriAXCore

/// Written for failures that have no request to attach to: usage errors and a `serve` that cannot
/// start. `ask` failures are always an `AskResult`.
struct Failure: Encodable {
  var command: String?
  var error: ErrorInfo
  var time: Date

  enum CodingKeys: String, CodingKey {
    case schema, command, status, error, time
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schema)
    try container.encode(command, forKey: .command)
    try container.encode(Status.error, forKey: .status)
    try container.encode(error, forKey: .error)
    try container.encode(time, forKey: .time)
  }
}

protocol Executable {
  func execute(_ environment: Environment) -> Int32
}

struct GuardOptions: ParsableArguments {
  @Option(
    name: .customLong("guard"),
    help: "Guard configuration file: the allowlist of phrases. See the README.")
  var file: String?

  @Option(
    name: .customLong("allow"),
    help: "An extra allowed phrase pattern, matched against the whole phrase. Repeatable.")
  var allow: [String] = []

  func build(_ environment: Environment) throws -> PhraseGuard {
    var settings = GuardSettings()
    if let file {
      let data: Data
      do {
        data = try environment.readFile(file)
      } catch {
        throw GuardConfigError("cannot read the guard file: \(error.localizedDescription)")
      }
      settings = try GuardSettings.parse(data)
    }
    settings.patterns += allow
    return try PhraseGuard(settings)
  }
}

struct Ask: ParsableCommand, Executable {
  static let configuration = CommandConfiguration(
    abstract: "Send one phrase to Siri in a new conversation and print the answer as JSON.")

  @OptionGroup var guardOptions: GuardOptions

  @Option(
    help:
      "Seconds to wait for the answer, 1 to 120. The first request after launch can take a minute.")
  var timeout = defaultTimeout

  @Option(help: "Seconds the answer must stay unchanged to count as settled, 0.4 to 30.")
  var settle = defaultSettle

  @Argument(help: "The phrase. Put -- before it if it starts with a dash.")
  var phrase: String

  mutating func validate() throws {
    guard timeoutRange.contains(timeout) else {
      throw ValidationError("--timeout must be 1 to 120")
    }
    guard settleRange.contains(settle) else {
      throw ValidationError("--settle must be 0.4 to 30")
    }
  }

  func execute(_ environment: Environment) -> Int32 {
    let result: AskResult
    do {
      let asker = Asker(
        phraseGuard: try guardOptions.build(environment), surface: environment.surface(),
        time: environment.time)
      result = asker.ask(phrase, options: AskOptions(timeout: timeout, settle: settle))
    } catch {
      result = CLI.askFailure(.configInvalid, "\(error)", phrase: phrase, environment)
    }
    environment.out(JSON.line(result))
    return result.exitCode
  }
}

struct Serve: ParsableCommand, Executable {
  static let configuration = CommandConfiguration(
    abstract: "Answer request files from a queue directory until SIGINT or SIGTERM.")

  @OptionGroup var guardOptions: GuardOptions

  @Option(help: "Seconds an answer must stay unchanged to count as settled, 0.4 to 30.")
  var settle = defaultSettle

  @Argument(help: "The queue directory. It is created if missing.")
  var queueDirectory: String

  mutating func validate() throws {
    guard settleRange.contains(settle) else {
      throw ValidationError("--settle must be 0.4 to 30")
    }
  }

  func execute(_ environment: Environment) -> Int32 {
    let phraseGuard: PhraseGuard
    do {
      phraseGuard = try guardOptions.build(environment)
    } catch {
      return CLI.fail(.configInvalid, "\(error)", command: "serve", environment)
    }
    let surface = environment.surface()
    do {
      try surface.checkAvailable()
    } catch let failure as SiriFailure {
      return CLI.fail(failure.info.code, failure.info.message, command: "serve", environment)
    } catch {
      return CLI.fail(.axFailure, "\(error)", command: "serve", environment)
    }
    let root = URL(fileURLWithPath: queueDirectory).standardizedFileURL
    let time = environment.time
    let runner = QueueRunner(
      root: root, asker: Asker(phraseGuard: phraseGuard, surface: surface, time: time),
      settle: settle, log: { environment.out(JSON.line($0)) })
    do {
      try runner.createDirectories()
    } catch {
      return CLI.fail(.queueFailure, "\(error)", command: "serve", environment)
    }
    let stop = environment.watchStopSignals()
    environment.out(
      JSON.line(
        ServeEvent(
          event: .started, time: time.now(),
          detail:
            "queue \(root.path); \(phraseGuard.patternCount) patterns; max length \(phraseGuard.maxLength)"
        )))
    do {
      try runner.run(shouldStop: stop)
    } catch {
      return CLI.fail(.queueFailure, "\(error)", command: "serve", environment)
    }
    environment.out(JSON.line(ServeEvent(event: .stopped, time: time.now(), detail: "signal")))
    return 0
  }
}

struct DoctorCommand: ParsableCommand, Executable {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract:
      "Report whether Accessibility is granted and Siri AI is installed, running, and windowed.")

  func execute(_ environment: Environment) -> Int32 {
    let report = Doctor.report(environment.probe, now: environment.time.now())
    environment.out(JSON.line(report))
    return report.exitCode
  }
}

struct SiriAXCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "siri-ax",
    abstract: "Ask Siri from the command line. Standard output is JSON and nothing else.",
    subcommands: [Ask.self, Serve.self, DoctorCommand.self])
}

public enum CLI {
  /// Runs the tool and returns its exit code. Help text goes to stderr.
  public static func run(_ arguments: [String], environment: Environment) -> Int32 {
    do {
      var parsed = try SiriAXCommand.parseAsRoot(arguments)
      if let command = parsed as? any Executable {
        return command.execute(environment)
      }
      if parsed is SiriAXCommand {
        return fail(
          .usage, "a subcommand is required: ask, serve, or doctor", command: nil, environment)
      }
      // A help request parses to a command whose run throws the help text.
      try parsed.run()
      return 0
    } catch {
      let code = SiriAXCommand.exitCode(for: error)
      if code == .success {
        environment.err(SiriAXCommand.fullMessage(for: error))
        return 0
      }
      let message = SiriAXCommand.message(for: error)
      if arguments.first == "ask" {
        let result = askFailure(.usage, message, environment)
        environment.out(JSON.line(result))
        return result.exitCode
      }
      let command = ["serve", "doctor"].contains(arguments.first ?? "") ? arguments.first : nil
      return fail(.usage, message, command: command, environment)
    }
  }

  static func askFailure(
    _ code: ErrorCode, _ message: String, phrase: String? = nil, _ environment: Environment
  )
    -> AskResult
  {
    let now = environment.time.now()
    return AskResult(
      status: .error, phrase: phrase, error: ErrorInfo(code: code, message: message),
      startedAt: now,
      finishedAt: now, elapsedMilliseconds: 0)
  }

  static func fail(
    _ code: ErrorCode, _ message: String, command: String?, _ environment: Environment
  )
    -> Int32
  {
    environment.out(
      JSON.line(
        Failure(
          command: command, error: ErrorInfo(code: code, message: message),
          time: environment.time.now())))
    return code == .usage ? 64 : 3
  }
}
