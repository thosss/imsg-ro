import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func int64(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcReadOnlyRejectsMutatingMethod() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"7","method":"send","params":{"to":"+15551234567","text":"hi"}}"#
  await server.handleLineForTesting(line)

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == 1)
  let envelope = output.errors[0]
  // JSON-RPC framing is preserved: id is echoed.
  #expect(envelope["id"] as? String == "7")
  let error = envelope["error"] as? [String: Any]
  #expect(int64(error?["code"]) == Int64(kReadOnlyRPCErrorCode))
  #expect(error?["data"] as? String == "send")
}

@Test
func rpcReadOnlyRejectsRepresentativeMutations() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  for method in ["tapback", "message.delete", "chats.markUnread", "group.leave", "typing", "read"] {
    let output = TestRPCOutput()
    let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)
    let line = #"{"jsonrpc":"2.0","id":"1","method":"\#(method)","params":{}}"#
    await server.handleLineForTesting(line)
    let error = output.errors.first?["error"] as? [String: Any]
    #expect(
      int64(error?["code"]) == Int64(kReadOnlyRPCErrorCode),
      "\(method) should be refused in read-only mode")
  }
}

@Test
func rpcReadOnlyStillServesReadMethods() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)

  let line = #"{"jsonrpc":"2.0","id":"9","method":"chats.list","params":{"limit":10}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.isEmpty)
  #expect(output.responses.count == 1)
}

@Test
func rpcReadWriteServerStillSendsWhenNotReadOnly() async throws {
  // Sanity: without read-only, a mutating method is not blocked by the gate
  // (it may still fail for other reasons, but never with the read-only code).
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"1","method":"send","params":{"to":"+1"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64(error?["code"]) != Int64(kReadOnlyRPCErrorCode))
}

@Test
func rpcReadOnlyRejectsUnknownMethodRatherThanFailingOpen() async throws {
  // The gate is an allow-list keyed on kReadOnlyRPCMethods, not a block-list
  // keyed on known mutating methods, so it stays fail-closed even for a
  // method that was never registered at all (e.g. a future handler added to
  // the dispatch switch but forgotten in kSupportedRPCMethods).
  //
  // Fail-closed is about what runs, not about which code comes back: the call
  // is refused before dispatch either way, and an unregistered name is
  // reported as method-not-found because that is what it is.
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)

  let line = #"{"jsonrpc":"2.0","id":"1","method":"totally.unregistered","params":{}}"#
  await server.handleLineForTesting(line)

  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64(error?["code"]) == Int64(RPCErrorCode.methodNotFound.rawValue))
}

@Test
func rpcReadOnlyReportsMutationsAndAbsentMethodsDifferently() async throws {
  // A refusal a client can act on: -32005 means "this exists and this server
  // will not do it", -32601 means "no such method here". Conflating them
  // mislabels a read method that `macOSOnly` compiled out of the build as a
  // blocked mutation.
  let store = try CommandTestDatabase.makeStoreForRPC()

  for method in ["send", "tapback", "chats.delete"] {
    let output = TestRPCOutput()
    let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"1","method":"\#(method)","params":{}}"#)
    let error = output.errors.first?["error"] as? [String: Any]
    #expect(
      int64(error?["code"]) == Int64(kReadOnlyRPCErrorCode),
      "\(method) is a compiled-in mutation and should read as read-only refused")
  }

  for method in ["totally.unregistered", "send.definitely_not_a_method"] {
    let output = TestRPCOutput()
    let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)
    await server.handleLineForTesting(
      #"{"jsonrpc":"2.0","id":"1","method":"\#(method)","params":{}}"#)
    let error = output.errors.first?["error"] as? [String: Any]
    #expect(
      int64(error?["code"]) == Int64(RPCErrorCode.methodNotFound.rawValue),
      "\(method) does not exist and should read as method-not-found")
  }

  // Whichever code comes back, the gate refused before dispatch.
  #expect(rpcMethodIsDispatchable("send") == kSupportedRPCMethods.contains("send"))
  #expect(rpcMethodIsDispatchable("totally.unregistered") == false)
}

