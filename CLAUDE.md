# CLAUDE.md

This file provides guidance to AI assistants when working with code in this repository.

## Build

The app is built using Bazel via the `Make.py` wrapper. There is no selective per-module build — the only supported invocation builds the full `Telegram/Swiftgram` target, producing `bazel-bin/Telegram/Swiftgram.ipa`.

**Command:**

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion \
 --cacheDir ~/telegram-bazel-cache \
 build \
 --configurationPath build-system/local-development-configuration.json \
 --codesigningInformationPath build-system/fake-codesigning \
 --buildNumber=1 --configuration=debug_sim_arm64
```

**Codesigning is directory-based on this machine, not git-based.** The
`--gitCodesigningRepository` form documented previously does not work here: there
is no `~/.zshrc` and `TELEGRAM_CODESIGNING_GIT_PASSWORD` is not set in any shell
init file, so the fetch fails. Real profiles are committed instead:

| Path | Profiles | Use |
| --- | --- | --- |
| `build-system/fake-codesigning` | 9 × App Store distribution | simulator builds, TestFlight |
| `build-system/fake-codesigning-dev` | 9 × development (device-scoped) | direct install on a tethered device |

Bazel is not on `PATH`; Make.py drives `build-input/bazel-8.4.2-darwin-arm64`.
Warm-cache timings: simulator ~10 min, `debug_arm64` ~10 min the first time then
~15s, `release_arm64` ~18 min.

Add `--continueOnError` after `build` (forwards to bazel's `--keep_going`) when verifying changes that may surface errors in many files at once — it lets the full set of errors land in one pass instead of stopping at the first failing target.

**Running tests.** `Make.py test` runs Bazel test targets (same config + codesigning as `build`, forced `debug_sim_arm64`). It accepts `--target <label>` (added 2026-06-19; default `Tests/AllTests`) so a single `ios_unit_test` can run in isolation, e.g.:

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache \
 test --configurationPath build-system/local-development-configuration.json \
 --codesigningInformationPath build-system/fake-codesigning \
 --target //submodules/TextFormat:TextFormatTests
```

The first app-side `ios_unit_test` is `//submodules/TextFormat:TextFormatTests` (the mention/date link codecs). An `ios_unit_test` here needs an `ios_test_runner` pinned to a real device/OS (e.g. `iPhone 17` / `26.5`) — the default runner picks an invalid device and the test process exits 15. **Run new targets via `--target`, not the default suite:** `Tests/AllTests` currently references a dangling `//submodules/TgVoipWebrtc:TgCallsTests`, so the default would fail to build until that suite is repaired.

### Updating the running simulator after a rebuild (whole-`.app` copy)

`simctl install` will NOT replace an already-installed app when the build number is unchanged (installd keeps a hard-link cache), so a rebuilt binary silently doesn't take effect. **Preferred fix: copy the whole freshly-built `.app` over the installed bundle in place.** This is more robust than swapping only the `Frameworks/TelegramUIFramework` binary (no risk of app↔framework version skew), and it preserves the account/login because the **data container is a separate path** (`.../data/Containers/Data/Application/<uuid>/`, keyed by bundle id) — only the **bundle** container is replaced, and the install-DB entry stays valid since the path + bundle id are unchanged.

```sh
# Look the UDID up; do not hardcode it. The dedicated "K" sims referenced in an
# earlier version of this file no longer exist, and simctl answers a stale UDID
# with "Invalid device" rather than anything that hints the name has changed.
K3="$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 17 Pro \(/{print $2; exit}')"
BUNDLE=org.ccc38e857449d6e8.Limegram   # from build-system/local-development-configuration.json
# Fresh build output (unzipped bundle, not the .ipa). `-L` is REQUIRED — `bazel-out` is a symlink,
# so a plain `find bazel-out …` silently returns nothing:
SRC="$(find -L bazel-out -maxdepth 14 -path '*ios_sim_arm64-dbg*/Swiftgram_archive-root/Payload/Swiftgram.app' -type d | head -1)"
DEST="$(xcrun simctl get_app_container "$K3" "$BUNDLE" app)"   # installed bundle path
# GUARD before the destructive rm: never rm the installed app unless SRC actually resolved,
# or a failed cp leaves the sim with NO app installed (relaunch then fails).
[ -x "$SRC/Swiftgram" ] || { echo "no fresh bundle at SRC=$SRC — aborting"; exit 1; }
xcrun simctl terminate "$K3" "$BUNDLE" 2>/dev/null            # terminate before replacing the running binary
rm -rf "$DEST" && cp -Rp "$SRC" "$DEST"                        # replace bundle in place; data container untouched
xcrun simctl launch "$K3" "$BUNDLE"
```

