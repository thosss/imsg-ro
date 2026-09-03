import Foundation
import IMsgCore

/// Every JSON-RPC error code this server emits, in one place.
///
/// The point of the enum is that Swift rejects duplicate raw values at compile
/// time. A future error condition that tries to claim an already-used code —
/// `readOnly`'s -32005 above all — fails the build instead of silently
/// colliding, which is what happened once already: read-only originally used
/// -32001, and an upstream merge later assigned that code to `deliveryFailure`.
/// Add a case here before writing a new `RPCError` constructor, and never
/// hardcode a numeric code at a construction site.
enum RPCErrorCode: Int, CaseIterable, Sendable {
  // JSON-RPC 2.0 reserved range.
  case parseError = -32700
  case invalidRequest = -32600
  case methodNotFound = -32601
  case invalidParams = -32602
  case internalError = -32603
  // Implementation-defined server-error range (-32000…-32099).
  case serverBusy = -32000
  case deliveryUnknown = -32001
  case databaseUnavailable = -32002
  case bridgeUnavailable = -32003
  case mutationLaneBlocked = -32004
  case readOnly = -32005
}

/// JSON-RPC error code for a read-only mode refusal.
///
/// Must stay distinct from every other code this server emits — see
/// `RPCError.readOnly` for why, and `rpcReadOnlyErrorCodeDoesNotCollide` for
/// the test that enforces it.
let kReadOnlyRPCErrorCode = RPCErrorCode.readOnly.rawValue

final class RPCWriter: RPCOutput, Sendable {
  func sendResponse(id: Any, result: Any) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    send(payload)
  }

  func sendNotification(method: String, params: Any) {
    send(["jsonrpc": "2.0", "method": method, "params": params])
  }

  func flush() {
    StdoutWriter.flush()
  }

  private func send(_ object: Any) {
    do {
      let data = try JSONSerialization.data(withJSONObject: object, options: [])
      if let output = String(data: data, encoding: .utf8) {
        StdoutWriter.writeLine(output)
      }
    } catch {
      StdoutWriter.writeLine(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"write failed\"}}"
      )
    }
  }
}

struct RPCError: Error, @unchecked Sendable {
  let code: Int
  let message: String
  let data: String?
  let structuredData: [String: Any]?

  /// Codes come from `RPCErrorCode` rather than integer literals so that the
  /// enum stays the single source of truth for what each number means.
  init(code: RPCErrorCode, message: String, data: String?) {
    self.code = code.rawValue
    self.message = message
    self.data = data
    self.structuredData = nil
  }

  private init(code: RPCErrorCode, message: String, structuredData: [String: Any]) {
    self.code = code.rawValue
    self.message = message
    self.data = nil
    self.structuredData = structuredData
  }

  static func parseError(_ message: String) -> RPCError {
    RPCError(code: .parseError, message: "Parse error", data: message)
  }

  static func invalidRequest(_ message: String) -> RPCError {
    RPCError(code: .invalidRequest, message: "Invalid Request", data: message)
  }

  static func methodNotFound(_ method: String) -> RPCError {
    RPCError(code: .methodNotFound, message: "Method not found", data: method)
  }

  static func invalidParams(_ message: String) -> RPCError {
    RPCError(code: .invalidParams, message: "Invalid params", data: message)
  }

  static func internalError(_ message: String) -> RPCError {
    RPCError(code: .internalError, message: "Internal error", data: message)
  }

  /// Returned when a mutating method is invoked while the server runs in
  /// read-only mode. Uses a code in the JSON-RPC implementation-defined
  /// server-error range (-32000…-32099) so the response stays a well-formed
  /// JSON-RPC error rather than breaking the protocol.
  ///
  /// Originally -32001. Renumbered to `kReadOnlyRPCErrorCode` (-32005) when
  /// upstream claimed -32001 for `deliveryFailure` ("Delivery outcome
  /// unknown"); two unrelated conditions sharing one code would leave a client
  /// unable to tell "refused, nothing happened" from "may have been delivered"
  /// by code alone — opposite meanings for a caller deciding whether to retry.
  static func readOnly(_ method: String) -> RPCError {
    RPCError(
      code: .readOnly,
      message: "Read-only mode: mutating method disabled",
      data: method
    )
  }

  static func serverBusy(_ message: String) -> RPCError {
    RPCError(code: .serverBusy, message: "Server busy", data: message)
  }

