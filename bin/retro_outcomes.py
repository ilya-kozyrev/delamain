"""Frozen task evidence, descriptive completion snapshots and bounded model trials."""
from __future__ import annotations

from collections import Counter, defaultdict
import csv
import datetime as dt
from fractions import Fraction
import hashlib
import json
from pathlib import Path
from statistics import mean, median
from urllib.parse import urlsplit, urlunsplit

import task_outcomes as outcomes


SCHEMA = 1
FOLLOWUP = dt.timedelta(days=7)
DEFINITION = {
    "completion": "unique root task; latest closure in [since, until); lifetime usage at cutoff",
    "descriptive_tokens": "observed tokens by completion or legacy cohort; unknown usage boundary reported separately",
    "assignment": "root assignment in [since, until); evidence through assignment + 7 days",
    "visibility": "recorded_at <= cutoff",
    "tokens": "input including cache plus output; Claude all-model deltas; Codex cumulative usage deltas",
    "turns": ["claude_result_turns", "codex_turn_started"],
    "review": "first primary report per artifact; reported counts",
    "ci": "first eligible CI attempt per applicable artifact",
}
DIMENSIONS = ("cohort", "task_class", "task_kind", "change_class", "engine", "model", "effort")
INCUMBENT_FIELDS = ("repository_key", "task_class", "change_class", "engine", "model", "effort")


def stamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def order(ev):
    return (stamp(ev["occurred_at"]), stamp(ev["recorded_at"]), ev["event_id"])


def active(events, cutoff):
    visible = [ev for ev in events if stamp(ev["recorded_at"]) <= cutoff and stamp(ev["occurred_at"]) <= cutoff]
    replaced = {ev["supersedes"] for ev in visible if "supersedes" in ev}
    return sorted((ev for ev in visible if ev["event_id"] not in replaced), key=order)


def snapshot(audit, out, load_json, write_json):
    target = out / "outcome-inputs.json"
    frozen = load_json(target)
    identity = {k: audit.win[k] for k in ("home", "since", "until", "exclude_stages")}
    if frozen:
        if frozen["window"] != identity or frozen["schema_version"] != SCHEMA:
            raise ValueError("frozen outcome inputs belong to a different window or schema; choose a new --out")
        return frozen
    records, sources, warnings, damaged = [], [], [], set()
    stage_dirs = set(audit.stages) | {p.parent for p in audit.home.glob("*/task-outcomes") if p.is_dir()}
    for stage in sorted(stage_dirs):
        if stage.name in audit.win["exclude_stages"]:
            continue
        for file in sorted((stage / "task-outcomes").glob("*.jsonl")):
            raw = file.read_bytes()
            prefix = []
            lines = raw.splitlines(keepends=True)
            for number, line in enumerate(lines, 1):
                source = f"{file}:{number}"
                if not line.endswith(b"\n"):
                    warnings.append(f"{source}: torn final line")
                    damaged.add(file.stem)
                    continue
                try:
                    ev = json.loads(line)
                    if not isinstance(ev, dict) or ev.get("schema_version") != SCHEMA:
                        raise ValueError("unsupported event schema")
                    outcomes.validate(ev)
                    if file.stem != ev["task_id"]:
                        raise ValueError("task ID does not match filename")
                except (ValueError, KeyError, TypeError, UnicodeError) as exc:
                    warnings.append(f"{source}: {exc}")
                    damaged.add(file.stem)
                    continue
                if stamp(ev["recorded_at"]) <= audit.until:
                    prefix.append(line)
                    records.append(dict(event=ev, source=source))
            sources.append(dict(path=str(file), records=len(prefix),
                                sha256=hashlib.sha256(b"".join(prefix)).hexdigest()))
    legacy = []
    seen_sessions = set()
    typed_sessions = {entry["event"]["data"].get("session_id") for entry in records
                      if entry["event"]["type"] in ("run_started", "run_identity")}
    for old in audit.rows["agents"]:
        meta = audit.agent_meta[old["stage"], old["id"].split("/", 1)[-1]]
        if meta.get("task_id"):
            continue
        sid = meta.get("cli_session_id") or meta.get("session_id")
        if sid and (sid in seen_sessions or sid in typed_sessions):
            continue
        if sid:
            seen_sessions.add(sid)
        engine = old["engine"] or "unknown"
        path = Path(old["log"])
        usage = legacy_usage(path, meta, engine, audit.until)
        legacy.append(dict(id=old["id"], task_id=None, stage=old["stage"], source=old["source"],
                           task_class="unknown", task_kind="review" if old["is_review"] else "executor",
                           assignment_source="missing", change_class="unknown", engine=engine,
                           model=meta.get("resolved_model") or requested(old["model"]), effort=old["effort"] or "unknown",
                           assigned_at=old["started_at"], cohort="legacy_started", closure=None,
                           review_applicability="unknown", ci_applicability="unknown",
                           turns=usage.get("turns"), turn_unit=usage.get("turn_unit"),
                           tokens=usage.get("tokens_total"), cost_usd=usage.get("cost_usd")))
    frozen = dict(schema_version=SCHEMA, window=identity, sources=sources, records=records, legacy=legacy,
                  warnings=warnings, damaged=sorted(damaged))
    write_json(target, frozen)
    return frozen