The sim ignores code signing, so the unsigned `Swiftgram_archive-root` bundle runs fine. **Constrain the find to the config directory** (`ios_sim_arm64-dbg*` above): once you have built more than one configuration, `bazel-out` holds a `Swiftgram_archive-root` per arch/config and an unfiltered `head -1` silently picks the wrong one. Bazel stamps a reproducible `Jan 1 1980` mtime on the copied binary — that's expected, not a stale copy. The `Swiftgram_archive-root` is regenerated by the Make.py wrapper's post-build packaging; if it's stale/missing after an incremental build, unzip `Payload/Swiftgram.app` out of `bazel-bin/Telegram/Swiftgram.ipa` instead. (The older framework-only `cp` of `TelegramUIFramework` still works and is faster, but prefer the whole-`.app` copy to avoid version skew.)

## Device builds and TestFlight

**Direct install on a tethered device.** Distribution profiles cannot be
side-loaded (`get-task-allow=false`, no provisioned devices), so device builds
need the development set in `build-system/fake-codesigning-dev`. Regenerate it
with:

```sh
~/.sg-asc-venv/bin/python tools/limegram-dev-profiles.py            # auto-detect tethered device
~/.sg-asc-venv/bin/python tools/limegram-dev-profiles.py --udid <udid> --name 'My iPhone'
~/.sg-asc-venv/bin/python tools/limegram-dev-profiles.py --list     # read-only account dump
```

It registers the device in App Store Connect, creates an `IOS_APP_DEVELOPMENT`
profile per Limegram bundle id, and writes them under the filenames Make.py
expects. The `~/.sg-asc-venv` virtualenv holds its `pyjwt`/`cryptography`/
`requests` deps (the system python3 has none of them). Modern A12+ UDIDs are
`8hex-16hex` — **keep the hyphen**, App Store Connect rejects a stripped one.

Then build and install:

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache \
 build --configurationPath build-system/local-development-configuration.json \
 --codesigningInformationPath build-system/fake-codesigning-dev \
 --buildNumber=1 --configuration=debug_arm64
xcrun devicectl device install app --device <udid> bazel-bin/Telegram/Swiftgram.ipa
```

**TestFlight.** Use the App Store profiles and the appstore configuration:

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache \
 build --configurationPath build-system/appstore-configuration.json \
 --codesigningInformationPath build-system/fake-codesigning \
 --buildNumber=<unique> --configuration=release_arm64
xcrun altool --validate-app -f bazel-bin/Telegram/Swiftgram.ipa -t ios \
 --apiKey 343KK3A33G --apiIssuer 0a5f93a2-0d79-41d3-9904-aee08a76ed32
xcrun altool --upload-app   -f bazel-bin/Telegram/Swiftgram.ipa -t ios \
 --apiKey 343KK3A33G --apiIssuer 0a5f93a2-0d79-41d3-9904-aee08a76ed32
```

altool reads the key from `~/.appstoreconnect/private_keys/AuthKey_343KK3A33G.p8`
(copy of `build-system/AuthKey_343KK3A33G.p8`). **Bump `--buildNumber` every
upload** — Apple rejects a duplicate `CFBundleVersion` within a version. Always
`--validate-app` first; it catches the same errors as the upload without burning
a build number. Processing to `VALID` takes 5-15 min; the internal beta group
"Limegram Internal" has `hasAccessToAllBuilds=true`, so a processed build needs no
further wiring (and explicitly POSTing to that group's `relationships/builds`
returns a harmless 422 — builds attach on their own).

Note `build-system/register_app.py` carries a stale `TEAM_ID` (`C67CF9S4VU`) and a
`PRIVATE_KEY_PATH` pointing outside this checkout. The live team is `KH29VAV74D`.

### Entitlements must be a subset of what the profile grants

`ProcessEntitlementsFiles` fails the build when the generated entitlements name a
key the provisioning profile lacks — but **simulator builds skip that check
entirely**, so an entitlement mistake stays invisible until the first
`debug_arm64`/`release_arm64` build. When adding a capability, gate it on the
bundle id in `Telegram/BUILD` the way `unrestricted_voip_fragment` and
`carplay_fragment` do, rather than emitting it unconditionally; Apple grants
things like CarPlay Messaging per-app-id and forks do not inherit them.

Open follow-up: `MinimumOSVersion` is 13.0. From Spring 2027 App Store Connect
rejects uploads below iOS 15.0 (altool warning 90068).

## Translation backends

Message translation routes through a user-selectable service, chosen in Swiftgram
Settings ▸ Translation ▸ Service and stored as
`SGSimpleSettings.TranslationBackend`:

| Case | Implementation |
| --- | --- |
| `default` | Telegram's own translation API |
| `gtranslate` | `Swiftgram/SGGTranslate` — scrapes `translate.google.com/m`, one request per line |
| `system` | iOS 18+ `Translation` framework (`TranslateScreen.swift`) |
| `azure` | `Swiftgram/SGAzureTranslate` — Azure AI Translator REST v3.0, native array batching |
| `openai` | `Swiftgram/SGOpenAITranslate` — OpenAI chat completions behind a translation prompt, one request per message |
| `openaiRealtime` | `Swiftgram/SGOpenAIRealtimeTranslate` — `gpt-realtime-2` over the realtime WebSocket, batches sequentially down one socket |
| `openaiCasual` | `Swiftgram/SGOpenAICasualTranslate` — `gpt-4o` over chat completions, casual register, 6-message context window |
| `openaiLuna` | `Swiftgram/SGOpenAILunaTranslate` — `gpt-5.6-luna`, the same provider and prompt as `openaiCasual` with a 20-message window |

The selection is applied in `sgWrappedTranslateSingle` / `sgWrappedTranslateMultiple`
(`TelegramCore/.../TelegramEngineMessages.swift`) and `sgTranslateViaText`
(`TelegramCore/.../Translate.swift`). To add a backend: add the enum case, add a
branch in those three functions, add a `Settings.Translation.Backend.<case>`
string, and add the module to `submodules/TelegramCore/BUILD`'s `sgdeps`. Also
add it to `SGTranslationCompareModel` and to the skip-when-unconfigured checks in
`SGSettingsController`, or the new service is invisible in both the picker and
the comparison screen.

Two things to know when debugging a backend:

- **Failures fall back silently to GTranslate.** A bad credential produces
  plausible translations from the wrong service rather than an error. To confirm
  which service answered, translate the same text under two settings and compare
  wording.
- `translationBackendUsesLocalText` (in `SGSimpleSettings`) is what the chat UI
  checks to force the client-side `viaText:` path regardless of Premium status.
  A new client-side backend must be added to it, not just to the enum.

### The OpenAI backend is a prompt, not a translation API

Two consequences worth knowing before changing it:

- **One request per message, deliberately.** Asking the model for a batch in a
  single call means trusting it to return exactly N items in order; one malformed
  reply would scramble a whole chat. Translating a 40-message chat is 40 calls.
- **Replies are post-processed.** Models wrap output in quotes despite being told
  not to, so a single pair of wrapping quotes is stripped — unless the original
  message was itself quoted.

There are **two** chat-completions backends, `openai` (gpt-5.1) and
`openaiCasual` (gpt-4o). They are the same code with a different model and
prompt: `openai` is told to preserve the original and not editorialise, while
`openaiCasual` is told to write what a native speaker would actually say —
regional idiom, contractions, relaxed register — favouring that over literal
accuracy. Measured side by side, `T'inquiète pas, c'est pas grave` versus
`Pas de souci, ce n'est pas grave`. Neither is strictly better; that is why both
are selectable and why the comparison screen shows them together.

`SGOpenAILunaTranslate` is in turn a mechanical copy of the casual provider,
differing in exactly two values: `model` (`gpt-5.6-luna`) and
`contextMessageCount` (20 against 6). It does not copy the prompt — it
*references* `SGOpenAICasualTranslateConfig.systemPrompt` and
`.contextInstruction`, so the two cannot drift and a side-by-side isolates the
model and window rather than comparing two prompts. Verify a model exists before
wiring it: `GET /v1/models` on the account currently lists `gpt-5.6-luna`,
`gpt-5.6-sol` and `gpt-5.6-terra`.

The wider window is measurable. With the antecedent 14 messages back, the
6-message provider loses it and answers `¿Está bueno?`; the 20-message one still
sees it and answers `¿Está buena?`.

The per-backend window lives in `sgSelectedBackendContextWindow()`
(`Translate.swift`) — a new context-taking provider must be added there or it
silently gets none.

`SGOpenAICasualTranslate` is a **mechanical copy** of `SGOpenAITranslate` with
symbols renamed, not a reimplementation, and the two output-cleaning helpers
(`sgStripModelQuoting`, `sgParseOpenAIErrorMessage`) are exported from
`SGOpenAITranslate` and imported rather than duplicated — so the pair cannot
drift in how they strip model quoting or surface errors. Its prompt keeps the
formatting sentence about @mentions, URLs and code spans: that is not padding,
without it the model rewrites mentions and breaks messages rather than merely
restyling them.

The request body is intentionally just `model` + `messages`. Newer
reasoning-capable models reject `temperature` and renamed `max_tokens`, so
omitting both keeps the backend working across whatever model id is configured.
That applies to the casual backend too — gpt-4o would accept `temperature`, but
the prompt carries the register and a minimal body keeps the model constant
swappable.
HTTP failures carry OpenAI's own `error.message` through to the comparison
screen, which is what makes a misconfigured model self-diagnosing.

### The realtime backend, and why it is a separate module

