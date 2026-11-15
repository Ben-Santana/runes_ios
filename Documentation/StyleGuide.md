# Runes for iPhone — Style guide

One ring, one sentence, one action. Runes is an instrument, not a dashboard: it answers
*what is my band doing right now* and gets out of the way. The look is the Mac app's
(`runes_mac/docs/design.md`) carried to the phone: achromatic, Geist, hairlines,
no shadows at rest, 200 ms motion. The home screen is the reference; every other screen is
drawn with the same six tokens and the same parts, defined once in the component library,
`RunesIOS/Views/Design/`.

A live version of this document is the `style-guide` snapshot
(`RUNES_SNAPSHOT=style-guide`, or the "Style guide" preview in `Views/Design/StyleGuide.swift`).
It draws every token and part with the real code and has the appearance switch at its top.

### The library

| File | Holds |
| --- | --- |
| `Theme.swift` | Tokens only: colour, type, motion, metrics, and the `Appearance` choice |
| `Buttons.swift` | Button styles, `IconButton`, `RoundAction`, `CapsuleAction`, press styles |
| `Surfaces.swift` | `page()`, `panel()`, `PanelGroup`, panel rows, `Rule`, `Chevron`, issue and notice cards |
| `Ledger.swift` | `Block`, `Heading`, `Hairline`, `Note`, `AddRow`, `HairlineSegments` |
| `Inputs.swift` | `FormSheet`, `ChoiceList`, `ChoiceSheet`, `ChipRow`, `TitleField`, `NumberChip`, `HairlineSwitch` |
| `Indicators.swift` | `GestureChip`, `PulseDot`, `OrbitDot`, `RepBar`, `StepProgress`, `TimerRing`, `Sparkline` |
| `Motion.swift` | `arrive(_:)`, `breathing(_:)`, `jiggle(_:index:)` |
| `Icons.swift`, `HairlineRing.swift`, `TriggerComposer.swift`, `SwipeToDelete.swift` | The icon set, the ring, the trigger sheet, rows and chips, swipe to delete |

A part goes in the library when a second screen needs it. Parts that read one app's model
(`Waveform`, `StepTicks`, `DurationChip`) stay with that app and are still shown in the gallery.

## 1. Principles

1. **The object is the interface.** The hairline ring carries state, feedback and the
   primary action. Chrome around it is quiet: hairlines, muted captions, a single ink button.
2. **Ink on paper.** Two colours do the work. Hierarchy comes from weight, size and distance,
   never from colour or shadow. Red appears only on a destructive control.
3. **Hairlines, not boxes.** Edges are 1 pt rules. Panels are reserved for grouped settings;
   content lists are open ledgers with rules between rows.
4. **One sentence, one button.** A problem is a plain sentence and its remedy. Protocol detail
   never reaches the screen.
5. **Motion explains.** Everything that moves does so in 200 ms with an ease-out; arrivals take
   350 ms. Springs are for touch feedback only. Reduce Motion removes every movement and
   leaves the states.
6. **Same icon as the Mac.** Lucide 0.468 at a 1.5 stroke in a 24-unit box, plus the Mac's
   hand-drawn finger icons. No SF Symbols in the interface.

## 2. Colour

Six semantic tokens; light and dark are the same tokens, inverted. Never write a hex value in a view.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `paper` | `#FFFFFF` | `#0B0B0C` | Page and panel background |
| `ink` | `#191919` | `#EDEDED` | Text, icons, primary fills, active strokes |
| `muted` | `#696969` | `#8E8E8E` | Secondary text, inactive icons, captions |
| `rule` | `#E8E8E8` | `#262628` | Hairlines, panel borders, inactive tracks |
| `soft` | `#FAFAFA` | `#141416` | Quiet fills: issue card, flashed row, pressed secondary |
| `faint` | `#C9C9C9` | `#55555A` | Resting electrode strokes, empty dots |
| `destructive` | system red | system red | Only the swipe-to-delete square |

Contrast: `muted` on `paper` is 5.6:1 light and 6.4:1 dark. `faint` is decorative only and
never carries text.

