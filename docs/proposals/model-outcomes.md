# Per-task model outcomes

Status: capture shipped in Delamain 1.0.29. CI history and retro are the second implementation PR.
Business result: every delegated task has independently assigned difficulty, execution identity and observed outcomes;
retro compares these records and offers evidence to the owner, who alone decides model changes.
Source references below use repository revision `072559c15279842afce4a3eb222fd8cca2e90ff1`.
The initial telemetry probe is `~/agent-hub/model-outcomes/coordinator/telemetry-probe-2026-11-26.md`.

## Existing seams and decisions

| Existing behaviour (source) | Use in this design |
|---|---|
| Spawn constructs/saves metadata, copies brief (`bin/agent:893-905,928`); run IDs and resume kind are saved at launch (`bin/agent:680-715`). | Assign a stable task UUID at spawn; snapshot each run's dimensions. |
| Model aliases resolve at spawn/init (`bin/agent:793,713-715`); resume can update effort (`bin/agent:1296`). | Preserve requested and observed model, and effort per run, never overwrite history. |
| `--task-class` only feeds advice (`bin/agent:815,1646-1649`); three classes and model fallback (`bin/limit_pace.py:60,357-363,535`). | Persist task class separately; no model fallback in telemetry. |
| Exit wrapper invokes `exit-note` (`bin/agent:670-675`); clean exits with own status return early (`bin/agent:1550-1552`). | Record run outcome **before** this early return, on every exit. |
| Death observer holds agent lock and claims exit once (`bin/agent:1106-1139`). | Add idempotent incomplete-run evidence; preserve existing journal semantics. |
| Retro walks metadata/logs, infers reviewer identity, and reads journal terminal words (`bin/retro:256-311`). | Add a distinct task-outcome reader; retain the old agents table. |
| Reviewer `for` filters change classes (`bin/reviewers.py:18,84`); docs/code/risky describe review need (`docs/reviewers.md:144-153`). | Keep risk and task difficulty as separate axes. |
| Reviews already have severity and verdict lines (`templates/brief-review.md:44-57`); exit quotes final outcome (`bin/agent:1443-1462,1558-1571`). | Extend the report footer with one structured findings line. |
| Await writes exit/duration and an inferred link, not pipeline history (`bin/await:167-173,219-230`). | Reuse its completion hook, but require typed CI evidence. |
| GitHub waiter reads current-head checks/runs (`bin/gh-ci-wait:72-89,119-148`). | Its success alone cannot prove first-run green. |
| Forge flow counts failures/reviews; first-time-right needs verified joins (`bin/retro:856-868,926-939`). | Keep this metric; add a separately defined first-CI-attempt metric. |
| Retro writes CSVs/metrics, with nullable data and manual interpretation (`bin/retro:1183-1188`; `skills/retro/SKILL.md:19-43`). | Add measured tables and a deterministic proposal gate before interpretation. |

## Task taxonomy and assignment

- `task_class`: `mechanical` (checkable extraction/execution), `bounded` (implementation from a finished design),
  `judgement` (design, unresolved diagnosis, independent review), or `unknown`. These describe the brief, never model.
- `task_kind`: `executor` or `review`; a reviewer normally has difficulty `judgement`. A mechanical extraction helper
  is an executor, not an independent review. `change_class` independently carries `docs|code|risky|unknown` or a
  validated custom class; preserve the existing extensible change-class contract (`docs/reviewers.md:146-147`).
- Hub assigns all three before launch. Persist existing `--task-class`; add `--task-kind` and `--change-class`.
  New hub templates require explicit difficulty; reviewer start lines emit kind=review and difficulty=judgement,
  forward valid `--for` identifiers as change class, and link a role author by task UUID. An engine-only author leaves
  the link null.
- Compatibility: omitted difficulty is `unknown` with one warning, not a spawn refusal. Missing change class is
  `unknown`; omitted kind uses the existing review detector with source=`legacy_inference`, otherwise executor.
  New templates always pass kind explicitly; inferred kinds are descriptive only in retro.
- A stage's `hub-rules.md` may tell its hub which default fits its briefs; the hub must pass that class explicitly.
  Do not parse prose as configuration and do not add a global default that silently labels every task bounded.
- `limit_pace.classify()` remains advice-only for old callers; an omitted/explicit unknown class cannot become an
  observed class. Historical agents stay `unknown`, including those with an eloquent `reason`; no automatic backfill.
  Pass None to the legacy advisor for unknown, not a new unknown key in its class-to-model lookup.