`gpt-realtime-2` is **not reachable over `/v1/chat/completions`** — the live API
answers 404/400 — so it cannot be used by simply changing `model` in
`SGOpenAITranslateCredentials`. `SGOpenAIRealtimeTranslate` talks to
`wss://api.openai.com/v1/realtime` with `URLSessionWebSocketTask` instead. It
reuses the same key: `SGOpenAITranslateCredentials.key` is the only secret, and
the realtime module's own config (model, endpoint, prompt, limits) is committed
in `SGOpenAIRealtimeTranslateConfig.swift` because it holds nothing secret.

Protocol facts, all established against the live endpoint rather than the docs:

- **`OpenAI-Beta: realtime=v1` is now rejected** ("The Realtime Beta API is no
  longer supported"). `Authorization` is the only header.
- **`session.update` must carry `session.type = "realtime"`**, or the server
  answers `Missing required parameter: 'session.type'`.
- Text arrives as `response.output_text.delta`, terminated by `response.done`.
- **One response in flight per connection.** A second `response.create` before
  `response.done` fails with `conversation_already_has_active_response`, so a
  batch goes down one socket sequentially (~0.5s/message after a 1-3s connect).
- **`conversation.item.delete` does not work here** (`item_delete_invalid_item_id`)
  and desynchronises the read loop, so earlier turns cannot be pruned. Context
  therefore grows ~20-25 input tokens per message for the life of the socket.
  `maxMessagesPerConnection` (16) caps that; longer batches fan out over
  parallel sockets, which is allowed and roughly halves wall-clock at 20 items.
- **A bad key is not a failed upgrade.** The server completes the handshake and
  then sends an `error` event with `invalid_api_key`, so it surfaces as
  `.api(code, message)` — the `.handshake(Int)` case is a defensive fallback for
  a genuinely refused upgrade, not the path a wrong key takes. OpenAI masks the
  key in that message, so it is safe to show in the comparison screen.

Because every user message shares one conversation, the prompt carries an
explicit independence clause. Without it the model starts answering later
messages in context instead of translating them — verified with a batch
containing "What about the other one?", which translates literally rather than
resolving the reference.

**Verifying this module without the app.** The whole realtime path is plain
Foundation + SwiftSignalKit, so it can be compiled for macOS and run against the
live API in seconds, which is far faster than a 6-minute app build plus manual
UI steps:

```sh
mkdir -p /tmp/h/src && cp submodules/SSignalKit/SwiftSignalKit/Source/*.swift /tmp/h/src/
for f in Swiftgram/SGOpenAITranslate/Sources/*.swift Swiftgram/SGOpenAIRealtimeTranslate/Sources/*.swift; do
  sed -e '/^import SwiftSignalKit$/d' -e '/^import SGOpenAITranslate$/d' \
      -e 's/SwiftSignalKit\.Timer/H.Timer/g' "$f" > /tmp/h/src/"$(basename $f)"
done
# add /tmp/h/src/main.swift calling openAIRealtimeTranslateBatch(...)
xcrun swiftc -O -module-name H -o /tmp/h/h /tmp/h/src/*.swift && /tmp/h/h
rm -rf /tmp/h   # the copies contain the real API key — delete them
```

**The `gpt-realtime-*` models do not work here** (verified 2026-08-18).
`gpt-realtime-2` returns 404 *"This is not a chat model"* from
`v1/chat/completions` and 400 *"model not found"* from `v1/responses`, even
though its model page lists both endpoints and the account has access. Those
models are reachable only over the realtime protocol (WebSocket/WebRTC/SIP),
which this backend does not speak, and `gpt-realtime-translate` is
audio-in/audio-out only so cannot translate text at all. Using one would mean
writing a realtime WebSocket transport — that is open follow-up work, not a
config change. The shipped default is `gpt-5.1` (1.09s on a test phrase;
`gpt-4.1-mini` matched it at 1.10s for less money, `gpt-5-mini` was 2.44s).

Azure and OpenAI credentials are baked in at build time via
`Swiftgram/SGAzureTranslate/Sources/SGAzureTranslateCredentials.swift` and
`Swiftgram/SGOpenAITranslate/Sources/SGOpenAITranslateCredentials.swift`, both
**gitignored** — copy each from the `.swift.template` beside it on a fresh
checkout or those modules will not compile. An empty `key` disables the backend: the
row is hidden from the picker and never selected, so a blank file still builds and
runs.

## Driving builds from an agent with no macOS shell

`tools/sg-build-mcp/server.py` is a dependency-free MCP stdio server that runs
shell commands on this Mac as detached background jobs with polling, for sessions
whose own shell is a Linux container (e.g. Cowork running in the cloud). Register
it in `~/Library/Application Support/Claude/claude_desktop_config.json`, then fully
quit and reopen the app. See `tools/sg-build-mcp/README.md`; it grants arbitrary
shell access, so remove the entry when done.

## Code Style Guidelines
- **Naming**: PascalCase for types, camelCase for variables/methods
- **Imports**: Group and sort imports at the top of files
- **Error Handling**: Properly handle errors with appropriate redaction of sensitive data
- **Formatting**: Use standard Swift/Objective-C formatting and spacing
- **Types**: Prefer strong typing and explicit type annotations where needed
- **Documentation**: Document public APIs with comments

## Project Structure
- Core launch and application extensions code is in `Telegram/` directory
- Most code is organized into libraries in `submodules/`
- External code is located in `third-party/`
- App-side unit tests are minimal: the first `ios_unit_test` (`//submodules/TextFormat:TextFormatTests`) was added 2026-06-19 (run via `Make.py test --target` — see Build). The RichTextEditor SwiftPM package keeps its own suite (`swift test` / `Scripts/iostest.sh`). Most modules still have no tests.

## RichTextEditor editor & the `ChatInputContent` composer

A from-scratch WYSIWYG rich-text editor (`submodules/TelegramUI/Components/RichTextEditor`) is the native chat-composer backend — by default a **dual-field switch** (the composer uses the legacy input and latches to the native editor only when content becomes legacy-non-representable); the `forceNewTextInput` experimental flag (Debug Settings ▸ "Force Text Field v2") forces always-native. (This inverted the earlier default+`forceLegacyTextInput`-opt-out scheme.) `ChatInputContent` (a TelegramCore-native value model) replaced `NSAttributedString` as the composer currency. The app-side integration — the model and its load-bearing invariants, composer ↔ editor wiring, the formatting-menu / custom-emoji-mention-date / code-block / inline-media round-trips, rich-message send / edit / pending-display, the long-press-Send send-options preview, and draft persistence (local, cross-device media sync, re-login restore) — lives in [`docs/richtext-composer.md`](docs/richtext-composer.md). Editor internals (the TextKit seam, layout) are the editor's own `submodules/TelegramUI/Components/RichTextEditor/CLAUDE.md`; message **rendering** is [`docs/instantpage-richtext.md`](docs/instantpage-richtext.md).

## Embedded watch app (`Telegram/WatchApp`)

A standalone watchOS Telegram client (developed in the separate `~/build/tgwatch` repo) is vendored into this repo at `Telegram/WatchApp/` and can be embedded into the **device** IPA under `Telegram.app/Watch/`. It is built by `xcodebuild` (not Bazel) and codesigned by the Bazel build.

**Build it:** add `--embedWatchApp` to a Make.py **device** build (`--configuration=debug_arm64` or `release_arm64`) together with `--watchApiId`, `--watchApiHash`, `--watchSigningIdentity`, `--watchProvisioningProfile`. Off by default (it adds a ~4-min xcodebuild step); simulator builds never embed, and the default `debug_sim_arm64` build is unaffected.

**`Telegram/WatchApp/` is a synced snapshot — do not hand-edit it.** The source of truth and dev tooling live in the `tgwatch` repo. To change the watch app, edit it there, then re-sync with `tgwatch/tools/export-sources.sh /abs/path/to/telegram-ios/Telegram/WatchApp` and commit the result. The committed `tgwatch.xcodeproj` is generated (kept via a `!tgwatch.xcodeproj` negation in `Telegram/WatchApp/.gitignore`, since the root `.gitignore` ignores `*.xcodeproj`); `.build`/`.swiftpm`/`xcuserdata` are excluded.

**How it's wired:** `//Telegram:TelegramWatchApp` (rule in `Telegram/prebuilt_watchos.bzl`) runs in **two actions**: `PrebuiltWatchosCompile` (`Telegram/prebuilt_watchos_compile.sh`) runs xcodebuild on the snapshot in a writable temp copy with PLACEHOLDER version/api values (the bundle ids are baked from the snapshot's pbxproj/Info.plist — `ph.telegra.Telegraph.watchkitapp` / `ph.telegra.Telegraph`), emitting an unsigned `.app`; `PrebuiltWatchosPatchSign` (`Telegram/prebuilt_watchos_patch.sh`) then rewrites **six** per-build Info.plist keys (`CFBundleShortVersionString`, `CFBundleVersion`, `TG_API_ID`, `TG_API_HASH`, `CFBundleIdentifier`, `WKCompanionAppBundleIdentifier`) and codesigns the `.app` + nested `TDLibFramework.framework` (identity + the watchkitapp profile from `--define`s). The result feeds the `Telegram` `ios_application`'s `watch_application` slot (gated by the `//Telegram:embedWatchApp` flag). The rule takes `bundle_id` (set to `"{telegram_bundle_id}.watchkitapp"` in `Telegram/BUILD`) and derives the host bundle id by stripping the `.watchkitapp` suffix; both are passed to the patch worker as args (not action inputs), so the patch action re-runs when the host bundle id changes but the (expensive) compile stays cached. **The compile action's only inputs are the snapshot (+ its worker)** — so changing the version, build number, api id/hash, host bundle id, or signing identity re-runs only the cheap patch+sign action, not xcodebuild; xcodebuild re-runs only when the snapshot changes. This is correct because none of those values reach the compiled binary: each lands only in the Info.plist (via `$(...)` substitution and a runtime `Bundle.main.object(forInfoDictionaryKey:)` lookup in `Secrets.swift`, except for the bundle-id keys which only Info.plist consumers read).

