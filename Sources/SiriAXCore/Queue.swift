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

let maxRequestBytes = 16 * 1024

public struct QueueFailure: Error, Equatable, CustomStringConvertible {
  public var description: String
  public init(_ description: String) { self.description = description }
}

/// The body of a request file. Only these two fields exist; anything else is rejected.
struct QueueRequest: Decodable, Equatable {
  var phrase: String
  var timeoutSeconds: Double?

  private struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    let allowed: Set<String> = ["phrase", "timeout_seconds"]
    if container.allKeys.contains(where: { !allowed.contains($0.stringValue) }) {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "unknown field"))
    }
    phrase = try container.decode(String.self, forKey: Key(stringValue: "phrase")!)
    timeoutSeconds = try container.decodeIfPresent(
      Double.self, forKey: Key(stringValue: "timeout_seconds")!)
  }
}

public enum QueueLayout {
  public static func isValid(id: String) -> Bool {
    let scalars = Array(id.unicodeScalars)
    guard (1...64).contains(scalars.count) else { return false }
    func alphanumeric(_ scalar: Unicode.Scalar) -> Bool {
      (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
        || (scalar >= "0" && scalar <= "9")
    }
    return alphanumeric(scalars[0])
      && scalars.allSatisfy { alphanumeric($0) || $0 == "_" || $0 == "-" }
  }

  /// The id of a request file name, or nil when the name is not `<id>.json` with a valid id.
  public static func id(fromFileName name: String) -> String? {
    guard name.hasSuffix(".json") else { return nil }
    let id = String(name.dropLast(".json".count))
    return isValid(id: id) ? id : nil
  }
}

public final class QueueRunner {
  public let root: URL
  private let asker: Asker
  private let settle: Double
  private let log: (ServeEvent) -> Void
  private var reported: Set<String> = []
  static let maxReported = 1000

  var requests: URL { root.appending(path: "requests", directoryHint: .isDirectory) }
  var claimed: URL { root.appending(path: "claimed", directoryHint: .isDirectory) }
  var results: URL { root.appending(path: "results", directoryHint: .isDirectory) }

  public init(root: URL, asker: Asker, settle: Double, log: @escaping (ServeEvent) -> Void) {
    self.root = root
    self.asker = asker
    self.settle = settle
    self.log = log
  }

  public func prepare() throws {
    try createDirectories()
    try recover()
  }