  static func databaseUnavailable(path: String, detail: String) -> RPCError {
    RPCError(
      code: .databaseUnavailable,
      message: "Database unavailable",
      structuredData: ["path": path, "detail": detail, "retryable": true]
    )
  }

  static func bridgeUnavailable() -> RPCError {
    RPCError(
      code: .bridgeUnavailable,
      message: "Bridge unavailable",
      structuredData: [
        "detail":
          "The bridge is not started. Run imsg launch explicitly before using bridge methods.",
        "retryable": true,
      ]
    )
  }

  static func bridgeEventsUnavailable(detail: String) -> RPCError {
    RPCError(
      code: .bridgeUnavailable,
      message: "Bridge events unavailable",
      structuredData: ["detail": detail, "retryable": true]
    )
  }

  static func deliveryFailure(_ failure: DeliveryFailure) -> RPCError {
    let unknown = failure.disposition != .notStarted
    return RPCError(
      code: unknown ? .deliveryUnknown : .internalError,
      message: unknown ? "Delivery outcome unknown" : "Delivery failed before dispatch",
      structuredData: deliveryData(failure)
    )
  }

  static func mutationLaneBlocked(_ failure: DeliveryFailure) -> RPCError {
    var data = deliveryData(failure)
    data["detail"] =
      "A prior \(failure.operation) remains in flight. Restart the RPC child before sending another mutation."
    return RPCError(
      code: .mutationLaneBlocked, message: "Mutation lane blocked", structuredData: data)
  }

  private static func deliveryData(_ failure: DeliveryFailure) -> [String: Any] {
    [
      "retry_safe": failure.retrySafe,
      "disposition": failure.disposition.rawValue,
      "transport": failure.transport.rawValue,
      "operation": failure.operation,
      "detail": failure.detail,
    ]
  }

  func asDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "code": code,
      "message": message,
    ]
    if let structuredData {
      dict["data"] = structuredData
    } else if let data {
      dict["data"] = data
    }
    return dict
  }
}

