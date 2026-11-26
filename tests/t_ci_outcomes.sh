#!/bin/bash
# Exercise the real adapters and await completion with stand-in authenticated CLIs.
. "$(dirname "$0")/lib.sh"
set -e
new_home
export HUB_STAGE=ci HUB_TAG=executor
export CI_TEST_BIN="$B"
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

b = Path(os.environ["CI_TEST_BIN"])
sys.path.insert(0, str(b))
import ci_outcomes
import task_outcomes as task

stage = Path(os.environ["AGENT_HUB_HOME"]) / "ci"
stage.mkdir()
(stage / "roles.json").write_text("{}")
fake = stage / "fake"
fake.mkdir()
os.environ["PATH"] = f"{fake}:{os.environ['PATH']}"
os.environ["CI_FIXTURE"] = str(fake / "responses.json")
cli = '''#!/usr/bin/env python3
import json, os, sys
assert sys.argv[1:3] == ["api", "--hostname"]
responses = json.load(open(os.environ["CI_FIXTURE"]))
entry = responses.get(sys.argv[-1])
if entry is None:
    sys.exit(23)
print(json.dumps(entry))
'''
for cmd in ("gh", "glab"):
    path = fake / cmd
    path.write_text(cli)
    path.chmod(0o755)


def new_task():
    tid = str(uuid.uuid4())
    brief = fake / "brief.md"
    brief.write_text("fixture")
    task.start_task(stage, dict(task_id=tid, stage="ci", role="executor", task_class="bounded",
        task_kind="executor", change_class="code", assignment_source={}, engine="codex", model="sol", effort="medium",
        brief=str(brief), repository_key="/repo/.git", review_applicability="not_required", ci_applicability="required",
        usage_boundary="own_only", usage_in_parent="unknown"))
    return tid


def fixture(responses):
    (fake / "responses.json").write_text(json.dumps(responses))


def page(endpoint, number=1):
    return endpoint + ("&" if "?" in endpoint else "?") + f"per_page=100&page={number}"


def list_field(field, items, total=None):
    return {"total_count": len(items) if total is None else total, field: items}


created = "2026-11-01T00:00:00Z"
early = "2026-11-01T00:01:00Z"
pre_item = "2026-10-31T23:59:00Z"
committed = "2026-10-31T23:58:00Z"
later = "2026-11-02T00:00:00Z"
gh = "repos/example/project"
gh_url = "https://github.com/Example/Project/pull/7"
pull = dict(created_at=created, commits=2, base=dict(ref="main"),
            head=dict(sha="new", ref="change", repo=dict(full_name="example/project")))


def run(rid, suite, sha, at, attempt=1, event="pull_request", workflow=1, linked=True, conclusion=None):
    return dict(id=rid, head_sha=sha, head_branch="change", head_repository={"full_name": "example/project"},
                created_at=at, run_attempt=attempt, check_suite_id=suite, workflow_id=workflow, event=event,
                conclusion=conclusion, pull_requests=[dict(number=7, head=dict(sha="new"))] if linked else [])


def gh_job(id_, name, state):
    return dict(id=id_, name=name, status="completed" if state else "in_progress", conclusion=state)


def check(id_, name, suite, app=6):
    return dict(id=id_, name=name, check_suite=dict(id=suite), app=dict(id=app))


runs_endpoint = f"{gh}/actions/runs?branch=change&created=%3E%3D2026-10-31T23%3A58%3A00%2B00%3A00"
scheduled = [run(100 + i, 999, "old", early, event="schedule") for i in range(99)]
github = {
    f"{gh}/pulls/7": pull,
    page(f"{gh}/issues/7/timeline"): [],
    page(f"{gh}/pulls/7/commits"): [{"sha": "old", "commit": {"committer": {"date": committed}}}, {"sha": "new"}],
    f"{gh}/branches/main": {"protected": True, "protection": {
        "required_status_checks": {"checks": [{"context": n, "app_id": 6} for n in ("build", "lint")]}}},
    page(f"{gh}/rules/branches/main"): [],
    page(runs_endpoint): list_field("workflow_runs", scheduled + [run(3, 13, "new", later)], 102),
    page(runs_endpoint, 2): list_field("workflow_runs", [run(1, 11, "old", early, 2), run(2, 12, "old", early, workflow=2)], 102),
    page(f"{gh}/actions/runs/1/attempts/1/jobs"): list_field("jobs", [gh_job(21, "build", "failure")]),
    page(f"{gh}/actions/runs/2/attempts/1/jobs"): list_field("jobs", [gh_job(22, "lint", "success")]),
    page(f"{gh}/commits/old/check-runs?filter=all"): list_field("check_runs",
        [check(30, "build", 11), check(31, "build", 11), check(32, "lint", 12)]),
    page(f"{gh}/commits/old/statuses"): [],
}
tid = new_task()
fixture(github)
failed = ci_outcomes.observe(stage, tid, gh_url)
assert failed["first_run_green"] is False and failed["first_head"] == "old", failed
assert failed["required_checks_source"] == "policy"
assert [(r["id"], r["latest_attempt"]) for r in failed["history"]] == [(1, 2), (2, 1), (3, 1)]
assert {job["name"] for job in failed["jobs"] if job["required"]} == {"build", "lint"}
ci_outcomes.observe(stage, tid, gh_url.rstrip("/") + "/")
assert len(task.read(task.path(stage, tid))[0]) == 2
print("GitHub late wait, two pages and two workflows: original failed required build remains false after retry")

