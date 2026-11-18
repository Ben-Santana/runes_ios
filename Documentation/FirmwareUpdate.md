# Band firmware update

Status on 2026-11-17: stage 3 of 5 is done and stage 4 is built and not run. The app speaks
the link of newer firmware as well as the firmware the band runs today, and the changed app
connects to the band as it is. Key 20 is on the band, and a trial of build 72 sent both items,
had the band verify each, and had it discard them. The band still runs `770435744`. The band
tests page can now install a package, behind a confirmation that says it cannot be undone.

An update is one way. The band refuses older firmware, and nobody has found a way back.

## Sources

All public. They were read, not run.

- band-core (`gitlab.com/896kb/band-core`, MIT) and the two apps built on it, Air Gestures for
  Linux and Android. Its authors claimed, connected and updated a band on builds 64 and 70 and
  wrote down what they saw (`docs/hardware-day.md` in the Linux app). This is the only source
  with hardware evidence for an update.
- visor (`github.com/macedonga/visor`) and its protocol pages. A second, independent
  implementation of the newer link. It removed its own update code on 2026-11-07 and marks that
  code "not tried on the band yet".
- Decompiled message classes in `akitaonrails/instagram-analysis`. Field numbers and names
  only. The enum value names are stripped, so every enum value below comes from band-core.

## What the band runs

Read on 2026-11-16: firmware `79a235830f7f`, software `770435744`, models dated February 2025,
no protocol version reported. Meta's version numbers seen elsewhere are `1003366292` (shown as
build 64) and `1054928927` (build 70, October 2026). The band is older than both. Its link
offers scheme 3, the only one this app spoke until now.

Read on 2026-11-17 with the changed app: `link: offered 3, using 3, band named 3`, and the
stream answer `1=4 2=1 5={2=0 3=1 6=0 8=0}`. The update status, asked on channel 1, came back
as `8={2={2=1 4=1 5=bytes(6) 5=bytes(8) 5=bytes(2) 6=1}}`: update protocol 1, idle, stable
firmware, three items, key version 1. The band left out its result and its device state, so it
drops fields that are zero. Whether it also drops an accepted result from a key or start answer
is not known, and the app does not take a missing result as a yes for a start.

Meta's answers for this band on the same day, both hosts agreeing: `FetchSystemUpdates` offers
build 64 (`1003366292`, about 10 MB) whether asked as the band's own version or as version 1,
and `FetchConstellationUpdates` offers build 72 (`1075365371`, about 12 MB). Both need key 20.
Build 72 is newer than anything a public source has connected to, so build 64 is the one to
try first.

Meta's sign-in: the page this app has always used (`auth.meta.com` with a native token) now
stops on its `native_sso/confirm` step for this account with "This content is no longer
available". The route the public visor project uses works: `accounts.meta.com/oidc`, a code
at the redirect, then a token exchange. The firmware check uses that one. Setting a band up
again still uses the older page and would meet the same stop.

## The update, request by request

Every request is an `RpcRequest` on an open service channel: field 1 is the request number,
and one more field carries the request. Answers are `RpcResponse`: field 1 the same number,
field 2 a status where 1 is success. band-core sends update requests on channel 6. The band
tests page sends its status request on channel 1, and the band's answer there is not known yet.

| Step | Request | Answer |
|---|---|---|
| Status | 7 `OtaReq` { 1 `deviceInfoRequest` {} } | 8 `OtaResp` { 2 { 1 result, 2 update protocol version, 3 device state, 4 update state, 5 items { 1 type, 2 version }, 6 key version, 7 why unavailable } } |
| Key | 7 { 6 { 1 key version, 2 key type 0, 3 wrapped key } } | 8 { 1 { 1 { 1 result code, 2 retry delay } } } |
| Start an item | 7 { 2 { 1 { 1 type, 2 version }, 2 size, 3 skip version check 0, 4 key version 0 } } | 8 { 1 general } |
| Transfer setup | 9 `BulkDataTransferReq` { 1 { 1 MD5, 2 size, 3 type 1, 4 transfer number } } | 10 { 1 { 1 state, 2 free memory, 3 offset to start from, 4 version, 5 transfer number } } |
| Chunk | 9 { 2 { 1 transfer number, 2 offset, 3 up to 950 bytes } } | 10 { 2 ack { 1 number, 2 offset } } or 10 { 3 nack { 1 number, 2 reason, 3 from sender } } |
| Verify an item | 7 { 3 { 1 { 1 type, 2 version } } } | 8 { 3 { 1 result, 2 must commit without deferring } } |
| Abort | 7 { 5 {} } | 8 { 1 general } |
| Commit | 7 { 4 { 1 defer restart 0 } } | 8 { 4 { 1 result, 2 will restart } } |

