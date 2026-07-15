# Trifola motion inventory

Trifola is a calm instrument: silent while it watches, instant under keyboard hands, and willing to spend delight only on first sight and meaningful state change. Frequency—not component prestige—selects motion. Production sites route through `Theme.motion(...)` or a shared `View.motion(...)`/`Reveal` helper; call sites do not invent curves, accessibility branches, or durations.

`TRIFOLA_MOTION_SLOW` is read once at launch and multiplies every production token and authored delay by four. Reduce Motion never inherits that review multiplier.

## Tokens

| Token | Timing | Authorized use |
|---|---:|---|
| `Motion.quick` | 120ms ease-out | Hover/focus/toggle feedback and the quiet transcript-line fade |
| `Motion.roll` | 180ms strong ease-out | Every `numericText` digit roll |
| `Motion.move` | 300ms critically damped spring, bounce 0 | 6pt insertion/disclosure travel, height/reorder retargeting, toast entry |
| `Motion.exit` | 160ms ease-out | Opacity-led removals and downward toast exit |
| `Motion.ceremony` | 300ms ease-out | Door Light trim draw and core hue/opacity only |
| `Motion.nav` | 200ms strong ease-out | Pointer section settle, sidebar selection travel, disclosure chevrons |
| `Motion.reveal` | 300ms strong ease-out | Launch and per-section one-shot reveals; 40ms step, 320ms section cap |
| `Motion.draw` | 500ms in-out continuous; 400ms strong ease-out bars | One-shot chart/gauge geometry |
| `Motion.echo` | 400ms strong ease-out | One state-flip Door Light attention echo |

The source brief calls this “all eight tokens,” but adding `roll` to the original four plus four named additions yields nine public transition tokens. All nine, both draw variants, the 40ms stagger, and authored reveal delays are review-scaled.

Door Light ambient phases are not transition tokens: running breath is a 2.4s opacity sine; the blocked reminder retains its 8s cadence and 300ms window. Both stop under Reduce Motion.

## M-directive surfaces

| ID / site | Trigger and stable key | Frequency | Token / movement | Reduce Motion |
|---|---|---|---|---|
| M-1 `AppServices.select(_:origin:)` | Every section mutation; `NavOrigin.pointer`, `.keyboard`, or `.programmatic` | Infrastructure | One `withTransaction`; pointer carries `nav`, all other origins disable animation | Same origin policy; view helpers remove spatial movement |
| M-2 `ContentColumn` | Section identity changes under a pointer transaction | Occasional | Incoming opacity + y 8→0 with `nav`; outgoing opacity with `exit`. The cold/not-ready shell enters instantly (it is the feedback frame) and exits opacity-led with `exit`; the destination keeps one structural identity across the pending→presented flip (probes parameterize, never detach) | 160ms cross-fade, no offset |
| M-3 `SidebarRail` selection capsule | Same selection transaction; one `matchedGeometryEffect` id | Occasional | Capsule travels with `nav`; icon/text wash uses `quick` | Matched geometry is removed; highlight snaps with a 160ms wash |
| M-4 root rail + `ScreenScaffold` header/content | Once per process launch; replay after a window has been closed at least 30 minutes | Rare | Rail 0ms, header 60ms, content 120ms; opacity + y 6→0 with `reveal`; total 420ms | All groups fade together for 200ms; no offset or stagger |
| M-5 `ScreenScaffold` direct blocks | First visit to each section in `seenSections`; Sessions uses two explicit blocks, populated Fleet uses strip then bays | Rare per section | Opacity + y 6→0 with `reveal`; 40ms reading-order steps, capped at 320ms | Blocks fade together for 160ms; no offset |
| M-6 `BurnSparkline`, `TierSplitBar`, `BarStrip`, reroute sparkline | Geometry’s first section appearance; local progress remains 1 across data republishes | Rare/explanatory | Bars grow from a visible baseline with 30ms steps and `draw(.bar)` | Complete geometry; enclosing block supplies the 160ms fade |
| M-6 `QuotaWindowRow` | First Overview appearance only; later quota updates retain progress 1 | Rare/explanatory | Leading sweep with `draw()` | Complete geometry; enclosing block fades |
| M-7 every in-window `SeatMark` | Launch rail or section’s first appearance; explicit/containing reading-order index | Rare | Ring trim 0→1 + core fade with `ceremony`; first six step 40ms, 7+ share 200ms | Ring complete immediately; core fades 160ms |
| M-7 menu-bar dropdown `SeatMark` | Dropdown presentation | Frequent | Explicitly exempt; complete ring, no first-appearance draw | Complete ring |
| M-8 every visible `SeatMark` | Distinct transition into waiting or blocked; never republish or recovery | Ceremonial | One ring scale 1→1.35 while opacity 0.35→0 with `echo`; existing 8s blocked reminder continues | Echo off; existing reduced ceremony remains |
| M-9 receipt, launch-detail, adjudicated, snoozed/muted, and Fleet child disclosures | Stable disclosure boolean | Occasional | Content opacity + y 6→0 + height with `move`; removal `exit`; chevron `nav` | Layout snaps; content opacity 160ms; chevron snaps |
| M-10 shared `TapButton` | Pointer-down gesture state; palette sets `pressFeedback: false` | Frequent interaction | Press-in 100ms strong ease-out, scale 0.96 + one-shade wash; release `quick` | No scale; 160ms wash/opacity |
| M-11 Ledger, Launch, SessionActions `Toast` | Feedback-string identity, including non-nil replacement | Occasional | Enter y 12→0 + opacity with `move`; leave y 0→8 + opacity with `exit` | Opacity only, 160ms |
| M-12 `TranscriptRow` | Stable event id inserted into the live feed | Ambient | Opacity only with `quick`; no y or height animation | Instant |
| M-13 Attention empty ↔ rows | `shown` session ids / empty state | Occasional | Asymmetric `move`/`exit` cross-fade with 6pt populated entry and spring height | 160ms opacity; layout snaps |
| M-13 Live, Fleet, Sessions inspector, Deadlines, Ledger, Stack | Empty/populated identity or stable row ids | Occasional | Shared `move` insertion + `exit` removal; parent height/reorder retargets with `move` | 160ms opacity; no offset, layout snaps |
| M-14 `CommandPalette.swift` | Presentation, typing, pointer/keyboard selection, execution | 100+ / day | No motion API, transition, or animation occurrences; navigation executes with keyboard origin | Already instant |