**Non-obvious invariants** (also in the `.bzl` comments): `AppleBundleInfo`'s public init is banned — use the internal `new_applebundleinfo`; `watch_application` requires BOTH `AppleBundleInfo` (with a non-None `infoplist` File) AND `WatchosApplicationBundleInfo`; the embedded watch app's `CFBundleShortVersionString`/`CFBundleVersion` must exactly equal the host's (sourced from `versions.json['app']` + `--define=buildNumber`); the host does NOT re-sign the embedded watch app, so the worker must sign it; the watch bundle id `ph.telegra.Telegraph.watchkitapp` must track the host `telegram_bundle_id`.

**Status:** verified with **development** signing on `debug_arm64` only. Open follow-ups before App Store shipping: secure timestamp (drop `codesign --timestamp=none`), distribution profile (`get-task-allow=false`), `release_arm64` + `altool --validate-app`, and committing a `Package.resolved` for hermetic remote-SwiftPM resolution.

## View frame ownership

A view does not control its own `frame`. The parent (or a layout system) sets the frame; the view positions its own subviews against `self.bounds` in response.

This matters in two places specifically:

- **Reusable components (`UIView`/`ASDisplayNode` subclasses).** Public methods like `update(...)` / `apply(...)` rebuild internal state, mutate child frames, and read `self.bounds` to lay them out — but they do not write `self.frame`. The caller has already chosen the frame; mutating it from inside the component overrides that choice and fights the parent's next layout pass.
- **`asyncLayout`-style content nodes.** The measure pass runs off-main and returns a size; the apply step runs on main and the chat layout system positions the node. A child view that writes `self.frame` from `update()` corrupts the size the parent just measured.