Values, from band-core:

- Device state: 0 stable, 1 trial firmware, 2 recovery firmware.
- Update state: 0 unavailable, 1 idle, 2 in progress, 3 ready (received and verified).
- Item type on the wire: 0 running firmware, 1 received firmware, 2 model bundle. A firmware
  item is started as type 0.
- Why unavailable: 0 none, 1 no Bluetooth, 2 turned off on the band, 3 power, 4 trial firmware running.
- Transfer state: 1 or 2 ready to receive, 3 already complete.
- Result codes: 0 OK, 100 invalid item, 200 no space, 201 power state, 202 old version,
  203 update in progress, 204 no update in progress, 205 incorrect state, 206 running trial
  firmware, 207 key version mismatch, 208 invalid key, 209 key install failed, 300 wrong checksum.

Order, as the Meta app does it and as band-core's `Update` mode copies it:

1. Status. If an earlier update is in progress or ready, Abort and ask again.
2. If the band's key version is not the one the package names, install the key and ask again.
3. For the firmware, then the model bundle: Start, transfer setup, chunks, Verify.
4. Commit, in the same connection. The band answers and restarts into the new firmware.

A trial is the same without step 4: after the last Verify it sends Abort, then asks the status
and expects idle with nothing received. Nothing is installed. A key installed in step 2 stays.

Timing in band-core: 15 s for a status, key, start, verify, abort or commit answer; 5 s for the
transfer setup; 5 s for a chunk, sent again up to four times before the transfer is given up.
Chunks are 950 bytes. The band says how much memory it has and band-core keeps at most 8 chunks
in flight; with the 17 that build 64 allowed, links dropped. The model bundle is sent only when
it is over 10 KiB. The Android app says a whole send takes 15 to 25 minutes and the restart
about a minute.

What stops meanwhile in band-core: vibration requests, and gyro and orientation streams, which
it turns off for the transfer because the extra traffic made build 64 lose its place. It also
skips a stream frame that will not parse during an update instead of dropping the connection.

Before Commit is sent the band keeps running its firmware whatever happens, and an Abort clears
what it holds. A transfer cut off part way can be picked up: the transfer setup answers with the
offset to continue from. A Commit sent in a later connection than the Verify is refused with
205; verifying each item again first is accepted.

After a Commit the band has been seen to come up in standby, sending no gestures, until it is
asked for the active state. This app already asks for that on every connection.

Not known from any source: how long the band is unreachable, whether it runs the new firmware
as "trial" at first and what ends that, and whether ownership always survives. band-core's
authors kept their owner key across two updates.

## Where the files come from

Meta serves them to a signed in owner. Each is a form POST to `/graphql` on
`ar-genai.graph.meta.com` (then `ar.graph.meta.com`), with `Authorization: OAuth <user token>`
and the fields `fb_api_req_friendly_name`, `client_doc_id` and `variables`.

- `FetchSystemUpdates`, document `29744781653741296994778085945`. Variables name the band by
  serial number, a device type (`ota.ceres_p1.user` in band-core, `ota.ceres.user` in visor) and
  the firmware version it has. The answer holds `file_uri`, `target_version`,
  `build_number_display_name`, `file_size`, `file_checksum` (SHA-256), `kek_id` and release notes.
  `FetchConstellationUpdates`, document `155904535318377635033579516369`, is the newer form.
- The file is a zip with `manifest.json`: each item's path, size, SHA-256, version and kind
  (1 firmware, 2 model bundle), and the key version the package needs.
- `FetchEncryptedKEKInfoByKEKId`, document `313699925716490204858433749875`, with the serial
  number and key number, answers with the key wrapped for that one band.

The app has the sign-in (`MetaService`) and its token is the kind these calls take. The
firmware check keeps it in this phone's Keychain, readable only while the phone is unlocked, so
a restart does not ask again. It is dropped when Meta stops accepting it, and a row on the band
tests page forgets it. The band's serial number arrives with its device information on every
connection and is kept out of the journal.

On the phone: `FirmwareService` asks the questions and downloads the package,
`FirmwarePackage` unpacks it in memory and checks every item's size and SHA-256 against the
package's own list, and the package is kept in the app's Application Support under `Firmware`
once its checksum matches the one Meta gave, with that checksum beside it, so a later run can
use it without asking Meta. The wrapped key is asked for after that and stays in memory. The
link, the key and the sign-in are never written to the journal.

## The trial on 2026-11-17

Run from the band tests page on the band's factory firmware, battery 91% to 89%, worn.

- Key: the band had key 1. The install was answered `1={1=bytes(0)}`, a result that is there
  and empty, and the status after it reported key 20. So this firmware does send a result for
  a yes, with the zero code left out.
