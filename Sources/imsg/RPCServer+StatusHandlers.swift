import Foundation
import IMsgCore

struct RPCBridgeSnapshot: Sendable {
  let probed: Bool
  let ready: Bool
  let bridgeVersion: Int?
  let v2Ready: Bool?
  let registryAvailable: Bool?
  let eventPathUsable: Bool
  let selectors: [String: Bool]
  let error: String?

  private init(
    probed: Bool,
    ready: Bool,
    bridgeVersion: Int?,
    v2Ready: Bool?,
    registryAvailable: Bool?,
    eventPathUsable: Bool,
    selectors: [String: Bool],
    error: String?
  ) {
    self.probed = probed
    self.ready = ready
    self.bridgeVersion = bridgeVersion
    self.v2Ready = v2Ready
    self.registryAvailable = registryAvailable
    self.eventPathUsable = eventPathUsable
    self.selectors = selectors
    self.error = error
  }

  static let unavailable = RPCBridgeSnapshot(
    probed: false,
    ready: false,
    bridgeVersion: nil,
    v2Ready: nil,
    registryAvailable: nil,
    eventPathUsable: false,
    selectors: [:],
    error: "The bridge is not started. Run imsg launch explicitly before using bridge methods."
  )

  static let probeFailed = RPCBridgeSnapshot(
    probed: false,
    ready: false,
    bridgeVersion: nil,
    v2Ready: nil,
    registryAvailable: nil,
    eventPathUsable: false,
    selectors: [:],
    error: "The existing bridge did not answer a non-launching status probe."
  )

  init(status: [String: Any], eventPathUsable: Bool = false) {
    let version = Self.integer(status["bridge_version"])
    let v2Ready = status["v2_ready"] as? Bool
    let registryAvailable = status["registry_available"] as? Bool
    self.probed = true
    self.ready = version != nil && v2Ready == true && registryAvailable == true
    self.bridgeVersion = version
    self.v2Ready = v2Ready
    self.registryAvailable = registryAvailable
    self.eventPathUsable = eventPathUsable
    self.selectors = Self.boolDictionary(status["selectors"])
    self.error =
      self.ready
      ? nil : "The running bridge did not report a ready v2 inbox and chat registry."
  }

  var dictionary: [String: Any] {
    var result: [String: Any] = ["ready": ready]
    if let bridgeVersion { result["bridge_version"] = bridgeVersion }
    if let v2Ready { result["v2_ready"] = v2Ready }
    if let registryAvailable { result["registry_available"] = registryAvailable }
    if probed {
      result["selectors"] = selectors
    }
    if let error { result["error"] = error }
    return result
  }

  func supports(_ requirement: RPCBridgeRequirement) -> Bool {
    if requirement == .none { return true }
    guard bridgeVersion != nil, v2Ready == true else { return false }
    if requirement.requiresRegistry, registryAvailable != true { return false }
    if requirement.requiresEventPath, !eventPathUsable { return false }
    guard requirement.allSelectors.allSatisfy({ selectors[$0] == true }) else { return false }
    return requirement.anySelectors.isEmpty
      || requirement.anySelectors.contains { selectors[$0] == true }
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
  }

  private static func boolDictionary(_ value: Any?) -> [String: Bool] {
    if let value = value as? [String: Bool] { return value }
    guard let value = value as? [String: Any] else { return [:] }
    return value.reduce(into: [:]) { result, pair in
      if let flag = pair.value as? Bool { result[pair.key] = flag }
    }
  }
}

extension RPCServer {
  func handleInitialize(id: Any?, params: [String: Any]) async throws {
    let params = try RPCParameters(
      params,
      method: "initialize",
      supportedKeys: ["protocol_version"]
    )
    if let requestedVersion = try params.integer("protocol_version"),
      requestedVersion != kRPCProtocolVersion
    {
      throw RPCError.invalidParams(
        "unsupported protocol_version \(requestedVersion); supported version is \(kRPCProtocolVersion)"
      )
    }
    respond(id: id, result: try await statusSnapshot())
  }

  func handleStatus(id: Any?, params: [String: Any]) async throws {
    _ = try RPCParameters(params, method: "status", supportedKeys: [])
    respond(id: id, result: try await statusSnapshot())
  }

  /// The result shared by `initialize` and `status`.
  ///
  /// Both method lists are filtered to what the gate would actually accept, and
  /// `read_only` states the mode outright. This is the same reasoning
  /// `StatusCommand.advertisedRPCMethods` applies to the CLI's `rpc_methods`:
  /// these lists are what a capability-aware client dispatches against, so
  /// advertising a mutating method the gate will refuse hands it a menu of
  /// calls that cannot succeed. It matters more here than on the CLI, because
  /// the stdio surface is the one an agent negotiates against at `initialize`,
  /// and without `read_only` it can only discover the mode by trial.
  ///
  /// `redact_codes` is reported for a different reason: read-only announces
  /// itself the moment a call is refused, but redaction silently changes the
  /// content of successful results. A client caching or forwarding message
  /// text has no other way to learn that it was modified.
  func statusSnapshot() async throws -> [String: Any] {
    async let database = databaseResources.snapshot()
    async let bridge = bridgeSnapshot()
    let (databaseSnapshot, bridgeSnapshot) = try await (database, bridge)
    var methods = rpcUsableMethods(database: databaseSnapshot, bridge: bridgeSnapshot)
    var supported = kSupportedRPCMethods
    if readOnly {
      methods = methods.filter { kReadOnlyRPCMethods.contains($0) }
      supported = supported.filter { kReadOnlyRPCMethods.contains($0) }
    }
    return [
      "version": IMsgVersion.current,
      "protocol_version": kRPCProtocolVersion,
      "database": databaseSnapshot.dictionary,
      "bridge": bridgeSnapshot.dictionary,
      "contacts": ["available": !contactResolver.contactsUnavailable],
      "methods": methods,
      "supported_methods": supported,
      "read_only": readOnly,
      "redact_codes": redactCodes,
    ]
  }

  func bridgeSnapshot() async throws -> RPCBridgeSnapshot {
    try Task.checkCancellation()
    guard isBridgeReady() else { return .unavailable }
    do {
      return RPCBridgeSnapshot(
        status: try await bridgeInvoker(.status, [:]),
        eventPathUsable: bridgeEventPathUsable(bridgeEventsPath)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .probeFailed
    }
  }
}