def legacy_usage(path, meta, engine, cutoff):
    def legacy_stamp(value):
        try:
            parsed = stamp(value)
            return parsed.replace(tzinfo=cutoff.tzinfo) if parsed and parsed.tzinfo is None else parsed
        except (ValueError, TypeError, AttributeError):
            return None

    if engine not in ("claude", "codex") or not path.is_file():
        return {}
    offsets = [0]
    for run in meta.get("runs", []):
        at, offset = legacy_stamp(run.get("at")), run.get("log_offset")
        if at is not None and at >= cutoff:
            if type(offset) is not int:
                return {}
            offsets.append(offset)
            break
    end = offsets[-1] if len(offsets) > 1 else None
    events, intact = outcomes.log_events(path, end=end)
    if not intact or any((legacy_stamp(ev["timestamp"]) or cutoff) >= cutoff for ev in events if ev.get("timestamp")):
        return {}
    # A legacy Codex resume can switch sessions; without run boundaries its cumulative totals
    # cannot be attributed to a contract. An untimed resumed transcript is equally ambiguous.
    if engine == "codex" and len({ev.get("thread_id") for ev in events if ev.get("type") == "thread.started"}) > 1:
        return {}
    if end is None and meta.get("last_run_at") and (legacy_stamp(meta["last_run_at"]) or cutoff) >= cutoff:
        return {}
    return outcomes.usage(path, 0, engine, meta.get("session_id"), end=end)


def requested(value):
    return f"requested:{value}" if value and value not in ("default", "unknown", "cli-default") else "unknown"


def identity(data, resolved=None):
    return data.get("engine") or "unknown", resolved or requested(data.get("requested_model")), data.get("effort") or "unknown"


def complete_sum(values):
    values = list(values)
    return sum(values) if values and all(v is not None for v in values) else None


def contract_runs(tasks):
    runs, seen = [], set()
    for sid, events in tasks.items():
        by_run = defaultdict(dict)
        for ev in events:
            if ev["run_id"] and ev["type"] in outcomes.TERMINAL_TYPES | {"run_started", "run_identity"}:
                by_run[ev["run_id"]][ev["type"]] = ev
        for rid, by_type in by_run.items():
            start = by_type.get("run_started")
            if not start:
                continue
            init = by_type.get("run_identity", {}).get("data", {})
            terminal = by_type.get("run_ended") or by_type.get("run_observed_dead") or {}
            usage = terminal.get("data", {}).get("usage") or {}
            run_key = (start["data"]["engine"], init.get("session_id") or start["data"].get("session_id"),
                       rid)
            if run_key in seen:
                continue
            seen.add(run_key)
            runs.append(dict(task_id=sid, run_id=rid, first=start["occurred_at"], started=order(start),
                             identity=identity(start["data"], init.get("resolved_model")),
                             reason=start["data"]["resume_reason"], started_kind=start["data"]["kind"],
                             usage=usage, terminal=terminal.get("event_id"), start=start["event_id"]))
    return sorted(runs, key=lambda r: r["started"])


def contract_usage(runs, helpers_complete):
    counters = [r["usage"] for r in runs]
    units = {u.get("turn_unit") for u in counters}
    bases = {u.get("cost_basis") for u in counters}
    turn_unit = next(iter(units)) if len(units) == 1 else None
    cost_basis = "reported_claude_usd_delta" if bases == {"reported_claude_usd_delta"} else None
    observed_tokens = complete_sum(
        u.get("tokens_total") if u.get("complete") and u.get("usage_basis") != outcomes.CLAUDE_LEGACY_USAGE_BASIS
        else None for u in counters)
    return dict(tokens=observed_tokens if helpers_complete else None,
                observed_tokens=observed_tokens, usage_boundary_complete=helpers_complete,
                turn_unit=turn_unit,
                turns=complete_sum(u.get("turns") for u in counters) if turn_unit and helpers_complete else None,
                cost_basis=cost_basis, cost_usd=complete_sum(u.get("cost_usd") for u in counters)
                if cost_basis and helpers_complete else None)


def artifact_id(value):
    try:
        url = urlsplit(value)
    except ValueError:
        return value
    if url.scheme and url.netloc:
        path = url.path.rstrip("/")
        if url.hostname == "github.com":
            path = path.lower()
        return urlunsplit((url.scheme.lower(), url.netloc.lower(), path, "", ""))
    return value


def observation_artifact(data):
    value = data.get("artifact_id") or data.get("item")
    return artifact_id(value) if isinstance(value, str) and value else None