- One spawn = one task contract; all its resumes keep the UUID and difficulty. A new independent task gets a new
  spawn, even if role is reused. Reassignment to another agent uses `continuation_of`; collapse the chain for sample
  counts, retain each contributor's effort, and mark mixed attribution. No independent samples from repair agents.

## Storage, lifecycle and schema

Extend `meta.json` only with immutable `outcome_schema=1`, `task_id` (UUID), taxonomy, assignment source,
`continuation_of`, optional `review_target_task_id`, canonical `repository_key`, expected review/CI applicability,
`parent_task_id`, `usage_in_parent` and `usage_boundary`. Keep mutable outcomes out of meta to avoid late CI/reviewer
writers racing `agent send`. Canonical evidence is append-only JSONL at `<stage>/task-outcomes/<task_id>.jsonl`;
it survives role-directory archival/reuse (existing archival: `bin/agent:887-889`). No transcript text is copied.

Each event has `schema_version`, `event_id`, `task_id`, `run_id|null`, `type`, `occurred_at`, `recorded_at`,
`source` (file:line or provider identity), `writer`, and typed `data`. Times are offset-aware ISO 8601.
A shared `bin/task_outcomes.py` validates/writes under a per-task lock, flushes/fsyncs, and deduplicates event IDs.
Deterministic IDs identify run start/end and provider observations; identical retries are no-ops, conflicting payloads
are rejected. The writer admits one automatic terminal event per run under the task lock. Retries use artifact times
from the exit marker or log. Corrections append an explicit `supersedes` event with reason. Readers ignore/report a partial final
line; a subsequent writer truncates only that torn tail under lock before appending. Never silently skip corruption.

| Event / writer / moment | Required payload or nullable observations |
|---|---|
| `task_started` / spawn, before child launch | Taxonomy + source; stage/role; brief path/hash; canonical repository key; expected review/CI applicability; continuation/target/helper links and usage inclusion/boundary; requested engine/model/effort. |
| `run_started` / launcher, each invocation | Existing run ID, session ID when known, spawn/resume, engine, requested model, effort, log byte offset. Init appends `run_identity` with actual session/resolved model. |
| `run_ended` / exit-note, every termination | End time, exit code, CLI result, termination reason, reported status, usage, turns/unit, cost/basis, evidence completeness. |
| `run_observed_dead` / death observer | Evidence timestamp from the log, process-death evidence and available partial usage. Actual end time and exit code remain null. |
| `review_observed` / exit-note or hub import | Reviewer's task/run, target UUID, artifact/head, review round, verdict, findings counts/IDs and provenance. |
| `ci_observed` / await completion adapter | Target UUID, canonical repository/item/head, pipeline/suite identity and attempt, history coverage, status and provider times. |
| `artifact_observed` / hub, even after closure | Target UUID, artifact IDs, review/CI applicability; unknown remains distinct from not_required. |
| `task_closed` / hub override only | `success|failure|cancelled`, evidence path, closure time, linked artifact IDs, review/CI applicability. |

Automatic closure is a read-only projection of the current run's terminal evidence, never a second automatic
`task_closed` write: reported DONE/REVIEWED/MERGED mean success; abnormal EXIT/STOP mean failure, with projected
`source=auto_status`. `run_observed_dead` preserves reported completion for a successful current result with reason
`wrapper_lost`, and projects failure when recovery/stop provides abnormal terminal evidence.
Actual end time and exit code stay null. BLOCKED/QUESTION and limit exhaustion leave the contract open. A clean process
exit alone does not close an executor; a delivered rejecting review can succeed. Current-run BLOCKED/QUESTION wins
over a wrapper's fallback REVIEWED. Save journal day/byte position at run start so a same-minute prior DONE cannot
close the next run. Stop, wrapper exit and recovery share the terminal transition and distinguish LIMIT from failure.
There is no mandatory per-task hub closing step. `agent outcome ROLE --file FILE` imports typed review, CI, artifact,
closure or correction events. Use `--task-id` for archived agents. A review task's imported target matches its
`task_started.review_target_task_id`, including null. Only the hub writes
`task_closed` with `source=hub`; it binds to a run and overrides its automatic projection. A resume or continuation
reopens the contract and retains old evidence. A crash immediately after run_ended cannot lose automatic closure.
Expected review/CI applicability comes from launch flags filled from the brief/project rule (`required|not_required|unknown`);
never infer not_required from DONE or a missing artifact. Later artifact/review/CI observations attach evidence without
reclosing the task or changing its closure time. Persist provisional starts and failure evidence even before init.