- Build 72 (`1075365371`): firmware 5472878 bytes in 227 s, model bundle 7151732 bytes in
  358 s, 18 to 26 KiB a second. The band offered 8192 bytes of memory, so eight chunks were in
  flight. No chunk was sent twice. Part of the firmware went across with the app in the
  background, kept running by the band's own traffic.
- The band verified both items, accepted the discard, and then reported idle, stable firmware,
  running and received both `770435744`, key 20.
- After the discard it still reports the model bundle as `1075365371`. That number cannot be
  trusted to skip a model bundle, so a real update must send every item, as band-core does.
- Build 64's package holds firmware of 5326044 bytes and a model bundle of 5236658 bytes. It
  was fetched and checked and has not been sent.

Not shown by this: a dropped link part way, which only the offline check covers, and anything
about a commit or the band after one.

## The update engine

`FirmwareUpdate` writes the requests and reads the answers, and `SessionCore` carries them on
channel 1, the channel the status request was answered on. It has four runs: the key alone,
a trial, a discard, and an install. Only the install sends a commit.

The install is the trial with a commit where the trial discards:

- It sends every item whatever model version the band reports, and so does a trial.
- A dropped link before the commit starts it again from the first item, after a discard, so
  the commit is always asked for in the connection that verified everything.
- A refused commit ends with a discard. A commit with no result, no answer, or a link that
  drops just after it, is taken as asked for: nothing is discarded or stopped after that,
  since the band may be part way through.
- Once the commit is asked for, the page waits for the band to come back and says which
  version it then reports. "Run the band checklist" asks the things the app relies on and
  journals each answer: version, update status, wrist setting, a vibration, the named settings
  and a gesture. It can be run before an update too, to compare.

- While it runs, vibration, the wrist setting, named settings, the other band tests, EMG, gyro
  and orientation are held back, and gestures keep arriving.
- Its timeouts count only time the app was running, so a pause in the background is not taken
  for a silent band.
- A dropped link forgets what was in flight. When the band streams again the update asks its
  status and picks up where the band says, or starts the item again if the band dropped it.
  After five drops it gives up.
- Any failure after an item was started ends with the band told to discard what it holds.
- The page refuses to start below 50% battery or with the level unknown, keeps the screen on,
  and asks first. The key's and the install's confirmations say they cannot be undone. The app
  cannot tell whether the band is on its charger, so the confirmation asks for it.

## What newer firmware changed in the link

| Difference | What the app did before | Now |
|---|---|---|
| The band offers schemes 27 and names 26, not 3 | Refused the connection at the first message | Chooses rules from the offer (`BandLink`) |
| Key from the raw shared secret with salt SHA-256(challenge, seed) | Would have failed every record's check | Done for scheme 26 |
| Each record's check covers `02 02 00 00` first | Same | Done |
| Every record is padded, a whole block of `d0` after an aligned frame | Read the next frame out of the padding and stalled | Padding always removed on this link, and sent the same way |
| Frames cut across records | Could finish a frame with padding bytes | Handled, since padding is known exactly |
| Extra bits on channels the band answers on (`9c01` for `8001`) | Ignored the trust and setup answers until a timeout | Channels compared by direction bit and low byte |
| Channel number read from the band | Accepted only `ff 00` | Reads the number; still 255 everywhere seen |
| A stream answer that leaves out flags that are off | Fatal error | A missing flag is read as off |
| Protocol version 2 wants streams listed by kind and sends gestures under kinds 60 to 200 | Gestures would never arrive | Sent and read when the band reports version 2 (`BandStreams`) |
| Standby after an update | Already asked for the active state on connecting | Unchanged |

Unchanged between generations in every source: the trust exchange, the ownership steps, device
information, the wrist setting, vibration requests, gesture message contents.

The choice is made per connection from what the band says: the scheme offer in its first
message, and the protocol version in its device information. A band that offers exactly 3 and
reports no version gets byte for byte what it got before.

The journal's `protocol` lines now end with the offer, for example
`link: offered 3, using 3, band named 3`, and a `band_streams` line records the band's answer to
each stream request as numbers.

## Evidence

`Tests/BandLinkTests.swift` runs offline:

- Published vectors: the scheme 3 key and two records from the reference Python package; the
  raw secret key derivation and a real record's check from the glasses' scheme 31, which scheme
  26 shares apart from which key makes the check.
- The app's cipher against a second cipher written from the description, both directions, both
  generations, lengths around block edges and at the record limit.
- band-core's frame reader cases, which came from records its authors saw on bands.
- One scripted connection run on a pretend early band and a pretend late band, whole, a byte at
  a time and with frames cut into 3 and 7 pieces. All must report the same 25 things: trust,
  device information, stream start, gestures, gyro, orientation, EMG, wrist read and write, two
  vibrations, named settings, update status, a chunk sized request, a closed service.
