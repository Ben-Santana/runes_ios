# What the band exposes

A map of everything the band can be asked for or sends, and where Runes stands on each. The
names and numbers come from the public sources listed in `FirmwareUpdate.md`: the decompiled
message classes give field numbers and names, band-core gives the values it measured. A name
says what Meta called a thing, not what this band does with it. Only the "On this band" column
is evidence, and it is filled in from the user's journal.

Status words: **used** means the app relies on it, **tests page** means it can be run from
Settings, Band tests, **probe** means the band probe tries it, **not sent** means nothing sends it.

The band tested is the user's, on build 72 (`1075365371`) unless a row says otherwise.

## Requests

A request is `{1 number, N body}` on a service channel, and the answer is `{1 number, 2 status,
N+1 body}` with status 1 for success. From request 12 on the answer's place varies.

| N | Name | What it is | Runes | On this band |
|---|------|------------|-------|--------------|
| 2 | battery | Level, charging, temperature, voltage, current | probe | not asked yet |
| 3 | device information | Revisions, models, protocol version, features | used | answers |
| 4 | stream control | Turns streams on and off, see Streams | used | answers |
| 5 | configuration | Reads or writes the settings report | used | answers |
| 6 | time sync | Sets or reads the band's clock | not sent | unknown |
| 7 | firmware update | Status, key, start, verify, commit, discard | used | builds 64 and 72 installed |
| 8 | opaque | A blob with an encoding number | probe | unknown |
| 9 | bulk transfer | Sends a file in chunks | used | used by the update |
| 10 | link test | Ping, latency and throughput tests | probe | unknown |
| 11 | gesture acknowledgement | Tells the band a gesture arrived | tests page | not rechecked on build 72 |
| 12 | bug report | Asks for logs, a core dump or a report | probe, empty only | unknown |
| 13 | custom model | Custom pipeline with a metadata blob | not sent | unknown |
| 14 | named settings | Count, describe, read, write, run | used | 38 settings on build 64 |
| 15 | system settings | Wi-Fi, speaker, display and so on, for other devices | probe | unknown |
| 16 | radio test mode | "Aggressor" mode | not sent | unknown |
| 17 | haptics | Vibrate, play a stored pattern, stop, store a pattern | used | answers |
| 18 | device identity | Challenge and signature | not sent | unknown |
| 19 | study event | A JSON message for a study | not sent | unknown |
| 20 | model event | Events about the model pipeline | not sent | unknown |
| 21 | detector | Runs or cancels a detector by type | probe, empty only | unknown |
| 22 | health | Health streams and a user profile, for other devices | probe | unknown |
| 23, 24 | bioimpedance | Calibration and hardware settings | not sent | unknown |
| 25 | stream acknowledgement | Acknowledges a stream state message | not sent | unknown |
| 26 | EMG sign in | Enrol and sign in with a gesture, as a passkey would | not sent | unknown |
| 27 | data removal | A package and a proof that data was removed | not sent | unknown |

Not sent on purpose: 6, 13 and 16 because an empty request could itself be an instruction, 18,
26 and 27 because they touch identity and stored data, 23 and 24 because they calibrate.

## Streams

Each is a switch in the stream request. A switch lasts as long as the connection. Data frames
have a type of their own, `0x020002NN`. Everything else arrives as an unasked message, type
`0x02000316`.

| N | Name | Runes | On this band |
|---|------|-------|--------------|
| 2 | raw EMG | used | 8 channels at 2048 a second, by its settings |
| 3 | gestures | used | arrives |
| 4 | model scores | tests page | 9 scores, pipeline 2 |
| 6 | gyro | used | arrives |
| 8 | orientation | used | arrives |
| 1, 5, 7 | raw motion, accelerometer, magnetometer | probe | unknown |
| 9 | wake status | probe | unknown |
| 10 | band log | probe | unknown |
| 11, 13, 28 | telemetry, device telemetry, Kwaltz telemetry | probe | unknown |
| 12 | battery updates | probe | unknown |
| 16 | device state | probe | unknown |
| 17 | EMG and motion batches | probe | unknown |
| 19 | setting changes | probe | unknown |
| 22 | named setting updates | tests page, probe | unknown |
| 23 | model events | probe | unknown |
| 26 | model input | probe | unknown |
| 27 | detector updates | tests page, probe | unknown |
| 29, 30 | band orientation result and state | probe | unknown |
| 38 | on wrist events | probe | unknown |
| 39, 40 | wrist tilt, wrist down | probe | unknown |
| 41 | temperature | probe | unknown |
| 42, 50, 56, 58 | detector, passive context, Jamba and handwriting scores | probe | unknown |
| 43 | written text | probe | unknown |
| 49 | grip strength | probe | unknown |
| 14, 15, 18, 20, 25, 31, 32, 33, 34 | sensors this band may not have | probe | unknown |
| 24, 45 | touch events, trackpad touch | probe | unknown |
| 44, 46, 47, 48, 51 to 55 | health and activity | probe | unknown |
| 35, 36, 37 | priority, the list of kinds, a use name | used from protocol version 2 | this band reports no version |
| 21 | opaque streams | not sent | unknown |

