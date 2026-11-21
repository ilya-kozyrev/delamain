# Hub retrospective — {{since}} to {{until}}

Home: `{{home}}`. Exact window: `[{{since}}, {{until}})`. Baseline: `{{baseline}}`.
Inputs: `window.json`, `{{metrics}}`, CSVs, reader/lessons/efficiency reports, independent verification.
Use the final 2026-11-21 report's section order below; translate headings/content into the owner's language.
Replace instructions with verified results and retain explicit data limits.

## Outcome
Five lines: what improved, biggest recurring defect, largest delivery brake, cost finding, owner decision.
Include a ≤12-number A–D scorecard: current/baseline, per-day where meaningful, denominators and sources.

## 1. Release checklist
Read `{{check_next}}`. Table: original row id | what changed | baseline | current | original pass criterion |
verdict (pass/fail/measured/unknown). Preserve original criteria and label non-comparable windows. Note released
complexity changes only when source/version evidence exists.

## 2. Idle and brakes
### D. Idle time
Gap counts/hours by cause, night/day separately; ready-to-next median/p90 with open-plan evidence. List all
evidenced brakes and ten longest gaps: stage, window, preceding line/quote, ending, hours, source. Separate
missed wakes, legitimate waits, brakes and permission brakes; silence alone cannot establish a cause.

## 3. Feature delivery and stage completion
### A. Feature flow
Per-stage merged items, lead time median/p90, build/review/CI/merge-queue segments, throughput per day/shift,
first-time-right and cost/merge. Show current/baseline and journal-only merge lower bounds beside figures.
### B. Stages
Started/closed/open/hanging, close age and plan items done/dropped/carried over. Each state needs evidence.
### C. Autonomy
Owner touches by class and per merge/stage-day; questions/defaults, answer waits and work continuing meanwhile;
self-decided share; hub-to-hub responses/escalations, reply median/p90 and conflict resolutions.

## 4. Lessons
Inventory/verdicts/promotions/withdrawals, changed behavior and recurrence controls, quality, spread,
rule-text cost, trial verdict and candidate plugin fixes. Mark snapshot-only history unknown.

## 5. Money and limits
Agents by engine/model/effort; ten most expensive agents and brief purpose; hub shifts, turns, input including
cache, max context, compactions and no-tool wakes; agent+hub cost/day by stage, hub/review cost shares.
Source gaps stay unknown. Runtime observations are not savings estimates. Name applicable policy conflicts.

## 6. Rule compliance
Applicable rule | cases | stage | evidence | recurrence/consequence | plugin defect or stage choice | confidence.
Account for historical version/engine policy and standing permissions before calling a violation. Include
quantitative friction (hook denials, plugin nonzero exits, watchdog wakes, EXIT/ENDED without status) and
status→reaction median/p90/worst ten, with detector controls. Separate detection from proven plugin causality.

## 7. Proposed changes, ranked by effect
Change | source/code verification | expected measurable effect | implementation/rule-text cost | uncertainty.
Separate plugin changes from project-hub changes. Every owner decision has A/B, recommendation, default and
`ask add` id. A proposed change is distinct from authorization to implement/release it.

## 8. Data limits
Coverage by source/engine/window, unresolved needs_review ids, missing fields and historical attribution;
independent verifier's verified/rejected/unresolved verdicts. Give exact repeat command, saved input paths and
interpretation changes needed to reproduce the comparison. Null stays unknown.

## What to check in the next retro
Link completed `CHECK-NEXT.md`; summarize stable metric ids, baselines, detectors/positive controls, pass
criteria and release boundaries for each ranked change. Keep unavailable baselines explicit.