`repository_key` is the resolved common Git database identity, shared by linked worktrees, with an explicit target
checkout when reviewer cwd is a hub/report directory. Unknown/non-Git targets stay null; exclude unknown or ambiguous
repositories from model comparisons. Separate clones conservatively remain separate local keys rather than guessing
from prose, stage names or unverified forge URLs.

Capture immutable task/run IDs and log offset in the exit wrapper: an old wrapper must never finish a newer resume.
Reconcile missing run-end events under the existing agent lock on status/resume; run-end recording is independent
of `claim_exit`'s journal marker. Telemetry failure warns but does not change process exit or suppress journal lines.
A start without a matching end remains incomplete; retro is read-only and does not repair source files.

### Usage and attempts

- Save raw reported counters plus `usage_basis`, `usage_scope`, `complete`, and normalized input/output/cache fields.
  Claude `result.usage` is per invocation in the checked sample; sum distinct results. `total_cost_usd` is cumulative
  per session: use deltas between results, then sum sessions. Do not sum cumulative `modelUsage` snapshots.
- Codex uses latest cumulative usage per session and delta per run (`bin/engines.py:268-281`;
  `bin/agent-top:452-469`; `bin/retro:504-531`). Never add full resume totals. Missing baseline, counter regression,
  partial log, or changed provider semantics => incomplete/null delta, preserve raw data and show a warning.
- Comparable normalized `tokens_total` = input including cache + output. Claude input includes fresh + cache-read +
  cache-create; Codex input already includes cached input. Reasoning tokens are an output subset, never added twice.
  Cache counters stay separate. Separately measured helpers carry `parent_task_id` and `usage_in_parent=included|excluded|unknown`;
`usage_boundary=own_only|includes_helpers|unknown` defines the parent's provider-counter boundary. Aggregate the contract
with helper inclusion explicitly deduplicated. Unknown helper inclusion/boundary makes contract spend incomplete for
the recommendation gate, even if all visible runs have counters. Linked reviews remain a separate quality/cost slice.
Cost is reported Claude USD only; Codex cost=null/basis=`unavailable`, never zero or
  a fitted estimate. Keep native usage scopes explicit; do not count linked reviewers/helpers twice in task totals.
- `turns` = sum Claude result `num_turns`, or count Codex `turn.started`; `turn_unit` names that engine-specific unit.
  Missing result turns remain unknown. These are not cross-engine efficiency equivalents; old `agents.csv` retains
  its stream-message counting (`bin/agent:979-1005`; `bin/retro:306`) and is not relabelled as the new metric.
- `run_count` counts invocations; `resume_count=run_count-1`. These are not fix rounds: replies, rebase and recovery
  also resume. `review_rounds` counts distinct linked review rounds; `fix_rounds` counts explicit hub-labelled
  `resume_reason=review_fix|ci_fix` runs, else unknown. Add that optional reason to `agent send` without guessing text.
- Aggregate the full contract including fixes. Per-run engine/model/effort snapshots expose changes. More than one
  execution identity yields a `mixed` task cell, with run breakdown; exclude mixed tasks from model recommendations.
  Resolved model wins; otherwise show `requested:<id>` with resolution coverage, never silently combine aliases
  across versions. CLI-default/missing model or effort is unknown and ineligible for a recommendation.

## Findings and CI evidence