Rare exceptions: top-level view-controller views integrating with the system's first-responder/inset model. If you find yourself wanting `self.frame = …` from inside a child view, refactor so the parent positions it instead.

## ChatHistoryListNode composition

`ChatHistoryListNodeImpl` (`submodules/TelegramUI/Sources/ChatHistoryListNode.swift`) **composes** rather than inherits `ListViewImpl` (`submodules/Display/Source/ListView.swift`): it is an `ASDisplayNode` wrapper holding `private let listView: ListViewImpl` and exposes a deliberately narrowed surface (the `ChatHistoryListNode` protocol in `AccountContext` + curated concrete forwarders) instead of the full `ListView` API. `ListViewImpl` gained a `getCustomItemDeleteAnimationDuration` closure hook so the one former `override` works via composition.

These invariants are **compiler-invisible** — getting them wrong silently breaks the app's primary scroll surface:

- **The π rotation stays on the wrapper** (chat is bottom-up). The wrapper keeps `transform = π` + a `rotated` flag; the child `listView` gets only `rotated = true` (identity transform). So `historyNode.view`/`.layer` remain the rotated surface, and rotation-coupled code — hitTest coordinate conversions, the blur `drawHierarchy` flip, the dust/delete layer, `.layer` animations, and the overscroll-overlay + snapshot-slide reparenting — **stays on `self` (the wrapper)** unchanged.
- **Only genuine scroll-surface concerns route to the child:** gesture recognizers (selection pan; external taps via `addContentGestureRecognizer`) attach to `self.listView.view` to share the scroll pan's simultaneity environment, and scroller access goes to `self.listView.scroller`.
- **`let _ = self.view` in `init` is load-bearing.** The old inherited node was view-loaded eagerly (so `self.isNodeLoaded` was always true); `enqueueHistoryViewTransition` gates the history dequeue on it. The wrapper must force-load its view in init or off-screen nodes (created during thread switches) never become ready and `reloadChatLocation`'s completion never fires.
- **Item nodes are one level deeper.** Any `.supernode` chain / hierarchy-depth assumption passing through the history node gained one level (item → child `listView` → wrapper). E.g. `ChatMessageTransitionNode` converts item rects up `supernode?.supernode?.supernode?.view` (was 2 hops) so the wrapper's rotation is applied as an intermediate transform; a missing hop reflects effect-burst overlays ~180°.
- Child geometry is driven inside `updateLayout` via `transition.updateFrame(node: self.listView, …)` — the project never relies on ASDisplayNode's automatic `layout()`.

The public surface is being narrowed incrementally (e.g. `scroller` → `bounces`/`contentHeight`; the `trackingOffset`/`beganTrackingAtTopOrigin` pair → `didInteractivelyDragFromTopOrigin`). Prefer intent-named accessors over re-exposing raw `ListView` state.

## InstantPage V2 & rich-text messages

