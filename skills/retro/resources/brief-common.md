# Retro — common contract

Home: `{{home}}`  
Output: `{{out}}`  
Window: `[{{since}}, {{until}})`  
Baseline: `{{baseline}}`  
Previous checklist: `{{check_next}}`  
Metrics: `{{metrics}}`

Stages:
{{stages}}

Goal: identify evidenced plugin improvements in rule compliance, recurring mistakes, cost, delivery,
stage completion, autonomy, idle time and lessons. Compare totals and per-day rates over the exact windows.
Read `window.json`, `measure.md`, the previous checklist and applicable stage/global rules before interpreting.
The installed rules are evidence of current behavior; use release/version boundaries for historical claims.

Read-only: all audited homes, transcripts, repositories, registers and baselines. Write only your assigned
outputs under `{{out}}`. Coordination commands belong to the audit hub; workers do not change audited state,
run repository tests, contact forges or send messages to other stages. Local forge exports are optional inputs.

Every finding: stage + file:line or timestamp + quote (at most 25 words) + observed consequence + confidence.
Every number: metric key or CSV row and source; rerunnable extraction goes into measurement, not mental counts.
A zero requires the same detector to match a known positive (synthetic only when real coverage is unavailable,
labelled synthetic). Missing source, incomplete transcript or ambiguous join means unknown, never zero.
Separate observed rule violations from plugin causality; check the rule that actually applied in the window.

Inspect: status-only agent reporting; wakes without new events; executor ownership of commits/pushes/waits;
review rounds and author/reviewer independence; handoff/compaction; evidence and negative controls; owner-only
decisions and standing permissions; agreed DoD; model/effort and MCP choices; focused tests; script-based CI
waits; supported launch modes. Report only rules applicable to the audited stage/version.

Return one report path and a one-sentence result (or BLOCKED with the missing source). Stop at the assigned
call budget, save partial results and list unread inputs. No claim of full coverage after a partial read.