actor SubscriptionStore {
  struct Reservation: Sendable, Equatable {
    let id: Int
    fileprivate let generation: UInt64
  }

  enum ReservationResult: Sendable, Equatable {
    case reserved(Reservation)
    case closed
    case limitReached
  }

  enum ActivationResult: Sendable, Equatable {
    case activated
    case closed
    case removed
  }

  private enum Entry {
    case pending(generation: UInt64)
    case active(generation: UInt64, task: Task<Void, Never>)
  }

  private let limit: Int
  private var nextID = 1
  private var nextGeneration: UInt64 = 1
  private var entries: [Int: Entry] = [:]
  private var accepting = true
  private var emptyWaiters: [CheckedContinuation<Void, Never>] = []
  private var closedWaiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = limit
  }

  func reserve() -> ReservationResult {
    guard accepting else { return .closed }
    guard entries.count < limit else { return .limitReached }
    let id = nextID
    nextID += 1
    let generation = nextGeneration
    nextGeneration += 1
    let reservation = Reservation(id: id, generation: generation)
    entries[id] = .pending(generation: generation)
    return .reserved(reservation)
  }

  func activate(_ task: Task<Void, Never>, reservation: Reservation) -> ActivationResult {
    guard accepting else { return .closed }
    guard
      case .pending(let generation) = entries[reservation.id],
      generation == reservation.generation
    else {
      return .removed
    }
    entries[reservation.id] = .active(generation: generation, task: task)
    return .activated
  }

  func removeForCancellation(_ id: Int) -> Task<Void, Never>? {
    guard let entry = entries.removeValue(forKey: id) else { return nil }
    resumeEmptyWaitersIfNeeded()
    if case .active(_, let task) = entry {
      return task
    }
    return nil
  }

  func complete(_ reservation: Reservation) {
    guard let entry = entries[reservation.id] else { return }
    let generation: UInt64
    switch entry {
    case .pending(let value), .active(let value, _):
      generation = value
    }
    if generation == reservation.generation {
      entries.removeValue(forKey: reservation.id)
      resumeEmptyWaitersIfNeeded()
    }
  }

  func cancelAll() async {
    accepting = false
    resumeClosedWaiters()
    let tasks = entries.values.compactMap { entry -> Task<Void, Never>? in
      guard case .active(_, let task) = entry else { return nil }
      return task
    }
    entries.removeAll()
    resumeEmptyWaitersIfNeeded()
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      await task.value
    }
  }

  var count: Int {
    entries.count
  }

  var nextIDForTesting: Int {
    nextID
  }

  func waitUntilEmpty() async {
    guard !entries.isEmpty else { return }
    await withCheckedContinuation { continuation in
      emptyWaiters.append(continuation)
    }
  }

  func waitUntilClosed() async {
    guard accepting else { return }
    await withCheckedContinuation { continuation in
      closedWaiters.append(continuation)
    }
  }

  private func resumeEmptyWaitersIfNeeded() {
    guard entries.isEmpty else { return }
    let waiters = emptyWaiters
    emptyWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func resumeClosedWaiters() {
    let waiters = closedWaiters
    closedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

actor SubscriptionStartGate {
  private var result: Bool?
  private var waiters: [CheckedContinuation<Bool, Never>] = []

  func wait() async -> Bool {
    if let result { return result }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open(_ result: Bool) {
    guard self.result == nil else { return }
    self.result = result
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume(returning: result)
    }
  }
}

extension RPCServer {
  func sendViaBridge(
    chatGUID: String,
    text: String,
    file: String,
    selectedMessageGuid: String? = nil,
    textFormatting: Any? = nil,
    clientMessageGuid: String? = nil
  ) async throws -> [String: Any] {
    let action: BridgeAction = file.isEmpty ? .sendMessage : .sendAttachment
    if clientMessageGuid != nil {
      guard file.isEmpty else {
        throw RPCError.invalidParams("tracked sends do not support attachments")
      }
      let status: [String: Any]
      do {
        status = try await invokeBridge(action: .status, params: [:])
      } catch {
        throw DeliveryFailure(
          disposition: .notStarted,
          transport: .bridgeV2,
          operation: action.rawValue,
          detail: "Bridge capability inspection failed before the tracked send was published."
        )
      }
      let selectors = status["selectors"] as? [String: Any]
      guard selectors?["clientMessageGuidReservation"] as? Bool == true else {
        throw DeliveryFailure(
          disposition: .notStarted,
          transport: .bridgeV2,
          operation: action.rawValue,
          detail: "running bridge does not support caller-owned message GUIDs"
        )
      }
    }
    if !file.isEmpty {
      let requiresMetadata = !text.isEmpty || selectedMessageGuid != nil || textFormatting != nil
      if requiresMetadata {
        let status: [String: Any]
        do {
          status = try await invokeBridge(action: .status, params: [:])
        } catch {
          throw DeliveryFailure(
            disposition: .notStarted,
            transport: .bridgeV2,
            operation: action.rawValue,
            detail: "Bridge capability inspection failed before the send was published."
          )
        }
        guard status["attachment_metadata"] as? Bool == true else {
          throw RPCError.internalError(
            "running bridge does not support captioned or threaded attachments; "
              + "restart Messages with the current imsg bridge"
          )
        }
      }
      let stagedFile: String
      do {
        stagedFile = try stageAttachment(file)
      } catch {
        throw DeliveryFailure(
          disposition: .notStarted,
          transport: .bridgeV2,
          operation: action.rawValue,
          detail: "The attachment could not be staged before bridge dispatch."
        )
      }
      var params: [String: Any] = [
        "chatGuid": chatGUID, "filePath": stagedFile, "isAudioMessage": false,
      ]
      if !text.isEmpty {
        params["message"] = text
      }
      if let selectedMessageGuid {
        params["selectedMessageGuid"] = selectedMessageGuid
      }
      if let textFormatting {
        params["textFormatting"] = textFormatting
      }
      return try await invokeBridge(action: .sendAttachment, params: params)
    }
    var params: [String: Any] = ["chatGuid": chatGUID, "message": text]
    if let selectedMessageGuid {
      params["selectedMessageGuid"] = selectedMessageGuid
    }
    if let textFormatting {
      params["textFormatting"] = textFormatting
    }
    if let clientMessageGuid {
      params["clientMessageGuid"] = clientMessageGuid
    }
    let result = try await invokeBridge(action: .sendMessage, params: params)
    if let clientMessageGuid {
      guard let returnedGuid = result["messageGuid"] as? String,
        returnedGuid.caseInsensitiveCompare(clientMessageGuid) == .orderedSame
      else {
        throw DeliveryFailure(
          disposition: .mayHaveCompleted,
          transport: .bridgeV2,
          operation: action.rawValue,
          detail: "Bridge dispatched the tracked send but did not echo its exact message GUID."
        )
      }
    }
    return result
  }
}