Typed markdown with structure the regular message-entity set can't represent (headings, lists, tables, formulas, nested blockquotes) is sent as a **rich message** — a `RichTextMessageAttribute` carrying an `InstantPage`, drawn by `ChatMessageRichDataBubbleContentNode` via the **InstantPage V2** renderer (with AI-streaming progressive reveal, inline custom emoji, and entity cases). The detailed architecture and non-obvious invariants — streaming reveal, V2 table/text-box layout, custom-emoji & entity round-trips, task-list checkboxes, nested blockquotes, thinking blocks, the markdown send / edit / copy / paste paths, and surfacing rich-message media through the shared-media/gallery/preview pipelines via `Message.effectiveMedia` — live in [`docs/instantpage-richtext.md`](docs/instantpage-richtext.md).

## Postbox → TelegramEngine refactor (in progress)

A gradual migration is underway to eliminate direct `import Postbox` from consumer submodules in favor of `TelegramEngine`.

**Historical record:** Wave-by-wave outcomes, the running tally of Postbox-free modules, the full wave-selection guidance, and the `TelegramEngine.Resources` facade inventory (also authoritatively defined in `submodules/TelegramCore/Sources/TelegramEngine/Resources/TelegramEngineResources.swift`) live in [`docs/superpowers/postbox-refactor-log.md`](docs/superpowers/postbox-refactor-log.md). Read that file when you need wave-specific context, a full worked example of a pattern, or the history of a particular module's migration.

See the log for per-wave detail; the current wave count and the list of still-open migration opportunities live in the `project_postbox_refactor_next_wave.md` memory file.

### Rules that apply to every wave

1. `TelegramCore` does **not** `@_exported import Postbox`. Once a consumer drops `import Postbox`, every remaining Postbox-type reference must use an engine-typealiased equivalent.
2. **Never typealias `Postbox`, `Account`, or `MediaBox`.** These umbrella types rename without encapsulating. Narrow utility typealiases (`MemoryBuffer`, `PostboxDecoder`, `PostboxEncoder`, `AdaptedPostboxDecoder`, `MediaResource`, …) remain allowed and expected.
3. No new engine wrapper **structs** unless the wave's spec explicitly allows — only typealiases and thin forwarding methods.
4. **Discovery first:** before adding any new engine wrapper/typealias, grep `submodules/TelegramCore/Sources/TelegramEngine/` for existing equivalents. Record the search result in the commit message.
5. **Abandonment protocol:** if a module can only be refactored by violating rule 2 or by editing a module outside the current wave's list, mark the task Abandoned with a recorded reason. Do NOT substitute a new module mid-wave.
6. Full project build per module. No unit tests exist in this project.
7. **TelegramCore never imports UIKit/Display.** `TelegramCore` is shared with the Telegram-Mac codebase; its Bazel `deps` and source files must not reference UIKit, Display, or any Apple-UI framework. UIKit-needing helpers (image scaling, rendering, etc.) stay in consumer-side submodules.
8. **Never substitute Postbox protocols (`Media`, `Peer`, `Message`) with `Any` / `AnyObject`** in code that previously used them. Type erasure throws away the domain semantics that the next reader expects. Use the matching engine wrapper (`EngineMedia`, `EnginePeer`, `EngineMessage`) — extending it as needed (e.g. add a missing case-init or convenience). If neither typealias nor wrapper covers the use site, restore the original Postbox import + type for now and flag the case for a future facade. Existing `Any`/`AnyObject` parameters predating the refactor are not in scope for this rule.

### Engine typealias cheat sheet (existing aliases)

