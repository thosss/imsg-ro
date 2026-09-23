import Commander

/// Whether a command mutates iMessage state (sends, reactions, edits, chat
/// changes, read receipts, …) or only reads it. Used by `--read-only` mode to
/// deterministically refuse anything that could write.
///
/// The default for a `CommandSpec` is `.write` (fail-closed): a command must
/// explicitly opt in to `.read` to be permitted in read-only mode, so any newly
/// added command is blocked until it has been reviewed and classified.
enum MutationPolicy: Sendable {
  /// Never mutates state; always allowed in read-only mode.
  case read
  /// Mutates state; always blocked in read-only mode.
  case write
  /// Mutates state only for some invocations. The predicate returns `true` when
  /// the given parsed arguments would perform a write.
  case conditional(@Sendable (ParsedValues) -> Bool)
}

struct CommandSpec: Sendable {
  let name: String
  let abstract: String
  let discussion: String?
  let signature: CommandSignature
  let usageExamples: [String]
  let mutation: MutationPolicy
  let run: @Sendable (ParsedValues, RuntimeOptions) async throws -> Void

  init(
    name: String,
    abstract: String,
    discussion: String?,
    signature: CommandSignature,
    usageExamples: [String],
    mutation: MutationPolicy = .write,
    run: @escaping @Sendable (ParsedValues, RuntimeOptions) async throws -> Void
  ) {
    self.name = name
    self.abstract = abstract
    self.discussion = discussion
    self.signature = signature
    self.usageExamples = usageExamples
    self.mutation = mutation
    self.run = run
  }

  var descriptor: CommandDescriptor {
    CommandDescriptor(
      name: name,
      abstract: abstract,
      discussion: discussion,
      signature: signature
    )
  }

  /// Whether every invocation of this command mutates state, judged without
  /// arguments to parse.
  ///
  /// For advertising a command list in read-only mode: a `.conditional`
  /// command stays listed because some of its invocations are permitted (e.g.
  /// `name-photo status`), while a `.write` command is dropped, since nothing
  /// it can be asked to do would be allowed.
  var isAlwaysMutating: Bool {
    if case .write = mutation { return true }
    return false
  }

  /// Whether this specific invocation would mutate state, honouring
  /// `.conditional` policies that depend on the parsed arguments.
  func isMutating(for values: ParsedValues) -> Bool {
    switch mutation {
    case .read:
      return false
    case .write:
      return true
    case .conditional(let predicate):
      return predicate(values)
    }
  }
}
