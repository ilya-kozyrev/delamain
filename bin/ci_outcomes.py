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


def github_required(api, repo, branch, branch_info):
    rules = api.pages(f"{repo}/rules/branches/{branch}")
    required = set()
    for rule in rules:
        if rule["type"] == "required_status_checks":
            required.update((check["context"], check.get("integration_id"))
                            for check in rule["parameters"]["required_status_checks"])
        elif rule["type"] in {"workflows", "required_workflows"}:
            raise CoverageError("required workflow rules cannot be mapped to attempt jobs")
    if branch_info["protected"]:
        protection = branch_info.get("protection")
        if protection is None:
            raise CoverageError("GitHub branch protection could not be verified")
        classic = protection.get("required_status_checks") or {}
        mapped = {check["context"]: check.get("app_id") for check in classic.get("checks", [])}
        required.update((context, mapped.get(context)) for context in set(classic.get("contexts", [])) | mapped.keys())
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
    required = github_required(api, repo, branch, branch_info)
    data["required_checks_source"] = "policy" if required else "inferred"
    data["required_checks"] = [{"name": name, "app_id": app} for name, app in required]
    initial = commits[0]
    initial_at = min(created, timestamp(initial["commit"]["committer"]["date"]))
    query = f"branch={quote(head['ref'], safe='')}&created={quote('>=' + initial_at.isoformat(), safe='')}"
    runs = api.pages(f"{repo}/actions/runs?{query}", "workflow_runs", cap=1000)
    pr_events = {"pull_request", "pull_request_target", "pull_request_review"}
    eligible = []
    for run in runs:
        sha, at, event = run["head_sha"], timestamp(run["created_at"]), run["event"]
        if event not in pr_events | {"push"} or at < initial_at:
            continue
        prs = run["pull_requests"]
        linked = any(pr["number"] == int(number) for pr in prs)
        branch_match = (run.get("head_branch") == head["ref"]
                        and (run.get("head_repository") or {}).get("full_name", project).lower() == project)
        if not linked and (prs or not branch_match or sha not in heads):
            continue
        if sha not in heads:
            raise CoverageError("GitHub workflow refers to an unverified historical head")
        if at < created and (event != "push" or sha != initial["sha"]):
            continue
        eligible.append((at, run["id"], sha, run))
    eligible.sort()
    if not required:
        pr_workflows = {run["workflow_id"] for _, _, _, run in eligible if run["event"] in pr_events}
        eligible = [row for row in eligible if row[3]["workflow_id"] in pr_workflows]
    data["history"] = [
        dict(id=rid, head=sha, suite=run["check_suite_id"], latest_attempt=run["run_attempt"], created_at=run["created_at"])
        for _, rid, sha, run in eligible
    ]
    while eligible:
        _, _, first_head, first_run = eligible[0]
        workflows = {}
        for _, _, sha, run in eligible:
            if sha == first_head:
                workflows.setdefault(run["workflow_id"], run)
        first_runs = list(workflows.values())
        jobs = github_jobs(api, repo, first_runs)
        data.update(first_head=first_head, attempt_id=f"github:{first_head}:1", attempt_created_at=first_run["created_at"],
                    jobs=jobs)
        if not github_replaced(api, repo, first_runs, jobs, eligible):
            break
        data["superseded_attempts"].append(data["attempt_id"])
        eligible = [row for row in eligible if row[2] != first_head]
    else:
        raise CoverageError("no eligible GitHub workflow history")
    if any(run.get("conclusion") == "cancelled" and run["run_attempt"] == 1 for run in first_runs):
        return None
    checks = api.pages(f"{repo}/commits/{first_head}/check-runs?filter=all", "check_runs")
    if not required:
        suites = {(c["check_suite"]["id"], c["name"]) for c in checks}
        for job in jobs:
            if (job["suite"], job["name"]) not in suites:
                raise CoverageError("GitHub workflow job has no matching check run")
            if job["status"] not in ("skipped", "neutral"):
                job["required"] = True
                data["required_checks"].append(dict(name=job["name"], suite=job["suite"]))
        return result([j["status"] for j in jobs if j.get("required")])
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
    if any(s["context"] in {name for name, _ in required}
           for s in api.pages(f"{repo}/commits/{first_head}/statuses")):
        raise CoverageError("required GitHub commit status has no attempt history")
    return result([j["status"] for j in data["jobs"] if j.get("required")])


def github_jobs(api, repo, runs):
    evidence = []
    for run in runs:
        rid = run["id"]
        jobs = api.pages(f"{repo}/actions/runs/{rid}/attempts/1/jobs", "jobs")
        if run["run_attempt"] > 1 and (not jobs or any(job["status"] != "completed" for job in jobs)):
            raise CoverageError("GitHub attempt 1 jobs missing after a retry")
        for job in jobs:
            check_id = job.get("check_run_url", "").rsplit("/", 1)[-1]
            evidence.append(dict(id=job["id"], name=job["name"], status=job.get("conclusion"),
                                 run_id=rid, suite=run["check_suite_id"], attempt=1,
                                 check_id=int(check_id) if check_id.isdecimal() else job["id"]))
    return evidence