Add `REVIEW_OUTCOME: {"schema_version":1,"target_task_id":"…","head":"…","round":1,
"findings":{"high":0,"medium":0,"low":0},"finding_ids":[]}` immediately before the existing VERDICT line,
in both report and final answer. The parser reads the full report/result, not the journal's truncated quotation
(`bin/agent:1570-1571`). Require nonnegative integer counts, distinct IDs with severity, matching head and target (including JSON null for an
engine-only author), and
agreement between copies. Missing, malformed or contradictory lines yield null plus diagnostics, never zero.
Each nonempty finding entry is `{"id":"F1","severity":"high"}`; counts must equal entries by severity.
Verdict aliases (`APPROVE`, `merge`, `merge after fixes`, `changes requested`) normalize with raw text retained.
V1 records the reviewer-reported counts; per-finding hub adjudication (`accepted|rejected|pending`) is optional.
Without adjudication, retro (PR 2) labels these counts "reported, not adjudicated". When provided, the hub maps duplicate IDs across reviewers/rounds;
rechecks retain IDs, genuinely new defects get new IDs. Executor accepted findings/task = distinct accepted defects across
its linked reviews; absent or pending adjudication makes that accepted aggregate incomplete. Reported counts stay
available separately without a mandatory adjudication flow. Unreviewed tasks have null, not zero.
Reviewer cells show reported and accepted findings separately: zero findings/APPROVE is not reviewer accuracy.
Unlinked reviews retain reviewer task/run, verified head and reported counts in reviewer cells; executor attribution
requires a confirmed target link, never a fabricated UUID. External reviewer skills import the same event through the hub; missing usage is explicit, not fabricated.

Await gets optional proposed `--outcome-task UUID --ci-item URL` binding, inherited stage plus immutable task ID.
On completion it calls `bin/ci_outcomes.py`: GitHub/GitLab adapters use their installed authenticated CLIs to fetch
paginated item/head/pipeline history and write typed evidence through the shared writer. No `--forge` export needed.
The child wait command and its exit remain unchanged; unsupported provider, permission error, timeout, incomplete
pagination or unverifiable history gives CI=null and coverage reason. Generic PASSED/FAILED is never CI evidence.

Define first-run green **per artifact's first eligible CI attempt**, not the first wait, latest head, or last retry:
GitLab uses the earliest attached push/MR pipeline. GitHub groups the first runs of workflows on the earliest
eligible item head. The initial head's push can precede item creation and is eligible from the commit timestamp.
Exclude scheduled/manual/deploy/merge-train runs. A cancellation verified as displaced by a later push is excluded.
Manual cancellations and cancellations with no evidence of replacement are unknown. Persist ordered history and
required checks with their source. Prefer the configured policy when available. Without one, infer blocking
non-manual jobs on GitLab and PR workflow checks excluding skipped and neutral entries on GitHub (D-OUTCOMES-004).
If the history or check set cannot be established, the result is unknown. Separate immutable attempt identity
from observation version/state identity: identical state retries are idempotent independent of observation time/writer;
pending→success appends a new state version and reduces to one attempt, not a conflict or two samples. Failed required job/check makes
first-run=false permanently, even if rerun in the same pipeline becomes green. True requires all required checks
succeed on attempt 1 and complete history; skipped/neutral/cancelled/missing check or lost retry history is unknown.
Record the earliest attempt when first observed, and retain it across later heads and observations. A late waiter
must verify history back to the initial commit, not assume its first observation was first. Multiple linked artifacts:
task true only if every applicable artifact is true, false if any is false, otherwise null. No CI required is N/A.
This deliberately differs from existing first-time-right, which also includes review rounds; show both definitions.

## Retro output and recommendation gate

Read `<stage>/task-outcomes/*.jsonl`, reduce events as of the report cutoff, and materialize `task-outcomes.csv`.
Freeze input event prefixes/hashes in the audit output so late updates cannot rewrite an old report. Reopened tasks
are pending as of cutoff. Descriptive completion cohorts are snapshots of latest closure in [since, until), including
lifetime run totals; combining/comparing periods must recompute unique root task IDs at a common cutoff rather than
sum snapshot rows. Event visibility uses recorded_at <= cutoff: a late correction with earlier occurred_at cannot
rewrite an already frozen report. Recommendation cohorts use comparable assigned tasks with equal observation windows;
show pending/cancelled/missing-closure counts alongside it. Existing start-window `agents.csv` remains unchanged.
Read legacy metadata/logs into descriptive `unknown` rows without writing back. Do not also count those agents as
new tasks. Deduplicate continuation chains, archived UUIDs, session counters, reviewer events and CI observations.

`model-outcomes.csv` and `measure.md` contain a class × engine/model/effort table, split by task kind and change class:
`n`, successful/known closures, median turns (unit), median tokens, total/median reported USD, reviewed-task coverage,
reported findings/task (first primary report per artifact), accepted findings/task separately, first-run CI passed/known-applicable, and missing counts for every metric. Null is “unknown”,
N/A is distinct, rates show numerator/denominator. Costs say “reported Claude cost”, not subscription spend.
Add namespaced `model_outcomes.*` metrics and `outcome_schema_version=1` to metrics.json while preserving its current
schema and keys (`bin/retro:1184-1188`); compare baselines only with identical outcome schema/cohort/unit definitions.
Do not reuse `review_fields().class_`: that is an audit-classification field (`bin/retro:1047-1048`).

