import Foundation

/// RPC methods permitted while the server runs in read-only mode
/// (`imsg rpc --read-only`). Derived from each method's declared
/// `RPCMethodDescriptor.lane` rather than a hand-maintained name list.
///
/// Fail-closed by construction, in two ways:
///
/// 1. Only a method with a registered descriptor can appear here, so an
///    unrecognized method name is refused rather than falling through to the
///    dispatch switch.
/// 2. `RPCMethodDescriptor` requires an explicit `lane:` at every declaration
///    site — there is no default — so a newly added mutating method is denied
///    the moment it is written, without anyone remembering to update a
///    separate allow-list.
///
/// `.read` and `.control` are both permitted: `.control` covers `initialize`,
/// `watch.subscribe`/`unsubscribe`, and `bridge.events.subscribe`, which
/// manage this process's own streams and never write to Messages.
///
/// Platform filtering matters for the gate's safety: a macOS-only mutating
/// method must not become permitted just because it is not compiled on Linux,
/// so descriptors are screened by `isCompiledForCurrentPlatform` before their
/// lane is consulted.
let kReadOnlyRPCMethods: Set<String> = Set(
  rpcMethodDescriptors
    .filter { $0.isCompiledForCurrentPlatform && $0.lane != .mutation }
    .flatMap(\.names)
)

/// RPC methods that mutate state. Not consulted by the runtime gate directly
/// (see `kReadOnlyRPCMethods`); kept so a test can assert that every advertised
/// method is classified as exactly one of read or mutating.
let kMutatingRPCMethods: Set<String> = Set(kSupportedRPCMethods)
  .subtracting(kReadOnlyRPCMethods)