pending = github.copy()
pending[page(runs_endpoint, 2)] = list_field("workflow_runs", [run(1, 11, "old", early), run(2, 12, "old", early, workflow=2)], 102)
pending[page(f"{gh}/actions/runs/1/attempts/1/jobs")] = list_field("jobs", [gh_job(21, "build", None)])
tid = new_task()
fixture(pending)
v1 = ci_outcomes.observe(stage, tid, gh_url)
assert v1["first_run_green"] is None and v1["history_coverage"] == "complete"
green = pending.copy()
green[page(f"{gh}/actions/runs/1/attempts/1/jobs")] = list_field("jobs", [gh_job(21, "build", "success")])
fixture(green)
v2 = ci_outcomes.observe(stage, tid, gh_url)
ci_outcomes.observe(stage, tid, gh_url)
assert v1["attempt_id"] == v2["attempt_id"] and v2["first_run_green"] is True
assert len(task.read(task.path(stage, tid))[0]) == 3
print("GitHub pending → green: two states, one attempt, repeated state idempotent")

for label, endpoint, data in [
    ("short page", page(runs_endpoint, 2), list_field("workflow_runs", [run(2, 12, "old", early, workflow=2)], 102)),
    ("missing first attempt", page(f"{gh}/actions/runs/1/attempts/1/jobs"), list_field("jobs", [])),
    ("missing protection metadata", f"{gh}/branches/main", {"protected": True}),
    ("force push", page(f"{gh}/issues/7/timeline"), [{"id": 4, "event": "head_ref_force_pushed"}]),
]:
    fixture(github | {endpoint: data})
    observed = ci_outcomes.observe(stage, new_task(), gh_url)
    assert observed["first_run_green"] is None and observed["history_coverage"] == "incomplete", (label, observed)
print("GitHub gaps: short page, lost retry, missing policy and rewritten head stay unknown")

# M2/H1/L2: no admin endpoint, actual PR linkage before and after merge, and safe inference.
inferred = github | {f"{gh}/branches/main": {"protected": False}}
inferred[page(runs_endpoint, 2)] = list_field("workflow_runs", [
    run(1, 11, "old", early, 2, linked=False), run(2, 12, "old", early, workflow=2, linked=False)], 102)
inferred[page(f"{gh}/actions/runs/2/attempts/1/jobs")] = list_field("jobs", [gh_job(22, "lint", "skipped")])
fixture(inferred)
post_merge = ci_outcomes.observe(stage, new_task(), gh_url)
assert post_merge["first_run_green"] is False and post_merge["first_head"] == "old", post_merge
assert post_merge["required_checks_source"] == "inferred" and [j["name"] for j in post_merge["required_checks"]] == ["build"]

# M3: pre-item initial push counts if it ran a workflow used by the PR. A different pre-item SHA does not.
pre = inferred | {page(runs_endpoint): list_field("workflow_runs", [
    run(1, 11, "old", pre_item, event="push", linked=False), run(3, 13, "new", later),
    run(5, 15, "new", pre_item, event="push", linked=False, workflow=3)])}
fixture(pre)
observed = ci_outcomes.observe(stage, new_task(), gh_url)
assert observed["first_run_green"] is False and observed["attempt_created_at"] == pre_item, observed
assert [r["id"] for r in observed["history"]] == [1, 3]