**Appearance.** Runes follows the phone by default. Settings → Appearance offers Automatic,
Light and Dark (`Appearance` in `Theme.swift`, stored under `Preferences.appearance`). The
choice is set on the app's windows, not on a view, so sheets, covers and alerts follow it.
Never use `preferredColorScheme` in a screen; a screen that must stay dark for its content
(Reels' video) paints its own background instead. Check every new screen in both.

The Wrist scene uses a thin `wristGlow` blue outline during movement, with faint elliptical floor outlines.
Its hand and ring strokes retain the shared monochrome treatment.

## 3. Type

Geist, bundled (OFL). Every style is relative to a Dynamic Type text style and scales.
Letter-spacing is set only on `display` (−0.6).

| Token | Size / weight | Relative to | Use |
| --- | --- | --- | --- |
| `display` | 28 medium | largeTitle | The ring's state, onboarding titles, big numbers |
| `heading` | 20 medium | title3 | App names, plan names, sheet headings |
| `bodyText` | 15 regular | body | Rows, sentences, fields |
| `label` | 14 medium | subheadline | Buttons, toolbar actions, segment titles, chip text |
| `caption` | 12 regular | caption | Section labels, footers, metadata, tab titles |
| `code` | footnote mono | footnote | Request bodies and raw values only |

Numbers that change use `monospacedDigit()` and `.contentTransition(.numericText())`.
Nothing is below 10 pt; 10–11 pt is reserved for dense instrument readouts (tab bar labels,
chart ticks, step-chip axes).

## 4. Space and shape

Base unit 4. Page gutter 20. Section gap 28 (panels) or 36 (ledgers). Row inset 14.

| Token | Value | Use |
| --- | --- | --- |
| `Metric.hairline` | 1 | Every rule and border |
| `Metric.chip` | 4 | Step chips, tiny badges |
| `Metric.control` | 6 | Buttons, segments, delete square |
| `Metric.panel` | 8 | Panels, issue card, app cards, profile tiles |
| `Metric.gutter` | 20 | Page side padding |
| `Metric.inset` | 14 | Horizontal padding inside a panel row |
| `Metric.rowDense` | 44 | Detail rows (key / value) |
| `Metric.row` | 48 | Standard rows, buttons |
| `Metric.rowTall` | 52 | Rows with a two-line label or an icon |
| `Metric.tap` | 44 | Minimum hit target; icon buttons are 44 × 44 |

Capsules are used for the run action and for state chips (gesture chip, "Up next").
Circles are for icons that represent an object (apps, round actions, the battery ring).
No shadows, no blur, no material.

## 5. Surfaces

**Page.** `paper`, ink foreground, ink tint. Applied once with `.page()`.

**Panel** (`.panel()`): paper fill, hairline `rule` border, 8 pt corners. Used for grouped
settings, mapping groups, the live strip, the Applications cards. Rows inside sit at `Metric.inset`
and are separated by `Rule(inset: Metric.inset)`.

**PanelGroup**: a `SectionLabel` (caption, muted, 2 pt in from the edge), the panel, then
an optional caption footer. The single group component for Settings, Advanced, Mappings and
the air-gesture editor.

**Ledger** (Workouts): no panel. Rows are separated by `Hairline` rules
that draw in from the leading edge. Headings are `Heading` (label-weight title, hairline to
the trailing edge). Captions use `Note`.

**Issue card**: `soft` fill, hairline border, a 6 pt dot (`ink`, or `muted` when gentle),
one sentence, one hairline button.

## 6. Parts

| Part | Where defined | Rule |
| --- | --- | --- |
| `PrimaryButton` | Buttons | Ink fill, paper label, 48 tall, full width, 6 pt radius; pressed = 82 % |
| `SecondaryButton` | Buttons | Paper fill, hairline border; pressed = `soft` |
| `QuietButton` | Buttons | Muted text only, 44 tall; for the option under a primary |
| `IconButton` | Buttons | A 20 pt Lucide icon in a 44 × 44 target; toolbar and header actions |
| `Rule` | Surfaces | Hairline divider, optional leading inset |
| `Chevron` | Surfaces | 16 pt Lucide chevron-right, muted; trailing edge of every link row |
| `SectionLabel` | Surfaces | Caption, muted, header trait |
| `IssueCard` | Surfaces | See Surfaces |
| `FormSheet` | Inputs | A small editing sheet: inline title, Cancel, one confirming action |
| `ChoiceList` / `ChoiceSheet` | Inputs | Options as panel rows with a check; the sheet closes on choice |
| `ChipRow` | Inputs | Discrete values as scrolling pills with faded edges; replaces menu pickers |
| `TitleField` | Inputs | A display-size text field over a rule that wakes with focus |
| `NumberChip` | Inputs | A number with its unit; tap to type, + and − appear; replaces Stepper |
| `LucideIcon` | Icons | Sizes 20 (toolbar), 18 (row object), 16 (trailing/inline), 14 (within chip) |
| `HairlineRing` | HairlineRing | The product's face; never scaled below 150 pt wide |
| `Hairline`, `Heading`, `Note`, `AddRow`, `HairlineSegments` | Ledger | Ledger parts |
| `RoundAction`, `CapsuleAction` | Buttons | The run screen's round and capsule actions |
| `GestureChip`, `PulseDot`, `OrbitDot`, `RepBar`, `Sparkline` | Indicators | State and progress in ink against hairline |
| `StepProgress`, `StepTicks`, `DurationChip` | Indicators, CookView | A recipe's steps as hairline segments and ticks; a step's time as a quiet chip |
| `TimerRing` | Indicators | A hairline circle that fills as a timer runs out |
| `HairlineSwitch` | Inputs | A switch in ink and hairline (outline and open knob off, filled on); reads in both appearances |
| `ComboCreator` | ComboCreator | The one way to set a gesture or build a combo: the steps as beads on a string, with a pad of gesture keys down the right that opens from the ring at the string's end. `TriggerRules` decides which keys are offered |
| `TriggerSheet` | TriggerComposer | The creator over a draft, with the time between steps for a combo, with Cancel and Save; `TriggerRules` says whether it takes one gesture, a combo or either |
| `TriggerRow`, `TriggerChip` | TriggerComposer | A ledger row for something the band does, with its gesture or its combo's steps as a capsule |
| `NoticeCard` | Surfaces | The issue card's look for any sentence and one action |
| `Waveform` | CaptureView | A recording as hairline bars, inked up to the playback position |

### Row anatomy

Panel row: `Metric.inset` horizontal padding, `row` / `rowTall` height, `bodyText` title,
optional `caption` detail under it (2–3 pt gap), value or `Chevron` at the trailing edge,
`.contentShape(Rectangle())`, `.buttonStyle(.plain)`. Dividers inset to match.

Ledger row: 12–16 pt vertical padding, full-width hairline, `PressRow` style (dims to 55 %).

### Input, never in a system alert

Text input, choices and numbers are edited in the app's own parts: a `FormSheet` for a name
and its options, a `ChoiceSheet` for one-of-many, a `TriggerSheet` for a gesture or combo (never a
list or a menu of gestures), `HairlineSegments` for two to four options,
`ChipRow` for a short scale, `NumberChip` for a number. System alerts are for confirmations
only, and `Menu` only for a short list of verbs on an object (duplicate, delete), never for
setting a value.

### Nav chrome

Every pushed or presented screen is `navigationBarTitleDisplayMode(.inline)`. Toolbar
actions are text in `label`: **Done** (confirmation) or **Cancel** (cancellation), **Save** when
a draft exists. One icon action at most, drawn with `IconButton`. The root screen has no
navigation bar; its header is the battery ring and three icon buttons.

## 7. Motion

| Token | Curve | Use |
| --- | --- | --- |
| `.standard` | ease-out 200 ms | State and control changes, fades, selection |
| `.entrance` | ease-out 350 ms | A screen's content arriving |
| `.lively` | spring 300 ms, bounce 0.3 | Press feedback on round and capsule controls |
| Ring tweens | 700 ms | Pods moving, inherited from the Mac's Hairline |

Press states: scale 0.97–0.98 and opacity 0.85 on the ring and tiles; opacity 0.55 on ledger
rows; opacity 0.6 on quiet buttons. Rows that just fired a mapping flash `soft`.
With Reduce Motion: no scale, no offset, no repeating animation; opacity changes stay.

## 8. Writing

Sentence case everywhere, including buttons and section labels. One sentence per caption.
Verbs on buttons ("Pair Mac", "Forget band", "Search again"). Problems are addressed to
the person and end with the remedy. Protocol names, codes and identifiers belong in the
journal and in Advanced only.

## 9. Accessibility

Dynamic Type through `relativeTo` on every font. Tap targets ≥ 44 pt. Rows combine their
children into one element with a value ("On", "Off", "82 percent"). Decorative strokes and
icons are hidden; icon buttons carry labels. Every state the ring shows is also in words.
Reduce Motion is checked wherever something moves.

## 10. Do / don't

- Do use `Rule` and `Chevron`; don't draw a `Rectangle` divider or an SF chevron inline.
- Do use the metric tokens; don't type 44, 48, 52 or a corner radius.
- Do keep the home screen as it is; it is the reference, not a client of the guide.
- Don't add colour to mean state. Filled vs hairline, ink vs muted, does the job.
- Don't add a shadow, blur or material anywhere.
