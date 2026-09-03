import Foundation

extension Message {
  /// Returns a copy with `text` and `replyToText` passed through
  /// `SecurityCodeRedactor`. Used by `--redact-codes` callers so a texted
  /// security code never reaches a renderer, JSON payload, or RPC
  /// notification.
  ///
  /// Every other field is carried through unchanged — `rowID` in particular,
  /// which callers use to look up prefetched reactions after redacting.
  public func redactingSecurityCodes() -> Message {
    Message(
      rowID: rowID,
      chatID: chatID,
      sender: sender,
      text: SecurityCodeRedactor.redact(text),
      date: date,
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: attachmentsCount,
      guid: guid,
      routing: RoutingMetadata(
        replyToGUID: replyToGUID,
        threadOriginatorGUID: threadOriginatorGUID,
        threadOriginatorPart: threadOriginatorPart,
        destinationCallerID: destinationCallerID,
        replyToText: SecurityCodeRedactor.redact(replyToText),
        replyToSender: replyToSender
      ),
      balloonBundleID: balloonBundleID,
      urlPreview: urlPreview,
      reaction: ReactionMetadata(
        isReaction: isReaction,
        reactionType: reactionType,
        isReactionAdd: isReactionAdd,
        reactedToGUID: reactedToGUID
      ),
      poll: poll,
      isRead: isRead,
      dateRead: dateRead
    )
  }
}