def github_replaced(api, repo, runs, jobs, history):
    canceled = [run for run in runs if run["run_attempt"] == 1 and run.get("conclusion") == "cancelled"]
    if not canceled or any(job["status"] in FAILURE for job in jobs):
        return False
    for run in canceled:
        later_revision = any(other.get("workflow_id") == run.get("workflow_id") and sha != run["head_sha"]
                             and created > timestamp(run["created_at"]) for created, _, sha, other in history)
        if not later_revision:
            return False
        evidence = [j for j in jobs if j["run_id"] == run["id"] and j["status"] == "cancelled"]
        try:
            proven = any(annotation.get("message", "").startswith("Canceling since a higher priority waiting request")
                         for job in evidence
                         for annotation in api.pages(f"{repo}/check-runs/{job['check_id']}/annotations"))
        except (CoverageError, OSError, subprocess.TimeoutExpired):
            proven = False
        if not proven:
            return False
    return True


def gitlab_replacement(detail, candidates):
    # Some GitLab versions expose the replacing pipeline through the canceled status tooltip.
    replaced_by = detail.get("auto_canceled_by_id")
    if replaced_by is None:
        tooltip = (detail.get("detailed_status") or {}).get("tooltip") or ""
        match = re.search(r"auto[- ]canceled (?:by|because of) (?:pipeline )?#(\d+)", tooltip, re.IGNORECASE)
        replaced_by = int(match[1]) if match else None
    return next((p for p in candidates if p["id"] == replaced_by and p["sha"] != detail["sha"]), None)


def gitlab(api, project, number, data):
    repo = f"projects/{quote(project, safe='')}"
    item = f"{repo}/merge_requests/{number}"
    mr = api.get(item)
    created = timestamp(mr["created_at"])
    data["head"], data["item_created_at"] = mr["sha"], mr["created_at"]
    config = api.get(repo)
    policy = config.get("only_allow_merge_if_pipeline_succeeds")
    if type(policy) is not bool:
        raise CoverageError("GitLab pipeline policy could not be verified")
    data["required_checks_source"] = "policy" if policy else "inferred"
    if mr["source_project_id"] != mr["target_project_id"]:
        raise CoverageError("fork push history cannot be reconciled with the GitLab MR")
    versions = api.pages(f"{item}/versions")
    heads = {version["head_commit_sha"] for version in versions}
    if mr["sha"] not in heads:
        raise CoverageError("incomplete GitLab MR diff history")
    initial = min(versions, key=lambda version: version["id"])["head_commit_sha"]
    commit = api.get(f"{repo}/repository/commits/{quote(initial, safe='')}")
    initial_at = min(created, timestamp(commit["committed_date"]))
    attached = api.pages(f"{item}/pipelines")
    attached_ids = {p["id"] for p in attached}
    ref = quote(mr["source_branch"], safe="")
    # GitLab's created_after is exclusive.
    after = quote((initial_at - dt.timedelta(seconds=1)).isoformat(), safe="")
    pushes = api.pages(f"{repo}/pipelines?ref={ref}&source=push&created_after={after}")
    refs = {mr["source_branch"], f"refs/merge-requests/{number}/head", f"refs/merge-requests/{number}/merge"}
    eligible = []
    for row in {p["id"]: p for p in pushes + attached}.values():
        if row["ref"] not in refs or timestamp(row["created_at"]) < initial_at:
            continue
        if timestamp(row["created_at"]) < created and (row["source"] != "push" or row["sha"] != initial):
            continue
        if (row["source"] == "push" and row["sha"] in heads
                or row["source"] == "merge_request_event" and row["id"] in attached_ids):
            eligible.append(row)
    eligible.sort(key=lambda pipe: (timestamp(pipe["created_at"]), pipe["id"]))
    data["history"] = [
        dict(id=p["id"], head=p["sha"], source=p["source"], ref=p["ref"], created_at=p["created_at"], status=p["status"])
        for p in eligible
    ]
    for index, row in enumerate(eligible):
        endpoint = f"{repo}/pipelines/{row['id']}"
        first = api.get(endpoint)
        if any(first[k] != row[k] for k in ("sha", "ref", "status")):
            raise CoverageError("GitLab pipeline changed during collection")
        data.update(first_head=first["sha"], attempt_id=f"gitlab:{first['id']}:1", attempt_created_at=first["created_at"])
        if first["status"] != "canceled":
            break
        if not gitlab_replacement(first, eligible[index + 1:]):
            return None
        data["superseded_attempts"].append(data["attempt_id"])
    else:
        raise CoverageError("no eligible GitLab pipeline history")
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
    required = [j for j in first_jobs.values() if not j["allow_failure"] and (policy or j["status"] != "manual")]
    data["required_checks"] = [{"name": j["name"], "stage": j["stage"]} for j in required]
    statuses = [j["status"] for j in required]
    value = result(statuses)
    if value is True and (first["status"] != "success" and (policy or first["status"] != "manual")):
        raise CoverageError("GitLab pipeline state does not establish first-attempt success")
    return value


def observe(stage, task_id, url):
    events, _ = outcomes.read(outcomes.path(stage, task_id))
    if not any(e["type"] == "task_started" for e in events):
        raise ValueError("CI binding refers to an unknown task")
    # An invalid binding can contain URL credentials or query tokens. Keep its identity without storing the input.
    unverified_item = "unverified:" + hashlib.sha256(url.encode()).hexdigest()
    data = dict(target_task_id=task_id, provider=None, repository=None, item=unverified_item, head=None, status="unknown",
                first_run_green=None, history_coverage="incomplete", coverage_reason=None, attempt_id=None,
                attempt_created_at=None, first_head=None, item_created_at=None, history=[], required_checks=[],
                required_checks_source=None, superseded_attempts=[], jobs=[])
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