def ci_quality(artifacts, observations, applicability, exempt):
    if applicability == "not_required":
        return None
    grouped = defaultdict(list)
    for ev in observations:
        data = ev["data"]
        artifact = observation_artifact(data)
        if artifact:
            grouped[artifact].append(ev)
    values = []
    for artifact in (artifacts | grouped.keys()) - exempt:
        observed = grouped[artifact]
        failed = {ev["data"].get("attempt_id") for ev in observed if ev["data"].get("first_run_green") is False}
        superseded = {attempt for ev in observed for attempt in ev["data"].get("superseded_attempts", [])} - failed
        attempts = [ev for ev in observed if ev["data"].get("attempt_id") and ev["data"].get("attempt_created_at")
                    and ev["data"]["attempt_id"] not in superseded]
        if not attempts:
            values.append(None)
            continue
        first = min(attempts, key=lambda ev: (stamp(ev["data"]["attempt_created_at"]), order(ev)))
        states = [ev["data"] for ev in attempts if ev["data"]["attempt_id"] == first["data"]["attempt_id"]
                  and ev["data"]["history_coverage"] == "complete"]
        value = False if any(d.get("first_run_green") is False for d in states) else (
            True if any(d.get("first_run_green") is True for d in states) else None)
        values.append(value)
    return False if False in values else True if values and all(v is True for v in values) else None


def review_quality(artifacts, observations, applicability, exempt, reviewer=False):
    if applicability == "not_required" and not reviewer:
        return {}
    grouped = defaultdict(list)
    accepted, complete = set(), True
    seen = set()
    for ev in observations:
        data = ev["data"]
        artifact = observation_artifact(data)
        if artifact is None and len(artifacts) == 1:
            artifact = next(iter(artifacts))
        key = (data["reviewer_task_id"], data["reviewer_run_id"], data["head"], data["round"], artifact)
        if key in seen:
            continue
        seen.add(key)
        if artifact in exempt:
            continue
        if not artifact and artifacts:
            # Several declared artifacts need explicit review-to-artifact evidence.
            complete = False
        grouped[artifact].append(ev)
        findings = data.get("finding_ids")
        mapping = data.get("adjudication") or {}
        if findings is None or data.get("adjudication") is None:
            complete = False
        for finding in findings or []:
            verdict = mapping.get(finding["id"]) if isinstance(mapping, dict) else None
            if isinstance(verdict, str):
                verdict = {"status": verdict}
            if not isinstance(verdict, dict) or verdict.get("status") not in ("accepted", "rejected"):
                complete = False
            elif verdict["status"] == "accepted":
                accepted.add(verdict.get("canonical_id") or (artifact, finding["id"]))
    primary = []
    for artifact in (artifacts | grouped.keys()):
        reports = [ev for ev in grouped[artifact] if ev["data"].get("primary", True)]
        first = min(reports, key=lambda ev: (ev["data"]["round"] or 1, order(ev)), default=None)
        primary.append(first["data"]["findings"] if first else None)
    known = bool(primary) and all(item is not None for item in primary)
    rounds = {(artifact, ev["data"]["round"]) for artifact, events in grouped.items()
              for ev in events if ev["data"]["round"] is not None}
    return dict(reported_findings=sum(sum(item.values()) for item in primary) if known else None,
                reported_high=sum(item["high"] for item in primary) if known else None,
                accepted_findings=len(accepted) if grouped and complete else None,
                review_rounds=len(rounds) if grouped else None)


def artifact_scopes(meta, events, closure):
    scopes = {key: {} for key in ("review_applicability", "ci_applicability")}
    defaults = {key: meta[key] for key in scopes}
    artifacts = set()
    for ev in events:
        if ev["type"] == "artifact_observed" and ev["data"]["target_task_id"] == ev["task_id"]:
            per_artifact = True
        elif ev["type"] == "task_closed" and ev["event_id"] == closure.get("evidence_event_id"):
            per_artifact = False
        else:
            continue
        data = ev["data"]
        ids = {artifact_id(a) for a in data["artifact_ids"]}
        artifacts.update(ids)
        for key, scope in scopes.items():
            app = data[key]
            if app == "unknown":
                continue
            if per_artifact and ids:
                scope.update(dict.fromkeys(ids, app))
            else:
                defaults[key] = app
    return artifacts, defaults, scopes


def applicable_artifacts(artifacts, observed, default, overrides):
    values = {a: overrides.get(a, default) for a in artifacts | observed}
    exempt = {a for a, value in values.items() if value == "not_required"}
    statuses = set(values.values()) or {default}
    applicability = ("required" if "required" in statuses else
                     "not_required" if statuses == {"not_required"} else "unknown")
    return artifacts - exempt, applicability, exempt