  public func createDirectories() throws {
    do {
      for directory in [root, requests, claimed, results] {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
    } catch {
      throw QueueFailure("cannot create the queue directories: \(error.localizedDescription)")
    }
  }

  public func recover() throws {
    for name in try listing(claimed) {
      guard let id = QueueLayout.id(fromFileName: name) else {
        try? FileManager.default.removeItem(at: claimed.appending(path: name))
        continue
      }
      if !FileManager.default.fileExists(atPath: resultURL(id).path) {
        try write(
          failure(
            id: id, phrase: nil, .interrupted,
            "the runner stopped while handling this request; it may or may not have reached Siri"))
        emit(.recovered, id: id, status: .error)
      }
      try? FileManager.default.removeItem(at: claimed.appending(path: name))
    }
  }

  public func run(shouldStop: () -> Bool) throws {
    try recover()
    while !shouldStop() {
      while !shouldStop(), try processNext() {}
      asker.time.sleep(0.25)
    }
  }

  public func processNext() throws -> Bool {
    for name in try listing(requests).sorted() {
      guard name.hasSuffix(".json") else { continue }
      guard let id = QueueLayout.id(fromFileName: name) else {
        report(name, "invalid_id")
        continue
      }
      if FileManager.default.fileExists(atPath: resultURL(id).path) {
        let claimedURL = claimed.appending(path: name)
        guard
          (try? FileManager.default.moveItem(at: requests.appending(path: name), to: claimedURL))
            != nil
        else {
          report(name, "cannot_claim")
          continue
        }
        defer { discard(claimedURL) }
        let phrase = parse(claimedURL).request?.phrase
        try write(
          failure(
            id: id, phrase: phrase, .invalidRequest,
            "a result for this id already exists; use a fresh id"),
          to: rejectedURL(id))
        emit(.ignored, id: id, status: .error)
        continue
      }
      do {
        try FileManager.default.moveItem(
          at: requests.appending(path: name), to: claimed.appending(path: name))
      } catch {
        report(name, "cannot_claim")
        continue
      }
      try handle(id: id, claimedAt: claimed.appending(path: name))
      return true
    }
    return false
  }

  private func handle(id: String, claimedAt url: URL) throws {
    defer { discard(url) }
    emit(.request, id: id)
    let result: AskResult
    switch parse(url) {
    case .failure(let message):
      result = failure(id: id, phrase: nil, .invalidRequest, message)
    case .success(let request):
      let timeout = request.timeoutSeconds ?? defaultTimeout
      if !timeoutRange.contains(timeout) {
        result = failure(
          id: id, phrase: request.phrase, .invalidRequest,
          "timeout_seconds must be \(Int(timeoutRange.lowerBound)) to \(Int(timeoutRange.upperBound))"
        )
      } else {
        result = asker.ask(
          request.phrase, id: id, options: AskOptions(timeout: timeout, settle: settle))
      }
    }
    try write(result)
    emit(.result, id: id, status: result.status)
    if result.error?.code == .guardTimeout {
      throw QueueFailure(
        "an allow pattern backtracks without end; fix the guard configuration and restart")
    }
  }

  private enum Parsed {
    case success(QueueRequest)
    case failure(String)

    var request: QueueRequest? {
      if case .success(let request) = self { return request }
      return nil
    }
  }

  private func parse(_ url: URL) -> Parsed {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return .failure("the request is not a readable file") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      return .failure("the request is not a regular file")
    }
    guard
      let data = try? handle.read(upToCount: maxRequestBytes + 1), data.count <= maxRequestBytes
    else {
      return .failure("the request is larger than \(maxRequestBytes) bytes")
    }
    do {
      return .success(try JSONDecoder().decode(QueueRequest.self, from: data))
    } catch {
      return .failure(
        "the request must be a JSON object with a string \"phrase\" and optional numeric \"timeout_seconds\""
      )
    }
  }

  private func failure(id: String, phrase: String?, _ code: ErrorCode, _ message: String)
    -> AskResult
  {
    let now = asker.time.now()
    return AskResult(
      id: id, status: .error, phrase: phrase, error: ErrorInfo(code: code, message: message),
      startedAt: now, finishedAt: now, elapsedMilliseconds: 0)
  }

  private func resultURL(_ id: String) -> URL {
    results.appending(path: "\(id).json", directoryHint: .notDirectory)
  }

  private func rejectedURL(_ id: String) -> URL {
    results.appending(path: "\(id).rejected.json", directoryHint: .notDirectory)
  }

  private func write(_ result: AskResult, to destination: URL? = nil) throws {
    guard let id = result.id else { throw QueueFailure("result has no id") }
    let data = Data((JSON.line(result) + "\n").utf8)
    do {
      try data.write(to: destination ?? resultURL(id), options: .atomic)
    } catch {
      throw QueueFailure("cannot write the result for \(id): \(error.localizedDescription)")
    }
  }

  private func listing(_ directory: URL) throws -> [String] {
    do {
      return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw QueueFailure(
        "cannot list \(directory.lastPathComponent): \(error.localizedDescription)")
    }
  }

  private func discard(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func report(_ name: String, _ reason: String) {
    if reported.count < Self.maxReported, reported.insert("\(name) \(reason)").inserted {
      log(
        ServeEvent(event: .ignored, time: asker.time.now(), id: nil, detail: "\(reason): \(name)"))
    }
  }

  private func emit(_ name: ServeEvent.Name, id: String, status: Status? = nil) {
    log(ServeEvent(event: name, time: asker.time.now(), id: id, status: status))
  }
}
