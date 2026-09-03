import IMsgCore

extension MessageStore {
  /// Applies `runtime`'s redaction policy to this store and returns it, for
  /// use where a command opens its database:
  ///
  ///     let store = try MessageStore(path: dbPath).configured(for: runtime)
  ///
  /// Configuring the store rather than redacting each result is what keeps
  /// `--redact-codes` from being fail-open — see
  /// `MessageStore.redactSecurityCodes`. A command that reads message text
  /// should route its store through here.
  func configured(for runtime: RuntimeOptions) -> MessageStore {
    redactSecurityCodes = runtime.redactCodes
    return self
  }
}