@Test
func rpcReadOnlyStatusAdvertisesOnlyPermittedMethods() async throws {
  // status/initialize is what a stdio client negotiates against, so the lists
  // it returns must not offer calls the gate will refuse, and read_only has to
  // be discoverable without probing.
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: true, output: output)

  await server.handleLineForTesting(#"{"jsonrpc":"2.0","id":"1","method":"status","params":{}}"#)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["read_only"] as? Bool == true)

  let supported = result?["supported_methods"] as? [String] ?? []
  #expect(!supported.isEmpty)
  #expect(!supported.contains("send"))
  #expect(supported.allSatisfy { kReadOnlyRPCMethods.contains($0) })

  let methods = result?["methods"] as? [String] ?? []
  #expect(methods.allSatisfy { kReadOnlyRPCMethods.contains($0) })
}

@Test
func rpcReadWriteStatusStillAdvertisesEverything() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, readOnly: false, output: output)

  await server.handleLineForTesting(#"{"jsonrpc":"2.0","id":"1","method":"status","params":{}}"#)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["read_only"] as? Bool == false)
  #expect((result?["supported_methods"] as? [String]) == kSupportedRPCMethods)
}

@Test
func rpcMethodClassificationIsComplete() {
  let supported = Set(kSupportedRPCMethods)
  // Every advertised method is classified as exactly one of read or mutating.
  #expect(kReadOnlyRPCMethods.isDisjoint(with: kMutatingRPCMethods))
  #expect(kReadOnlyRPCMethods.union(kMutatingRPCMethods) == supported)
  // Read methods must never be treated as mutating.
  #expect(kReadOnlyRPCMethods.isSubset(of: supported))
}

@Test
func rpcReadOnlyErrorCodeDoesNotCollide() {
  // A read-only refusal means "nothing happened, safe to stop"; the codes
  // below mean other things entirely — notably deliveryFailure's -32001, which
  // can mean "may already have been delivered". A client that keys off `code`
  // must never confuse them, so the read-only code has to stay unique.
  //
  // This is a real regression: read-only originally used -32001, and an
  // upstream merge later assigned that same code to deliveryFailure.
  //
  // Uniqueness itself is enforced by the compiler, not by this test: RPCErrorCode
  // is a raw-value enum, so a future case claiming -32005 fails the build. What
  // is checked here is that the constructors go through that enum — a numeric
  // literal at a construction site would escape the compiler's check, and this
  // fork's tests run neither locally nor in CI, so an assertion resting on a
  // hand-maintained list of constructors would be worth little.
  #expect(RPCError.readOnly("send").code == RPCErrorCode.readOnly.rawValue)
  #expect(kReadOnlyRPCErrorCode == RPCErrorCode.readOnly.rawValue)

  let constructed: [RPCError] = [
    .parseError("x"),
    .invalidRequest("x"),
    .invalidParams("x"),
    .internalError("x"),
    .methodNotFound("x"),
    .serverBusy("x"),
    .databaseUnavailable(path: "/tmp/x", detail: "x"),
    .bridgeUnavailable(),
    .bridgeEventsUnavailable(detail: "x"),
    .deliveryFailure(
      DeliveryFailure(
        disposition: .mayHaveCompleted,
        transport: .appleScript,
        operation: "send",
        detail: "x"
      )),
    .deliveryFailure(
      DeliveryFailure(
        disposition: .notStarted,
        transport: .appleScript,
        operation: "send",
        detail: "x"
      )),
    .mutationLaneBlocked(
      DeliveryFailure(
        disposition: .stillInFlight,
        transport: .appleScript,
        operation: "send",
        detail: "x"
      )),
  ]

  for error in constructed {
    #expect(
      RPCErrorCode(rawValue: error.code) != nil,
      "\(error.message) carries code \(error.code), which is not a declared RPCErrorCode")
    #expect(
      error.code != kReadOnlyRPCErrorCode,
      "\(error.message) reuses the read-only code \(kReadOnlyRPCErrorCode)")
  }
}