class Evidence:
    def __init__(self, frozen):
        self.events = defaultdict(list)
        self.sources = defaultdict(list)
        self.reviews = defaultdict(list)
        self.children = defaultdict(list)
        self.starts = {}
        self.ambiguous = set(frozen.get("damaged", []))
        self.warnings = list(frozen["warnings"])
        seen = {}
        for entry in frozen["records"]:
            ev, source = entry["event"], entry["source"]
            task = ev["task_id"]
            key = task, ev["event_id"]
            if key in seen:
                if ev != seen[key]:
                    self.ambiguous.add(task)
                    self.warnings.append(f"{source}: conflicting duplicate event")
                continue
            seen[key] = ev
            self.events[task].append(ev)
            self.sources[task].append(source)
        for task, events in self.events.items():
            starts = [ev for ev in events if ev["type"] == "task_started"]
            original = [ev for ev in starts if "supersedes" not in ev]
            if len(original) != 1:
                self.ambiguous.add(task)
                self.warnings.append(f"{task}: missing or ambiguous task start")
                continue
            start = original[0]
            self.starts[task] = start
            if start["data"]["parent_task_id"]:
                self.children[start["data"]["parent_task_id"]].append(task)
            for ev in events:
                if ev["type"] != "review_observed":
                    continue
                data = ev["data"]
                target = data.get("target_task_id")
                confirmed = (target == start["data"]["review_target_task_id"]
                             if start["data"]["task_kind"] == "review" else target == task)
                if target and confirmed:
                    self.reviews[target].append(ev)

    def chains(self):
        result = defaultdict(list)
        for task in self.starts:
            root, seen = task, set()
            while self.starts[root]["data"]["continuation_of"]:
                seen.add(root)
                parent = self.starts[root]["data"]["continuation_of"]
                if parent not in self.starts or parent in seen:
                    root = task
                    self.ambiguous.add(task)
                    self.warnings.append(f"{task}: broken continuation chain")
                    break
                root = parent
            result[root].append(task)
        return result

    def helper_runs(self, by_task, cutoff):
        runs, complete = [], True
        pending = list(by_task)
        seen = set(pending)
        while pending:
            parent = pending.pop()
            meta = self.starts[parent]["data"]
            children = [child for child in self.children[parent] if stamp(self.starts[child]["recorded_at"]) <= cutoff]
            if meta["usage_boundary"] == "unknown":
                complete = False
            for child in children:
                child_meta = self.starts[child]["data"]
                included = child_meta["usage_in_parent"]
                if child in seen or included == "unknown" or (included == "included" and meta["usage_boundary"] == "own_only"):
                    complete = False
                    continue
                seen.add(child)
                pending.append(child)
                if included == "excluded":
                    measured = contract_runs({child: active(self.events[child], cutoff)})
                    if not measured or child in self.ambiguous:
                        complete = False
                    runs.extend(measured)
        return runs, complete

    def reduce(self, root, tasks, cutoff):
        by_task = {task: active(self.events[task], cutoff) for task in tasks}
        starts = {task: next((ev for ev in events if ev["type"] == "task_started"), None)
                  for task, events in by_task.items()}
        by_task = {task: events for task, events in by_task.items() if starts[task]}
        if root not in by_task:
            return None
        initial = starts[root]
        meta = initial["data"]
        latest_task = max(by_task, key=lambda task: max(
            [order(starts[task])] + [order(ev) for ev in by_task[task] if ev["type"] == "run_started"]))
        closure = outcomes.project_closure(by_task[latest_task]) or {}
        evs = sorted((ev for events in by_task.values() for ev in events), key=order)
        artifacts, defaults, scopes = artifact_scopes(meta, evs, closure)
        reviewer = meta["task_kind"] == "review"
        matched_ci = [ev for ev in evs if ev["type"] == "ci_observed" and ev["data"]["target_task_id"] == ev["task_id"]]
        linked = ([ev for ev in evs if ev["type"] == "review_observed"] if reviewer else
                  active([ev for task in by_task for ev in self.reviews[task]], cutoff))
        observed_ci = {observation_artifact(ev["data"]) for ev in matched_ci} - {None}
        observed_reviews = {observation_artifact(ev["data"]) for ev in linked} - {None}
        review_artifacts, review_app, review_exempt = applicable_artifacts(
            artifacts, observed_reviews, defaults["review_applicability"], scopes["review_applicability"])
        ci_artifacts, ci_app, ci_exempt = applicable_artifacts(
            artifacts, observed_ci, defaults["ci_applicability"], scopes["ci_applicability"])
        runs = contract_runs(by_task)
        first = next((r["identity"] for r in runs if r["task_id"] == root), identity(meta))
        identities = {tuple(r["identity"]) for r in runs} | {tuple(identity(starts[t]["data"])) for t in by_task
                                                                    if not any(r["task_id"] == t for r in runs)}
        mixed = len(identities) > 1
        display = ("mixed", "mixed", "mixed") if mixed else next(iter(identities), first)
        helper_runs, helpers_complete = self.helper_runs(by_task, cutoff)
        row = dict(id=root, task_id=root, stage=meta["stage"], repository_key=meta["repository_key"],
                   task_class=meta["task_class"], task_kind=meta["task_kind"], change_class=meta["change_class"],
                   assignment_source=json.dumps(self.starts[root]["data"]["assignment_source"], sort_keys=True),
                   explicit=all(self.starts[root]["data"]["assignment_source"].get(k) == "explicit"
                                for k in ("task_class", "task_kind", "change_class")),
                   engine=display[0], model=display[1], effort=display[2],
                   assigned_engine=first[0], assigned_model=first[1], assigned_effort=first[2],
                   mixed=mixed, handoff=len(by_task) > 1, helper=bool(meta["parent_task_id"]),
                   assigned_at=initial["occurred_at"], closure=closure.get("outcome"), closed_at=closure.get("closed_at"),
                   closure_source=closure.get("source"), run_count=len(runs),
                   resume_count=max(0, len(runs) - 1) if runs else None,
                   fix_rounds=sum(r["reason"] in ("review_fix", "ci_fix") for r in runs)
                   if any(r["reason"] in ("review_fix", "ci_fix") for r in runs) else None,
                   first_run_ci=ci_quality(ci_artifacts, matched_ci, ci_app, ci_exempt),
                   source=json.dumps(sorted({source for task in by_task for source in self.sources[task]})),
                   event_ids=json.dumps(sorted({ev["event_id"] for ev in evs + linked})),
                   artifact_ids=json.dumps(sorted(artifacts)), contributors=json.dumps(sorted(by_task)),
                   run_breakdown=json.dumps([{k: v for k, v in run.items() if k not in ("started", "usage")}
                                             for run in runs + helper_runs]),
                   ambiguous=any(task in self.ambiguous for task in by_task)
                   or len({starts[task]["data"]["repository_key"] for task in by_task}) != 1)
        row.update(review_applicability=review_app, ci_applicability=ci_app,
                   **contract_usage(runs + helper_runs, helpers_complete),
                   **review_quality(review_artifacts, linked, review_app, review_exempt, reviewer))
        return row


