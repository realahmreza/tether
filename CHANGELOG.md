# Changelog

## Unreleased

## 1.2.1 — 2026-11-24

### Branding

- Fixed the Android Client app display name to iFixTel.


## 1.2.0 — 2026-11-24

### Branding

- Rebranded the Android and iOS apps as iFixTel, including app display names and application icons.


## 1.1.0 — 2026-11-23

### New features

- iPhone Link tab › Phone tools: send carrier codes (balance etc.) on a chosen SIM and read the answer, "Find phone"
  (rings the Android phone on the alarm stream for up to 30 s) and a ringer mode picker. New optional messages
  `ussd.send` / `ussd.result`, `phone.find` / `phone.finding`, `ringer.set` / `ringer.result`, and `tools`, `ringer`,
  `dnd` in `status`; the section is hidden when the Android phone does not report `tools`.
- Phone numbers are shown grouped like phones show them ("+98 912 345 6789", "+1 (555) 010-0001"), on the
  iPhone's keypad as you type, in Recents, Contacts, Messages, the call screen, CallKit and notifications, and on
  the Android phone's call screen. National numbers follow the SIM's country (new optional `country` per SIM in
  `status`). Short codes, USSD codes and names are left as they are; what is dialled, stored and searched is unchanged.
- **Android client** (`android/client`, "Tether Client"): a second Android phone (Android 10+) as a Tether client,
  like the iPhone app: QR pairing, the link with the iPhone's reconnect rules, calls as self-managed Telecom calls
  (Bluetooth headsets and car kits) with Opus audio both ways, keypad, Recents, Contacts and Favourites, Messages,
  notifications, the Link screen and switches, `tel:` links. Tested against a simulated Android phone only so far.
- iPhone: call numbers from other apps. `tel:` links (as the iOS 18.2+ default calling app, paid accounts only),
  the `tether://dial?number=` scheme, a "Call a Number" Shortcuts / Siri action that also finds a number in text,
  and optional call-backs from the Phone app's Recents. Links always ask before dialling; service codes and
  extensions are kept.
- Calls on Bluetooth headsets and car kits: an **Audio** menu on the call screen (iPhone, Speaker, each accessory)
  moves the call there and back, routes chosen on the system screen, Control Center or in the car are followed,
  the speaker button follows the real route, and the call audio rebuilds itself when a hands-free microphone
  changes the sample rate instead of going silent. Route changes are listed in the Link log.
- A "Calls paused" notification when the app is closed while running; docs on what happens when it is swiped away.

### Developer platform

- Swift SDK: TetherCore can be added to any package with `.package(url: "https://github.com/amirwmr/tether",
  from: "1.1.0")` (root `Package.swift`). Everything except the Bluetooth client builds and passes its tests on
  Linux (swift-crypto in place of CryptoKit, a portable lock, a regular-expression fallback where NSDataDetector does
  not exist); the package builds for iOS, macOS, tvOS, watchOS and visionOS. DocC documentation with four articles,
  public initialisers for every message body, `TetherPrivateKey`, `SyncBody.codecs` / `client`, and two examples:
  `examples/swift/Loopback` (a whole session in memory, macOS and Linux) and `examples/swift/MacCentral` (a Mac
  Bluetooth client). See docs/SDK-swift.md. The iPhone app's behaviour is unchanged.
- Kotlin/JVM library `com.github.amirwmr.tether:tether-core` (JitPack or `publishToMavenLocal`): the protocol
  core now builds as a plain JVM 17 library for desktops, servers and Android, with Dokka API docs, a command-line
  example (`examples/kotlin-jvm`) and docs/SDK-kotlin.md; MediaCodec Opus moved to `android/core-android`.
