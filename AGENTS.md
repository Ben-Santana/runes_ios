# RunesIOS repository notes

This file contains shared engineering context only. Keep personal Apple teams,
device identifiers, machine paths, account details, deployment records, and chat
history in the user's separate personal project workspace. Do not copy them here.

## Start here

- Read `README.md` for current features and installation requirements.
- Use the checked-in `RunesIOS.xcodeproj`, scheme `RunesIOS`; the app embeds the
  `RunesActivity` Live Activity extension. This is a native Swift/SwiftUI project,
  with an iOS 26 minimum and no required package-generation step.
- Full Xcode and a matching iOS SDK are required. Command Line Tools alone are
  insufficient. Prefer `xcodebuild` and `xcrun devicectl` for routine builds and
  device deployment; use UI control only for setup that requires it.
- Do not run `generate_project.py` casually: it predates parts of the resource
  setup. Add source/resource membership directly to the existing project.
- Before updating from upstream, inspect and preserve local changes. Keep build
  caches and logs outside tracked source. Do not publish changes without a request.
- Follow the rules for branches, commits and comments below.

## Branches and commits

- Use `bug/` branches for fixes and `feature/` branches for features. Group
  related changes on one branch; a tiny change does not need a branch of its
  own. Keep unrelated concerns apart so each branch can become one pull request.
- Commit every small change as soon as it builds and its checks pass. Many small
  commits are better than one large one: each should be readable alone and safe
  to revert alone.
- Start the subject with the kind of change: `feat:`, `fix:`, `refactor:`,
  `test:`, `docs:` or `chore:`. Then say what was done in plain words, lower
  case, no full stop, about 70 characters at most. For example:
  `fix: onboarding can search again while an old band is pending`.
- When one line cannot say it, leave a blank line and add a few short lines, one
  per thing done. Say what changed and, where it is not obvious, why. No
  paragraphs, no lists of files, no account of how the work went.
- Do not push, open a pull request or merge into `main` unless asked.

## Comments and wording

- Keep code simple and comments few. Comment only what the code cannot say: a
  constraint, a reason, a unit, an order that matters. Leave out a comment that
  repeats the line under it.
- Write plain full sentences. Do not use a dash as punctuation: no em dash, no
  en dash and no spaced hyphen standing in for one. Use a full stop, a comma or
  a colon, or split the sentence.
- Leave out anything that reads as generated: tool or assistant names, emoji,
  arrows, decorative banners, labels such as "Note:" or "Important:", and filler
  such as "simply", "robust" or "seamless".
- Describe the code as it is. A comment does not tell the story of a change
  ("now uses", "no longer", "fixed"); that belongs in the commit message.
- No commented-out code. A `TODO` says what is missing and why it is not done.
- The same wording rules apply to documentation, commit messages and text shown
  in the app.

## Architecture

- `RunesIOSApp.swift` starts `SessionController` even on Bluetooth restoration;
  `Views/RootView.swift` binds live state to onboarding and app screens.
- `SessionController` is the main-actor UI/integration adapter. `SessionCore`
  owns band connection state on `BandTransport`'s execution context. Preserve
  that boundary rather than moving Bluetooth state into view code.
- `Transport/`, `Protocol/`, and `Authentication/` implement Core Bluetooth,
  bounded wire decoding, mutual trust, Meta login, and ownership ceremonies.
- `Persistence/IdentityStore.swift` holds protected identities in Keychain.
  `EventJournal.swift` writes bounded local diagnostics. Never log keys, tokens,
  ownership receipts, QR identity payloads, or raw authenticated HTTP bodies.
- `Mappings/` contains gesture/combo matching, action execution, profile state,
  and Spotify integration. App-specific gesture reservations are coordinated by
  `SessionController`; avoid firing both an app action and its reserved mapping.
- `Workouts/`, `Scores/`, `Cook/`, and `Capture/` provide the mini-apps. Capture
  stores AAC recordings and notes locally and uses on-device speech models;
  model assets can download. Its pocket mode opens the microphone in the
  foreground and keeps it open for subsequent background triggers.
- `Sounds/AudioHub.swift` owns the shared audio session. Score, Cook, and Capture
  must coordinate through it; independent audio-engine/session changes can
  interrupt recording. Microphone, speech, and other permissions remain explicit
  user choices when the corresponding feature is used.
- `Relay/` handles the Mac link. `Shared/` supplies types/icons used by both the
  app and extension. `Views/Design/` and `Documentation/StyleGuide.md` describe the
  shared visual system.

## Build and signing

Unsigned device compilation:

```sh
xcodebuild -project RunesIOS.xcodeproj -scheme RunesIOS \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/runes-derived-data CODE_SIGNING_ALLOWED=NO build
```

For a personal install, use the user's external `.xcconfig` with `-xcconfig` and
automatic provisioning. The checked-in project's upstream signing values are
not the current user's identity. Override both targets, retaining the installed
app's team and bundle IDs across updates so its data and Keychain access survive.
The extension identifier must begin with the app identifier plus a dot.

Use a signed Release build for standalone phone use. Verify the signature, the
actual device transport, installation, and process launch separately. For a Wi-Fi
request, require `localNetwork` in `devicectl` JSON; a wired install is not proof
of wireless deployment. Do not uninstall the app to repair an ordinary update.

## Verification

- Existing checks are standalone `swiftc` executables in `Tests/`, not an XCTest
  scheme. Read each test's header and source dependencies before running it.
- For Cook/Capture updates, run `CookTests.swift`, `CaptureTests.swift`, and the
  mapping tests; Score checks cover shared gesture reservation behavior.
- Mapping-related checks require `Models.swift`, `Wire.swift`,
  `IdentityStore.swift`, `MappingModel.swift`, `AirGesture.swift`, and generally
  `MappingEngine.swift`, plus `Shared/ProfileIcon.swift`, `Shared/SVGPath.swift`,
  and `Shared/LucideData.swift`. Some older README/header command lines omit
  those shared dependencies; add the real dependencies instead of test stubs.
- `Tests/SessionPolicyTests.swift` exercises reconnect and gesture sequence
  rules. `Documentation/ManualAcceptance.md` describes device validation.
- `Tests/BandRecoveryTests.swift` checks captured-band authorization, cancellation,
  pending identity retention, and promotion only after fresh authentication.
  `Tests/ConnectionDiagnosticsTests.swift` uses ephemeral encrypted exchanges to
  distinguish trust rejection, invalid proof, timeout, and readiness. These
  offline tests do not perform Meta login or change a real band's ownership.
- Recovery requires explicit confirmation. Preserve saved credentials while
  staging enrollment; opening diagnostics or cancelling a dialog must not enroll.
- Keep all `#Preview` declarations and fixtures within their debug guards.
  Always compile Release before installing a standalone app.
- A successful build or model test does not verify band gestures, Meta login,
  Spotify authorization, microphone capture, or locked-phone/background behavior.
  Record those as not checked until there is direct device evidence.
- For HTTP failures, distinguish account login from API entitlement and capture
  only sanitized endpoint/status/reason metadata. Avoid claiming a root cause
  from an HTTP status alone.
- `Tests/SpotifyResponseTests.swift` exercises the Foundation-only response
  classification in `Mappings/SpotifyResponse.swift`. The separate bounded
  Spotify diagnostic journal belongs in app Application Support; inspect its
  sanitized status/reason evidence when investigating a reported failure.
