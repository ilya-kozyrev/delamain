#!/bin/bash
# Compare matched task contracts, retain cutoff evidence and reject biased cohorts.
. "$(dirname "$0")/lib.sh"
set -e
new_home
export RETRO_OUTCOME_BIN="$B"
export RETRO_OUTCOME_OUT="${RETRO_OUTCOME_OUT:-$(mktemp -d)}"
python3 - <<'PY'
import csv
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

b = Path(os.environ["RETRO_OUTCOME_BIN"])
out = Path(os.environ["RETRO_OUTCOME_OUT"])
out.mkdir(parents=True, exist_ok=True)
home = Path(os.environ["AGENT_HUB_HOME"])
sys.path.insert(0, str(b))
import task_outcomes as task

BASE = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)

def time(day):
    return (BASE + dt.timedelta(days=day)).isoformat()

def put(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj))

def emit(stage, tid, kind, data, day, run=None, name=None, recorded=None, source="fixture", **extra):
    event = task.event(tid, run, kind, data, source, event_id=name, **extra)
    event.update(occurred_at=time(day), recorded_at=time(day if recorded is None else recorded))
    task.append(stage, event)
    return event["event_id"]

def id_for(name, domain="fixture"):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{domain}/{name}"))

def start(stage, name, model="old", day=0, parent=None, continuation=None, engine="claude",
          task_kind="executor", target=None, usage_boundary="own_only", usage_in_parent="unknown"):
    tid = id_for(name, stage.name)
    emit(stage, tid, "task_started", dict(task_class="bounded", task_kind=task_kind, change_class="code",
        assignment_source=dict(task_class="explicit", task_kind="explicit", change_class="explicit"),
        stage=stage.name, role=name, brief_path="fixture.md", brief_sha256="hash", continuation_of=continuation,
        review_target_task_id=target, engine=engine, requested_model=model, effort="high", repository_key="/fixture/.git",
        review_applicability="required", ci_applicability="required", parent_task_id=parent,
        usage_boundary=usage_boundary, usage_in_parent=usage_in_parent), day, name=f"{tid}:start")
    return tid

def launch(stage, tid, model, day, tag="1", engine="claude", effort="high", end="DONE", tokens=100, cost=1):
    rid = f"{tid}:{tag}"
    emit(stage, tid, "run_started", dict(session_id=tid, kind="spawn" if tag == "1" else "resume",
        engine=engine, requested_model=model, effort=effort, log_offset=0,
        resume_reason=None if tag == "1" else "review_fix"), day, rid)
    emit(stage, tid, "run_identity", dict(session_id=tid, resolved_model=model), day, rid)
    if end:
        unit = "claude_result_turns" if engine == "claude" else "codex_turn_started"
        cost_basis = "reported_claude_usd_delta" if engine == "claude" else "unavailable"
        emit(stage, tid, "run_ended", dict(ended_at=time(day + .25), exit_code=0, cli_result="success",
             termination_reason="exit", reported_status=end, complete=True,
             usage=dict(complete=tokens is not None, tokens_total=tokens, turns=5, turn_unit=unit,
                        cost_usd=cost if engine == "claude" else None, cost_basis=cost_basis)), day + .25, rid)
    return rid

def review(stage, tid, day=1, high=0, round_=1, count=1, adjudication=None, primary=True):
    findings = dict(high=high, medium=count-high, low=0)
    ids = [dict(id=f"R{i}", severity="high" if i<high else "medium") for i in range(count)]
    return emit(stage, tid, "review_observed", dict(reviewer_task_id=id_for("reviewer" if primary else "second-reviewer"), reviewer_run_id=f"round-{round_}",
        target_task_id=tid, head="old-head" if round_ == 1 else "new-head", round=round_,
        verdict="fixes", findings=findings, finding_ids=ids, diagnostics=[], adjudication=adjudication, primary=primary),
        day, run=None)

def ci(stage, tid, value=True, day=1, attempt="a", created=.5, artifact=None):
    artifact = artifact or f"https://github.com/example/fixture/pull/{int(uuid.UUID(tid))}"
    return emit(stage, tid, "ci_observed", dict(target_task_id=tid, repository="https://github.com/example/fixture",
        item=artifact, head=attempt, first_head=attempt, status="success" if value else "failure",
        history_coverage="complete", first_run_green=value, attempt_id=attempt, attempt_created_at=time(created),
        required_checks=["build"], history=[attempt]), day)

incumbents = out / "current-assignments.csv"
incumbents.write_text("repository_key,task_class,change_class,engine,model,effort\n/fixture/.git,bounded,code,claude,old,high\n")

