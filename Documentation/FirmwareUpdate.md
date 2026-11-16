# Band firmware update

Status on 2026-11-16: stage 1 of 5. The app now speaks the link of newer firmware as well as
the firmware the band runs today, proven offline. Nothing in the app sends update data to a
band yet, and nothing here has been checked on a real band.

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

The app has the sign-in (`MetaService`) and its token is the kind these calls take, but it is
kept only while a band is being set up, so a check needs a fresh sign-in. The band's serial
number arrives with its device information on every connection and is kept out of the journal.
The app has no GraphQL call, no zip reader, no place to keep a package and no update engine yet.

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
2. Read only, run from the band tests page: the update status, and a check with Meta that shows
   versions only.
3. A trial: key, transfer, verify, abort. Needs an update engine with several chunks in flight
   on one channel, resuming after a dropped link, and the screen kept on.
4. The real update behind a confirmation, on the charger, then a checklist that journals each
   result.
5. Settings and onboarding.

First on the band, both read only: connect with this build and export the journal, then tap
"Read update status" on the band tests page and export again.
