# Trifola motion inventory

Motion is assigned by frequency, not by component prestige. All production animations resolve through `Theme.Motion`; `TRIFOLA_MOTION_SLOW` is read once at launch and multiplies the four tokens by four for review.

## Tokens

| Token | Timing | Authorized use |
|---|---:|---|
| `Motion.quick` | 120ms ease-out | Ambient digit rolls; hover, focus, pressed, and toggle feedback |
| `Motion.move` | 250ms critically damped spring, bounce 0 | Occasional row membership, height, reorder, disclosure, transcript pin, and feedback toast movement |
| `Motion.exit` | 160ms ease-out | Opacity-led removals |
| `Motion.ceremony` | 300ms ease-out | Door Light trim draw and core hue cross-fade only |

The shipped Door Light ambient phases are not transition tokens: running breath is a 2.4s sine on opacity only; the blocked echo keeps its 8s cadence and a 300ms window. Both stop under Reduce Motion.

## Animated surfaces

| Site | Trigger / stable key | Frequency | Token | Reduce Motion behavior |
|---|---|---|---|---|
| Sidebar footer today + month | Exact displayed burn line | Ambient | `quick` numeric text | Plain monospaced swap |
| Sidebar fleet / ledger badge | Exact displayed count | Ambient | `quick` numeric text | Plain monospaced swap |
| Overview verdict dollars, counts, pace, and age | Exact displayed sentence fragment | Ambient | `quick` numeric text | Plain monospaced swap |
| KPI `StatTile` values (Overview, Spend, other bands) | Exact displayed value string | Ambient | `quick` numeric text | Plain monospaced swap |
| Daily burn today, Opus share, projection, and run rate | Exact displayed value string | Ambient | `quick` numeric text | Plain monospaced swap |
| Live tile session-to-date dollars | Exact displayed cost; row id is `SessionSummary.id` | Ambient | `quick` numeric text | Plain monospaced swap |
| Overview Live-now session dollars | Exact displayed cost; row id is `SessionSummary.id` | Ambient | `quick` numeric text | Plain monospaced swap |
| Menu-bar title count / whole-dollar alert | Exact reducer-produced title (`9+` remains stable) | Ambient | `quick` numeric text | Plain monospaced swap |
| Overview tier total, sessions, tokens, dollars, and share | Display string; row id is `ModelTier` | Ambient | `quick` numeric text | Plain monospaced swap |
| Shared tier legend and Spend tier table values | Display string; row id is `ModelTier` | Ambient | `quick` numeric text | Plain monospaced swap |
| Attention legend and snoozed/disclosure counts | Display string; state/disclosure identity is stable | Ambient | `quick` numeric text | Plain monospaced swap |
| Attention rows | Membership/order keyed by session id | Occasional | Insert `move` opacity + container height; remove `exit` opacity | Layout snaps; opacity transition is 160ms |
| Snoozed disclosure | Stable `snoozed-disclosure` id; suppressed session ids in parent key | Occasional | `move` / `exit` | Opacity only, 160ms |
| Moving-again acknowledgment | Acknowledgment id | Occasional | `move` / `exit` | Opacity only, 160ms |
| Live board tiles and overflow row | Stable session ids | Occasional | `move` / `exit`; parent reorder uses `move` | Opacity only, 160ms |
| Overview Live-now rows | Stable session ids | Occasional | `move` / `exit`; parent reorder uses `move` | Opacity only, 160ms |
| Sessions rows | Stable session ids | Occasional | `move` / `exit`; parent order key is the displayed id array | Opacity only, 160ms |
| Fleet bays, seats, and nested subagents | Stable bay/session ids from `FleetBoard`; disclosure bool | Occasional | `move` / `exit`; disclosure/reorder uses `move` | Opacity only, 160ms; layout snaps |
| Deadline live and shipped rows | Stable project ids | Occasional | `move` / `exit`; each list has an id-order key | Opacity only, 160ms |
| Menu-bar attention rows | Stable session ids, including suppressed namespace | Occasional | `move` / `exit` | Opacity only, 160ms |
| Muted disclosures | `isExpanded` | Occasional | `move` | Layout snaps |
| Ledger/Launch/SessionActions feedback toast | Feedback string | Occasional | `move`; existing bottom-origin transition | Opacity only, 160ms |
| Transcript “Jump to live” pill | `pinnedToLive`; bottom is real spatial origin | Occasional | `move` | Opacity only, 160ms; programmatic scroll is instant |
| TapButton pressed | Press gesture state | Frequent interaction | `quick`, scale 0.97 | Scale is removed; 160ms opacity feedback |
| TapButton focus | Focus state | Frequent interaction | `quick` | 160ms non-spatial focus wash |
| HoverRow and sidebar item hover | Hover bool | Frequent interaction | `quick` | 160ms non-spatial wash |
| TapToggle | Bound bool and focus state | Occasional interaction | `quick` | 160ms reduced transition |
| Door Light ring + core at every SwiftUI `SeatMark` site (rail, attention strip, rows, dropdown, inspectors) | The shared `DoorLightState` value; local trim never restarts during an in-flight draw | Ceremonial | `ceremony` | Ring becomes complete instantly; core opacity/hue fades in 160ms; breath/pulse stop |
| Door Light running breath | Absolute timeline phase, only while running | Ambient | Shipped 2.4s sine, opacity only | Off |
| Door Light blocked echo | Absolute timeline phase, 8s cadence | Ambient | 300ms opacity/ring echo | Off |

## Intentionally instant

- Command palette presentation, typing, selection, and execution.
- Section changes from sidebar shortcuts or command-palette actions.
- Programmatic transcript jump after the user invokes “Jump to live.”
- Unchanged heartbeat republishes: every numeric animation is keyed by the displayed value, and every membership/reorder animation is keyed by stable ids only.

There is no stagger, scroll-linked motion, animated shadow/blur, sound, or haptic feedback.

## Mechanism boundary

The macOS menu-bar glyph, Dock badge, and application icon are AppKit raster images, not live SwiftUI `SeatMark` views. They update state immediately and therefore cannot participate in the trim/hue ceremony. All live SwiftUI Door Lights share the central value-keyed ceremony; the menu-bar title numeral still uses the ambient numeric transition.
