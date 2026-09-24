# Plan: live call translation fixes (build 15)

Overall: T1–T11 done, uncommitted on feature/azure-translator (2026-09-24). Build 16 on TestFlight: VALID, IN_BETA_TESTING, notes attached (2026-09-24). Pushed as 4334a26d10. Issue 1 (silent mic) open, diagnostic given to testers.

Status legend: [ ] todo · [~] in progress · [x] done · [!] blocked / needs a real call to confirm

Reported 2026-09-24 (Scott iPhone 18 Pro Max, sometimes Bose QC2 mic; Ericka iPhone 16e, Venezuelan Spanish):

1. Video call: mic sometimes missing from outgoing audio.
2. Video call: translate button shows ON at call start but nothing happens.
3. Translation stops working after a while (Ericka); button must be pressed twice to recover.
4. Ericka's voice is diarised as two speakers, so half her lines are captioned "Speaker 2" and never reach the subtitles.

## Findings so far

- (2) `CallControllerNodeV2` seeds the button from the per-contact saved
  `isCallTranslationEnabled` but never calls `sgStartTranslation()` for it, so
  the session is never created and the mic sink is never installed. Even if it
  were, `call.sharedAudioContext?.audioDevice` is only usable once the call's
  audio device is running, so the sink must be (re)installed when the call goes
  active, not just at button time.
- (3) `SGModulateSTTSession.receiveNext` on `.failure` sets `isOpen = false`
  and reports `.network`, but leaves `self.task` non-nil. Every later frame is
  sent into the dead socket and no reconnect ever happens. The session
  comment "the next utterance opens a fresh socket" is wrong. Toggling the
  button off/on creates a whole new session, which is the double-tap workaround.
  The socket dies whenever Modulate closes it after silence (the VAD sends
  nothing while the other person talks) or the 45 s `idleTimeout` fires.
- (4) Diarisation is `speaker_diarization=true`; the tap is post-AEC local mic
  so there is normally one speaker. Any label other than 1 is dropped from the
  subtitle strip. Fix: stop trusting the label for the subtitle gate and/or
  turn diarisation off. Check Modulate docs for a speaker-count parameter.
- (1) The mic tap runs inside the ADM `RecordedDataIsAvailable` under the ADM
  mutex, before WebRTC's transports get the buffer. The Swift sink allocates
  (array append, Data, dispatch). Also `SGModulateAudioFrontEnd` is mutated
  from the audio thread and from the session queue (`finish`) with no lock.
  Not yet proven to be the cause of a silent mic; the outgoing-audio path
  itself is untouched upstream code. Needs a device repro or logs.

## Tasks

- [x] T1 Reconnect the STT socket after a failure / server close (fix 3).
- [x] T2 Auto-start translation when the call becomes active if the saved
      per-contact toggle is on; re-install the mic sink whenever the audio
      device (re)appears, e.g. after the video upgrade (fix 2).
- [x] T3 Treat every diarised speaker as the local speaker for subtitles, and
      turn diarisation off (fix 4). Confirm against Modulate docs.
- [x] T4 Make the mic tap safe: copy-and-enqueue only on the audio thread,
      move all processing to a queue, serialise front-end state (fix 1
      candidate, and a real data race regardless).
- [x] T5 Build (debug_sim_arm64) and check own-file warnings.
- [x] T6 Write build-15 notes for the testers.

## Round 2 (2026-09-24, later)

5. After a medium/long utterance the transcript sometimes does not arrive
   until the speaker makes any noise. Hypothesis: the gate stops sending
   700 ms after speech ends, so the server never sees enough trailing silence
   to endpoint; the next noise carries silence around it and releases it.
6. Partial results: show transcription fragments live in the chat message
   and in the subtitles; replace with the final translation when it lands.
   Partials are never sent to translation.

- [x] T7 Reproduce 5 in the harness (clip + short hangover vs longer), fix.
- [x] T8 STT: `partial_results=true`, parse `partial_utterance`, expose it.
- [x] T9 Session: partial -> provisional subtitle line + throttled chat edit;
      final transcript replaces it, then translation edits in as before.
- [x] T10 Harness check of partial cadence / uuid continuity; rebuild.
- [x] T11 TestFlight: bump build number, release_arm64, validate, upload,
      set release notes from build15-notes.txt (user asked 2026-09-24).

## Notes / log

- Modulate streaming spec (velma_2_stt_streaming.yaml) has NO speaker-count
  parameter; `speaker_diarization` is the only knob, and speaker numbers are
  only stable within one connection. Decision: diarisation off. Every
  utterance is then unlabelled and treated as the phone owner's.
- The spec says the server closes the socket after any `error`, and
  URLSession's `timeoutIntervalForRequest` (was 45 s) fails a websocket that
  receives nothing for that long — the server only sends when an utterance
  finalises, so a listener's socket dies in 45 s. Both paths left a dead task.