def cell(rows, descriptive=False):
    def known(field):
        return [r[field] for r in rows if r.get(field) is not None]

    n = len(rows)
    closed, tokens, usd = (known(k) for k in ("closure", "tokens", "cost_usd"))
    if descriptive:
        tokens = [r.get("observed_tokens", r.get("tokens")) for r in rows
                  if r.get("observed_tokens", r.get("tokens")) is not None]
    findings, accepted, ci = (known(k) for k in ("reported_findings", "accepted_findings", "first_run_ci"))
    turns = defaultdict(list)
    for row in rows:
        if row.get("turns") is not None and row.get("turn_unit"):
            turns[row["turn_unit"]].append(row["turns"])
    review_na = sum(r["review_applicability"] == "not_required" and r["task_kind"] != "review" for r in rows)
    ci_na = sum(r["ci_applicability"] == "not_required" for r in rows)
    keys = ("turns", "tokens", "cost_usd", "reported_findings", "accepted_findings", "first_run_ci")
    missing = {k: n - len(known(k)) for k in keys}
    missing.update(closure=n - len(closed), tokens=n - len(tokens))
    missing["reported_findings"] -= review_na
    missing["accepted_findings"] -= review_na
    missing["first_run_ci"] -= ci_na
    return dict(n=n, success=closed.count("success"), closed=len(closed), cancelled=closed.count("cancelled"),
                pending=n - len(closed), median_turns={unit: median(vals) for unit, vals in sorted(turns.items())},
                median_tokens=median(tokens) if tokens else None, mean_tokens=mean(tokens) if tokens else None,
                boundary_unknown=sum(r.get("usage_boundary_complete") is False for r in rows),
                known_cost=len(usd), median_reported_usd=median(usd) if usd else None,
                mean_reported_usd=mean(usd) if usd else None,
                total_reported_usd=sum(usd) if usd else None, review_observed=len(findings),
                review_applicable=n - review_na, review_na=review_na,
                mean_reported_findings=mean(findings) if findings else None,
                mean_reported_high=mean(known("reported_high")) if findings else None,
                mean_accepted_findings=mean(accepted) if accepted else None, accepted_observed=len(accepted),
                ci_passed=ci.count(True), ci_known=len(ci), ci_applicable=n - ci_na, ci_na=ci_na,
                handoffs=sum(bool(r.get("handoff")) for r in rows), missing=missing,
                sample_ids=sorted(r["id"] for r in rows))


def key_id(prefix, key):
    return prefix + "-" + hashlib.sha256(json.dumps(key).encode()).hexdigest()[:16]


def comparison_summary(rows):
    summary = cell(rows)
    n = summary["n"]
    summary["success_bounds"] = [summary["success"] / n, (summary["success"] + summary["pending"]) / n]
    summary["applicability"] = dict(Counter(
        f"{r['review_applicability']}/{r['ci_applicability']}" for r in rows))
    summary["cost_comparable"] = all(r.get("cost_basis") == "reported_claude_usd_delta" and
                                     r.get("cost_usd") is not None for r in rows)
    return summary


def comparable(a, b):
    for group in (a, b):
        n = group["n"]
        if n < 5 or group["closed"] != n or group["missing"]["tokens"]:
            return False
        if any("unknown" in mix for mix in group["applicability"]):
            return False
        for numerator, denominator in (("review_observed", "review_applicable"), ("ci_known", "ci_applicable")):
            m = group[denominator]
            if m and (group[numerator] < 5 or Fraction(group[numerator], m) < Fraction(4, 5)):
                return False
    a_mix = {k: Fraction(v, a["n"]) for k, v in a["applicability"].items()}
    b_mix = {k: Fraction(v, b["n"]) for k, v in b["applicability"].items()}
    if (a_mix != b_mix or b["success_bounds"][0] < a["success_bounds"][1]
            or Fraction(b["handoffs"], b["n"]) > Fraction(a["handoffs"], a["n"])):
        return False
    if a["review_applicable"] and (
            Fraction(a["review_observed"], a["review_applicable"]) != Fraction(b["review_observed"], b["review_applicable"])
            or b["mean_reported_high"] > a["mean_reported_high"]
            or b["mean_reported_findings"] > a["mean_reported_findings"]):
        return False
    return (not a["ci_applicable"] or Fraction(b["ci_passed"], b["ci_known"]) >= Fraction(a["ci_passed"], a["ci_known"]))


