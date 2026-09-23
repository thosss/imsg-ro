import Foundation
import IMsgCore

extension RPCServer {
  func handleLine(_ line: String) async -> RPCExecutionResult {
    let request: RPCRequest
    switch RPCRequestParser.parse(line) {
    case .success(let parsed):
      request = parsed
    case .failure(let failure):
      if failure.shouldRespond {
        output.sendError(id: failure.id, error: failure.error)
      }
      return .completed
    }
    let method = request.method
    let params = request.params
    let id = request.id

    // Allow-list, not block-list: a method passes only if its descriptor
    // declares a non-mutating lane for this platform (see
    // `kReadOnlyRPCMethods`). Any unregistered method name is denied by
    // omission, so the gate stays fail-closed regardless of what the dispatch
    // switch below happens to cover.
    //
    // The refusal is evaluated before dispatch, so nothing runs. Notifications
    // get no response, per JSON-RPC — they are still refused, just silently.
    //
    // Which error comes back is a separate question from whether the call is
    // refused: a name with no compiled-in descriptor is not a blocked mutation
    // but an absent method, and answering -32601 for it keeps read-only mode
    // reporting the same thing read-write mode would. Without that split, a
    // Linux client asking for `handles.check` (a `.read` method compiled out
    // by `macOSOnly`) would be told its read was refused as a mutation.
    if readOnly && !kReadOnlyRPCMethods.contains(method) {
      if !request.isNotification {
        let error =
          rpcMethodIsDispatchable(method)
          ? RPCError.readOnly(method)
          : RPCError.methodNotFound(method)
        output.sendError(id: id, error: error)
      }
      return .completed
    }

    do {
      guard let route = rpcDispatchRoutes[method] else {
        if !request.isNotification {
          output.sendError(id: id, error: RPCError.methodNotFound(method))
        }
        return .completed
      }
      switch route {
      case .initialize:
        try await handleInitialize(id: id, params: params)
      case .status:
        try await handleStatus(id: id, params: params)
      case .chatsList:
        try await handleChatsList(id: id, params: params)
      case .messagesStats:
        try await handleMessagesStats(id: id, params: params)
      case .messagesHistory:
        try await handleMessagesHistory(id: id, params: params)
      case .messagesSearch:
        try await handleMessagesSearch(id: id, params: params)
      case .messagesAfter:
        try await handleMessagesAfter(id: id, params: params)
      case .watchSubscribe:
        try await handleWatchSubscribe(id: id, params: params)
      case .bridgeEventsSubscribe:
        try await handleBridgeEventsSubscribe(id: id, params: params)
      case .watchUnsubscribe:
        try await handleWatchUnsubscribe(id: id, params: params)
      case .send:
        try await handleSend(params: params, id: id)
      case .sendTracked:
        try await handleSendTracked(params: params, id: id)
      case .sendRich:
        try await handleSendRich(params: params, id: id)
      case .sendAttachment:
        try await handleSendAttachment(params: params, id: id)
      case .sendMultipart:
        try await handleSendMultipart(params: params, id: id)
      case .sendSticker:
        try await handleSendSticker(params: params, id: id)
      case .messagesScheduled:
        try await handleMessagesScheduled(params: params, id: id)
      case .pollSend:
        try await handlePollSend(params: params, id: id)
      case .pollVote:
        try await handlePollVote(params: params, id: id)
      case .pollUnvote:
        try await handlePollUnvote(params: params, id: id)
      case .tapback:
        try await handleTapback(params: params, id: id)
      case .typing:
        try await handleTyping(params: params, id: id)
      case .read:
        try await handleRead(params: params, id: id)
      case .messageEdit:
        try await handleMessageEdit(params: params, id: id)
      case .messageUnsend:
        try await handleMessageUnsend(params: params, id: id)
      case .messageDelete:
        try await handleMessageDelete(params: params, id: id)
      case .messageNotifyAnyways:
        try await handleMessageNotifyAnyways(params: params, id: id)
      case .messageSendStatus:
        try await handleMessageSendStatus(params: params, id: id)
      case .chatsCreate:
        try await handleChatsCreate(id: id, params: params)
      case .chatsDelete:
        try await handleChatsDelete(id: id, params: params)
      case .chatsMarkUnread:
        try await handleChatsMarkUnread(id: id, params: params)
      case .groupRename:
        try await handleGroupRename(id: id, params: params)
      case .groupSetIcon:
        try await handleGroupSetIcon(id: id, params: params)
      case .groupAddParticipant:
        try await handleGroupAddParticipant(id: id, params: params)
      case .groupRemoveParticipant:
        try await handleGroupRemoveParticipant(id: id, params: params)
      case .groupLeave:
        try await handleGroupLeave(id: id, params: params)
      case .contactsShouldShare:
        try await handleNamePhotoStatus(params: params, id: id)
      case .contactsShare:
        try await handleNamePhotoShare(params: params, id: id)
      case .handlesCheck:
        try await handleHandlesCheck(params: params, id: id)
      }
    } catch is CancellationError {
      return .completed
    } catch let signal as RPCMutationPoisonSignal {
      return .deliveryFailure(signal.failure)
    } catch let failure as DeliveryFailure {
      if !request.isNotification {
        output.sendError(id: id, error: RPCError.deliveryFailure(failure))
      }
      return .deliveryFailure(failure)
    } catch let err as RPCError {
      if !request.isNotification {
        output.sendError(id: id, error: err)
      }
    } catch let err as IMsgError {
      guard !request.isNotification else { return .completed }
      if err.isCallerCausedRPCError {
        output.sendError(id: id, error: RPCError.invalidParams(err.localizedDescription))
      } else {
        output.sendError(id: id, error: RPCError.internalError(err.localizedDescription))
      }
    } catch {
      if !request.isNotification {
        output.sendError(id: id, error: RPCError.internalError(error.localizedDescription))
      }
    }
    return .completed
  }

  func rejectBusy(_ line: String) {
    switch RPCRequestParser.parse(line) {
    case .success(let request):
      if !request.isNotification {
        output.sendError(
          id: request.id,
          error: RPCError.serverBusy("outstanding request limit exceeded")
        )
      }
    case .failure(let failure):
      if failure.shouldRespond {
        output.sendError(id: failure.id, error: failure.error)
      }
    }
  }

  func rejectMutationBlocked(_ line: String, poison: DeliveryFailure) {
    guard case .success(let request) = RPCRequestParser.parse(line) else { return }
    if !request.isNotification {
      output.sendError(id: request.id, error: RPCError.mutationLaneBlocked(poison))
    }
  }

}

extension IMsgError {
  fileprivate var isCallerCausedRPCError: Bool {
    switch self {
    case .invalidISODate, .invalidService, .unsupportedService, .invalidChatTarget,
      .invalidReaction, .unsupportedReaction, .chatNotFound:
      return true
    case .permissionDenied, .appleScriptFailure, .typingIndicatorFailed:
      return false
    }
  }
}