- Extensions: developers can add features on top of the link without forking the apps (protocol §7,
  docs/EXTENDING.md). Extension messages use the reserved `x.<reverse-dns>` namespace; each side announces what it
  speaks in `caps` (in `sync` and `status`), the highest common major version is used, and older apps neither send nor
  receive anything new. Registries in TetherCore and the shared Android core route only extension types (never a core
  one), cap sizes (16 KiB, 2 KiB during a call) and rates (20/s), answer an unknown extension request with
  `error {t, code}` and switch off an extension that keeps failing. Built in on every side: `x.tether.echo` (round
  trip, clock offset, transport); `tools/dbg.sh ext` / `ext_echo`, and a Developer row in Debug iPhone builds.
- Releases: one version in `VERSION` for the Android apps (versionName / versionCode) and the iPhone app;
  `tools/release.sh <version>` updates it, the CHANGELOG and tags; a tag builds a GitHub Release with the A54 and
  client APKs, an unsigned iPhone IPA, SHA256SUMS and build provenance attestations. CI keeps debug-signed APKs of
  every push to main. See docs/RELEASING.md.
- The Android phone's protocol and codec code moved to a shared module (`android/core`) used by both Android apps.

### Calls and audio

- Call audio, uplink (the iPhone's voice to the far end): no voice frames are thrown away any more. The Android
  phone's helper kept 8 frames and dropped the oldest when full, plus a frame whenever 2 stayed queued for a second:
  5-7 % of the iPhone's voice was lost on real-iPhone test calls (42-54 dropped and 13-17 trimmed of ~975 frames). It
  now keeps up to 1 s, steers the delay ahead of each frame (queue plus inject track) to what the recent Bluetooth
  hold-ups and the track's mixer need (5-60 ms), and corrects it where it cannot be heard: quiet frames are cut or
  repeated, and only without a pause for 0.5 s is speech sped up or slowed down by at most 3 %. Clock drift of
  ±2 % is absorbed the same way. Real-iPhone test calls: 0 frames lost; the call statistics show what was cut,
  added, sped up or slowed, the delay ahead and its target, and the capture's and track's sample clocks.
- The uplink starts when the Android phone's audio path is open: frames the iPhone sent before (0.3-1 s while the
  interception API waited for the call's audio mode; it is now polled every 30 ms instead of 150 ms) only delayed the
  first words; they are no longer forwarded.
- Call audio: the Android phone no longer throws away far-end voice when its capture delivers in bursts (its delay
  guard trims only standing delay and only audio already buffered: 1.3 s lost per 6.5 s test call before, 0.07 s
  after). The iPhone's playout depth follows the spread of frame arrival times (periodic Bluetooth hold-ups are
  absorbed instead of concealed: 1 s → 0.2 s concealed per minute on a simulated 30 ms link with 60-77 ms gaps), and
  frames lost for lateness are filled with Opus concealment (libopus decoding).
- iPhone playout: the statistics show the playout delay the listener really had (the buffer's level: 44-46 ms on
  the reference link, 0.3-1.1 % concealed) instead of the target (105-110 ms, which overstated it). The arrival
  spread is measured around the far clock's own rate (a drift of 2 % used to hold the target at its maximum, or run
  the buffer dry every few seconds), arrival times are taken when a frame comes off the link rather than when the
  audio queue gets to it, and the first 2 s of a call no longer count (a ~260 ms hold-up while the connection
  interval is shortened kept the target at its maximum for 10 s); a slow far clock is made up for in quiet frames.
- Android client: the iPhone's playout tuning ported (arrival-spread depth around a drift line, first 2 s left out,
  quiet-frame fill for a slow far clock, concealment of frames dropped for lateness, arrivals stamped off the link,
  the same call statistics); its trace tests give the same numbers as TetherCore's.