def relative(a, b):
    return (b - a) / a if a is not None and a > 0 and b is not None else None


def crosses_gate(a, b):
    token_change = relative(a["median_tokens"], b["median_tokens"])
    cost_change = relative(a["median_reported_usd"], b["median_reported_usd"]) if (
        a["cost_comparable"] and b["cost_comparable"]) else None
    return any(d is not None and d <= -0.20 for d in (token_change, cost_change)), token_change, cost_change


def incumbent_assignments(path):
    if path is None:
        return {}
    with Path(path).open(newline="", encoding="utf-8") as file:
        reader = csv.DictReader(file)
        if not set(INCUMBENT_FIELDS) <= set(reader.fieldnames or []):
            raise ValueError("incumbent CSV needs " + ", ".join(INCUMBENT_FIELDS))
        result = {}
        for row in reader:
            keys = tuple(row[k] for k in INCUMBENT_FIELDS)
            if not all(keys) or keys[:3] in result:
                raise ValueError("each incumbent stratum needs one complete assignment")
            result[keys[:3]] = keys[3:]
    return result


def trials(evidence, chains, since, until, incumbents):
    groups = defaultdict(list)
    excluded = Counter()
    incomplete_strata = Counter()
    for root, members in chains.items():
        when = stamp(evidence.starts[root]["occurred_at"])
        if not since <= when < until:
            continue
        horizon = when + FOLLOWUP
        row = evidence.reduce(root, members, min(horizon, until))
        if row is None:
            excluded["assignment_recorded_after_followup"] += 1
            continue
        if row["task_kind"] != "executor" or row["helper"]:
            excluded["review_or_helper"] += 1
            continue
        if horizon > until:
            excluded["insufficient_followup"] += 1
            continue
        stratum = tuple(row[k] for k in ("repository_key", "task_class", "change_class"))
        if (not row["repository_key"] or not row["explicit"] or row["task_class"] == "unknown"
                or row["change_class"] == "unknown"):
            excluded["unknown_or_ambiguous_assignment"] += 1
            continue
        model = (row["assigned_engine"], row["assigned_model"], row["assigned_effort"])
        if row["ambiguous"] or "unknown" in model or model[1].startswith("requested:"):
            # An unidentifiable assignment could be an unsuccessful candidate or incumbent.
            # Keep it visible and block comparisons in this stratum.
            incomplete_strata[stratum] += 1
        key = stratum + model
        groups[key].append(row)
    proposals, assignments = [], []
    for key, rr in sorted(groups.items()):
        full = comparison_summary(rr)
        direct = [r for r in rr if not r["mixed"]]
        row = dict(zip(INCUMBENT_FIELDS, key))
        row.update(id=key_id("assignment", key), full=full,
                   direct=comparison_summary(direct) if direct else None,
                   excluded_mixed=len(rr) - len(direct),
                   unresolved_in_stratum=incomplete_strata[key[:3]],
                   trial_status="incumbent" if incumbents.get(key[:3]) == key[3:]
                   else "insufficient evidence (n/coverage)")
        assignments.append(row)
    for b in assignments:
        key = tuple(b[k] for k in INCUMBENT_FIELDS)
        incumbent = incumbents.get(key[:3])
        if not incumbent or key[3:] == incumbent or b["unresolved_in_stratum"]:
            continue
        a = next((row for row in assignments if row["id"] == key_id("assignment", key[:3] + incumbent)), None)
        if not a or not a["direct"] or not b["direct"]:
            continue
        if not comparable(a["direct"], b["direct"]) or not comparable(a["full"], b["full"]):
            continue
        direct_gate, direct_tokens, direct_cost = crosses_gate(a["direct"], b["direct"])
        full_gate, tokens, cost = crosses_gate(a["full"], b["full"])
        full_mean_tokens = relative(a["full"]["mean_tokens"], b["full"]["mean_tokens"])
        full_mean_cost = relative(a["full"]["mean_reported_usd"], b["full"]["mean_reported_usd"]) if (
            a["full"]["cost_comparable"] and b["full"]["cost_comparable"]) else None
        # Both medians and the full-cohort mean must clear the threshold on the same resource.
        coherent = any(all(delta is not None and delta <= -0.20 for delta in deltas)
                       for deltas in ((direct_tokens, tokens, full_mean_tokens), (direct_cost, cost, full_mean_cost)))
        if direct_gate and full_gate and coherent:
            b["trial_status"] = "eligible owner trial"
            proposals.append(dict(incumbent=a["id"], candidate=b["id"], token_change=tokens, cost_change=cost,
                                  direct_token_change=direct_tokens, direct_cost_change=direct_cost,
                                  full_mean_token_change=full_mean_tokens, full_mean_cost_change=full_mean_cost,
                                  conflict=tokens is not None and cost is not None and tokens * cost < 0))
    return assignments, proposals, dict(excluded), sum(incomplete_strata.values())