```
PeerId              → EnginePeer.Id
MessageId           → EngineMessage.Id
MessageIndex        → EngineMessage.Index
MessageTags         → EngineMessage.Tags
MessageAttribute    → EngineMessage.Attribute
MessageFlags        → EngineMessage.Flags
MessageForwardInfo  → EngineMessage.ForwardInfo
MediaId             → EngineMedia.Id
PreferencesEntry    → EnginePreferencesEntry
TempBox             → EngineTempBox
PinnedItemId        → EngineChatList.PinnedItem.Id
MemoryBuffer        → EngineMemoryBuffer           (added 2026-04)
PostboxDecoder      → EnginePostboxDecoder         (added 2026-04)
PostboxEncoder      → EnginePostboxEncoder         (added 2026-04)
AdaptedPostboxDecoder → EngineAdaptedPostboxDecoder (added 2026-04)
ItemCollectionId    → EngineItemCollectionId       (added 2026-04-20)
FetchResourceSourceType → EngineFetchResourceSourceType (added 2026-04-20)
FetchResourceError  → EngineFetchResourceError     (added 2026-04-20)
StoryId             → EngineStoryId                (added 2026-05-02)
ChatListIndex       → EngineChatListIndex          (added 2026-05-03)
TempBoxFile         → EngineTempBoxFile            (added 2026-05-03)
ItemCollectionItemIndex → EngineItemCollectionItemIndex (added 2026-05-03)
ItemCollectionViewEntryIndex → EngineItemCollectionViewEntryIndex (added 2026-05-03)
ValueBoxEncryptionParameters → EngineValueBoxEncryptionParameters (added 2026-05-03)
MessageAndThreadId  → EngineMessageAndThreadId      (added 2026-05-03)
PeerStoryStats      → EnginePeerStoryStats          (added 2026-05-03)
MessageHistoryAnchorIndex → EngineMessageHistoryAnchorIndex (added 2026-05-03)
ChatListTotalUnreadStateCategory → EngineChatListTotalUnreadStateCategory (added 2026-05-03)
ChatListTotalUnreadStateStats → EngineChatListTotalUnreadStateStats (added 2026-05-03)
PeerSummaryCounterTags → EnginePeerSummaryCounterTags (added 2026-05-03)
ChatListTotalUnreadState → EngineChatListTotalUnreadState (added 2026-05-04)
ItemCacheEntryId    → EngineItemCacheEntryId        (added 2026-05-04)
HashFunctions       → EngineHashFunctions           (added 2026-05-04 wave 251)
CachedMediaResourceRepresentationResult → EngineCachedMediaResourceRepresentationResult (added 2026-05-04 wave 265)
MediaResourceDataFetchResult → EngineMediaResourceDataFetchResult (added 2026-05-04 wave 266)
MediaResourceDataFetchError → EngineMediaResourceDataFetchError (added 2026-05-04 wave 266)
MediaResourceStatus → EngineMediaResourceStatus     (added 2026-05-04 wave 272)
```

**Free-function thin forwarders in TelegramCore** (rule 3 allows):
- `engineFileSize(_ path:, useTotalFileAllocatedSize: Bool = false)` — forwards to Postbox's `fileSize(...)` (added 2026-05-04 wave 268)

**TelegramEngineUnauthorized.resources facade**: `UnauthorizedResources.storeResourceData(id: EngineMediaResource.Id, data:, synchronous:)` — bridges to `account.postbox.mediaBox.storeResourceData` (added 2026-05-04 wave 271)

For the `MediaResource` Postbox protocol, prefer the TelegramCore subtype `TelegramMediaResource` when the consumer's usage allows (note: `EngineMediaResource` is a wrapper **class**, not a typealias, so it is not interchangeable with the protocol).

### MediaResource → EngineMediaResource consumer migration

`EngineMediaResource` is a `final class` in `TelegramCore` wrapping a `MediaResource` value. Unlike the typealiases above it is **not** interchangeable with the protocol, but it does provide wrap/unwrap helpers:

- `EngineMediaResource(rawResource)` — wrap a raw `MediaResource`.
- `engineResource._asResource()` — unwrap to the raw `MediaResource`.
- `EngineMediaResource.ResourceData(rawResourceData)` — wrap `MediaResourceData`.
- `EngineMediaResource.Id(rawMediaResourceId)` — wrap `MediaResourceId`.

**Pattern for facade functions:** when a `TelegramEngine.<Area>` method leaks raw `MediaResource` in its public signature, **change the facade signature in place** to `EngineMediaResource` (and change any closure parameter types the same way). Bridge inside the facade body by calling the existing `_internal_*` function with `engineResource._asResource()` / wrapping raw inputs from inner closures with `EngineMediaResource(rawResource)`. Update all call sites in the same commit. The `_internal_*` function stays on raw `MediaResource` — it is the Postbox-facing layer.

Do **not** add opt-in `EngineMediaResource` overloads alongside raw-`MediaResource` overloads. Duplicate signatures fragment the public API and leave the leak in place forever.

For consumer modules, prefer `EngineMediaResource` as the type in properties, locals, generic arguments and function parameters when the usage is a pure type reference. Do **not** try to use `EngineMediaResource` where a class must conform to `TelegramMediaResource` (Postbox protocol) or override `isEqual(to: MediaResource)` — those remain `import Postbox`.

## tgcalls Testbench

This repo includes a tgcalls testbench (CLI tool, Go/Pion SFU, Docker build) layered on top of the iOS source. All testbench code, build instructions, and architecture docs live inside the tgcalls submodule:

- `submodules/TgVoipWebrtc/tgcalls/CLAUDE.md` — top-level testbench overview, build/run commands
- `submodules/TgVoipWebrtc/tgcalls/tools/cli/CLAUDE.md` — CLI test tool architecture
- `submodules/TgVoipWebrtc/tgcalls/tools/go_sfu/CLAUDE.md` — Go SFU internals
- `submodules/TgVoipWebrtc/CLAUDE.md` — tgcalls library internals + macOS/Linux build patches

Build the test binary from this directory with:

`./build-input/bazel-8.4.2 build //submodules/TgVoipWebrtc/tgcalls/tools/cli:tgcalls_cli`
