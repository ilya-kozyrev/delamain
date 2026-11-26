# Retro — independent verification

Read `{{out}}/brief-common.md`. Window `[{{since}}, {{until}})`; baseline `{{baseline}}`; metrics `{{metrics}}`.
Stages:
{{stages}}

Ownership: `{{out}}/verification-REPORT.md`. Read-only review; selected available independent reviewer at
high effort, different model from the measurement code author. Follow the hub's cross-engine review policy.

1. Inspect the measurement implementation and saved inputs. Check half-open timestamps/timezone, window
   duration/per-day denominator, baseline selection, duplicate transcripts, stage/agent/MR joins, source
   coverage, missing-cost handling, percentile method and review/CI completeness. Check frozen task event
   visibility, root ID deduplication and pickup of original-assignment handoffs. Reproduce any proposed model
   trial from its source rows, equal observation windows, reported findings and first-run CI. No forge network calls.
2. Check every material report finding against its actual source and applicable historical rule. Recalculate
   key A–D scorecard and cost/latency numbers from raw rows. Null is unknown; journal merge counts are lower
   bounds without complete exports. Check classification ids, supported taxonomy and evidence acceptance.
3. Verify detector positives for each claimed zero, including owner-message exclusions and recurring lessons.
   Audit lessons promotion/verdict timing rather than current status alone. Separate observational cost/time
   evidence from causal savings claims. Check previous CHECK-NEXT rows against their original pass criteria.
4. Return severity, affected metric/finding, evidence, impact and concrete correction; distinguish verified,
   rejected and unresolved claims. Verify quantitative sections: agents by engine/model/effort; hub turns,
   cache/context/compactions and no-tool wakes; cost/day and cost share; friction; status→reaction latency
   median/p90 and worst ten. Missing coverage remains an explicit limitation.

Done when all material findings/scorecard entries have a verdict and remaining risks are listed. Stop after
100 tool calls, save partial review and unverified items. Corrections belong to the executor/hub, not reviewer.