A candidate is a **suggested owner-approved trial**, not a causal claim or a config edit. Fixed v1 gate:
1. Compare executor cells only, within the same repository, difficulty, change class and task kind/window; at least
   five independent completed contracts **in each cell**, all explicitly classified before launch. Keep the full assigned
   cohort with equal follow-up time alongside completed samples, including BLOCKED/QUESTION/open outcomes. Compare
   completion share and demonstrate that unknown/open outcomes cannot reverse the apparent advantage. Report handoff
   share by original assignment; mixed continuation chains remain one contract with full spend and final outcome in
   the original-assignment row. The candidate's handoff share must be no higher than the incumbent's. Show the
   advantage on the full original-assignment cohort including mixed spend/outcomes. Excluding mixed tasks from
   direct cells cannot hide initial failures.
2. Each comparison needs known closure and complete tokens for every task, at least 80% known applicable review/CI
   outcomes, and at least five observed values per applicable quality metric in each cell. Report excluded counts.
3. Candidate success share and first-run CI share must not be lower; reported high-severity findings must not rise;
   mean reported findings/task must not rise. In v1 use reported high/total from the first primary review per artifact
   at matched review coverage; rechecks of the same finding are not new defects. Accepted/adjudicated counts stay separate
   and optional, never a requirement for this gate. If review/CI is explicitly N/A for the whole stratum, omit that gate
   and name the limitation; missing evidence cannot masquerade as N/A. Do not compare different applicability mixes.
4. Require at least **20% savings on the same resource** across the direct median, full-cohort median and
   full-cohort mean. Compare tokens or reported cost when both cells are fully priced on the same basis. Never compare Claude dollars with Codex null. Turns alone cannot trigger a change. Direction is from the current assignment to a candidate, not both pair orders.
   When measured tokens and same-basis cost conflict, present one owner choice with both deltas instead of two opposite
   recommendations. Include original-assignment handoff/completion shares and unknown-outcome sensitivity.
5. Below these gates print “insufficient evidence (n/coverage)” with descriptive numbers. Reviewer cells remain
   descriptive: recommendation needs validated defect-detection quality, which counts/verdict alone cannot supply.

Proposal template: “Consider a bounded trial of B instead of A for <class/repo/risk>. A/B: n=…, success=…/…,
median tokens=…/… (…% difference), known cost=…/…, reported findings/task=…/… (accepted separately), first-CI=…/…;
coverage=…, period=…. Observational association; difficulty selection and reviewer mix may explain it.
Owner decision required; no model, effort, engine or hub rule was changed.” Include source row IDs and sample IDs.
The 5-sample/20% gate prioritizes trial suggestions, not statistical significance. The retro skill interprets the
saved evidence and forwards proposals through its existing owner-decision step (`skills/retro/SKILL.md:40-48`).

## Compatibility and delivery

Old metadata and missing event files remain readable; no destructive migration, model-based historical classing,
or unknown-to-zero conversions. Readers warn/skip unsupported event versions, preserving raw files and coverage.
Both engines use the same schema with explicit counter bases. Core is macOS/Linux; Windows support is through WSL2,
not a new native writer (`docs/agents/README.md:27-30`; `docs/windows-workflow.md:3-15,116-122`). Use Python pathlib,
UTF-8, existing POSIX locking conventions inside WSL; do not introduce platform-specific path parsing.

Two implementation PRs:
1. **Capture and lifecycle:** `bin/task_outcomes.py`, `bin/agent`, `bin/reviewers.py`, `bin/limit_pace.py` help separation;
   `templates/brief-executor-template.md`, `templates/brief-review.md`, hub launch/completion references,
   `docs/reference.md`, `docs/reviewers.md`, CHANGELOG. Add `tests/t_task_outcomes.sh` and agent/reviewer regressions.
   Check: fake Codex/Claude spawn→resume→exit→close produces one task, correct counter bases and immutable identity;
   explicit/missing classes, init failure, kill/recovery, duplicate exits, stale wrapper, concurrent append, torn tail,
   effort switch, reused role, continuation, missing findings and duplicate review IDs have positive/negative controls.
