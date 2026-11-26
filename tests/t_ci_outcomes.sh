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
later = "2026-11-02T00:00:00Z"
gh = "repos/example/project"
gh_url = "https://github.com/Example/Project/pull/7"
pull = dict(created_at=created, commits=2, base=dict(ref="main"),
            head=dict(sha="new", ref="change", repo=dict(full_name="example/project")))


def run(rid, suite, sha, at, attempt=1, event="pull_request"):
    return dict(id=rid, head_sha=sha, created_at=at, run_attempt=attempt, check_suite_id=suite,
                event=event, pull_requests=[dict(number=7, head=dict(sha=sha))])


def gh_job(id_, name, state):
    return dict(id=id_, name=name, status="completed" if state else "in_progress", conclusion=state)


def check(id_, name, suite, app=6):
    return dict(id=id_, name=name, check_suite=dict(id=suite), app=dict(id=app))


runs_endpoint = f"{gh}/actions/runs?branch=change&created=%3E%3D2026-11-01T00%3A00%3A00Z"
scheduled = [run(100 + i, 999, "old", early, event="schedule") for i in range(99)]
github = {
    f"{gh}/pulls/7": pull,
    page(f"{gh}/issues/7/timeline"): [],
    page(f"{gh}/pulls/7/commits"): [{"sha": "old"}, {"sha": "new"}],
    f"{gh}/branches/main": {"protected": True},
    page(f"{gh}/rules/branches/main"): [],
    f"{gh}/branches/main/protection": {
        "required_status_checks": {"checks": [{"context": n, "app_id": 6} for n in ("build", "lint")]}},
    page(runs_endpoint): list_field("workflow_runs", scheduled + [run(3, 13, "new", later)], 102),
    page(runs_endpoint, 2): list_field("workflow_runs", [run(1, 11, "old", early, 2), run(2, 12, "old", early)], 102),
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
assert [(r["id"], r["latest_attempt"]) for r in failed["history"]] == [(1, 2), (2, 1), (3, 1)]
assert {job["name"] for job in failed["jobs"] if job["required"]} == {"build", "lint"}
ci_outcomes.observe(stage, tid, gh_url.rstrip("/") + "/")
assert len(task.read(task.path(stage, tid))[0]) == 2
print("GitHub late wait, two pages and two workflows: original failed required build remains false after retry")

pending = github.copy()
pending[page(runs_endpoint, 2)] = list_field("workflow_runs", [run(1, 11, "old", early), run(2, 12, "old", early)], 102)
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
    ("short page", page(runs_endpoint, 2), list_field("workflow_runs", [run(2, 12, "old", early)], 102)),
    ("missing first attempt", page(f"{gh}/actions/runs/1/attempts/1/jobs"), list_field("jobs", [])),
    ("missing required checks", f"{gh}/branches/main/protection", {}),
    ("force push", page(f"{gh}/issues/7/timeline"), [{"id": 4, "event": "head_ref_force_pushed"}]),
]:
    fixture(github | {endpoint: data})
    observed = ci_outcomes.observe(stage, new_task(), gh_url)
    assert observed["first_run_green"] is None and observed["history_coverage"] == "incomplete", (label, observed)
print("GitHub gaps: short page, lost retry, missing policy and rewritten head stay unknown")

gl_url = "https://gitlab.example.com/group/sub/project/-/merge_requests/4"
gl = "projects/group%2Fsub%2Fproject"
mr = f"{gl}/merge_requests/4"
pipe = f"{gl}/pipelines"
pipes = {1: dict(id=1, sha="old", ref="branch", source="push", status="success", created_at=early),
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
    page(f"{pipe}?ref=branch&source=push&created_after=2026-11-01T00%3A00%3A00Z"): [pipes[1]],
    **{f"{pipe}/{k}": v for k, v in pipes.items()},
    page(f"{pipe}/1/bridges"): [],
    page(f"{pipe}/1/jobs?include_retried=true"): [retry, optional, first],
    page(f"{pipe}/1/jobs"): [retry, optional],
}
fixture(gitlab)
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is False and observed["first_head"] == "old", observed
assert [p["id"] for p in observed["history"]] == [1, 2]
print("GitLab late wait: first push pipeline's failed job remains false after a green retry; web pipeline ignored")

fixture(gitlab | {page(f"{pipe}/1/jobs?include_retried=true"): [optional, retry]})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is True, observed
fixture(gitlab | {page(f"{pipe}/1/jobs?include_retried=true"): [first, optional]})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is None and observed["history_coverage"] == "incomplete", observed
fixture(gitlab | {page(f"{pipe}/1/jobs?include_retried=true"): [optional, gl_job(4, "tests", "skipped")]})
observed = ci_outcomes.observe(stage, new_task(), gl_url)
assert observed["first_run_green"] is None, observed
print("GitLab controls: optional failure can pass; missing/current mismatch or skipped required job stays unknown")

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
unknown_args = [str(b / "await"), "--wait", "--outcome-task", unsupported, "--ci-item", "https://other.example/x", "--", "true"]
assert subprocess.run(unknown_args, capture_output=True).returncode == 0
events, _ = task.read(task.path(stage, unsupported))
assert events[-1]["data"]["first_run_green"] is None and events[-1]["data"]["coverage_reason"]
print("await binding writes typed CI independently of the child exit and reports unsupported providers as unknown")
PY