- Twelve gestures recorded from a band on late firmware by band-core's authors, read back.
- The ownership steps on both generations, with the 1888 byte identity reply seen on a band.
- Refusals: unknown schemes, a renamed scheme, wrong keys, a refused owner key, a forged proof.
- A whole trial transfer carried over the encrypted link on both generations: the update's
  requests numbered after the app's own, eight in flight, the answers on a marked channel.

`Tests/FirmwareUpdateTests.swift` runs the engine against a pretend band: the first requests
byte for byte, the status this band gave, the key alone, a whole trial, an earlier update
discarded first, lost chunks sent again, a chunk never answered, refusals of the key, a start,
a chunk and a verify, a band that goes silent, a link dropped mid item with the band keeping or
dropping what it had, a link dropped while verifying, stopping, and a discard on request. The
pretend band fails the check if a key run, a trial or a discard ever asks it to install.

For the install: the commit byte for byte, both forms of a yes, an answer with no result and
no answer at all, a refusal, a failed verify that never reaches the commit, a link dropped in
either item, a link dropped just after the commit, and stopping before and after it. The
pretend band refuses a commit for anything verified in an earlier connection.

`Tests/FirmwarePackageTests.swift` reads packages built in the check, stored and deflated, and
refuses a changed byte, a wrong size, odd paths, a missing firmware, zips that are encrypted,
cut short or packed another way, and key answers that are not a wrapped key.

Breaking any one rule on purpose (channel bits, padding, the check's prefix, the salt order)
fails the check. Every other check in `Tests/` passes unchanged, and the app builds.

## Risks

Proven by tests: the app follows the written rules of both generations, and the early
generation's bytes did not change.

Resting on other people's hardware: that the written rules are what late firmware does.
band-core's authors connected with them to builds from September and October 2026, and visor
arrived at the same key and check rules separately. Neither is this band.

Inferred, with no hardware evidence anywhere: the version 2 stream request and its gesture
kinds; that a version 2 band still answers status 1 to a request carrying both forms; that Meta
offers this band a build whose link is still scheme 26. If Meta now serves something newer than
build 70, nobody has written down its link.

Only a real band can show:

- Whether the changed app still connects to the band as it is. This is the first thing to run.
- What the band answers to the status request on its current firmware, and whether it has a key.
- What Meta offers this serial number.
- Whether a transfer survives the phone locking. iOS runs the app only while the band's pulse
  wakes it, so a transfer should be done with the app open and the screen on.
- After a Commit: how long the band is gone, whether the saved owner key is still accepted,
  whether the pulse that keeps the app awake in the background still arrives, battery level
  over Bluetooth, vibration, named settings, and whether setting 5 for handwriting appears.

If the band comes back and the app cannot connect:

1. The journal says how far it got: the offer, the scheme, the stage. A link the app does not
   speak is a change to the app. The band is not harmed by failed connections.
2. Air Gestures for Android or Linux connects to builds 64 and 70. It needs the band claimed to
   it: hold the band's button about 16 seconds to reset it, then claim it there.
3. The Meta AI app can set the band up again after the same reset.
4. After a reset the app must take ownership again. Those steps are covered by the offline check
   on the late link, and the saved credentials are kept until a new one authenticates.

There is no way back to the old firmware. The Python package refuses any offer but scheme 3
(`protocol/session.py`), and the Mac app's own connection is built on it, so both would stop
connecting directly to an updated band until they get the same change. The Mac link through
this phone does not depend on that.

## Stages

1. Done: this document and the link work.
2. Done on 2026-11-17: the update status and "Check with Meta" from the band tests page.
3. Done on 2026-11-17: the key installed and a trial of build 72 passed.
4. The real update behind a confirmation, on the charger, then a checklist that journals each
   result.
5. Settings and onboarding.

Setting a band up now uses the sign-in that works (`MetaService.prepareWebLogin`), since a
band that had to be reset after an update would need it. That path has not been run, because
running it means resetting the band.

Order on the band for the real update, the journal read between steps:

1. "Run the band checklist" on the firmware the band has, as the answers to compare with.
2. A trial of the build to be installed. The trial that passed was of build 72, and build 64
   has not been sent to the band.
3. The install, on the charger. Then wait for the band, and run the checklist again.

Which build to install is the owner's choice: build 64 is the newest one a public project has
connected to, and build 72 is what Meta's newer question offers.

Not known until it is done: how long the band is away, whether it reports protocol version 2
and takes the stream request written for it, whether the owner key is still accepted, and
whether the pulse that keeps the app awake in the background still arrives.