def run(label, since=0, until=10, baseline=None, declare=True):
    dest = out / label
    cmd = [str(b / "retro"), "measure", "--out", str(dest), "--since", time(since), "--until", time(until)]
    if declare:
        cmd.extend(["--incumbents", str(incumbents)])
    if baseline:
        cmd.extend(["--baseline", str(baseline)])
    result = subprocess.run(cmd, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return dest, json.loads((dest / "metrics.json").read_text())

def table(dest, basename):
    with (dest / f"{basename}.csv").open() as file:
        return list(csv.DictReader(file))

def reset(label):
    for old in home.glob("*/roles.json"):
        old.unlink()
        old.parent.rename(home.parent / f"{home.name}-{old.parent.name}")
    stage = home / label
    put(stage / "roles.json", {})
    return stage

def cohort(label, new_n=5, missing=False, mixed=False, pending=False, uninitialized=False,
           high=False, ci_false=False, equal_tokens=False):
    stage = reset(label)
    ids = {}
    for model, n in (("old", 5), ("new", new_n)):
        for i in range(n):
            tid = start(stage, f"{model}-{i}", model)
            rid = launch(stage, tid, model, .1, tokens=100 if model=="old" or equal_tokens else 75,
                         cost=1 if model=="old" else 1.5)
            ids[(model, i)] = (tid, rid)
            if model == "new":
                review(stage, tid, day=.8, high=2, count=2, primary=False)
            review(stage, tid, high=int(high and model == "new" and i == 0))
            # First-primary counts are stable across rechecks, even if the recheck has new IDs.
            review(stage, tid, day=2, round_=2, count=3 if model == "new" else 5)
            if not (missing and model == "new" and i == 0):
                ci(stage, tid, value=not (ci_false and model == "new" and i == 0))
    if mixed:
        root = ids[("new", 0)][0]
        continued = start(stage, "continued", "old", day=2, continuation=root)
        launch(stage, continued, "old", 2, tokens=80)
    if pending:
        tid = start(stage, "new-blocked", "new")
        launch(stage, tid, "new", 0, end="BLOCKED", tokens=None)
    if uninitialized:
        start(stage, "new-no-init", "new")
    return stage, ids

stage, ids = cohort("positive")
# Explicit adjudication stays separate; absent adjudication for everyone else does not block.
tid = ids[("old", 0)][0]
codex = start(stage, "codex", "sol", engine="codex", day=1)
launch(stage, codex, "sol", 1, engine="codex", tokens=180)
launch(stage, codex, "sol", 2, tag="2", engine="codex", tokens=90)
for role in ("codex", "codex.archived"):
    put(stage / "agents" / role / "meta.json", dict(role="codex", task_id=codex, started_at=time(1), engine="codex",
                                                    session_id=codex))
put(stage / "agents/legacy/meta.json", dict(role="legacy", started_at=time(1), engine="claude", model="sonnet"))
# An unmatched external review stays descriptive and doesn't attach to an executor.
external = start(stage, "external-review", "opus", task_kind="review")
launch(stage, external, "opus", 1)
emit(stage, external, "review_observed", dict(reviewer_task_id=external, reviewer_run_id="round-1",
    target_task_id=None, head="head", round=1, verdict="approve", findings=dict(high=0, medium=0, low=0),
    finding_ids=[], diagnostics=[], adjudication={}), 1)
# An old schema remains a valid baseline for the existing metrics.
old = out / "old-base"
put(old / "metrics.json", dict(schema_version=1, window={}, metrics={"agents.count": dict(kind="total", value=13, per_day=2)}))
dest, metrics = run("sourced", baseline=old)
items = metrics["model_outcomes"]
assert len(items["proposals"]) == 1, items
p = items["proposals"][0]
assert p["token_change"] == -.25 and p["cost_change"] == .5 and p["conflict"], p
assert all(c["full"]["mean_reported_findings"] == 1 for c in items["assigned"] if c["engine"] == "claude")
assert metrics["metrics"]["agents.count"]["baseline"] == 13 and "baseline_common_cutoff" not in items
rows = {r["id"]:r for r in table(dest, "task-outcomes")}
assert rows[codex]["run_count"] == "2" and rows[codex]["tokens"] == "270" and rows[codex]["turns"] == "10"
assert rows[codex]["cost_usd"] == "" and rows[codex]["turn_unit"] == "codex_turn_started"
assert rows[tid]["tokens"] == "100" and rows[tid]["turn_unit"] == "claude_result_turns"
assert sum(r["task_id"] == codex for r in rows.values()) == 1
assert rows[external]["reported_findings"] == "0"
legacy = rows[f"{stage.name}/legacy"]
assert legacy["task_class"] == "unknown" and not legacy["task_id"] and not legacy["closure"] and not legacy["first_run_ci"]
text = (dest / "measure.md").read_text()
assert p["incumbent"] in text and p["candidate"] in text and tid in text and "Consider a bounded trial" in text
print("Retro positive: five versus five, −25% tokens with +50% reported cost, one sourced owner choice")

# Event occurrence precedes the cutoff, recording does not. Both replay and fresh cutoff reads agree.
before = (dest / "outcome-inputs.json").read_bytes(), (dest / "task-outcomes.csv").read_bytes()
event = emit(stage, tid, "task_closed", dict(outcome="cancelled", closed_at=time(2), evidence_path="override",
        artifact_ids=[], review_applicability="required", ci_applicability="required"), 2,
        run=ids[("old", 0)][1], recorded=11, source="hub")
run("sourced", baseline=old)
assert before == ((dest / "outcome-inputs.json").read_bytes(), (dest / "task-outcomes.csv").read_bytes())
fresh, _ = run("same-cutoff", baseline=old)
assert next(r for r in table(fresh, "task-outcomes") if r["id"] == tid)["closure"] == "success"
later, common = run("common-cutoff", since=10, until=20, baseline=dest)
assert common["model_outcomes"]["baseline_common_cutoff"]["overlap"] == []
print("Retro cutoff replay ignores a backdated late override and recomputes baseline IDs at a common cutoff")

for label, kwargs in (
    ("four", dict(new_n=4)), ("missing-quality", dict(missing=True)),
    ("mixed-model", dict(mixed=True)), ("open-assignment", dict(pending=True)),
    ("uninitialized-assignment", dict(uninitialized=True)),
    ("higher-high-findings", dict(high=True)), ("worse-first-ci", dict(ci_false=True)),
    ("less-than-20-percent", dict(equal_tokens=True)),
):
    stage, ids = cohort(label, **kwargs)
    dest, metrics = run(label, baseline=old)
    assert not metrics["model_outcomes"]["proposals"], label
    assert "Insufficient evidence (n/coverage)" in (dest / "measure.md").read_text()
    if label == "mixed-model":
        tid = ids[("new", 0)][0]
        row = next(r for r in table(dest, "task-outcomes") if r["id"] == tid)
        assert row["mixed"] == "True" and row["tokens"] == "155" and row["run_count"] == "2"
        assigned = next(r for r in metrics["model_outcomes"]["assigned"] if r["model"] == "new")
        assert assigned["full"]["handoffs"] == 1 and assigned["full"]["n"] == 5 and assigned["direct"]["n"] == 4
    if label == "open-assignment":
        assigned = next(r for r in metrics["model_outcomes"]["assigned"] if r["model"] == "new")
        assert assigned["full"]["pending"] == 1 and assigned["full"]["success_bounds"] == [5 / 6, 1]
    if label == "uninitialized-assignment":
        assigned = next(r for r in metrics["model_outcomes"]["assigned"] if r["model"] == "requested:new")
        assert assigned["full"]["pending"] == 1 and assigned["unresolved_in_stratum"] == 1
print("Retro negative: four samples, missing CI, mixed handoff, open or unresolved assignments, worse quality and small savings give no trial")

stage, ids = cohort("artifacts")
tid = ids[("new", 0)][0]
first_item = f"https://github.com/example/fixture/pull/{int(uuid.UUID(tid))}"
second_item = "https://github.com/example/fixture/pull/9998"
third_item = "https://github.com/example/fixture/pull/9999"
emit(stage, tid, "artifact_observed", dict(target_task_id=tid, artifact_ids=[first_item, second_item, third_item],
    review_applicability="required", ci_applicability="required"), 2)
ci(stage, tid, False, day=2, artifact=second_item)
ci(stage, tid, True, day=3, artifact=second_item)
ci(stage, tid, True, day=4, attempt="later-head", created=3, artifact=second_item)
dest, metrics = run("multiple-artifacts", baseline=old)
row = next(r for r in table(dest, "task-outcomes") if r["id"] == tid)
assert row["first_run_ci"] == "False" and row["reported_findings"] == ""
assert not metrics["model_outcomes"]["proposals"]
print("Retro multi-artifact CI: known early failure dominates a green retry, a later head and a missing artifact")

emit(stage, tid, "artifact_observed", dict(target_task_id=tid, artifact_ids=[second_item, third_item],
    review_applicability="not_required", ci_applicability="not_required"), 5)
dest, metrics = run("exempt-artifacts", baseline=old)
row = next(r for r in table(dest, "task-outcomes") if r["id"] == tid)
assert row["ci_applicability"] == "required" and row["first_run_ci"] == "True"
assert row["review_applicability"] == "required" and row["reported_findings"] == "1"
assert len(metrics["model_outcomes"]["proposals"]) == 1
print("Retro multi-artifact CI: explicit exemptions leave applicable first-run CI and review evidence intact")
PY
