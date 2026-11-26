"""Regression controls for the append-only protocol and actual agent launch paths."""
import concurrent.futures
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

BIN = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(BIN))
import task_outcomes as out
import hubcore as hc
import reviewers


class Outcomes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.task = str(uuid.uuid4())

    def tearDown(self):
        self.temp.cleanup()

    def closure(self, event_id="closure"):
        return out.event(self.task, "run", "task_closed", dict(outcome="success", closed_at=out.now(),
                         evidence_path="fixture", artifact_ids=[], review_applicability="unknown", ci_applicability="unknown"),
                         "hub", event_id)

    def test_append_retry_conflict_and_corruption(self):
        ev = self.closure()
        self.assertTrue(out.append(self.root, ev))
        self.assertFalse(out.append(self.root, ev))
        ev["data"]["outcome"] = "failure"
        with self.assertRaisesRegex(ValueError, "conflicting"):
            out.append(self.root, ev)
        file = out.path(self.root, self.task)
        with file.open("ab") as f:
            f.write(b'{"torn":')
        self.assertTrue(out.read(file)[1])
        out.append(self.root, self.closure("next"))
        self.assertEqual(len(out.read(file)[0]), 2)
        self.assertFalse(out.read(file)[1])
        with file.open("ab") as f:
            f.write(b'broken\n')
        with self.assertRaises(ValueError):
            out.append(self.root, self.closure("must fail"))

    def test_concurrent_appends(self):
        events = [self.closure(str(i)) for i in range(32)]
        # Independent Python processes, not threads sharing an advisory lock descriptor.
        code = 'import json,sys;sys.path.insert(0,sys.argv[1]);import task_outcomes as o;o.append(sys.argv[2],json.loads(sys.stdin.read()))'
        def write(ev):
            return subprocess.run([sys.executable, "-c", code, str(BIN), str(self.root)], input=json.dumps(ev), text=True).returncode
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            self.assertEqual(list(pool.map(write, events + events)), [0] * 64)
        rows, torn = out.read(out.path(self.root, self.task))
        self.assertEqual(len(rows), 32)
        self.assertFalse(torn)

    def test_typed_envelope_and_corrections(self):
        ev = self.closure()
        out.append(self.root, ev)
        correction = self.closure("correction") | {"supersedes": ev["event_id"], "reason": "owner accepted"}
        out.append(self.root, correction)
        for mutation in ({"schema_version": 2}, {"task_id": "../escape"}, {"occurred_at": "2026-01-01"},
                         {"supersedes": "missing", "reason": "fix"}, {"data": {}}, {"type": "arbitrary"}):
            with self.assertRaises((ValueError, KeyError)):
                out.append(self.root, self.closure(str(uuid.uuid4())) | mutation)

    def write_log(self, events):
        file = self.root / "log.jsonl"
        file.write_text("".join(json.dumps(e) + "\n" for e in events))
        return file

    def test_claude_usage_is_invocation_but_cost_session_delta(self):
        init = dict(type="system", subtype="init", session_id="sid")
        def result(n, cost):
            return dict(type="result", session_id="sid", num_turns=n, total_cost_usd=cost,
                        usage=dict(input_tokens=10, output_tokens=20, cache_read_input_tokens=30, cache_creation_input_tokens=40))
        first = [init, result(3, 0.8)]
        file = self.write_log(first)
        offset = file.stat().st_size
        file = self.write_log(first + [init, result(2, 1.0)])
        a = out.usage(file, 0, "claude", "sid")
        b = out.usage(file, offset, "claude", "sid")
        self.assertEqual((a["tokens_total"], a["turns"], a["cost_usd"]), (200, 5, 1.0))
        self.assertEqual((b["tokens_total"], b["turns"]), (100, 2))
        self.assertAlmostEqual(b["cost_usd"], 0.2)
        file = self.write_log(first + [init, result(2, 0.1)])
        self.assertIsNone(out.usage(file, offset, "claude", "sid")["cost_usd"])
        file = self.write_log([init, dict(type="result", session_id="sid")])
        unknown = out.usage(file, 0, "claude", "sid")
        self.assertIsNone(unknown["tokens_total"])
        self.assertIsNone(unknown["turns"])
        self.assertIsNone(unknown["cost_usd"])

    def test_codex_cumulative_resume_and_regression(self):
        init = dict(type="thread.started", thread_id="sid")
        turn = dict(type="turn.started")
        def result(n):
            return dict(type="turn.completed", usage=dict(input_tokens=n, cached_input_tokens=n // 2,
                        output_tokens=n // 10, reasoning_output_tokens=n // 20))
        first = [init, turn, result(100)]
        file = self.write_log(first)
        offset = file.stat().st_size
        file = self.write_log(first + [init, turn, result(150)])
        u = out.usage(file, offset, "codex", "sid")
        self.assertEqual((u["input_tokens"], u["tokens_total"], u["turns"]), (50, 55, 1))
        self.assertIsNone(u["cost_usd"])
        self.assertEqual(u["cost_basis"], "unavailable")
        self.assertEqual(out.usage(file, 0, "codex", "sid")["tokens_total"], 165)
        for events in (first + [init, turn, result(50)], [init, turn] + [init, turn, result(150)]):
            file = self.write_log(events)
            run_offset = len((json.dumps(events[0]) + '\n' + json.dumps(events[1]) + '\n').encode()) if len(events) == 5 else offset
            u = out.usage(file, run_offset, "codex", "sid")
            self.assertFalse(u["complete"])
            self.assertIsNone(u["tokens_total"])
        file = self.write_log(first)
        with file.open("a") as f:
            f.write('{"partial":')
        self.assertFalse(out.usage(file, 0, "codex", "sid")["complete"])

    def test_review_reported_counts_and_negative_controls(self):
        meta = dict(task_id=self.task, review_target_task_id=self.task, review_head="abc")
        obj = dict(schema_version=1, target_task_id=self.task, head="abc", round=1,
                   findings=dict(high=0, medium=1, low=0), finding_ids=[dict(id="F1", severity="medium")])
        def text(o):
            return 'REVIEW_OUTCOME: ' + json.dumps(o) + '\nVERDICT: merge after fixes\n'
        good = text(obj)
        data = out.review(meta, "run", good, good)
        self.assertEqual(data["findings"]["medium"], 1)
        self.assertEqual(data["provenance"], "reported_not_adjudicated")
        self.assertIsNone(data["adjudication"])
        zero = obj | dict(findings=dict(high=0, medium=0, low=0), finding_ids=[])
        self.assertEqual(out.review(meta, "run", text(zero), text(zero))["findings"]["high"], 0)
        bad = ["", "REVIEW_OUTCOME: {broken}\nVERDICT: merge", good + good,
               text(obj | dict(target_task_id=str(uuid.uuid4()))), text(obj | dict(head="wrong")),
               text(obj | dict(finding_ids=obj["finding_ids"] * 2)),
               text(obj | dict(findings=dict(high=0, medium=True, low=0))),
               text(obj | dict(findings=dict(high=-1, medium=1, low=0))), text(zero)]
        for other in bad:
            result = out.review(meta, "run", good, other)
            self.assertIsNone(result["findings"], other)
            self.assertTrue(result["diagnostics"])


class Lifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.home = Path(os.environ["AGENT_HUB_HOME"])
        cls.work = cls.home / "w"
        cls.work.mkdir()
        (cls.work / "brief.md").write_text("# Fixture task\n")
        cls.stage = cls.home / "stage-a"
        cls.roles = set()

    @classmethod
    def tearDownClass(cls):
        for role in cls.roles:
            subprocess.run([str(BIN / "agent"), "stop", role], capture_output=True)

    def command(self, *args, env=None, ok=True):
        r = subprocess.run([str(BIN / "agent"), *args], env=os.environ | (env or {}), capture_output=True, text=True)
        if ok:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def spawn(self, role, *flags, env=None):
        self.roles.add(role)
        return self.command("spawn", "--role", role, "--cwd", str(self.work), "--brief", str(self.work / "brief.md"),
                            "--engine", "claude", "--model", "haiku", "--effort", "high", *flags, env=env)

    def meta(self, role):
        return json.loads((self.stage / "agents" / role / "meta.json").read_text())

    def rows(self, role):
        return out.read(out.path(self.stage, self.meta(role)["task_id"]))[0]

    def wait(self, role):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            meta = self.meta(role)
            r = self.command("status", role)
            if "ALIVE" not in r.stdout:
                rows = self.rows(role)
                if any(e["run_id"] == meta["runs"][-1]["id"] and e["type"] in ("run_ended", "run_observed_dead") for e in rows):
                    return rows
            time.sleep(0.1)
        self.fail("fixture did not exit")

    def test_a_spawn_resume_identity_and_auto_close(self):
        r = self.spawn("explicit", "--task-class", "bounded", "--task-kind", "executor", "--change-class", "code",
                       env=dict(FAKE_FINAL="DONE fixture"))
        self.assertNotIn("--task-class omitted", r.stderr)
        rows = self.wait("explicit")
        meta = self.meta("explicit")
        self.assertEqual(meta["task_class"], "bounded")
        self.assertCountEqual([e["type"] for e in rows], ["task_started", "run_started", "run_identity", "run_ended", "task_closed"])
        closure = next(e for e in rows if e["type"] == "task_closed")
        self.assertEqual(closure["source"], "auto_status")
        self.assertEqual(closure["data"]["reported_status"], "DONE")
        # Explicit snapshots survive a mutable effort change; resumes keep the task UUID.
        mp = self.stage / "agents/explicit/meta.json"
        meta["effort"] = "medium"
        mp.write_text(json.dumps(meta))
        self.command("send", "explicit", "continue", "--resume-reason", "review_fix", env=dict(FAKE_FINAL="BLOCKED fixture"))
        rows = self.wait("explicit")
        starts = [e for e in rows if e["type"] == "run_started"]
        self.assertEqual([e["data"]["effort"] for e in starts], ["high", "medium"])
        self.assertEqual(starts[-1]["data"]["resume_reason"], "review_fix")
        self.assertEqual(self.meta("explicit")["task_id"], meta["task_id"])
        self.assertEqual(len([e for e in rows if e["type"] == "task_closed"]), 1)
        old_count = len(rows)
        # A stale wrapper may neither end nor close the latest run (nor replay its unread queue).
        self.command("exit-note", "explicit", "--code", "1", env=dict(AGENT_RUN_ID=starts[0]["run_id"], AGENT_TASK_ID=meta["task_id"]))
        self.assertEqual(len(self.rows("explicit")), old_count)
        self.command("exit-note", "explicit", "--code", "0")
        self.assertEqual(len(self.rows("explicit")), old_count)
        self.command("send", "explicit", "reply", "--resume-reason", "invented", ok=False)

    def test_b_missing_class_reused_role_and_continuation(self):
        r = self.spawn("reuse", env=dict(FAKE_FINAL="DONE fixture"))
        self.assertEqual(r.stderr.count("--task-class omitted"), 1)
        self.wait("reuse")
        old = self.meta("reuse")["task_id"]
        self.assertEqual(self.meta("reuse")["task_class"], "unknown")
        self.spawn("reuse", "--task-class", "mechanical", "--continuation-of", old)
        self.wait("reuse")
        meta = self.meta("reuse")
        self.assertNotEqual(meta["task_id"], old)
        self.assertEqual(meta["continuation_of"], old)
        self.assertTrue(out.path(self.stage, old).exists())
        self.command("spawn", "--role", "bad", "--cwd", str(self.work), "--brief", str(self.work / "brief.md"),
                     "--model", "haiku", "--task-class", "invented", ok=False)
        self.command("spawn", "--role", "bad", "--cwd", str(self.work), "--brief", str(self.work / "brief.md"),
                     "--model", "haiku", "--continuation-of", "../escape", ok=False)

    def test_c_status_words_and_hub_override(self):
        for word in ("DONE", "REVIEWED", "MERGED", "STOP", "EXIT", "BLOCKED", "QUESTION", "PROGRESS"):
            role = "status-" + word.lower()
            self.spawn(role, "--task-class", "mechanical", env=dict(FAKE_FINAL=word + " fixture"))
            rows = self.wait(role)
            closures = [e for e in rows if e["type"] == "task_closed"]
            if word in ("BLOCKED", "QUESTION", "PROGRESS"):
                self.assertEqual(closures, [])
            else:
                self.assertEqual(closures[-1]["data"]["outcome"], "success" if word in ("DONE", "REVIEWED", "MERGED") else "failure")
        old = next(e for e in self.rows("status-done") if e["type"] == "task_closed")
        file = self.work / "override.json"
        data = old["data"] | dict(outcome="failure")
        file.write_text(json.dumps(dict(type="task_closed", event_id="owner-override", data=data)))
        self.command("outcome", "status-done", "--file", str(file))
        latest = self.rows("status-done")[-1]
        self.assertEqual(latest["source"], "hub")
        self.assertEqual(latest["supersedes"], old["event_id"])
        count_before = len(self.rows("status-done"))
        self.command("outcome", "--task-id", self.meta("status-done")["task_id"], "--file", str(file))
        self.assertEqual(len(self.rows("status-done")), count_before)
        file.write_text(json.dumps(dict(type="task_closed", task_id=str(uuid.uuid4()), data=data)))
        self.command("outcome", "status-done", "--file", str(file), ok=False)

    def test_d_kill_recovery_and_init_failure(self):
        self.spawn("kill", "--task-class", "mechanical", env=dict(FAKE_HOLD="60"))
        meta = self.meta("kill")
        os.killpg(meta["pid"], signal.SIGKILL)
        rows = self.wait("kill")
        dead = [e for e in rows if e["type"] == "run_observed_dead"]
        self.assertEqual(len(dead), 1)
        self.assertIsNone(dead[0]["data"]["exit_code"])
        self.assertIsNone(dead[0]["data"]["ended_at"])
        self.assertEqual(rows[-1]["data"]["reported_status"], "EXIT")
        self.command("status", "kill")
        self.assertEqual(len(self.rows("kill")), len(rows))
        self.command("send", "kill", "recover", "--resume-reason", "recovery", env=dict(FAKE_FINAL="DONE recovered"))
        self.assertEqual([e for e in self.wait("kill") if e["type"] == "task_closed"][-1]["data"]["outcome"], "success")
        r = self.command("spawn", "--role", "initfail", "--cwd", str(self.work), "--brief", str(self.work / "brief.md"),
                         "--model", "haiku", "--task-class", "bounded", env=dict(FAKE_CLAUDE="die"), ok=False)
        self.assertIn("exited", r.stderr)
        archived = list((self.stage / "agents").glob("*initfail*"))
        meta = json.loads((archived[0] / "meta.json").read_text())
        rows = out.read(out.path(self.stage, meta["task_id"]))[0]
        self.assertEqual(rows[-1]["type"], "task_closed")
        self.assertEqual(rows[-1]["data"]["outcome"], "failure")
        self.assertEqual([e for e in rows if e["type"] == "run_ended"][0]["data"]["termination_reason"], "init_failure")

    def test_e_reviewer_link_and_legacy(self):
        self.spawn("author", "--task-class", "bounded", env=dict(FAKE_FINAL="DONE author"))
        self.wait("author")
        task = self.meta("author")["task_id"]
        author = reviewers.parse_author("author", "stage-a")
        entry = reviewers.Entry(0, dict(name="test", kind="agent", model="opus", effort="high", engine="claude"))
        line = reviewers.start_line(entry, "stage-a", author.engine, "code", author.task_id)
        self.assertIn("--task-kind review --task-class judgement --change-class code", line)
        self.assertIn("--review-target-task-id " + task, line)
        self.assertNotIn("--review-target-task-id", reviewers.start_line(entry, "stage-a", "codex", "code"))
        self.spawn("review-fixture", "--task-class", "judgement", "--task-kind", "review", "--review-target-task-id", task,
                   env=dict(FAKE_FINAL="VERDICT: merge"))
        rows = self.wait("review-fixture")
        review = next(e for e in rows if e["type"] == "review_observed")
        self.assertIsNone(review["data"]["findings"])
        self.assertTrue(review["data"]["diagnostics"])
        # A legacy agent remains readable and unmodified by both legacy readers.
        meta = self.meta("author")
        for key in ("task_id", "outcome_schema", "task_class", "task_kind", "change_class", "assignment_source"):
            meta.pop(key, None)
        file = self.stage / "agents/author/meta.json"
        file.write_text(json.dumps(meta))
        before = file.read_bytes()
        self.command("status", "author")
        r = subprocess.run([str(BIN / "retro"), "measure", "--out", str(self.work / "retro"), "--exclude-stage", "other"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(file.read_bytes(), before)

    def test_limits_and_journal_only_status(self):
        extra = dict(is_error=True, subtype="error_during_execution", result="You've hit your usage limit")
        self.spawn("limited", "--task-class", "bounded", env=dict(FAKE_FINAL="DONE old text", FAKE_CLAUDE_RESULT_EXTRA=json.dumps(extra)))
        rows = self.wait("limited")
        self.assertFalse(any(e["type"] == "task_closed" for e in rows))
        self.assertEqual(next(e for e in rows if e["type"] == "run_ended")["data"]["termination_reason"], "limit")
        self.spawn("journalonly", "--task-class", "bounded", env=dict(FAKE_FINAL="report written", FAKE_SHELL='"$HUB_BIN/jlog" "DONE fixture report"'))
        rows = self.wait("journalonly")
        self.assertEqual(next(e for e in rows if e["type"] == "task_closed")["data"]["reported_status"], "DONE")
        # An explicit executor kind wins over a review-looking role name.
        self.spawn("review-executor", "--task-class", "bounded", "--task-kind", "executor", env=dict(FAKE_FINAL="report written"))
        self.assertFalse(any(e["type"] == "task_closed" for e in self.wait("review-executor")))

    def test_fixture_export(self):
        extra = dict(usage=dict(input_tokens=62, output_tokens=15783, cache_creation_input_tokens=135901,
                               cache_read_input_tokens=2982021), num_turns=30, total_cost_usd=1.9995202)
        self.spawn("claude-example", "--task-class", "judgement", "--task-kind", "executor", "--change-class", "code",
                   env=dict(FAKE_FINAL="DONE fixture", FAKE_CLAUDE_RESULT_EXTRA=json.dumps(extra)))
        rows = self.wait("claude-example")
        usage = next(e for e in rows if e["type"] == "run_ended")["data"]["usage"]
        self.assertEqual(usage["tokens_total"], 3133767)
        self.assertEqual(usage["turns"], 30)
        self.assertEqual(usage["cost_usd"], 1.9995202)
        if os.environ.get("MODEL_OUTCOME_EXAMPLES"):
            dest = Path(os.environ["MODEL_OUTCOME_EXAMPLES"])
            dest.mkdir(parents=True, exist_ok=True)
            for role in ("claude-example", "codex", "status-exit"):
                dest.joinpath(role + ".jsonl").write_bytes(out.path(self.stage, self.meta(role)["task_id"]).read_bytes())

    def test_f_codex_real_launch_and_resume(self):
        self.roles.add("codex")
        self.command("spawn", "--role", "codex", "--cwd", str(self.work), "--brief", str(self.work / "brief.md"),
                     "--engine", "codex", "--model", "gpt-6.1-sol", "--effort", "medium", "--task-class", "bounded",
                     env=dict(FAKE_CODEX_FINAL="DONE fixture"))
        rows = self.wait("codex")
        run = next(e for e in rows if e["type"] == "run_ended")
        self.assertEqual(run["data"]["usage"]["tokens_total"], 130)
        self.assertEqual(run["data"]["usage"]["turns"], 1)
        self.assertIsNone(run["data"]["usage"]["cost_usd"])
        self.command("send", "codex", "reply", env=dict(FAKE_CODEX_FINAL="DONE fixture"))
        rows = self.wait("codex")
        runs = [e for e in rows if e["type"] == "run_ended"]
        self.assertEqual(runs[-1]["data"]["usage"]["tokens_total"], 0)  # same cumulative fixture totals
        self.assertEqual(len([e for e in rows if e["type"] == "task_started"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