def completion_rows(evidence, chains, since, until, cutoff):
    rows = []
    for root, members in sorted(chains.items()):
        row = evidence.reduce(root, members, cutoff)
        if row and row["closed_at"] and since <= stamp(row["closed_at"]) < until:
            rows.append(dict(row, cohort="completion"))
        elif row and since <= stamp(row["assigned_at"]) < until:
            rows.append(dict(row, cohort="assignment_only"))
    return rows


def show(value):
    return "unknown" if value is None else f"{value:,.3f}".rstrip("0").rstrip(".") if isinstance(value, float) else str(value)


def rate(num, den, na=False):
    return "N/A" if not den and na else f"{num}/{den}" if den else f"unknown ({num}/{den})"


def quality_mean(value, applicable):
    return show(value) if applicable else "N/A"


def proposal_text(proposal, indexed, window):
    a, b = indexed[proposal["incumbent"]], indexed[proposal["candidate"]]
    x, y = a["full"], b["full"]
    model = lambda row: "/".join(row[k] for k in ("engine", "model", "effort"))
    pair = lambda field: f"{show(x[field])} / {show(y[field])}"
    counts = lambda numerator, denominator: " / ".join(rate(g[numerator], g[denominator]) for g in (x, y))
    delta = lambda value: "unavailable" if value is None else f"{value:+.1%}"
    findings = " / ".join(quality_mean(g["mean_reported_findings"], g["review_applicable"]) for g in (x, y))
    ci = " / ".join(rate(g["ci_passed"], g["ci_known"], not g["ci_applicable"]) for g in (x, y))
    choice = " Tokens and reported cost move in opposite directions. Choose which resource to prioritize." if proposal["conflict"] else ""
    return (
        f"Consider a bounded trial of **{model(b)}** instead of **{model(a)}** for "
        f"{a['task_class']} / {a['repository_key']} / {a['change_class']}. "
        f"Incumbent / candidate · n {pair('n')}, success {counts('success', 'closed')}, "
        f"median tokens {pair('median_tokens')} ({delta(proposal['token_change'])}), median reported Claude USD "
        f"{pair('median_reported_usd')} ({delta(proposal['cost_change'])}, priced {counts('known_cost', 'n')}), "
        f"reported findings/task {findings}, accepted findings/task {pair('mean_accepted_findings')}, first CI {ci}. "
        f"Review coverage {counts('review_observed', 'review_applicable')}, CI coverage {counts('ci_known', 'ci_applicable')}, "
        f"completion {counts('closed', 'n')}, handoffs {counts('handoffs', 'n')}. "
        f"Full-cohort mean deltas {delta(proposal['full_mean_token_change'])} tokens and "
        f"{delta(proposal['full_mean_cost_change'])} reported Claude USD. "
        f"Success bounds with unknown outcomes {x['success_bounds']} / {y['success_bounds']}. "
        f"Mixed samples excluded from direct cells {a['excluded_mixed']} / {b['excluded_mixed']}. "
        f"Assignment period {window['since']} → {window['until']}, with seven days of follow-up per task.{choice} "
        "Observational association. Difficulty selection and reviewer mix may explain it. "
        "Accepting uses execution and review capacity for a bounded trial. Declining continues the incumbent assignment. "
        "Owner decision required. No model, effort, engine or hub rule was changed. "
        f"Rows `{a['id']}`, `{b['id']}`. Sample IDs {', '.join(x['sample_ids'])} / {', '.join(y['sample_ids'])}."
    )


def render(rows, assignments, proposals, excluded, blocking_unresolved, warnings, window, table, incumbent_source):
    headers = ["cohort", "class", "kind", "change", "engine", "model", "effort", "n", "success/known", "median turns (unit)",
               "median observed tokens", "boundary unknown/incomplete", "reported Claude USD total/median", "reviewed/applicable",
               "reported findings/task", "accepted findings/task", "first CI passed/known", "missing"]
    lines = []
    for r in rows:
        turns = ", ".join(f"{show(v)} ({u})" for u, v in r["median_turns"].items()) or "unknown"
        applicable_na = {"reported_findings": r["review_na"], "accepted_findings": r["review_na"], "first_run_ci": r["ci_na"]}
        lines.append([r[k] for k in DIMENSIONS] + [
            r["n"], rate(r["success"], r["closed"]), turns, show(r["median_tokens"]),
            rate(r["boundary_unknown"], r["n"]),
            f"{show(r['total_reported_usd'])} / {show(r['median_reported_usd'])}",
            rate(r["review_observed"], r["review_applicable"], bool(r["review_na"])),
            quality_mean(r["mean_reported_findings"], r["review_applicable"]),
            quality_mean(r["mean_accepted_findings"], r["review_applicable"]),
            rate(r["ci_passed"], r["ci_known"], bool(r["ci_na"]) and not r["ci_applicable"]),
            ", ".join(f"{k} {v}/{r['n'] - applicable_na.get(k, 0)}" for k, v in r["missing"].items() if v) or "none"])
    sections = [
        "## Task outcomes by class × model",
        "Latest closure in the window, with lifetime usage at the cutoff. Historical unknown-class rows use start dates. "
        "Completion cohorts are snapshots: recompute unique root task IDs at a common cutoff when combining periods.",
        "Findings are reported, not adjudicated, from the first primary report per artifact. Accepted findings are separate. "
        "First CI is the first eligible attempt per applicable artifact. First-time-right also includes review rounds.",
        table(headers, lines),
        "## Model trial evidence",
        "Seven days of follow-up per initial assignment. Recent assignments without seven days of follow-up are excluded. "
        "Mixed contracts retain their full spend and outcomes in the original-assignment cohort.",
        f"Incumbent source {incumbent_source or 'unavailable'}. Exclusions {json.dumps(excluded, sort_keys=True)}. "
        f"Blocking unresolved assignments retained in cohort {blocking_unresolved}.",
        table(["row", "repository", "class", "change", "assignment", "n", "closed", "pending", "cancelled",
               "handoffs", "mixed", "success bounds", "review coverage", "CI coverage", "trial"],
              [[r["id"], r["repository_key"], r["task_class"], r["change_class"],
                "/".join(r[k] for k in ("engine", "model", "effort")), r["full"]["n"], r["full"]["closed"],
                r["full"]["pending"], r["full"]["cancelled"], r["full"]["handoffs"], r["excluded_mixed"],
                r["full"]["success_bounds"], rate(r["full"]["review_observed"], r["full"]["review_applicable"], True),
                rate(r["full"]["ci_known"], r["full"]["ci_applicable"], True), r["trial_status"]] for r in assignments]),
    ]
    if proposals:
        indexed = {r["id"]: r for r in assignments}
        sections.extend(proposal_text(p, indexed, window) for p in proposals)
    else:
        sections.append("Insufficient evidence (n/coverage) for a model trial.")
    if warnings:
        sections.append("Outcome evidence warnings\n\n" + "\n".join(f"- {warning}" for warning in warnings))
    return sections