There is no line/area chart in the current production UI. If one is introduced, its first-appearance geometry must use leading-edge trim with `Motion.draw()` and the same persistent one-shot progress semantics.

## Existing ambient and membership surfaces

| Site | Trigger / stable key | Frequency | Token | Reduce Motion |
|---|---|---|---|---|
| Sidebar badges/footer; Overview, Spend, burn, quota, attention and menu-bar numerals | Exact displayed value/string | Ambient | `roll` numeric text | Plain monospaced swap |
| Attention, Live, Sessions, Fleet, Deadline, Ledger and menu-bar membership | Stable row ids / displayed id order | Occasional | Insert `move` with 6pt travel; remove `exit`; parent reorder `move` | Opacity 160ms; layout snaps |
| Transcript “Jump to live” pill | `pinnedToLive`; bottom is its real origin | Occasional | 6pt `move` / `exit`; programmatic scroll remains instant | Opacity 160ms |
| TapButton focus, HoverRow/sidebar hover, TapToggle | Focus/hover/bound value | Frequent | `quick` | 160ms non-spatial wash/change |
| Door Light running breath | Absolute running phase | Ambient | 2.4s opacity sine | Off |
| Door Light blocked reminder | Absolute blocked phase | Ambient | 8s cadence, 300ms ring/opacity window | Off |

## Intentionally instant

- Command palette presentation, focus, typing, selection, execution, and all palette rows.
- Command-digit sidebar navigation, palette navigation, restoration, deep links, and programmatic section changes.
- Programmatic transcript jump after “Jump to live.”
- Unchanged heartbeat/data republishes: digit animation is keyed to the displayed value, membership/reorder to stable ids, and chart progress never resets.
- Menu-bar dropdown Door Light presentation.

There is no scroll-linked motion, animated shadow/blur, sound, haptic feedback, overshoot, or `easeIn` curve.

## Mechanism boundary

Value-keyed animation remains the rule for retargetable state. Fire-and-forget `withAnimation` is allowed only inside the `Reveal` namespace’s launch, block, and chart-progress one-shot helpers; those helpers never disable input.

The menu-bar glyph, Dock badge, and application icon are AppKit raster images rather than live SwiftUI `SeatMark` views. They update immediately and cannot participate in trim/core/echo animation. The SwiftUI mark inside the dropdown is also deliberately exempt because the dropdown is frequent.
