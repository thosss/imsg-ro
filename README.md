# imsg 💬 — Messages, piped.

[![CI](https://img.shields.io/github/actions/workflow/status/openclaw/imsg/ci.yml?branch=main&style=flat-square&label=ci)](https://github.com/openclaw/imsg/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/openclaw/imsg?style=flat-square)](https://github.com/openclaw/imsg/releases/latest)
[![macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square)](docs/install.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org)
[![License](https://img.shields.io/github/license/openclaw/imsg?style=flat-square)](LICENSE)
[![Homebrew](https://img.shields.io/badge/Homebrew-steipete%2Ftap-FBB040?style=flat-square&logo=homebrew&logoColor=black)](https://github.com/steipete/homebrew-tap)
[![Docs](https://img.shields.io/badge/docs-imsg.sh-4B5563?style=flat-square)](https://imsg.sh)

![imsg banner](docs/assets/readme-banner.jpg)

`imsg` is a Swift CLI for reading, watching, and sending iMessage and SMS from macOS. It reads the local Messages database, sends through Messages.app automation, and exposes NDJSON and JSON-RPC for scripts and agents.

```bash
imsg chats --limit 10 --json | jq -s
imsg history --chat-id 42 --limit 20 --attachments --json | jq -s
imsg watch --chat-id 42 --reactions --json
imsg send --to "+14155551212" --text "on my way"
```

That's the whole pitch: read directly, stream updates, and ask Messages.app to send.

## Install

Homebrew is the smallest path on macOS:

```bash
brew install steipete/tap/imsg
imsg --version
```

`imsg` requires macOS 14 or newer. Signed macOS builds and Linux x86_64 read-only builds are also available from [GitHub Releases](https://github.com/openclaw/imsg/releases/latest). Linux reads a `chat.db` copied from macOS; it does not connect to iMessage or send messages. See the [Linux guide](docs/linux.md).

## Quick start

Grant your terminal **Full Disk Access** in **System Settings → Privacy & Security**, then reopen it. `imsg` needs that permission to read `~/Library/Messages/chat.db`.

```bash
# Find a chat and note its id.
imsg chats --limit 3

# Read its ten most recent messages.
imsg history --chat-id 42 --limit 10
```

Use an id from the first command in place of `42`. The [five-minute quickstart](docs/quickstart.md) continues with live watching and sending.

## Core workflows

| Goal | Start here |
| --- | --- |
| List chats and inspect their identifiers | [Chats](docs/chats.md) and [groups](docs/groups.md) |
| Read or search local history | [History](docs/history.md) |
| Stream new messages and tapbacks | [Watch](docs/watch.md) |
| Send text, files, and standard tapbacks | [Send](docs/send.md) and [attachments](docs/attachments.md) |
| Count messages and media | [Statistics](docs/stats.md) |
| Consume stable NDJSON or a long-running stdio API | [JSON schema](docs/json.md) and [JSON-RPC](docs/rpc.md) |
| Generate shell completions or model-ready CLI help | [Completions](docs/completions.md) |

Read commands open the database in SQLite read-only mode. `watch` follows database and WAL filesystem events, with a polling fallback when macOS drops an event or rotates a sidecar file.

## Permissions

Full Disk Access is required for local database reads. Sending and standard tapbacks also require **Automation → Messages**; Contacts access is optional and only adds resolved names. The [permissions guide](docs/permissions.md) covers parent-process grants and stale TCC entries, while [troubleshooting](docs/troubleshooting.md) maps common failures to their likely gate.

For SMS, enable Text Message Forwarding on the paired iPhone. `imsg send` uses Messages.app's AppleScript surface and cannot force a particular outgoing number when several numbers share one Apple ID.

## JSON and automation

`--json` emits one JSON object per line. Human progress and warnings stay on stderr, so stdout remains safe to stream. Pipe finite commands through `jq -s` when you want one array.

```bash
imsg chats --json | jq -s
imsg rpc
imsg completions llm
```

The [JSON schema](docs/json.md) documents chats, messages, attachments, reactions, polls, scheduled messages, and statistics. The [JSON-RPC reference](docs/rpc.md) covers the long-running stdio transport used by agents and gateways.

## Handing access to an untrusted agent

Two global flags exist for the case where message access is handed to an AI
agent or another consumer that should not have full run of the mailbox. Both
are accepted before or after the subcommand, and they combine freely.

### `--read-only`

Deterministically forbids every write or mutation across all commands and
`imsg rpc`, so a caller can hand the CLI over knowing it cannot send, react,
edit, delete, mark read, change chats, share Name & Photo, or relaunch
Messages.app with an injected dylib. Set `IMSG_READ_ONLY=1` to enforce it for
every child invocation. Either the flag or the environment variable is enough —
nothing turns it back off.

```bash
imsg --read-only history --chat-id 1 --json   # reads work as usual

imsg --read-only send --to +15551234567 --text hi
# -> read-only mode: 'send' performs a write or mutation and is disabled (exit 3)

IMSG_READ_ONLY=1 imsg rpc
```

Under `imsg rpc --read-only`, mutating methods are refused before dispatch with
a well-formed JSON-RPC error (`-32005`), so the stream is never broken. The
permitted set is derived from each method's declared execution lane rather than
a separate list, so a newly added mutating method is refused by default.
A method that does not exist on this build answers `-32601` (Method not found)
instead, so a client can tell "refused" from "no such method".

Commands that advertise capability narrow themselves to match, so a consumer is
never handed a menu of calls that cannot succeed:

- `imsg status` reports the mode (`read_only` in `--json`) and narrows its
  advertised `rpc_methods`.
- `imsg rpc`'s `status` and `initialize` report `read_only` and filter both
  `methods` and `supported_methods`.
- `imsg completions llm` — the CLI reference an agent reads to learn what it
  may do — lists only the commands that would run (38 down to 15). The shell
  completions narrow the same way.

`launch` is classified as a write: it terminates Messages.app and relaunches it
with `DYLD_INSERT_LIBRARIES`, and its `--dylib` option makes the injected code
caller-supplied, so permitting it would let a caller run arbitrary code inside
Messages — which can then send. Start the bridge yourself before handing over a
read-only session.

### `--redact-codes`

Strips texted security/verification codes (2FA, OTP, bank and vendor codes) out
of message text before it is rendered or serialized — `history`, `search`,
`watch`, `scheduled`, and the equivalent JSON-RPC methods.

Redaction is applied where database rows are decoded, not in each command, so
every read path inherits it — including quoted reply text and any path added
later. `imsg status --json` reports `redact_codes`.

```bash
imsg --redact-codes history --chat-id 1
# "873934 is your Ticketmaster code." -> "[redacted] is your Ticketmaster code."
```

This is a heuristic derived from real SMS OTP formatting, not a guarantee:

- Matches a `code`, `pin`, `otp`, `passcode`, or `authentication` keyword next
  to a 4–10 character digit-and-dash token, in either order — both "code:
  123456" and "123456 is your code" (the autofill-friendly format used by
  Google, PayPal, Coinbase, and others) are handled.
- **Every** matching token is replaced with `[redacted]`; the rest of the
  message is left intact. Redacting only the nearest match was a real leak:
  the token closest to a keyword is not always the secret, so a message
  reading "Citi card ending in 8940 … enter one-time passcode 082156" spent
  its one replacement on the card digits and published the passcode. Messages
  also simply carry two codes ("Alarm Code for Legacy System …" then "Alarm
  Code for Ring …"), where the second was never considered.
- A candidate inside a digit-and-dash run longer than 10 characters is skipped
  as a phone number, so "Didn't request a code? Call 1-800-387-2331" keeps its
  support number intact.
- Alphanumeric codes (rare — e.g. "7fpa1i") are **not** redacted.
- Only the first group of a space-separated multi-group code (e.g. a Pokémon GO
  trainer code, "4077 6631 9833") is redacted. Digits in the gap between
  keyword and token end the match, which is deliberate — it is what stops the
  matcher from reaching past an unmatchable code to a support phone number
  mentioned later.
- Street numbers and ZIPs are over-redacted when they sit within 60 characters
  *before* a code keyword with no digits in between: "1234 Main Street. Alarm
  code 271828" loses both. ("1234 30th Street" keeps its number, because the
  digits in "30th" end the match.) This errs toward removing too much rather
  than too little, and is left as-is.
- Coupon/discount codes phrased identically to OTP language (e.g. "code
  GREATMOVE15") may also be redacted; treated as an acceptable, low-stakes
  false positive.

## Advanced IMCore

Normal `chats`, `history`, `watch`, `send`, `react`, and read-only RPC workflows do not use private frameworks or process injection.

Read receipts, typing indicators, rich sends, message mutation, stickers, polls, and chat management use an injected helper inside Messages.app. They require SIP to be disabled and may be blocked by library validation or private-entitlement checks on current macOS releases. Start with [Advanced IMCore](docs/advanced-imcore.md), then use the [bridge command reference](docs/bridge.md) for the full CLI surface and IPC layout.

## Documentation

The complete guide lives at **[imsg.sh](https://imsg.sh)**. Useful entry points include [install](docs/install.md), [permissions](docs/permissions.md), [history](docs/history.md), [watch](docs/watch.md), [send](docs/send.md), [attachments](docs/attachments.md), [Linux](docs/linux.md), and [troubleshooting](docs/troubleshooting.md).

## Development

```bash
make lint
make test
make build
```

`IMsgCore` contains the reusable Swift core, `imsg` contains the CLI, and `IMsgHelper` contains the optional injected helper. The package uses Swift 6 and targets macOS 14 or newer.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Apple; iMessage and SMS are trademarks of their respective owners.