- During a bridged call the Android phone is silenced on more phones: Samsung (as before), Qualcomm (voice-call
  stream mute plus microphone mute) and MediaTek (its speech mute controls; never Android's microphone mute, which
  there also mutes the iPhone's voice); other phones get the earpiece muted. The Link tab shows "Android phone
  silent".
- Call statistics from the Android phone (frame spacing from the helper, link queue delay, uplink arrival, PHY,
  helper figures) arrive in the iPhone's Link log after each call (`audio.stats`). The call-audio self-test measures
  each uplink path's delay.
- TetherCore carries libopus 1.5.2 (`COpus` target) with `LibOpusDecoder` / `LibOpusEncoder`: Opus with packet-loss
  concealment and complexity control on the iPhone, checked against AudioToolbox's Opus both ways.
- Calls: the fast Bluetooth connection interval is requested at the first ring, and the iPhone's playout buffer
  adapts to bursty arrival (about 1 % of a call concealed instead of 4-6 %).

### Platforms

- Android 10 and later are supported (was 12): call audio is attempted on Android 11 and 12 (voice-call capture and
  the incall-music inject path) and the app says clearly when the phone cannot bridge call audio (Android 10). Version
  guards for the newer Bluetooth, telephony, notification and Telecom APIs, legacy Bluetooth permissions below 12, and
  a lint check that fails on unguarded newer APIs. Feature table: [docs/devices/android-versions.md](docs/devices/android-versions.md).
- Opt-in TCP debugging fallback for the audio helper: where Wireless debugging is missing (Android 10) or fails,
  Tether connects to the phone's adbd in `adb tcpip` mode on `127.0.0.1:5555` (port settable, key approval). Setup in
  [docs/SETUP.md](docs/SETUP.md); the security trade-off is in [SECURITY.md](SECURITY.md).
- The iPhone app runs on iOS 16 (it needed 17): Observation comes from swift-perception, a few iOS 17 views have
  iOS 16 stand-ins; iOS 17 and later behave as before. The Swift package needs network access at build time.

### Link

- Stable link while the phones are also paired for Bluetooth tethering (the Android phone holds an LE link during a
  session, so the session runs over LE / L2CAP and does not move between links).
- Reconnects after the app is closed and reopened (within ~1-3 s), after a link drop while the app is in the
  background (under 1 s), and after the Android app restarts.
- A suspended iPhone is woken after 15 minutes of silence instead of having its session dropped (it relinked,
  handshook and synced every 15 minutes); a session is ended only if the woken iPhone still does not answer.
- The Android phone kept failing to advertise after many link changes ("too many advertisers"): fixed.
- The Android phone knows the client kind "android" and holds / pulses the LE link only for an iPhone (a new
  client's kind is known at its first sync).

### Fixes

- After an update the Android phone's link service starts as soon as the app's process starts, not only when Samsung
  delivers the delayed update broadcast; until then the iPhone could not link and calls were not bridged.
- The other side could not hear the iPhone (#2, Galaxy Z Fold 6): during a bridged call the Android phone also muted
  its own microphone (through Android's mic mute, and on Samsung its tx control key), and on several audio systems
  that mute silences the injected iPhone voice too. The phone's microphone now stays on by default on every phone
  (its earpiece is still silenced); a new setting "Mute this phone's microphone during bridged calls" (Android app ›
  Call audio, and a switch in the iPhone's Link tab) turns it on with one mute per vendor, and then a check during
  the call compares the iPhone's speech with what the call's uplink carries, undoes the mute when the uplink stays
  silent, and remembers that for the phone model. The self-test runs the working inject method once more with the
  mic muted, its first row and the link log say whether the uplink injection opened, with which method and with
  which mute, and the link log flags an iPhone that sent only silence. New optional `micMute`, `uplink` and `capture`
  in `status.helper`, the `audio.set` message, and the helper's LOCAL frame (protocol §5, §6); docs/TROUBLESHOOTING.md
  "The other side cannot hear me".
- The Android phone's own microphone and earpiece now leave a bridged call instead of being muted (#2): Tether
  puts the call in Android's redirect audio mode (`MODE_CALL_REDIRECT`, Android 13+; set by the audio helper, which
  Android lets own the mode over Telecom's), in which the platform stops routing the call to the phone's mic and
  earpiece while the uplink injection and downlink capture go on. So the other side hears only the iPhone (no doubled
  voice, no bag noise, no echo of their own voice from the iPhone's speaker), without the mutes that silenced the
  injected voice on some phones. Each call checks the mode: it is set once the downlink has audio, set again when
  Telecom takes it back (3 times at most), undone when the downlink goes silent in it or when the iPhone's speech stops
  reaching the uplink, and what it found is remembered per phone model; a phone that breaks it falls back to the call
  screening mode (where the phone declares it) and then to an open microphone. The setting becomes "This phone's
  microphone during bridged calls: Off during calls (default) / Muted / On" on both phones; the self-test adds a
  `mic:<mode>` row per mode (mic level, tone and downlink without and with the mode). New optional `mic` and `micPath`
  in `status.helper`, `mic` in `audio.set` (`micMute` still read), the helper's `mic` report and `redirect` memory
  (protocol §5, §6); the helper's `mode` command; docs/TROUBLESHOOTING.md, docs/devices.
- Wireless debugging pairing from the notification no longer closes the app (#1): the work runs in a short foreground
  service instead of the notification's broadcast, a wrong or expired code is reported instead of being taken as
  success, and each failure (no Wi-Fi, pairing window closed, wrong code, connected later) says what to do, in English
  and Persian.
- Dates (also Persian calendar ones), version numbers, IP addresses and amounts in texts are no longer shown as
  phone numbers on the iPhone or the Android client, or picked by "Call with"; numbers written with dots
  (555.123.4567) now are.
- Contacts: a number's custom kind ("Satellite") is shown on the iPhone and kept when a contact is edited there; the
  Android phone now stores labels sent with `contact.add` / `contact.update`, and an empty label clears one.
- Fixed by those tests: a damaged iPhone data file is now kept aside instead of being overwritten; the Android
  client no longer deletes all local texts or calls on a malformed `sync.ids` page; a `tel:` link holding only an
  extension no longer dials the extension; the debug hooks no longer accept `+10000000000`.

### Tests and tooling

- Tests for future changes: protocol fixtures read by both implementations (old and newer app variants), an iPhone
  app test target (saved-data format, message handling, links), security and framing edge cases, the A54's safety
  guards and helper login, the Android client's synced state and call rules; about 380 automatic tests in all.
  `tools/test-all.sh` runs every check, `tools/check-private.sh` scans changes for private values,
  `tools/device-test.sh` runs the test-line checks on the phone, and CI runs on every push. See docs/TESTING.md.
- The test line behaves like a real call: nothing read its injected uplink, and an unread remote submix plays it ~10 %
  slower than real time (14.4 kHz for 16 kHz), which no network does; the helper now reads it as the far end would.
- Debug: `only none` no longer stops `loopback_call`; `loopback_call selftest`, `inject_ms`.

## 1.0.0 — first public release

- Calls on the iPhone through CallKit with two-way call audio (Opus 16 kHz) on Android phones that allow call-audio
  interception; ringback while dialling, speaker, hold, mute, keypad, call waiting, moving a call between devices.
- Messages: full sync, live texts, send from either SIM, shared read state, delete, mute, block, one-time codes,
  rich text, notifications with reply.
- Contacts with favourites and editing; Recents with search, delete and a missed-call badge.
- Link tab: battery and signal per SIM, remote switches for mobile data, data SIM, hotspot, Bluetooth tethering,
  airplane mode, network mode, and Share VPN.
- End-to-end encrypted link (P-256 handshake, AES-256-GCM) over Bluetooth LE L2CAP with a GATT fallback; no
  dependence on Bluetooth pairing, so it works alongside Bluetooth tethering.
- iPhone and iPad; English and Persian; light and dark.
- Local configuration for team id, bundle id and display name; scripts that find the connected devices.
