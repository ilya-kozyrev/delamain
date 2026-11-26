---
name: retro
description: Audit a period of hub work for recurring mistakes, token cost, delivery efficiency and lessons; compare it with the previous retro and propose evidenced plugin improvements. Use for retro, ретро, ретроспектива, аудит недели, a hub retrospective or weekly audit, not live agent status.
argument-hint: "[--since T] [--until T] [--readers N]"
---

# Hub retrospective

Produce a reproducible period comparison and ranked plugin fixes. The audit reads any resolved hub home;
its workers write only the chosen output directory. Installed resources live beside this skill in `resources/`.

1. **Register the audit.** Load `delamain:hub`; start a stage or take over its existing shift, check recorded
   decisions and agree the report's Business DoD. Preserve the selected worker engine. Done when the stage,
   window and authorization are recorded; audit permission covers reading, not changing audited stages.
2. **Plan.** Run `<plugin-root>/bin/retro plan --out <stage>/coordinator/work/retro-<date>` with the requested
   `--since`, `--until` and `--readers`. Read its `window.json` and generated `brief-common.md`. It fixes the
   resolved home, half-open window, baseline, checklist and stage assignments. Inspect CLI `--help` for exact
   options. Done when those inputs match the request and every discovered stage has a reader assignment.
3. **Measure before judgement.** Run `retro measure --out <out>` (through an executor under the hub rules).
   Supply `--baseline <previous-out>` to override discovery; `--forge <local-export-dir>` adds existing forge
   snapshots without network access. Read `measure.md`, `metrics.json` and coverage limits before spawning
   interpretation. Read `model-outcomes.csv` with `task-outcomes.csv` and the frozen evidence manifest.
   Completion cohorts are snapshots. Compare unique root IDs at a common cutoff, keep native turn units and
   reported Claude USD, and separate missing quality from explicitly N/A. First CI measures the first eligible
   attempt per artifact. First-time-right also includes review rounds. Done when files exist, source gaps are
   named and null values stay unknown.

   If the owner-approved incumbent assignments are available, pass `--incumbents FILE` on the first measurement.
   Use the CSV headers and resolved identities documented in the command reference. Read the original-assignment
   follow-up, handoffs, pending counts, coverage and sensitivity in `model-assignments.csv`. A candidate needs
   a handoff share no higher than the incumbent's and the 20% resource saving in both medians and the
   full-cohort mean. Observed tokens remain descriptive when the accounting boundary is unknown. The proposal gate
   uses first primary reported findings, with optional accepted findings displayed separately.
4. **Read and interpret in parallel.** Launch each generated `reader-NN.md` on Haiku high for mechanical
   evidence extraction; launch `brief-lessons.md` and `brief-classify.md` on Sonnet high or Opus medium for
   judgement. Use `agent spawn` under the hub launch protocol, not native forks in a registered hub. Check the
   selected standalone CLI's model catalog and quota first. For Codex, choose available equivalents explicitly:
   Luna for extraction, Terra/Sol for bounded interpretation; use the current engine policy if these are absent.
   Keep model and effort in each brief. A past audit observed roughly 16 minutes with Haiku readers and Sonnet
   quantitative work; this is an observation, not a runtime or savings promise. The bundled measurement is now
   deterministic. Done when each worker returns its report or a bounded coverage gap.
5. **Apply classifications.** Review the classifier's evidence, then rerun `retro measure --out <out>
   --classifications <out>/classifications` with the same baseline/forge inputs. Unreviewed or unsupported
   judgements remain `needs_review`; unknown forge fields remain null. Done when every accepted class has
   evidence and the measured tables can be reproduced from the saved inputs.
6. **Verify independently.** Launch generated `brief-verify.md` on Opus high, different from the code author;
   for a Claude author use the current cross-engine reviewer policy, and for a Codex author prefer Claude
   Opus/Fable when available, otherwise an available Astra high. Check availability/quota before launch and
   record the choice. Verification is read-only. Done when every material finding is verified, corrected or
   explicitly unresolved; stop at the brief's call budget and retain blockers.
7. **Report.** Fill generated `report.md` using verified evidence and measured numbers. Follow its section
   contract; report in the owner's language. Distinguish plugin defects from stage choices and observational
   associations from measured effects. Done when every recommendation names evidence, expected effect,
   implementation cost and uncertainty, and the scorecard covers A–D plus quantitative sections.
8. **Close the loop.** Fill generated `check-next.md` with baseline, detector and pass criterion for each
   proposed fix; publish it as `CHECK-NEXT.md` beside the report. Present owner decisions via `ask add`, each
   with A/B options, a recommendation and a default under the existing question protocol. Forward each eligible
   model trial with its sourced row and sample IDs, both resource deltas, coverage and uncertainty. Offer a bounded
   trial or continuation of the incumbent. Keep insufficient-evidence cells descriptive. Implementation,
   merging and release follow their own authorization. Done when the report, checklist and question ids are
   linked in the final audit status; do not implement proposed fixes as part of the audit.

Read [command semantics](../../docs/reference.md#retro-period-audit) when selecting timestamps, baselines,
classifications or local forge exports. The templates are contracts: keep read-only boundaries, evidence and
stop criteria when filling them. No hooks, schedules or configuration are enabled by this skill.
