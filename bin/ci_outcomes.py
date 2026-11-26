"""Observe first CI attempts through authenticated forge CLIs, independently of wait verdicts."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import subprocess
import time
from urllib.parse import quote, urlsplit

import task_outcomes as outcomes


class CoverageError(ValueError):
    pass


def timestamp(value):
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.utcoffset() is None:
        raise CoverageError("provider timestamp has no UTC offset")
    return result


def binding(url):
    item = urlsplit(url)
    if item.scheme != "https" or not item.hostname or item.username or item.port or item.query or item.fragment:
        raise CoverageError("expected an HTTPS pull or merge request URL")
    match = re.fullmatch(r"/([\w.-]+/[\w.-]+)/pull/([1-9]\d*)/?", item.path, re.ASCII)
    if match and item.hostname == "github.com":
        return "github", item.hostname, match[1].lower(), match[2]
    match = re.fullmatch(r"/([\w.-]+(?:/[\w.-]+)+)/-/merge_requests/([1-9]\d*)/?", item.path, re.ASCII)
    if match and not set(match[1].split("/")) & {".", ".."}:
        return "gitlab", item.hostname, match[1], match[2]
    raise CoverageError("unsupported CI item URL")


class API:
    def __init__(self, provider, host):
        self.cli = "gh" if provider == "github" else "glab"
        self.host = host
        self.deadline = time.monotonic() + 45

    def get(self, endpoint):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise CoverageError("provider timeout")
        result = subprocess.run([self.cli, "api", "--hostname", self.host, endpoint],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=min(15, remaining))
        if result.returncode:
            raise CoverageError(f"{self.cli} API request failed (exit {result.returncode})")
        return json.loads(result.stdout)

    def pages(self, endpoint, field=None, cap=None):
        """Walk API pages explicitly. Repeated rows, a changing total or a provider cap are gaps."""
        sep = "&" if "?" in endpoint else "?"
        rows, seen, expected = [], set(), None
        for page in range(1, 101):
            payload = self.get(f"{endpoint}{sep}per_page=100&page={page}")
            part = payload[field] if field else payload
            if not isinstance(part, list):
                raise CoverageError("invalid provider page")
            if field:
                total = payload["total_count"]
                if (expected is not None and total != expected) or (cap is not None and total >= cap):
                    raise CoverageError("provider history changed or reached a listing limit")
                expected = total
            for row in part:
                key = row.get("id") if isinstance(row, dict) else None
                if key is None:
                    key = json.dumps(row, sort_keys=True)
                if key in seen:
                    raise CoverageError("provider pagination repeated an item")
                seen.add(key)
            rows.extend(part)
            if len(part) < 100 or len(rows) == expected:
                if expected is not None and len(rows) != expected:
                    raise CoverageError("provider pagination count mismatch")
                return rows
        raise CoverageError("provider pagination limit reached")


FAILURE = {"failed", "failure", "timed_out"}


def result(checks):
    return False if any(status in FAILURE for status in checks) else True if checks and all(
        status == "success" for status in checks) else None


def github_required(api, repo, branch, protected):
    rules = api.pages(f"{repo}/rules/branches/{branch}")
    required = set()
    for rule in rules:
        if rule["type"] == "required_status_checks":
            required.update((check["context"], check.get("integration_id"))
                            for check in rule["parameters"]["required_status_checks"])
        elif rule["type"] in {"workflows", "required_workflows"}:
            raise CoverageError("required workflow rules cannot be mapped to attempt jobs")
    if protected:
        # The protection object requires permission. Its omission cannot establish the set.
        protection = api.get(f"{repo}/branches/{branch}/protection")
        classic = protection.get("required_status_checks") or {}
        mapped = {check["context"]: check.get("app_id") for check in classic.get("checks", [])}
        required.update((context, mapped.get(context)) for context in set(classic.get("contexts", [])) | mapped.keys())
    if not required:
        raise CoverageError("required GitHub checks unavailable")
    return sorted(required, key=lambda check: (check[0], str(check[1])))


def github(api, project, number, data):
    repo = f"repos/{project}"
    item = f"{repo}/pulls/{number}"
    pull = api.get(item)
    created = timestamp(pull["created_at"])
    base = pull["base"]["ref"]
    head = pull["head"]
    data["head"], data["item_created_at"] = head["sha"], pull["created_at"]
    timeline = api.pages(f"{repo}/issues/{number}/timeline")
    uncertain_events = {"head_ref_force_pushed", "base_ref_changed", "base_ref_force_pushed"}
    if any(event.get("event") in uncertain_events for event in timeline):
        raise CoverageError("rewritten GitHub head/base history cannot be verified")
    commits = api.pages(f"{item}/commits")
    heads = {commit["sha"] for commit in commits}
    if head["sha"] not in heads or len(commits) != pull["commits"] or len(commits) >= 250:
        raise CoverageError("incomplete GitHub PR commit history")
    if (head.get("repo") or {}).get("full_name", "").lower() != project:
        raise CoverageError("fork push history cannot be reconciled with the GitHub PR")
    branch = quote(base, safe="")
    branch_info = api.get(f"{repo}/branches/{branch}")
    required = github_required(api, repo, branch, branch_info["protected"])
    data["required_checks"] = [{"name": name, "app_id": app} for name, app in required]
    # Full branch history from PR creation includes previous heads. Direct PR associations
    # also cover synthetic merge SHAs where GitHub exposes them.
    query = f"branch={quote(head['ref'], safe='')}&created={quote('>=' + pull['created_at'], safe='')}"
    runs = api.pages(f"{repo}/actions/runs?{query}", "workflow_runs", cap=1000)
    eligible = []
    for run in runs:
        if run["event"] not in ("pull_request", "pull_request_target", "push") or timestamp(run["created_at"]) < created:
            continue
        prs = run["pull_requests"]
        linked = [pr for pr in prs if pr["number"] == int(number)]
        if linked:
            sha = linked[0]["head"]["sha"]
        elif run["head_sha"] in heads and run["event"] == "push" and not prs:
            sha = run["head_sha"]
        elif run["head_sha"] in heads and not prs:
            raise CoverageError("GitHub workflow has no verifiable PR association")
        else:
            continue
        if sha not in heads:
            raise CoverageError("GitHub workflow refers to an unverified historical head")
        eligible.append((timestamp(run["created_at"]), run["id"], sha, run))
    eligible.sort()
    data["history"] = [
        dict(id=rid, head=sha, suite=run["check_suite_id"], latest_attempt=run["run_attempt"], created_at=run["created_at"])
        for _, rid, sha, run in eligible
    ]
    if not eligible:
        raise CoverageError("no eligible GitHub workflow history")
    _, _, first_head, first_run = eligible[0]
    data.update(first_head=first_head, attempt_id=f"github:{first_head}:1", attempt_created_at=first_run["created_at"])
    data["jobs"] = []
    for created_at, rid, sha, run in eligible:
        if sha != first_head:
            continue
        jobs = api.pages(f"{repo}/actions/runs/{rid}/attempts/1/jobs", "jobs")
        for job in jobs:
            data["jobs"].append(dict(id=job["id"], name=job["name"], status=job.get("conclusion"),
                                     run_id=rid, suite=run["check_suite_id"], attempt=1))
        if run["run_attempt"] > 1 and (not jobs or any(job["status"] != "completed" for job in jobs)):
            raise CoverageError("GitHub attempt 1 jobs missing after a retry")
    checks = []
    # Verify the job provenance against exact checks and application identities.
    for sha in sorted({run["head_sha"] for _, _, head_sha, run in eligible if head_sha == first_head}):
        checks.extend(api.pages(f"{repo}/commits/{sha}/check-runs?filter=all", "check_runs"))
    for name, app in required:
        matches = [c for c in checks if c["name"] == name and (app in (None, -1) or c["app"]["id"] == app)]
        suites = {j["suite"] for j in data["jobs"] if j["name"] == name}
        if not matches or any(c["check_suite"]["id"] not in suites for c in matches):
            raise CoverageError("required GitHub check cannot be assigned to a workflow attempt")
        matching_suites = {c["check_suite"]["id"] for c in matches}
        first_jobs = [j for j in data["jobs"] if j["name"] == name and j["suite"] in matching_suites]
        if len(first_jobs) != 1:
            raise CoverageError("ambiguous required GitHub job on first head")
        first_jobs[0]["required"] = True
    # A classic commit status with the required name is also a merge requirement.
    for sha in sorted({run["head_sha"] for _, _, head_sha, run in eligible if head_sha == first_head}):
        if any(s["context"] in {name for name, _ in required} for s in api.pages(f"{repo}/commits/{sha}/statuses")):
            raise CoverageError("required GitHub commit status has no attempt history")
    return result([j["status"] for j in data["jobs"] if j.get("required")])


def gitlab(api, project, number, data):
    repo = f"projects/{quote(project, safe='')}"
    item = f"{repo}/merge_requests/{number}"
    mr = api.get(item)
    created = timestamp(mr["created_at"])
    data["head"], data["item_created_at"] = mr["sha"], mr["created_at"]
    config = api.get(repo)
    if config.get("only_allow_merge_if_pipeline_succeeds") is not True:
        raise CoverageError("required GitLab pipeline policy unavailable")
    if mr["source_project_id"] != mr["target_project_id"]:
        raise CoverageError("fork push history cannot be reconciled with the GitLab MR")
    versions = api.pages(f"{item}/versions")
    heads = {version["head_commit_sha"] for version in versions}
    if mr["sha"] not in heads:
        raise CoverageError("incomplete GitLab MR diff history")
    attached = api.pages(f"{item}/pipelines")
    ref = quote(mr["source_branch"], safe="")
    pushes = api.pages(f"{repo}/pipelines?ref={ref}&source=push&created_after={quote(mr['created_at'], safe='')}")
    refs = {mr["source_branch"], f"refs/merge-requests/{number}/head", f"refs/merge-requests/{number}/merge"}
    eligible = []
    for pid, row in {p["id"]: p for p in attached + pushes}.items():
        pipe = api.get(f"{repo}/pipelines/{pid}")
        if pipe["sha"] != row["sha"]:
            raise CoverageError("GitLab pipeline changed during collection")
        if timestamp(pipe["created_at"]) < created or pipe["ref"] not in refs:
            continue
        if pipe["source"] == "push" and pipe["sha"] in heads:
            eligible.append(pipe)
        elif pipe["source"] == "merge_request_event" and row in attached:
            eligible.append(pipe)
    eligible.sort(key=lambda pipe: (timestamp(pipe["created_at"]), pipe["id"]))
    data["history"] = [
        dict(id=p["id"], head=p["sha"], source=p["source"], ref=p["ref"], created_at=p["created_at"])
        for p in eligible
    ]
    if not eligible:
        raise CoverageError("no eligible GitLab pipeline history")
    first = eligible[0]
    endpoint = f"{repo}/pipelines/{first['id']}"
    data.update(first_head=first["sha"], attempt_id=f"gitlab:{first['id']}:1", attempt_created_at=first["created_at"])
    if api.pages(f"{endpoint}/bridges"):
        raise CoverageError("required GitLab bridge jobs cannot be verified")
    jobs = api.pages(f"{endpoint}/jobs?include_retried=true")
    current = api.pages(f"{endpoint}/jobs")
    ordered = sorted(jobs, key=lambda j: j["id"])
    data["jobs"] = [dict(id=j["id"], name=j["name"], stage=j["stage"], status=j["status"],
                         created_at=j["created_at"], finished_at=j.get("finished_at"), allow_failure=j["allow_failure"])
                    for j in ordered]
    job_key = lambda j: (j["stage"], j["name"])
    first_jobs, last_jobs = {}, {}
    for job in data["jobs"]:
        first_jobs.setdefault(job_key(job), job)
        last_jobs[job_key(job)] = job
    if {job["id"] for job in last_jobs.values()} != {job["id"] for job in current}:
        raise CoverageError("GitLab retried jobs do not reconcile with the current pipeline")
    if any(job["allow_failure"] != first_jobs[job_key(job)]["allow_failure"] for job in data["jobs"]):
        raise CoverageError("GitLab blocking job set changed on retry")
    required = [j for j in first_jobs.values() if not j["allow_failure"]]
    data["required_checks"] = [{"name": j["name"], "stage": j["stage"]} for j in required]
    statuses = [j["status"] for j in required]
    value = result(statuses)
    if value is True and (first["status"] != "success" or not required):
        raise CoverageError("GitLab pipeline state does not establish first-attempt success")
    return value


def observe(stage, task_id, url):
    events, _ = outcomes.read(outcomes.path(stage, task_id))
    if not any(e["type"] == "task_started" for e in events):
        raise ValueError("CI binding refers to an unknown task")
    data = dict(target_task_id=task_id, provider=None, repository=None, item=url, head=None, status="unknown",
                first_run_green=None, history_coverage="incomplete", coverage_reason=None, attempt_id=None,
                attempt_created_at=None, first_head=None, item_created_at=None, history=[], required_checks=[], jobs=[])
    try:
        provider, host, project, number = binding(url)
        repository = f"https://{host}/{project}"
        suffix = "pull" if provider == "github" else "-/merge_requests"
        data.update(provider=provider, repository=repository, item=f"{repository}/{suffix}/{number}")
        value = (github if provider == "github" else gitlab)(API(provider, host), project, number, data)
        data.update(first_run_green=value, status={True: "success", False: "failure", None: "unknown"}[value],
                    history_coverage="complete",
                    coverage_reason="first attempt has unfinished or inconclusive required checks" if value is None else None)
    except (CoverageError, subprocess.TimeoutExpired, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        data["coverage_reason"] = str(exc) if isinstance(exc, CoverageError) else (
            "provider timeout" if isinstance(exc, subprocess.TimeoutExpired) else "missing or invalid provider evidence")
    state = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
    ev = outcomes.event(task_id, None, "ci_observed", data, data["provider"] or "ci-item",
                        event_id=f"{task_id}:ci:{state}")
    outcomes.append(stage, ev)
    return data