## Unasked messages

One message, `0x02000316`, with one of these inside. The probe names the ones it sees.

1 device state, 2 battery, 3 log line, 4 sensor telemetry, 5 wake telemetry, 6 gesture
telemetry, 7 opaque, 8 setting change, 9 quality check, 10 device telemetry, 11 derived gesture
telemetry, 12 heartbeat, 13 crash log, 14 custom model, 15 named setting, 16 stream state,
17 system settings, 18 haptics, 19 study event, 20 model event, 21 detector, 22 Kwaltz
telemetry, 23 health event, 24 EMG sign in.

## The settings report

What the band sends back for request 5. The app reads the wrist (10), haptics (11) and standby
time (21) from it.

| Field | Name | On this band |
|-------|------|--------------|
| 1, 2 | motion and EMG rates | 128 and 2048 |
| 6 | device state | written as 2 on connecting, never reported back |
| 7 | logging: level and interval | level 3 |
| 9 | mode | 0 on factory firmware, 4 since build 64 |
| 10 | left wrist | 0 |
| 11 | haptics | 3 |
| 13 | standby gesture | 0 |
| 15 to 20 | gyro and accelerometer bias | present |
| 21, 22 | standby after seconds, sleep after minutes | 30 and 60 |
| 23, 24, 25 | data collection, stream in standby, core dumps | 0, 1, 1 |
| 40, 41 | accelerometer and gyro: rate, power mode, range, calibration | present |
| 42 | EMG: rate, channels, bits, samples in a batch, encoding | 2048, 8, 16, 16, 0 |
| 43 | batch sizes | 1, 1, 1 |
| 46 | model scores: stride, kind of model, how many scores | 32, 2, 9, and all zero just after a restart |

## Named settings

Build 64 lists 38, read on 2026-11-17 at 20:12. Build 72 has not been read. Each has a kind,
limits and actions: 0 read, 1 write, 2 run, and 3 and 4 which look like starting and stopping
updates. The app writes whole numbers, yes or no values and choices.

- Gestures: `enable-partial-gestures`, `index_ia_enabled`, `standby-gesture`, `hand`.
- Motion: `quat_stream_mode`, `quat_stream_frequency`, `imu_calibration_applied`, `gyro-bias`,
  `accel-bias`.
- Model: `inf_filter`, `inf_downsample`, `normalized-inference`, `load-flash-model`,
  `use-custom-metadata`, `data-collection`, `data-collection-model`, `wrist_encoding`.
- Feedback: `haptics`, `trigger-haptics`, `led_on_gestures`.
- Power: `auto-standby-timeout-secs`, `stream_in_standby`, `keep-alive`, `battery_update`,
  `battery_is_multicast`, `auto-off-btd`.
- Fit: `band-tightness-threshold`, `trigger-band-tightness`, `trigger-multi-tightness`.
- Radio: `le-power-control`, `le-tx-max-power-level`, `le-tx-init-power-level`,
  `lepc-golden-range`, `bcm` (pairing mode).
- Service: `settings-reset`, `coredump_collect`, `trigger-coredump-upload`, `positron-telemetry`.

Never write `haptics` 1: on 2026-11-16 it left the motor silent until a restart. `settings-reset`
and `bcm` are not offered anywhere.

## Handwriting

The band's handwriting model is `hw_t59_f1076659698_260503`, on the band since build 64. Device
information on this band does not list a handwriting feature. On 2026-11-18 the band took the
handwriting state (settings field 6 = 4) and kept sending 9 gesture scores, so that state does
nothing here. The public Mac app's route is two named settings, `data-collection` on and
`data-collection-model` 5, with scores that carry model kind 3. The app now tries the state
first and those settings after three seconds without rows of a hundred. Not yet tried on the band.

## Open

- Everything marked unknown above, which the probe answers.
- The detector types for request 21 and what `trigger-multi-tightness` returns.
- What selects the trial gesture model build 72 lists.
- The layout of EMG `wrist_encoding` 1.
- Whether gestures keep arriving while data collection is on.