2. **CI and retro:** `bin/ci_outcomes.py`, `bin/await`, `bin/retro`, `skills/retro/SKILL.md` and its report resources,
   reference docs/CHANGELOG; `tests/t_ci_outcomes.sh`, retro/await fixtures. Check: mocked GitHub/GitLab histories with
   first failure→retry green remain false, late wait/multiple workflows/pages/history gaps stay honest; two ≥5 cells
   meeting the 20% gate produce a sourced suggestion, four samples/missing quality/mixed models produce none.
   Exercise archive/continuation dedupe, cutoff replay, old baselines, historical nulls, and both engines' counters.
   Run targeted tests then `tests/run_all.sh` through tq; plugin strict validation and `git diff --check` for both PRs.
   Codex implementation gets one Claude independent code review per stage policy; no live provider/model in fixtures.

OWNER: no unresolved product decision blocks implementation. Automatic switching is excluded by the settled decision.
Every future proposed trial remains an owner decision: accept costs trial execution/review budget; decline costs
continued use of the incumbent. Retro must state those costs from observed data, never invent a monetary estimate.

## Appendix: three actual finished agents (read-only snapshot, 2026-11-26)

Paths below are relative to `/Users/ikozyrev/agent-hub/`. Each legacy projection has task_class=`unknown`,
class_source=`missing`, change_class=`unknown`, task_id=null (display key=stage/directory), accepted_status=null,
closed_at=null, exact ended_at=null, findings=null, first_run_ci=null, fix_rounds=null. No UUID, classification,
acceptance or first-CI success is invented. Journal completion times are minute-precision observations only.
Model/effort/start/session/runs come from each listed `meta.json`; result values cite exact `log.jsonl` lines.

| Field | Claude executor | Codex executor | Review |
|---|---|---|---|
| Agent directory | `dolya/agents/spec-17-8` | `dolya-finance-project-digital-twin/agents/twin-ets-live-acceptance-r811` | `core-d/agents/review-innova-tax-rate` |
| Engine; requested → resolved | claude; sonnet → claude-sonnet-5-5 | codex; gpt-6.1-sol → null | claude; opus → claude-opus-5-5 |
| Effort; kind (legacy inferred) | high; executor | medium; executor | medium; review |
| Started (+03:00) | 2026-11-25 18:05:55 | 2026-11-25 21:10:53 | 2026-11-26 09:02:59 |
| Session | 55a8ceb3-0873-4a51-90b2-6468b325410d | 01a213e7-464d-7cc1-b250-d7335f5d9f45 | 4a57137c-8397-4876-88e4-d454b3784463 |
| Runs; resumes | 2; 1 | 3; 2 | 1; 0 |
| Result lines; last result | 222,294; success | 123,292,377; turn.completed | 181; success |
| Turns (new unit) | 33+8=41 result turns | 3 turn starts | 30 result turns |
| Fresh input / cache-read / cache-create | 80 / 3,377,329 / 109,797 | input including cache=33,322,927; cached=32,940,672 | 62 / 2,982,021 / 135,901 |
| Output; normalized total tokens | 16,511; 3,503,717 | 99,466; 33,422,393 | 15,783; 3,133,767 |
| Reported USD | 0.9421909 (latest cumulative, not sum) | null | 1.9995202 |
| Observed completion / verdict | DONE 2026-11-25 18:53 / null | DONE 2026-11-26 09:27 / null | REVIEWED 2026-11-26 09:07 / APPROVE |

Completion sources: respectively `dolya/coordinator/work/journal-2026-11-25.md:99`,
`dolya-finance-project-digital-twin/coordinator/work/journal-2026-11-26.md:19`,
`core-d/coordinator/work/journal-2026-11-26.md:9`; verdict also in `core-d/coordinator/work/review-innova-tax-rate-REPORT.md:5`.
Claude executor usage is **62+18** fresh input across two result.usage blocks, while cost is **0.8150179→0.9421909**
cumulative. Its 39 unique streamed assistant IDs differ from 41 result turns: the unit must be stored, not guessed.
Codex result input grows **6,287,572→23,183,891→33,322,927**; use the last cumulative total, not their sum.
The initial probe's `core-d/innova-tax-rate` resumed again during design; it is deliberately not the finished Codex example.
