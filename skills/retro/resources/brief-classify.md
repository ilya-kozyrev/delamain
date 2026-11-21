# Retro — efficiency and evidence classification

Read `{{out}}/brief-common.md`, `measure.md` and CSV headers before editing. Sources: `{{metrics}}` and
`flow.csv`, `stages.csv`, `touches.csv`, `tells.csv`, `gaps.csv`, `questions.csv`, `await.csv` under `{{out}}`.
Stages:
{{stages}}

Ownership: `{{out}}/efficiency-REPORT.md` and `{{out}}/classifications/`. Use a selected available judgement
model (Sonnet high or Opus medium; Codex equivalent per policy). Preserve raw CSVs and metric files.

Classify only ambiguous rows whose surrounding evidence you read. Copy relevant input rows to matching CSV
filenames in `classifications/`; retain `id` and add/fill `needs_review`, `class`, `evidence` as documented by
`retro measure --help`. Evidence is file:line/time plus ≤25-word quote. Keep `needs_review` true until evidence
supports the class; accepted classifications set it false. Preserve unknown fields and source ids. Use only
CLI-supported classes; report a missing class as unresolved rather than inventing accepted vocabulary.

Taxonomy: owner touches = decision (money/product/outside company), unblock, correction, nudge, repeat,
new task. Gaps = legit wait, missed wake, brake (owner-ended/self-ended/hanging), permission brake. Resolve
plan items from approved P-entries and handoff next steps; distinguish done, dropped, carried over and unknown.
Tell autonomy needs an attributable reply and evidence of whether the owner intervened. Flow review/CI counts
need complete item joins, not absence of journal mentions. Missing forge coverage leaves first-time-right null.

Report the same four blocks for total and per stage, current/baseline and per-day where meaningful:
A. Feature flow: first linked executor spawn → merge lead time median/p90; build/review/CI/merge-queue
   segments; merges per stage-day/hub-shift; first-time-right (zero red CI and ≤1 review round); agent+hub
   cost per merged item. Treat journal-only merges as observed lower bounds, not complete forge throughput.
B. Stages: started/closed/open, close age, hanging (registered/open, ≥24h journal silence, unfinished plan),
   plan completion at close. Source coverage must support each state.
C. Autonomy: owner touches per merge/stage-day by class; questions asked/answered/defaulted and answer
   wait/continued work; self-decided share = decided/(decided+asked); tells answered without owner, reply
   median/p90, escalation share, conflict resolution. Deduplicate transcript/journal/register observations.
D. Idle: ≥30m gaps by cause, hours, 00:00–08:00 local nights separately; DONE/MERGED → next start with
   open plan median/p90; every brake's stage/time, preceding line, ending and hours. Silence alone is no brake.

Include ≤12-number scorecard, all evidenced brakes, ten longest gaps and data limits. Measurement remains
script-owned: request a rerun from the hub after classifications; do not fill unsupported metrics manually.
Done when each reviewed row has evidence or retains needs_review and A–D each has a result or explicit gap.
Stop after 120 tool calls; save partial outputs and unresolved row ids.
