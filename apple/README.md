# Hermes for Apple Watch

A standalone watchOS app (SwiftUI, watchOS 10+) that ports the Wear OS client: same gateway,
same wire contract, same chat/session model. The watch talks to your Hermes gateway directly
(per-agent `API_SERVER_KEY` bearer); watchkit stays the optional helper for mermaid, images,
state.db session reads and agent-key learning.

```
apple/
  HermesCore/     Swift package — pure logic + networking, `swift test` on macOS
  HermesWatch/    watchOS app target (SwiftUI) — settings, chat engine, screens
  project.yml     XcodeGen spec → HermesWatch.xcodeproj
```

## Build

```bash
scripts/apple.sh test      # 21 HermesCore tests; Command Line Tools are enough
scripts/apple.sh project   # brew install xcodegen; generates apple/HermesWatch.xcodeproj
scripts/apple.sh build     # needs full Xcode with the watchOS SDK
```

Open `apple/HermesWatch.xcodeproj` and set a signing team on the `HermesWatch` target. Then run it on
a paired Apple Watch or the watchOS simulator. Configure everything in-app: ☰ ▸ Settings ▸
Gateways (endpoints, token), watchkit token, Agent keys ▸ ⟳ learn.

## What maps to what

| Wear OS (Kotlin) | Apple Watch (Swift) |
|---|---|
| `domain/ProfileLogic`, `GatewayModel`, `Failover`, `SessionHistory`, `SessionSearch`, `ModelCatalog`, `NotificationDeepLink`, `SessionManage` | `HermesCore`, same rules, test cases ported from `app/src/test` |
| `net/HermesApi` (OkHttp + okhttp-sse) | `HermesAPI` (URLSession, hand-split SSE bytes → `SSEParser` → `RunEvent`) |
| `net/Watchkit` | `WatchkitClient` |
| `net/EndpointResolver` (2.5 s prober) | `EndpointResolver` actor + `HTTPProber` |
| `ui/md/WatchMarkdown` | `WatchMarkdown` blocks + `AttributedString(markdown:)` inline |
| `domain/ChatSession` | `HermesWatch/ChatSession.swift` (`@MainActor ObservableObject`) |
| `data/ChatStore` (DataStore + files) | `ChatStore` (Application Support JSON, atomic writes) |
| `data/AppSettings` (DataStore) | `AppSettings` (Keychain for gateways/tokens, UserDefaults for prefs) |
| `notify/Notifs` + approval receiver | `Notifications` (UNUserNotificationCenter, inline Approve/Deny) |
| `voice/SpeakAloud` | `Speaker` (AVSpeechSynthesizer) |
| Orb tap → Vosk STT | Orb = `TextFieldLink` → system dictation / Scribble / keyboard |
| Orb dial 8 lanes | ☰ menu: Chats · Sessions · Agent · Model · /btw · /steer · /fork · Sync · Settings |

Behaviour kept: durable idempotent submits with failover retry; SSE plus the 3-second status
poller (approval watchdog, never-lose-the-answer); stop, steer, fork, btw, fork-on-edit;
cross-profile sessions with watchkit fallback for key-less agents; history backfill and catch-up;
two-pass search; per-chat model pick plus adoption of the session's stamped model; per-agent keys;
answer and approval notifications while backgrounded.

## Not ported (yet)

- **On-watch Vosk STT / whisper fallback.** watchOS gives apps system dictation (on-device where
  the watch supports it) through the text input sheet. Raw-mic capture to watchkit `/stt/whisper` is not wired.
- **Body tools (Health Services, GPS → snapshot pusher / MCP).** These would need HealthKit +
  CoreLocation and the `SnapshotPusher` equivalent.
- **Tile and complication.** They would need a WidgetKit extension target.
- **Dev broadcast hooks (`DevAskReceiver`).** There's no adb on watchOS. Configure in-app instead.
- **Legacy-key migration and orb-dial customisation.** These only existed for Wear OS installs and gestures.
- **Background runs.** watchOS suspends the app soon after wrist-down, and there is no wake-lock
  equivalent. Answer/approval notifications only fire while the app still has runtime. Otherwise the run
  is re-attached or settled from `GET /v1/runs/{id}` when the app returns (the same resume path
  as a cold start). Push-driven alerts would need APNs from the gateway side.

## ATS

Gateways are plain `http` on the tailnet (WireGuard-encrypted) or the home LAN, so the target
sets `NSAllowsArbitraryLoads`. If every gateway you use is HTTPS, remove it from `project.yml`.
