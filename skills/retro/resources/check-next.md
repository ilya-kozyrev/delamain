# CHECK-NEXT — follow-up to {{since}} / {{until}}

Home: `{{home}}`  
Baseline metrics directory: `{{out}}`  
Baseline metrics: `{{metrics}}`  
Previous checklist: `{{check_next}}`

Fill after the verified report. Save the finished checklist as `CHECK-NEXT.md` beside `metrics.json`.
For each accepted/proposed change keep one stable row id:

| Id | Change / release boundary | Metric | Baseline value and coverage | Detector / exact source | Pass if | Owner decision |
|---|---|---|---|---|---|---|
| <id> | <proposed/implemented/released, exact evidence> | <metric key or row set> | <value/null, denominator, window> | <rerunnable command and positive control> | <numeric threshold or measurable-only> | <ask id/status> |

Use per-day rates for unequal windows; percentages carry denominators. Unknown baselines stay unknown.
For each behavioral change include the targeted failure and a detector positive, and track rule-text/token cost
when applicable. Record rollout time so the next audit can split old/new behavior. A proposed fix has no release
boundary until a release is evidenced. Readiness to propose is separate from authorization to implement/release.
Done when every ranked change has a measurable follow-up row or a stated reason it cannot yet be measured.
