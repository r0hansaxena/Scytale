# Scytale

End-to-end encrypted 1:1 messaging on the [Atsign Platform](https://docs.atsign.com/core),
built with Flutter for **Linux desktop**, plus a **Personal AI Agent** (Dart CLI)
that summarizes conversations, extracts action items, and answers
"what did I miss?" — all without any application backend.

Platform SDK reference for future development sessions: [ATPLATFORM_GUIDELINES.md](ATPLATFORM_GUIDELINES.md).

## Architecture (node mapping)

| AI Architect node | Implementation |
|---|---|
| Person (Sender/Receiver) | Each user signs in with their own Atsign via the Welcome/Auth screen ([lib/services/auth_service.dart](lib/services/auth_service.dart)) |
| Scytale | This Flutter app: inbox, conversation view, composer, reactions, replies, read receipts, favorites, profiles ([lib/](lib/)) |
| Message + Thread Graph | Encrypted AtKeys in the `scytale` namespace on each user's atServer (key table below) — no server-side store |
| Personal AI Agent | Dart CLI in [agent/bin/personal_agent.dart](agent/bin/personal_agent.dart), same Atsign as its owner, isolated `agent` RPC domain, invoked from the app over AtRpc |

- **Namespace:** `scytale` (app data). Agent RPC traffic rides in `agent.__rpcs.scytale`.
- **No backend:** atServers are the only infrastructure; every value is E2E encrypted (except the intentionally public profile).

## Data flow

```
 @alice (app) ── put() + notify() ──▶ @alice atServer ──▶ @bob atServer ──▶ @bob (app)
      │              msg.<id>.scytale (sharedWith @bob)                     │
      │                                                                       ▼
      │                                              stores self-copy recvmsg.<id>.scytale
      │                                              sends read.<aliceNoAt>.scytale back
      │
      └── AtRpc request.<n>.agent.__rpcs.scytale ──▶ Personal AI Agent (same Atsign)
                                                        reads own msg/recvmsg keys,
                                                        replies success.<n>... payload
```

- **Send:** every peer-facing write is `atClient.put()` (durable, fire-and-forget) **plus** `notificationService.notify()` (real-time + `NotificationResult` → delivery ticks).
- **Receive:** one subscription — `notificationService.subscribe(regex: '(msg|rct|read)\..*\.scytale@', shouldDecrypt: true)`. The monitor replays notifications missed while offline.
- **Offline catch-up:** on startup, each known peer's atServer is scanned via `getAtKeys(regex: 'msg\..*\.scytale', sharedBy: peer)` and unseen messages fetched with `get()`.
- **Multi-device history:** inbound items are re-stored as self AtKeys (`recvmsg.*` etc.) so they sync to all of the owner's devices.

## Key conventions (namespace `scytale`)

| Key | Visibility | Value (JSON) | Purpose |
|---|---|---|---|
| `msg.<msgId>` | sharedWith peer | `{id, from, to, text, ts, replyTo?, edited, deleted}` | Message. Edit = re-put same id; delete = tombstone (`deleted: true`, empty text) |
| `recvmsg.<msgId>` | self | same as above | Receiver's synced copy of an inbound message |
| `rct.<msgId>.<emojiId>` | sharedWith peer | `{msgId, emoji, by, ts, removed}` | Emoji reaction add/remove (`emojiId` = hex of emoji code units) |
| `recvrct.<msgId>.<emojiId>.<fromNoAt>` | self | same | Synced copy of inbound reaction |
| `read.<peerNoAt>` | sharedWith peer | `{conversationWith, lastReadTs}` | Read-receipt watermark ("I read your messages up to ts") |
| `recvread.<fromNoAt>` | self | same | Synced copy of inbound receipt |
| `myread.<peerNoAt>` | self | same | My own read position (drives unread counts; read by the agent) |
| `fav.<msgId>` | self | `{msgId, ts}` | Favorite/starred flag |
| `call.<callId>.<seq>` | sharedWith peer (notify-only, ttl 60s) | `{callId, type: offer\|answer\|candidate\|bye, sdp?, candidate?}` | WebRTC call signaling — ephemeral, never stored |
| `profile` | **public** | `{name, bio, avatarB64?}` | Lightweight public profile |
| `request.<n>.agent.__rpcs` / `(success\|error\|ack\|nack).<n>.agent.__rpcs` | sharedWith self | AtRpcReq / AtRpcResp JSON | Agent RPC envelope (managed by AtRpc) |

Delivery states shown in the UI: `sending` → `stored` (put succeeded; peer gets it eventually) → `delivered` (notification confirmed) → read (peer's `read.*` watermark ≥ message ts). `failed` if both put and notify fail.

## Video / voice calls

1:1 calls use **WebRTC** ([lib/services/call_service.dart](lib/services/call_service.dart)):

- **Media** flows directly between the two peers (DTLS-SRTP encrypted) — no media server.
- **Signaling** (offer/answer/ICE/hangup) rides atProtocol notifications in the
  `scytale` namespace — the same E2E encrypted channel as chat (`call.*` keys above).
- NAT traversal uses public STUN (`stun.l.google.com`) only. There is **no TURN
  relay**, so calls between two very restrictive NATs may fail to connect —
  a documented tradeoff to keep the zero-backend story intact.
- No camera? The call automatically falls back to audio-only.
- Start a call from the 📹 icon in any conversation.

## Agent RPC formats

Request payload: `{"method": "what_did_i_miss" | "summarize" | "action_items", "params": {"peer"?: "@bob", "sinceTs"?: 1700000000000}}`

Response payload: `{"result": "<text>", "mode": "claude" | "heuristic"}` (or `{"error": ...}` with respType `error`).

## Running the app

Prereqs: Flutter (Linux desktop enabled), and at least one Atsign.
Get free Atsigns: https://my.atsign.com/starterpack_app (the app's first-run
gate walks you through this).

```bash
flutter pub get
flutter run -d linux
```

First launch shows the **Atsign Gate** (mandatory), then the Welcome screen with
four auth workflows: keychain login, new-Atsign onboarding (Registrar), APKAM
device enrollment, and .atKeys file import.

Testing chat needs two Atsigns. Run a second instance as a different Linux user
or on another machine (two instances under one OS user share the keychain and
app-support storage), onboard the second Atsign there, then start a chat via
the ➕ button using the peer's Atsign.

## Running the Personal AI Agent

```bash
cd agent
dart pub get
# Heuristic mode (no LLM):
dart run bin/personal_agent.dart -a @alice
# Claude-powered (recommended):
export ANTHROPIC_API_KEY=sk-ant-...
# optional: export AGENT_MODEL=claude-opus-4-8
dart run bin/personal_agent.dart -a @alice
```

- The agent authenticates with the `.atKeys` file in `~/.atsign/keys/@alice_key.atKeys`
  (or pass `-k /path/to/keys.atKeys`). Export a backed-up keys file for an
  Atsign onboarded in the app via the platform keychain, or onboard the Atsign
  once with any at_ tool that writes `~/.atsign/keys`.
- Each instance auto-creates a unique temp storage dir (override with `-s`).
  Multiple instances coordinate via AtRpc's immutable-mutex race — only one
  handles each request.
- In the app: 🤖 icon → *Personal AI Agent* → "What did I miss?", "Summarize",
  or "Action items". The result chip shows whether Claude or the heuristic
  produced the answer.

## Project layout

```
lib/
  core/constants.dart            namespace, registrar, agent RPC domain
  models/models.dart             ChatMessage, Reaction, ReadReceipt, Profile
  services/auth_service.dart     4 auth workflows + post-auth setup
  services/message_service.dart  send/receive/subscribe, reactions, receipts, favorites, offline sweep
  services/profile_service.dart  public profile put/get
  services/agent_client.dart     AtRpcClient wrapper to the agent
  screens/atsign_gate_screen.dart  mandatory first-run gate
  screens/welcome_screen.dart      auth workflows
  screens/inbox_screen.dart        conversation list + unread badges
  screens/conversation_screen.dart messages, composer, reactions, replies, edit/delete
  screens/profile_screen.dart      profile editor
  screens/agent_screen.dart        AI agent UI
agent/
  bin/personal_agent.dart        Personal AI Agent (Dart CLI, AtRpc server)
```

## Configuration notes

- Registrar (new-Atsign onboarding): `my.atsign.com`, API key in
  [lib/core/constants.dart](lib/core/constants.dart).
- Root domain: `root.atsign.org` (default; selectable in the auth dialogs).
- Linux desktop is the only platform wired up. For macOS/iOS/Android later,
  add the platform permissions listed in ATPLATFORM_GUIDELINES.md (file_picker
  entitlements/permissions, network client+server entitlements, local-network
  usage description).
- Deferred features (by design, this iteration): media/voice notes, typing
  indicators, presence, mentions, granular privacy toggles, group chats,
  TURN relay for calls.

## Verification checklist

- `flutter analyze` and `cd agent && dart analyze` — clean.
- `flutter test` — model round-trip tests.
- `flutter build linux` — release build.
- Manual E2E: onboard @a and @b in two instances → exchange messages both ways
  → delivery ticks progress sending→stored→delivered→read → react, reply, edit,
  delete (tombstone), favorite → close @b, send from @a, reopen @b → message
  arrives (offline catch-up) → run the agent for @b and ask "What did I miss?".