def measure(audit, out, baseline, load_json, write_json, csv_write, table, incumbents_path):
    frozen = snapshot(audit, out, load_json, write_json)
    evidence = Evidence(frozen)
    chains = evidence.chains()
    observations = completion_rows(evidence, chains, audit.since, audit.until, audit.until)
    observations.extend(frozen["legacy"])
    cohorts = defaultdict(list)
    for row in observations:
        if row["cohort"] != "assignment_only":
            cohorts[tuple(row[k] for k in DIMENSIONS)].append(row)
    cells = [dict(zip(DIMENSIONS, key)) | dict(id=key_id("cell", key)) | cell(rows, descriptive=True)
             for key, rows in sorted(cohorts.items())]
    # Freeze the explicit routing evidence independently of task observations.
    choice_file = out / "outcome-incumbents.json"
    choice = load_json(choice_file)
    if choice is None:
        choice = dict(source=str(incumbents_path) if incumbents_path else None,
                      rows=[[list(k), list(v)] for k, v in sorted(incumbent_assignments(incumbents_path).items())])
        write_json(choice_file, choice)
    elif incumbents_path and str(incumbents_path) != choice["source"]:
        raise ValueError("incumbent inputs already frozen; choose a new --out")
    incumbent = {tuple(k): tuple(v) for k, v in choice["rows"]}
    assignments, proposals, excluded, blocking_unresolved = trials(evidence, chains, audit.since, audit.until, incumbent)
    info = dict(definitions=DEFINITION, cells=cells, assigned=assignments, proposals=proposals,
                exclusions=excluded, blocking_unresolved_identity=blocking_unresolved, incumbent_source=choice["source"], inputs="outcome-inputs.json",
                warnings=evidence.warnings)
    if (baseline.get("outcome_schema_version") == SCHEMA
            and baseline.get("model_outcomes", {}).get("definitions") == DEFINITION
            and baseline.get("window", {}).get("home") == audit.win["home"]
            and baseline["window"].get("exclude_stages") == audit.win["exclude_stages"]
            and stamp(baseline["window"]["until"]) <= audit.until):
        previous = baseline["window"]
        prior = completion_rows(evidence, chains, stamp(previous["since"]), stamp(previous["until"]), audit.until)
        prior_ids = {r["id"] for r in prior if r["cohort"] == "completion"}
        current_ids = {r["id"] for r in observations if r["cohort"] == "completion"}
        info["baseline_common_cutoff"] = dict(cutoff=audit.win["until"], prior=len(prior_ids),
                                             current=len(current_ids), unique=len(prior_ids | current_ids),
                                             overlap=sorted(prior_ids & current_ids))
    def csv_value(value):
        return json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value
    csv_write(out / "task-outcomes.csv", observations)
    csv_write(out / "model-outcomes.csv", [{k: csv_value(v) for k, v in row.items()} for row in cells])
    csv_write(out / "model-assignments.csv", [{k: csv_value(v) for k, v in row.items()} for row in assignments])
    for k, v in (("completion_count", sum(r["cohort"] == "completion" for r in observations)),
                 ("legacy_count", len(frozen["legacy"])), ("trial_count", len(proposals))):
        audit.metric(f"model_outcomes.{k}", v, "task-outcomes.csv; model-assignments.csv", total=False)
    return info, render(cells, assignments, proposals, excluded, blocking_unresolved, evidence.warnings, audit.win, table, choice["source"])
