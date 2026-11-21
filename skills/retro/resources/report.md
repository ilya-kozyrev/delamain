# Hub retrospective — {{since}} to {{until}}

Home: `{{home}}`. Exact window: `[{{since}}, {{until}})`. Baseline: `{{baseline}}`.
Inputs: `window.json`, `{{metrics}}`, CSVs, reader/lessons/efficiency reports, independent verification.
Replace instructions below with verified results in the owner's language; retain explicit data limits.

## Outcome
Five lines: what improved, biggest recurring defect, largest delivery brake, cost finding, owner decision.

## Previous release / CHECK-NEXT
Read `{{check_next}}`. Table: original metric | detector/source | baseline | current | original pass criterion |
verdict (pass/fail/measured/unknown). Preserve original row ids and criteria; label non-comparable windows.

## Efficiency scorecard
At most 12 numbers; A feature flow, B stage completion, C autonomy, D idle/brakes. Show current/baseline,
per-day where meaningful, coverage and source. Null stays unknown; no fabricated composite score.

## A. Feature flow and B. Stage completion
Per-stage lead time/segments, throughput, first-time-right, cost/merge; starts/closes/open/hanging and plan
outcomes. Include missing forge/join coverage and journal-only merge lower bounds beside the affected figures.

## C. Autonomy and D. Idle/brakes
Touches by class and rate, question waits/defaults, self-decided share, hub-to-hub response/escalation;
gap hours by cause and night/day, ready-to-next, all evidenced brakes and ten longest gaps.

## Lessons
Inventory/verdicts/promotions/withdrawals, changed behavior and recurrence controls, quality, spread,
rule-text cost, trial verdict and candidate plugin fixes. Mark snapshot-only history unknown.

## Rules and recurring mistakes
Applicable rule | evidence | recurrence | consequence | plugin defect or stage choice | confidence.
Account for historical version/engine policy and standing permissions before calling a violation.

## Tokens, limits and cost
Agents by engine/model/effort; top ten expensive agents and brief purpose; hub shifts, turns, input including
cache, max context, compactions, no-tool wakes; agents+hub cost/day by stage, hub and review cost shares.
Costs absent from sources stay unknown. Runtime observations are not savings estimates.

## Plugin friction and latency
Hook denials, plugin nonzero exits, watchdog wakes, EXIT/ENDED without status; status→hub reaction median/p90
and ten worst. Distinguish event detection from proven plugin-caused delay. Include detector controls.

## Ranked changes and owner decisions
Change | evidence | expected measurable effect | implementation/rule-text cost | uncertainty | priority.
Every owner question has A/B, recommended option, default and `ask add` id. Link follow-up `CHECK-NEXT.md`.

## Data limits and verification
Coverage by source/engine/window, unresolved needs_review ids, missing fields, verifier verdicts, repeat command.
State exact inputs and interpretation changes required to reproduce the comparison.