gh_cancel = pre | {
    page(runs_endpoint): list_field("workflow_runs", [
        run(1, 11, "old", early, conclusion="cancelled"), run(3, 13, "new", later)]),
    page(f"{gh}/actions/runs/1/attempts/1/jobs"): list_field("jobs", [gh_job(21, "build", "cancelled")]),
    page(f"{gh}/actions/runs/3/attempts/1/jobs"): list_field("jobs", [gh_job(23, "build", "success")]),
    page(f"{gh}/commits/new/check-runs?filter=all"): list_field("check_runs", [check(23, "build", 13)]),
}
annotations = page(f"{gh}/check-runs/21/annotations")
fixture(gh_cancel | {annotations: [{"message": "Canceling since a higher priority waiting request for CI exists"}]})
replaced = ci_outcomes.observe(stage, new_task(), gh_url)
assert replaced["first_run_green"] is True and replaced["first_head"] == "new", replaced
assert replaced["superseded_attempts"] == ["github:old:1"]
fixture(gh_cancel | {annotations: [{"message": "The workflow was canceled by a user."}]})
manual = ci_outcomes.observe(stage, new_task(), gh_url)
assert manual["first_run_green"] is None and manual["attempt_id"] == "github:old:1" and not manual["superseded_attempts"]
print("GitHub controls: merged PR linkage, inferred check set, initial push and superseded/manual cancellation")

gl_url = "https://gitlab.example.com/group/sub/project/-/merge_requests/4"
gl = "projects/group%2Fsub%2Fproject"
mr = f"{gl}/merge_requests/4"
pipe = f"{gl}/pipelines"
pipes = {1: dict(id=1, sha="old", ref="branch", source="push", status="success", created_at=pre_item),
         2: dict(id=2, sha="new", ref="refs/merge-requests/4/head", source="merge_request_event", status="success", created_at=later),
         3: dict(id=3, sha="old", ref="branch", source="web", status="success", created_at=created)}


def gl_job(id_, name, status, optional=False):
    return dict(id=id_, name=name, stage="test", status=status, created_at=early, allow_failure=optional)


retry = gl_job(4, "tests", "success")
first = gl_job(2, "tests", "failed")
optional = gl_job(3, "optional", "failed", True)
gitlab = {
    mr: dict(created_at=created, sha="new", source_project_id=5, target_project_id=5, source_branch="branch"),
    gl: {"only_allow_merge_if_pipeline_succeeds": True},
    page(f"{mr}/versions"): [{"id": 1, "head_commit_sha": "old"}, {"id": 2, "head_commit_sha": "new"}],
    page(f"{mr}/pipelines"): [pipes[2], pipes[3]],
    f"{gl}/repository/commits/old": {"committed_date": committed},
    page(f"{pipe}?ref=branch&source=push&created_after=2026-10-31T23%3A57%3A59%2B00%3A00"): [pipes[1]],
    f"{pipe}/1": pipes[1],
    page(f"{pipe}/1/bridges"): [],
    page(f"{pipe}/1/jobs?include_retried=true"): [retry, optional, first],
    page(f"{pipe}/1/jobs"): [retry, optional],
}
fixture(gitlab)
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is False and observed["first_head"] == "old", observed
assert observed["attempt_created_at"] == pre_item and observed["required_checks_source"] == "policy"
assert [p["id"] for p in observed["history"]] == [1, 2]
print("GitLab late wait: first push pipeline's failed job remains false after a green retry; web pipeline ignored")

successful_first = gl_job(2, "tests", "success")
fixture(gitlab | {page(f"{pipe}/1/jobs?include_retried=true"): [optional, successful_first],
                  page(f"{pipe}/1/jobs"): [optional, successful_first]})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is True, observed
fixture(gitlab | {page(f"{pipe}/1/jobs?include_retried=true"): [first, optional]})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is None and observed["history_coverage"] == "incomplete", observed
fixture(gitlab | {page(f"{pipe}/1/jobs?include_retried=true"): [optional, gl_job(4, "tests", "skipped")]})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is None, observed
print("GitLab controls: optional failure can pass; missing/current mismatch or skipped required job stays unknown")

# L3: later rows have no detail fixture. A changed selected row is still an evidence gap.
fixture(gitlab | {f"{pipe}/1": pipes[1] | {"sha": "unexpected"}})
assert ci_outcomes.observe(stage, new_task(), gl_url)["history_coverage"] == "incomplete"
gl_inferred = gitlab | {gl: {"only_allow_merge_if_pipeline_succeeds": False}}
manual_job = gl_job(5, "deploy", "manual")
inferred_jobs = [optional, successful_first, manual_job]
fixture(gl_inferred | {page(f"{pipe}/1/jobs?include_retried=true"): inferred_jobs,
                       page(f"{pipe}/1/jobs"): inferred_jobs})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is True and observed["required_checks_source"] == "inferred", observed
