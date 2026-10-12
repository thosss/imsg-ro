import Foundation

public struct Chat: Sendable, Equatable {
  public let id: Int64
  public let identifier: String
  public let name: String
  public let service: String
  public let lastMessageAt: Date
  public let accountID: String?
  public let accountLogin: String?
  public let lastAddressedHandle: String?
  /// Inbound unread row count, or nil when the database has no read state.
  public let unreadCount: Int?
  /// Messages' filing of the chat: 0 = normal, 1 = Unknown Senders, 2 = Junk.
  /// nil when the database has no chat.is_filtered column.
  public let isFiltered: Int?

  public init(
    id: Int64,
    identifier: String,
    name: String,
    service: String,
    lastMessageAt: Date,
    accountID: String? = nil,
    accountLogin: String? = nil,
    lastAddressedHandle: String? = nil,
    unreadCount: Int? = nil,
    isFiltered: Int? = nil
  ) {
    self.id = id
    self.identifier = identifier
    self.name = name
    self.service = service
    self.lastMessageAt = lastMessageAt
    self.accountID = accountID
    self.accountLogin = accountLogin
    self.lastAddressedHandle = lastAddressedHandle
    self.unreadCount = unreadCount
    self.isFiltered = isFiltered
  }
}
