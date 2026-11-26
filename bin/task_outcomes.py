"""Append-only, nullable task evidence. No routing decisions or transcript copies live here."""
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import math
import re
import uuid
from pathlib import Path

CLASSES = ("mechanical", "bounded", "judgement", "unknown")
KINDS = ("executor", "review")
TYPES = {"task_started", "run_started", "run_identity", "run_ended", "run_observed_dead",
         "review_observed", "ci_observed", "task_closed"}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def task_uuid(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("expected a canonical task UUID")
    return value


def change_class(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}", value):
        raise ValueError("change class must be a short identifier")
    return value


def path(stage_dir, task_id):
    return Path(stage_dir) / "task-outcomes" / (task_uuid(task_id) + ".jsonl")


def event(task_id, run_id, kind, data, source, event_id=None, **extra):
    stamp = now()
    return dict(schema_version=1, event_id=event_id or str(uuid.uuid4()), task_id=task_uuid(task_id),
                run_id=run_id, type=kind, occurred_at=stamp, recorded_at=stamp, source=source,
                writer="task_outcomes.py", data=data, **extra)


def validate(ev):
    if not isinstance(ev, dict) or ev.get("schema_version") != 1 or ev.get("type") not in TYPES:
        raise ValueError("unsupported outcome event/schema")
    task_uuid(ev.get("task_id"))
    for key in ("event_id", "source", "writer"):
        if not isinstance(ev.get(key), str) or not ev[key]:
            raise ValueError(f"missing {key}")
    for key in ("occurred_at", "recorded_at"):
        stamp = dt.datetime.fromisoformat(ev[key])
        if stamp.utcoffset() is None:
            raise ValueError("outcome times must have a UTC offset")
    if ev.get("run_id") is not None and not isinstance(ev["run_id"], str):
        raise ValueError("invalid run_id")
    data = ev.get("data")
    if not isinstance(data, dict):
        raise ValueError("event data must be an object")
    required = {
        "task_started": ("task_class", "task_kind", "change_class", "assignment_source", "stage", "role",
                         "brief_path", "brief_sha256", "continuation_of", "review_target_task_id", "engine", "requested_model", "effort"),
        "run_started": ("session_id", "kind", "engine", "requested_model", "effort", "log_offset", "resume_reason"),
        "run_identity": ("session_id", "resolved_model"),
        "run_ended": ("ended_at", "exit_code", "cli_result", "termination_reason", "reported_status", "usage", "complete"),
        "run_observed_dead": ("observed_at", "ended_at", "exit_code", "evidence", "usage", "complete"),
        "review_observed": ("reviewer_task_id", "reviewer_run_id", "target_task_id", "head", "round", "verdict", "findings", "finding_ids", "diagnostics"),
        "ci_observed": ("target_task_id", "repository", "item", "head", "status", "history_coverage"),
        "task_closed": ("outcome", "closed_at", "evidence_path", "artifact_ids", "review_applicability", "ci_applicability"),
    }[ev["type"]]
    if any(k not in data for k in required):
        raise ValueError(f"{ev['type']}: required fields: {', '.join(required)}")
    if ev["type"] == "task_started":
        if data["task_class"] not in CLASSES or data["task_kind"] not in KINDS:
            raise ValueError("invalid taxonomy")
        change_class(data["change_class"])
        for key in ("continuation_of", "review_target_task_id"):
            if data[key] is not None:
                task_uuid(data[key])
    if ev["type"] == "task_closed" and data["outcome"] not in ("success", "failure", "cancelled"):
        raise ValueError("invalid task outcome")
    if ev["type"] in ("review_observed", "ci_observed"):
        if data["target_task_id"] is not None:
            task_uuid(data["target_task_id"])
        if ev["type"] == "review_observed" and data["findings"] is not None:
            validate_findings(data)
    if "supersedes" in ev and (not isinstance(ev["supersedes"], str) or not ev.get("reason")):
        raise ValueError("a correction requires supersedes and reason")
    json.dumps(ev, allow_nan=False)


def read(file, strict=False):
    """Only a partial final line may be ignored; complete corrupt lines fail loudly."""
    if not Path(file).exists():
        return [], False
    raw = Path(file).read_bytes()
    torn = bool(raw and not raw.endswith(b"\n"))
    lines = raw.splitlines(keepends=True)
    events = []
    for line in lines[:-1] if torn else lines:
        ev = json.loads(line)
        if isinstance(ev, dict) and ev.get("schema_version") != 1 and not strict:
            import warnings
            warnings.warn(f"unsupported outcome version in {file}; event skipped (coverage incomplete)")
            continue
        validate(ev)
        events.append(ev)
    return events, torn


def append(stage_dir, ev):
    validate(ev)
    file = path(stage_dir, ev["task_id"])
    file.parent.mkdir(parents=True, exist_ok=True)
    with file.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        events, torn = read(file, strict=True)
        for old in events:
            if old["event_id"] == ev["event_id"]:
                # A retry's observation timestamps may differ; evidence must not.
                ignored = {"occurred_at", "recorded_at"}
                if {k: v for k, v in old.items() if k not in ignored} != {k: v for k, v in ev.items() if k not in ignored}:
                    raise ValueError(f"conflicting event id {ev['event_id']}")
                return False
        if ev.get("supersedes"):
            previous = next((x for x in events if x["event_id"] == ev["supersedes"]), None)
            if previous is None or previous["type"] != ev["type"]:
                raise ValueError("superseded event must exist in this task and have the same type")
            if ev["type"] != "task_closed" and ev["run_id"] != previous["run_id"]:
                raise ValueError("correction must retain run identity")
        with file.open("a+b") as out:
            if torn:
                import warnings
                warnings.warn(f"repairing torn outcome tail: {file}")
                out.seek(0)
                raw = out.read()
                out.truncate(raw.rfind(b"\n") + 1)
                out.seek(0, 2)
            out.write((json.dumps(ev, ensure_ascii=False, allow_nan=False) + "\n").encode())
            out.flush()
            import os
            os.fsync(out.fileno())
    return True


def emit(stage_dir, meta, run_id, kind, data, source="agent", **extra):
    if not meta.get("task_id"):
        return False  # historical agents are deliberately not backfilled
    return append(stage_dir, event(meta["task_id"], run_id, kind, data, source,
                                  event_id=f"{meta['task_id']}:{run_id or 'task'}:{kind}", **extra))


def start_task(stage_dir, meta):
    brief = Path(meta["brief"])
    data = {k: meta.get(k) for k in ("task_class", "task_kind", "change_class", "assignment_source", "stage", "role",
                                    "continuation_of", "review_target_task_id", "engine", "effort")}
    data.update(brief_path=str(brief), brief_sha256=hashlib.sha256(brief.read_bytes()).hexdigest(),
                requested_model=meta.get("requested_model", meta.get("model")))
    emit(stage_dir, meta, None, "task_started", data)


def log_events(file, offset=0, end=None):
    try:
        with Path(file).open("rb") as fh:
            raw = fh.read() if end is None else fh.read(end)
    except FileNotFoundError:
        return [], False
    complete = not raw or raw.endswith(b"\n")
    events = []
    for line in raw[offset:].splitlines():
        try:
            obj = json.loads(line)
            if not isinstance(obj, dict):
                raise ValueError("not an event")
            events.append(obj)
        except ValueError:
            complete = False
    return events, complete


def count(value):
    return value if type(value) is int and value >= 0 else None


def usage(file, offset, engine, session_id=None):
    events, intact = log_events(file, offset)
    before, prior_intact = log_events(file, end=offset)
    result = dict(usage_basis="claude_result_per_invocation" if engine == "claude" else "codex_session_cumulative_delta",
                  usage_scope="run", complete=False, raw=[], input_tokens=None, output_tokens=None,
                  cache_read_tokens=None, cache_creation_tokens=None, reasoning_output_tokens=None,
                  tokens_total=None, turns=None, turn_unit="claude_result_turns" if engine == "claude" else "codex_turn_started",
                  cost_usd=None, cost_basis="reported_claude_usd_delta" if engine == "claude" else "unavailable",
                  diagnostics=[])
    if engine == "claude":
        results = list({e.get("uuid", str(i)): e for i, e in enumerate(events) if e.get("type") == "result"}.values())
        result["raw"] = [{k: e.get(k) for k in ("usage", "num_turns", "total_cost_usd", "session_id")} for e in results]
        for field, key in (("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"),
                           ("cache_read_tokens", "cache_read_input_tokens"), ("cache_creation_tokens", "cache_creation_input_tokens")):
            values = [count((e.get("usage") or {}).get(key)) for e in results]
            result[field] = sum(values) if values and all(x is not None for x in values) else None
        turns = [count(e.get("num_turns")) for e in results]
        result["turns"] = sum(turns) if turns and all(x is not None for x in turns) else None
        # Price snapshots are cumulative by session; a resume needs the previous result's baseline.
        costs, baseline = [], {}
        for e in before:
            if e.get("type") == "result":
                baseline[e.get("session_id") or session_id] = e.get("total_cost_usd")
        known_sessions = {e.get("session_id") or session_id for e in before if e.get("type") == "system" and e.get("subtype") == "init"}
        for e in results:
            sid = e.get("session_id") or session_id
            previous = baseline.get(sid, None if sid in known_sessions else 0)
            current = e.get("total_cost_usd")
            valid = lambda x: type(x) in (float, int) and math.isfinite(x) and x >= 0
            costs.append(current - previous if valid(current) and valid(previous) and current >= previous else None)
            baseline[sid] = current
        if intact and prior_intact and costs and all(x is not None for x in costs):
            result["cost_usd"] = sum(costs)
        fields = [result[k] for k in ("input_tokens", "cache_read_tokens", "cache_creation_tokens", "output_tokens")]
    else:
        results = [e for e in events if e.get("type") == "turn.completed"]
        result["raw"] = [e.get("usage") for e in results]
        last_init = max((i for i, e in enumerate(before) if e.get("type") == "thread.started"), default=-1)
        previous = [e for e in before[last_init + 1:] if e.get("type") == "turn.completed"]
        previous_sid = next((e.get("thread_id") for e in reversed(before) if e.get("type") == "thread.started"), None)
        current_sid = next((e.get("thread_id") for e in events if e.get("type") == "thread.started"), session_id)
        baseline = {}
        if offset:
            if previous_sid == current_sid:
                baseline = previous[-1].get("usage") if previous else None
            elif not current_sid or not any(e.get("type") == "thread.started" for e in events):
                baseline = None
        if offset and previous_sid == current_sid and not previous:
            baseline = None
        snapshots = ([baseline] if baseline is not None else []) + [e.get("usage") for e in results]
        latest_result = max((i for i, e in enumerate(events) if e.get("type") == "turn.completed"), default=-1)
        monotonic = baseline is not None and not any(e.get("type") in ("turn.started", "turn.failed", "error") for e in events[latest_result + 1:])
        for a, b in zip(snapshots, snapshots[1:]):
            for key in ("input_tokens", "output_tokens", "cached_input_tokens", "reasoning_output_tokens"):
                av, bv = count((a or {}).get(key, 0)) if a == {} else count((a or {}).get(key)), count((b or {}).get(key))
                if av is not None and bv is not None and bv < av:
                    monotonic = False
        for field, key in (("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"),
                           ("cache_read_tokens", "cached_input_tokens"), ("reasoning_output_tokens", "reasoning_output_tokens")):
            last = count((results[-1].get("usage") or {}).get(key)) if results else None
            first = 0 if baseline == {} else count((baseline or {}).get(key))
            if monotonic and last is not None and first is not None and last >= first and intact and prior_intact:
                result[field] = last - first
        result["turns"] = sum(e.get("type") == "turn.started" for e in events) if intact and events else None
        fields = [result[k] for k in ("input_tokens", "output_tokens")]
    result["complete"] = intact and prior_intact and all(x is not None for x in fields) and result["turns"] is not None
    if result["complete"]:
        result["tokens_total"] = sum(fields)
    else:
        result["diagnostics"].append("missing, partial or regressing usage; totals unknown")
    return result


def validate_findings(data):
    findings, ids = data["findings"], data["finding_ids"]
    if not isinstance(findings, dict) or set(findings) != {"high", "medium", "low"} or any(count(v) is None for v in findings.values()):
        raise ValueError("findings require nonnegative integer severity counts")
    if not isinstance(ids, list) or any(not isinstance(x, dict) or not isinstance(x.get("id"), str) or not x["id"] or x.get("severity") not in findings for x in ids):
        raise ValueError("finding IDs require id and severity")
    if len({x["id"] for x in ids}) != len(ids):
        raise ValueError("duplicate finding IDs")
    if any(sum(x["severity"] == k for x in ids) != v for k, v in findings.items()):
        raise ValueError("findings counts disagree with IDs")


def review(meta, run_id, final, report):
    data = dict(reviewer_task_id=meta["task_id"], reviewer_run_id=run_id,
                target_task_id=meta.get("review_target_task_id"), head=None, round=None, verdict=None,
                findings=None, finding_ids=None, diagnostics=[], adjudication=None, provenance="reported_not_adjudicated")
    copies = []
    try:
        for text in (final, report):
            lines = re.findall(r"^REVIEW_OUTCOME:\s*(.*)$", text, re.M)
            if len(lines) != 1:
                raise ValueError("missing or multiple REVIEW_OUTCOME lines")
            obj = json.loads(lines[0])
            if not isinstance(obj, dict):
                raise ValueError("REVIEW_OUTCOME must be an object")
            if obj.get("schema_version") != 1 or obj.get("target_task_id") != data["target_task_id"]:
                raise ValueError("review schema/target mismatch")
            if obj["target_task_id"] is not None:
                task_uuid(obj["target_task_id"])
            if not isinstance(obj.get("head"), str) or not obj["head"] or type(obj.get("round")) is not int or obj["round"] < 1:
                raise ValueError("review requires head and positive round")
            if meta.get("review_head") and obj["head"] != meta["review_head"]:
                raise ValueError("review head mismatch")
            validate_findings(obj)
            verdicts = re.findall(r"^VERDICT:\s*(.*)$", text, re.M)
            if len(verdicts) != 1:
                raise ValueError("missing or multiple VERDICT lines")
            raw = verdicts[0].strip()
            verdict = {"approve": "approve", "merge": "approve", "merge after fixes": "fixes", "changes requested": "reject"}.get(raw.lower())
            if verdict is None:
                raise ValueError("unknown verdict")
            copies.append((obj, raw, verdict))
        if copies[0] != copies[1]:
            raise ValueError("review report/final disagree")
        obj, raw, verdict = copies[0]
        data.update({k: obj[k] for k in ("head", "round", "findings", "finding_ids")})
        data.update(verdict=verdict, raw_verdict=raw)
    except (ValueError, KeyError, TypeError) as exc:
        data["diagnostics"].append(str(exc))
    return data


def close(stage_dir, meta, run_id, status, evidence):
    if status not in ("DONE", "REVIEWED", "MERGED", "EXIT", "STOP"):
        return
    emit(stage_dir, meta, run_id, "task_closed",
         dict(outcome="success" if status in ("DONE", "REVIEWED", "MERGED") else "failure",
              reported_status=status, closed_at=now(), evidence_path=evidence, artifact_ids=[],
              review_applicability="unknown", ci_applicability="unknown"), source="auto_status")