- T1 design: `SGModulateSocket` (task + per-connection wall-clock ledger);
  session holds `live` and `ending`. Own idle timer ends the live socket
  gracefully (send "", read until done); failures/errors drop the socket;
  next frame reconnects. Stale-socket messages ignored by identity.
- T2: `sgAutoStartTranslationIfNeeded()` on first `.active` state. If the
  saved toggle is on but no target language resolves, the button is shown off.
- T4: `appendAudio` now copies + dispatches to the session queue; front end
  runs only there. `acceptsAudio` Atomic short-circuits when off.
- Issue 1 (silent mic) not root-caused. Diagnostic for testers: if the chat
  transcript fills while the remote hears nothing, the mic reaches the ADM and
  the loss is downstream (mute/transport/route); if it also stays empty, the
  input route is dead (Bluetooth HFP vs A2DP is the first suspect on Scott's
  side). Collect the call log from a failing call.

- 2026-09-24: plan created; code read through, findings above.
- Harness (scratchpad `h/`, macOS swiftc build of SGModulateSTT + SwiftSignalKit,
  `say -v Paulina` Spanish clips at 16 kHz): with idleTimeout shortened to 6 s,
  ALL PASS twice — clip 1 on socket 1, idle close, clip 2 opens socket 2 and is
  transcribed, clip 3 + finish() drained, session finished, no errors.
- Silent death reproduced once: with URLSession `timeoutIntervalForRequest` = 3 s
  and no idle timer, after 10 s idle the socket stopped answering, sends still
  "succeeded", receive never failed, finish() never got "done". A rerun with
  the same settings did NOT reproduce (socket survived). Non-deterministic, but
  it is exactly the field symptom, so: idle timer (45 s) pre-empts it, the
  request timeout is now 180 s, and the 20 s unanswered-audio watchdog cycles
  a socket that has gone quiet while audio flows (exercised with a 2.5 s limit:
  sockets cycled, every phrase came back).
- With `speaker_diarization=false` the server still reports `speaker: 1` on
  every utterance, so the formatter's local-speaker test holds either way.
- Build: full debug_sim_arm64 build green (744 actions), incremental rebuild
  after the watchdog edits green (124 actions, TelegramCallsUI recompiled).
  No warnings in the touched files. New log literal confirmed in
  TelegramUIFramework via `strings`.
- Harness source copies (held the Modulate key) deleted from the scratchpad;
  recreate from the recipe in CLAUDE.md's realtime section if needed, with
  `say -v Paulina` clips converted via afconvert to 16 kHz LEI16 mono.
- Tester notes: `Claude outputs/build15-notes.txt`. Not committed; build
  number for TestFlight still needs bumping.
- Round 2 harness (10.5 s synthetic Spanish utterance, partial_results on):
  final arrived 4.1 s / 1.2 s / 1.0 s after speech ended with hangover 700 ms
  + zero tail, 700 ms + room-tone tail, 2000 ms + room-tone tail. So the
  gate tail was NOT the cause with synthetic audio; hangover raised to
  1500 ms as insurance only. Partials: 5-10/s, `start_ms` constant per
  segment and equal to the final's `start_ms`; no uuid on partials.
- Partial design: `Provisional` keyed by start_ms ("partial:pending" until
  the server places it); strip line per utterance (partial -> final ->
  translation, same line); chat message posted once the partial is >= 12
  chars, edited at most every 2.5 s, final transcript edited in, then the
  translation. Partials never reach the translator. Stale provisionals older
  than a final are dropped (spec: a final supersedes all prior partials).
- SGSubtitleSequencer replaced by SGSubtitleStrip (git mv); 16-check swiftc
  harness ALL PASS.
- Simulator build with partials green, no warnings in touched files.
  Release build 16 (appstore config) started; next: altool validate, upload,
  `tools/asc-testflight.py 16 --notes-file "Claude outputs/build16-notes.txt"`.
- ASC shows builds 10-15 VALID; 15 uploaded 2026-09-15, so this is 16.
- The working tree also carries pre-existing uncommitted Azure/GTranslate and
  profile changes from this branch; they ship in build 16 as-is.
- CLAUDE.md "Live call translation" section extended with the socket,
  partial, diarisation and harness notes.
- Release build 16: green, CFBundleVersion 16 / 12.9.2, altool validate
  clean (only warning 90068, iOS 13 target), upload accepted 03:04.
  `asc-testflight.py 16 --notes-file` running to attach the notes.
- Build 16 processed VALID; internal group has it (IN_BETA_TESTING).
  TestFlight whatsNew has a 4000-char limit: the full notes (4935 chars)
  were rejected, so a 2063-char condensed copy lives in
  `Claude outputs/build16-testflight-notes.txt` and is what testers see.
