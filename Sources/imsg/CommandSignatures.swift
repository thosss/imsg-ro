import Commander
import IMsgCore

enum CommandSignatures {
  static func baseOptions() -> [OptionDefinition] {
    [
      .make(
        label: "db",
        names: [.long("db")],
        help: "Path to chat.db (defaults to ~/Library/Messages/chat.db)"
      )
    ]
  }

  /// Global `--read-only` flag. Registered on every command so it parses in the
  /// usual position (`imsg <cmd> --read-only`) and shows up in `--help`. It is
  /// also detected directly from argv / `IMSG_READ_ONLY` by `CommandRouter`, so
  /// enforcement does not depend on Commander parsing it.
  static let readOnlyFlagLabel = "readOnly"
  static let readOnlyFlagName = "--read-only"

  static func readOnlyFlag() -> FlagDefinition {
    .make(
      label: readOnlyFlagLabel,
      names: [.long("read-only")],
      help: "Refuse any write or mutation; only read operations are permitted"
    )
  }

  /// Global `--redact-codes` flag. Registered on every command so it parses in
  /// the usual position (`imsg <cmd> --redact-codes`). Also pre-scanned by
  /// `CommandRouter` alongside `--read-only` so it works before the
  /// subcommand too (`imsg --redact-codes <cmd>`) — Commander's root program
  /// expects the subcommand name as the first token, so any global flag ahead
  /// of it must be stripped before `program.resolve` runs, not just left for
  /// the per-command signature to parse.
  static let redactCodesFlagLabel = "redactCodes"
  static let redactCodesFlagName = "--redact-codes"

  static func redactCodesFlag() -> FlagDefinition {
    .make(
      label: redactCodesFlagLabel,
      names: [.long("redact-codes")],
      help: "Redact texted security/verification codes (2FA, OTP) from message text"
    )
  }

  /// Appends the fork's two global safety flags to a signature.
  ///
  /// The single place they are registered, so a command that opts out of the
  /// standard runtime flags (`--json`, `--verbose`) still picks these up —
  /// `completions` is the one such command, and hand-registering them there
  /// meant any third global flag would have missed it.
  ///
  /// The signature is rebuilt rather than mutated because Commander declares
  /// `CommandSignature.flags` as `public private(set)` and offers no generic
  /// appending builder. Keep the field list exhaustive: a stored property
  /// added to `CommandSignature` upstream and not copied here is dropped
  /// silently.
  static func withGlobalSafetyFlags(_ signature: CommandSignature) -> CommandSignature {
    CommandSignature(
      arguments: signature.arguments,
      options: signature.options,
      flags: signature.flags + [readOnlyFlag(), redactCodesFlag()],
      optionGroups: signature.optionGroups
    )
  }

  static func withRuntimeFlags(_ signature: CommandSignature) -> CommandSignature {
    withGlobalSafetyFlags(signature.withStandardRuntimeFlags())
  }
}