assert [j["name"] for j in observed["required_checks"]] == ["tests"]
push_page = page(f"{pipe}?ref=branch&source=push&created_after=2026-10-31T23%3A57%3A59%2B00%3A00")
cancel = pipes[1] | {"status": "canceled"}
gl_cancel = gl_inferred | {push_page: [cancel], f"{pipe}/1": cancel, f"{pipe}/2": pipes[2],
    page(f"{pipe}/2/bridges"): [], page(f"{pipe}/2/jobs?include_retried=true"): [successful_first],
    page(f"{pipe}/2/jobs"): [successful_first]}
fixture(gl_cancel | {f"{pipe}/1": cancel | {"detailed_status": {
    "tooltip": "Pipeline is redundant and is auto-canceled by Pipeline #2"}}})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is True and observed["superseded_attempts"] == ["gitlab:1:1"], observed
fixture(gl_cancel)
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is None and observed["attempt_id"] == "gitlab:1:1" and not observed["superseded_attempts"]
print("GitLab controls: selected detail only, inferred blocking jobs, superseded and unverified cancellations")

tid = new_task()
fixture(github)
args = [str(b / "await"), "--wait", "--ok", "PASSED", "--outcome-task", tid, "--ci-item", gh_url, "--"]
green_wait = subprocess.run(args + ["true"], capture_output=True, text=True)
assert green_wait.returncode == 0 and "PASSED" in green_wait.stdout, green_wait
red_wait = subprocess.run(args + ["false"], capture_output=True, text=True)
assert red_wait.returncode == 3 and "FAILED" in red_wait.stdout, red_wait
events, _ = task.read(task.path(stage, tid))
assert len(events) == 2 and events[-1]["data"]["first_run_green"] is False
bad = subprocess.run(args[:-3] + ["--", "true"], capture_output=True, text=True)
assert bad.returncode == 2, bad
unsupported = new_task()
unknown_args = [str(b / "await"), "--wait", "--outcome-task", unsupported, "--ci-item",
                "https://other.example/x?token=fixture-value", "--", "true"]
assert subprocess.run(unknown_args, capture_output=True).returncode == 0
events, _ = task.read(task.path(stage, unsupported))
assert events[-1]["data"]["first_run_green"] is None and events[-1]["data"]["coverage_reason"]
assert events[-1]["data"]["item"].startswith("unverified:")
assert "fixture-value" not in task.path(stage, unsupported).read_text()
print("await records unknown evidence for invalid bindings without storing URL credentials or changing the wait exit")
# L1: the attached verdict is already available inside a failing telemetry call.
import contextlib
import importlib.machinery
import importlib.util
import io
from types import SimpleNamespace

loader = importlib.machinery.SourceFileLoader("await_test", str(b / "await"))
spec = importlib.util.spec_from_loader(loader.name, loader)
waiter = importlib.util.module_from_spec(spec)
loader.exec_module(waiter)
original = ci_outcomes.observe
for command, expected_rc, verdict in (("true", 0, "PASSED"), ("false", 3, "FAILED")):
    args = SimpleNamespace(timeout="15s", ok="PASSED", label="control", link=None, to="hub",
                           outcome_task=tid, ci_item=gh_url)
    stdout = io.StringIO()
    invoked = []
    def broken(*_):
        invoked.append(stdout.getvalue())
        raise RuntimeError("telemetry control")
    ci_outcomes.observe = broken
    log = fake / f"await-{command}.log"
    with contextlib.redirect_stdout(stdout):
        assert waiter.supervise(args, [command], log, "ci", "control-await", {}) == expected_rc
    assert len(invoked) == 1 and verdict in invoked[0] and stdout.getvalue().count(verdict) == 1
    assert "CI evidence could not be recorded: RuntimeError" in log.read_text()
ci_outcomes.observe = original

for relative, expected in (
    ("skills/hub/SKILL.md", 1),
    ("skills/hub/references/launch-and-executors.md", 2),
):
    text = (b.parent / relative).read_text()
    examples = [line for line in text.splitlines() if "`await " in line and "--ok PASSED" in line]
    assert len(examples) == expected and all("--outcome-task " in x and "--ci-item " in x for x in examples), examples
    assert "AGENT_TASK_ID" in text and "meta.json" in text
print("L1/M4: telemetry failure preserves the printed verdict and wait exit; CI recipes bind both arguments")

PY
