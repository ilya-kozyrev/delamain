#!/bin/bash
# A retrospective reads a throwaway home, bounds evidence, and exposes judgments rather than guessing them.
. "$(dirname "$0")/lib.sh"
set -e
new_home
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export RETRO_TEST_BIN="$B"
export RETRO_TEST_OUT="$(mktemp -d)"
python3 - <<'PY'
import csv
import datetime as dt
import hashlib
import importlib.machinery
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys

home, out, b = map(lambda x: Path(os.environ[x]), ('AGENT_HUB_HOME', 'RETRO_TEST_OUT', 'RETRO_TEST_BIN'))
def put(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value) if not isinstance(value, str) else value)
def jl(p, rows):
    put(p, '\n'.join(json.dumps(r) for r in rows) + '\n')
def run(*args, ok=True):
    p = subprocess.run([str(b/'retro'), *map(str,args)], capture_output=True, text=True)
    assert (p.returncode == 0) == ok, (p.returncode,p.stdout,p.stderr,args)
    return p
def data(p):
    return json.loads((p/'metrics.json').read_text())['metrics']
def rows(p, name):
    with (p/(name+'.csv')).open() as f:
        return list(csv.DictReader(f))
def value(m, key):
    return m[key]['value']
def snapshot():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}

def test_r1_1_headless_hub_cost():
    """R1-1: registered headless SIDs have one cost owner, including retired runs."""
    isolated = out/'r1-1-home'
    stage = isolated/'headless'
    config = out/'r1-1-claude'
    saved = {key: os.environ.get(key) for key in ('AGENT_HUB_HOME', 'CLAUDE_CONFIG_DIR')}
    sid_a = '11111111-1111-2222-3333-444444444444'
    sid_b = '22222222-1111-2222-3333-444444444444'
    registration = dict(tag='hub-31', engine='claude', kind='headless',
                        set_at='2026-01-01T00:00:00Z', cli_session_id=sid_a)
    put(stage/'roles.json', {'roles': {'hub': registration}, 'retired': []})
    put(stage/'agents/hub-31/meta.json', dict(role='hub-31', tag='hub-31', engine='claude',
        session_id=sid_a, cli_session_id=sid_a, started_at='2026-01-01T00:00:00Z'))
    put(stage/'coordinator/work/journal-2026-01-01.md', '- 02:00 [hub-31] MERGED MR !31\n')
    # Twelve independent price points fit the same known rates as the main fixture.
    calibration = []
    for i in range(12):
        tokens = [(i+1)**k*100 for k in range(1, 5)]
        cost = sum(x*y for x, y in zip(tokens, [2, 10, .2, 3]))/1e6
        calibration.append(dict(type='result', session_id=sid_a, total_cost_usd=5,
            modelUsage={'claude-test': dict(zip(
                ['inputTokens', 'outputTokens', 'cacheReadInputTokens', 'cacheCreationInputTokens'], tokens), costUSD=cost)}))
    def transcript(sid, cost):
        jl(config/'projects/headless'/f'{sid}.jsonl', [dict(type='assistant',
            timestamp='2026-01-01T01:00:00Z', sessionId=sid,
            message=dict(id=sid, model='claude-test', content=[],
                         usage={'input_tokens': int(cost*1e6/2)}))])
    def measure(label, total, hub_cost):
        target = out/('r1-1-'+label)
        run('measure', '--out', target, '--since', '2026-01-01', '--until', '2026-01-02')
        metrics = data(target)
        for key, expected in {'cost.total_usd': total, 'hubs.cost_usd': hub_cost,
                              'agents.claude.cost_usd': total-hub_cost,
                              'cost.hub_share': hub_cost/total, 'cost.per_merge_usd': total,
                              'flow.merged_observed': 1}.items():
            actual = value(metrics, key)
            assert actual is not None and math.isclose(actual, expected, abs_tol=1e-8), ('R1-1', label, key, actual, expected)
        assert math.isclose(sum(float(r.get('cost_usd') or 0) for r in rows(target, 'hubs')), hub_cost), 'R1-1 hub CSV must have a single cost source per SID'
    try:
        os.environ.update(AGENT_HUB_HOME=str(isolated), CLAUDE_CONFIG_DIR=str(config))
        jl(stage/'agents/hub-31/log.jsonl', calibration)
        transcript(sid_a, 5)
        measure('current', 5, 5)

        # A resumed SID is cumulative (1 -> 3); a new SID contributes another $2.
        calibration = [dict(row, total_cost_usd=1 if i == 0 else 3) for i, row in enumerate(calibration)]
        jl(stage/'agents/hub-31/log.jsonl', calibration + [dict(type='result', session_id=sid_b, total_cost_usd=2)])
        transcript(sid_a, 3)
        transcript(sid_b, 2)
        current = dict(registration, cli_session_id=sid_b, set_at='2026-01-01T00:30:00Z')
        retired_a = dict(registration, role='hub', retired_at='2026-01-01T00:30:00Z')
        retired_b = dict(current, role='hub', retired_at='2026-01-01T01:30:00Z')
        put(stage/'roles.json', {'roles': {'hub': current}, 'retired': [retired_a, retired_b]})
        put(stage/'agents/hub-31/meta.json', dict(role='hub-31', tag='hub-31', engine='claude',
            session_id=sid_b, cli_session_id=sid_b, started_at='2026-01-01T00:00:00Z'))
        measure('retired-and-current', 5, 5)

        # A distinct worker is a negative control against dropping all agent costs.
        put(stage/'agents/build/meta.json', dict(role='build', engine='claude',
            session_id='unrelated-worker', started_at='2026-01-01T00:00:00Z'))
        jl(stage/'agents/build/log.jsonl', [dict(type='result', session_id='unrelated-worker', total_cost_usd=3)])
        measure('unrelated-worker', 8, 5)
    finally:
        for key, previous in saved.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous
    print('PASS R1-1 headless hub cost: current, retired, cumulative SIDs, unrelated worker')

def test_r1_2_run_tag_and_uncertainty():
    """R1-2: custom tags bind terminal evidence; inferred endings stay reviewable."""
    isolated = (out/'r1-2-home').resolve()
    stage = isolated/'waiting'
    journal = stage/'coordinator/work/journal-2026-01-01.md'
    previous = os.environ.get('AGENT_HUB_HOME')
    put(stage/'roles.json', {'roles': {'hub': dict(tag='hub-1', engine='claude',
        set_at='2026-01-01T00:00:00Z')}, 'retired': []})
    put(stage/'agents/build/meta.json', dict(role='build', tag='hub-1-build', engine='claude',
        started_at='2026-01-01T00:00:00Z'))
    put(stage/'agents/next/meta.json', dict(role='next', tag='hub-1-next', engine='claude',
        started_at='2026-01-01T12:00:00Z'))
    start = '- 00:00 [hub-1] started headless agent build (sonnet/high)\n'
    next_start = '- 12:00 [hub-1] started headless agent next (sonnet/high)\n'
    def measure(label, text):
        put(journal, text)
        target = out/('r1-2-'+label)
        run('measure', '--out', target, '--since', '2026-01-01', '--until', '2026-01-02')
        return target
    def covered(gaps, start_hour, end_hour):
        left = dt.datetime(2026, 1, 1, start_hour, tzinfo=dt.timezone.utc)
        right = dt.datetime(2026, 1, 1, end_hour, tzinfo=dt.timezone.utc)
        return [(row, (min(right, dt.datetime.fromisoformat(row['end'])) -
                       max(left, dt.datetime.fromisoformat(row['start']))).total_seconds()/3600)
                for row in gaps
                if dt.datetime.fromisoformat(row['start']) < right and left < dt.datetime.fromisoformat(row['end'])]
    def uncertain(target, start_hour, end_hour):
        overlap = covered(rows(target, 'gaps'), start_hour, end_hour)
        assert math.isclose(sum(hours for _, hours in overlap), end_hour-start_hour), ('R1-2 missing gap coverage', overlap)
        assert all(row['needs_review'].lower() == 'true' for row, _ in overlap), ('R1-2 inferred wait was confirmed', overlap)
        assert all(row['class'] != 'legit wait' for row, _ in overlap), ('R1-2 heuristic ending is not evidence', overlap)
    try:
        os.environ['AGENT_HUB_HOME'] = str(isolated)
        target = measure('custom-tag', start+'- 01:00 [hub-1-build] DONE implemented\n'+next_start)
        uncertain(target, 1, 12)
        # The matching terminal positively proves exactly the preceding run interval.
        confirmed = covered(rows(target, 'gaps'), 0, 1)
        assert math.isclose(sum(hours for _, hours in confirmed), 1), ('R1-2 missing proven run', confirmed)
        assert all(row['class'] == 'legit wait' and row['needs_review'].lower() == 'false'
                   for row, _ in confirmed), ('R1-2 matching DONE must confirm wait', confirmed)
        ready = [row for row in rows(target, 'ready') if row['source'] == str(journal)+':2']
        assert len(ready) == 1 and ready[0]['id'] == str(journal)+':2', ('R1-2 custom-tag DONE missing from ready.csv', ready)
        assert dt.datetime.fromisoformat(ready[0]['at']).hour == 1 and dt.datetime.fromisoformat(ready[0]['next_start']).hour == 12
        assert float(ready[0]['hours']) == 11, ('R1-2 next executor start', ready)

        target = measure('missing-terminal-cap', start+next_start)
        uncertain(target, 0, 12)
        target = measure('missing-terminal-own-line', start+'- 10:00 [hub-1-build] still working\n'+next_start)
        uncertain(target, 0, 12)

        # A separately proven parallel run suppresses readiness while it is active.
        put(stage/'agents/parallel/meta.json', dict(role='parallel', tag='hub-1-parallel', engine='claude',
            started_at='2026-01-01T00:30:00Z'))
        target = measure('proven-parallel', start+
            '- 00:30 [hub-1] started headless agent parallel (sonnet/high)\n'+
            '- 01:00 [hub-1-build] DONE implemented\n'+
            '- 02:00 [hub-1-parallel] DONE parallel work\n'+next_start)
        assert not any(row['source'] == str(journal)+':3' for row in rows(target, 'ready')), 'R1-2 proven parallel executor must exclude readiness'
        assert any(row['source'] == str(journal)+':4' for row in rows(target, 'ready')), 'R1-2 final parallel DONE must expose readiness'
    finally:
        if previous is None:
            os.environ.pop('AGENT_HUB_HOME', None)
        else:
            os.environ['AGENT_HUB_HOME'] = previous
    print('PASS R1-2 custom run tags, confirmed terminals, uncertain caps and own lines, proven parallel exclusion')

def test_r1_3_distinct_owner_touches():
    """R1-3: proximity alone cannot erase distinct owner decisions or requests."""
    isolated = (out/'r1-3-home').resolve()
    stage = isolated/'requests'
    config = (out/'r1-3-claude').resolve()
    sid = '33333333-1111-2222-3333-444444444444'
    transcript = config/'projects/requests'/f'{sid}.jsonl'
    journal = stage/'coordinator/work/journal-2026-01-01.md'
    saved = {key: os.environ.get(key) for key in ('AGENT_HUB_HOME', 'CLAUDE_CONFIG_DIR')}
    put(stage/'roles.json', {'roles': {'hub': dict(tag='hub-1', engine='claude',
        set_at='2026-01-01T00:00:00Z', cli_session_id=sid)}, 'retired': []})
    def typed(text):
        jl(transcript, [dict(type='user', timestamp='2026-01-01T10:00:00Z',
                            message={'content': text})])
    def measure(label, count):
        target = out/('r1-3-'+label)
        run('measure', '--out', target, '--since', '2026-01-01', '--until', '2026-01-02')
        touches = rows(target, 'touches')
        assert len(touches) == count and value(data(target), 'touches.count') == count, ('R1-3', label, count, touches)
        assert all(row['needs_review'].lower() == 'true' for row in touches), ('R1-3 classifications still require evidence', touches)
        return touches
    try:
        os.environ.update(AGENT_HUB_HOME=str(isolated), CLAUDE_CONFIG_DIR=str(config))
        put(journal, '- 10:00 [owner] Approve feature A\n- 10:10 [owner] Start a separate feature B\n')
        touches = measure('distinct-journal', 2)
        assert {row['text'] for row in touches} == {'Approve feature A', 'Start a separate feature B'}

        typed('Approve feature A')
        put(journal, '- 10:10 [owner] Start a separate feature B\n')
        touches = measure('distinct-transcript-journal', 2)
        assert {row['text'] for row in touches} == {'Approve feature A', 'Start a separate feature B'}
        assert any(str(transcript.resolve()) in row['source'] for row in touches)
        assert any(str(journal.resolve()) in row['source'] for row in touches)

        put(journal, '- 10:10 [owner] Approve feature A\n')
        touches = measure('confirmed-copy', 1)
        assert touches[0]['text'] == 'Approve feature A'
        assert str(transcript.resolve()) in touches[0]['source'] and str(journal.resolve()) in touches[0]['source'], 'R1-3 confirmed copy must retain both evidence sources'

        # Two date-only answers are independent decisions even with identical answer text.
        put(journal, '- 10:10 [owner] Start a separate feature B\n')
        put(stage/'questions.md', '''# Questions
## Q-R-001 — Approve the separate deployment
- asked: 2026-01-01 08:00
- status: answered: yes (2026-01-01)
## Q-R-002 — Approve the unrelated hiring plan
- asked: 2026-01-01 09:00
- status: answered: yes (2026-01-01)
''')
        touches = measure('independent-date-only-answers', 4)
        assert {'requests/Q-R-001', 'requests/Q-R-002'} <= {row['id'] for row in touches}, ('R1-3 date-only answers lost', touches)
        assert {'Approve feature A', 'Start a separate feature B'} <= {row['text'] for row in touches}

        put(stage/'questions.md', '# Questions\n')
        jl(transcript, [])
        put(journal, '- 10:00 [owner] Approve feature A\n')
        put(isolated/'other/roles.json', {'roles': {}, 'retired': []})
        put(isolated/'other/coordinator/work/journal-2026-01-01.md', '- 10:00 [owner] Approve feature A\n')
        touches = measure('same-content-different-stages', 2)
        assert {row['stage'] for row in touches} == {'requests', 'other'}, 'R1-3 stage identity must survive equal content and timestamps'
    finally:
        for key, previous in saved.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous
    print('PASS R1-3 distinct owner messages, confirmed copies, date-only answers, stage identity')

def test_r1_4_journal_item_joins():
    """R1-4: journal-only item keys join evidence without guessing repositories."""
    previous = os.environ.get('AGENT_HUB_HOME')
    def fixture(label):
        isolated = (out/('r1-4-home-'+label)).resolve()
        stage = isolated/'joins'
        put(stage/'roles.json', {'roles': {'hub': dict(tag='hub-1',
            set_at='2026-01-01T00:00:00Z')}, 'retired': []})
        put(isolated/'queue/roles.json', {'roles': {}, 'retired': []})
        os.environ['AGENT_HUB_HOME'] = str(isolated)
        return isolated, stage
    def agent(stage, role):
        put(stage/f'agents/{role}/meta.json', dict(role=role, tag=role, engine='claude',
            started_at='2026-01-01T00:00:00Z'))
    def measure(label):
        target = out/('r1-4-'+label)
        run('measure', '--out', target, '--since', '2026-01-01', '--until', '2026-01-02')
        return rows(target, 'flow')
    try:
        for label, item in [('bare', 'PR #7'), ('url', 'https://github.com/org/project/pull/7')]:
            isolated, stage = fixture(label)
            agent(stage, 'build')
            put(stage/'coordinator/work/journal-2026-01-01.md',
                '- 00:00 [hub-1] started headless agent build (sonnet/high)\n'+
                f'- 01:00 [build] DONE {item} implemented\n'+
                f'- 01:30 [review] REVIEWED {item} approved\n'+
                f'- 01:35 [hub-1-await] @hub PASSED {item} — https://ci.example/run/7 (exit 0, 10m, log /tmp/ci)\n'+
                f'- 02:00 [hub-1] MERGED {item}\n')
            put(isolated/'queue/coordinator/work/journal-2026-01-01.md',
                f'- 01:40 [joins-hub-1] @hub ready {item} for merge\n')
            flow = measure(label)
            assert len(flow) == 1, ('R1-4 item identity', label, flow)
            row = flow[0]
            assert row['exec_role'] == 'build', ('R1-4 executor join', label, row)
            assert dt.datetime.fromisoformat(row['spawn']) == dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc), ('R1-4 spawn', label, row)
            for key, expected in {'lead_h': 2, 'build_h': 1, 'review_rounds': 1,
                                  'review_h': .5, 'ci_awaits': 1, 'ci_min': 10, 'queue_h': 1/3}.items():
                assert row[key] and math.isclose(float(row[key]), expected, abs_tol=1e-8), ('R1-4', label, key, row[key], expected)

        isolated, stage = fixture('repo-ambiguity')
        url_a = 'https://github.com/org/repo-a/pull/7'
        url_b = 'https://github.com/org/repo-b/pull/7'
        for role in ('build-a', 'build-b', 'build-ambiguous'):
            agent(stage, role)
        put(stage/'coordinator/work/journal-2026-01-01.md',
            '- 00:40 [build-ambiguous] DONE PR #7 unqualified work\n'+
            f'- 01:00 [build-a] DONE {url_a} implemented A\n'+
            f'- 01:10 [build-b] DONE {url_b} implemented B\n'+
            f'- 01:20 [review-a] REVIEWED {url_a} approved A\n'+
            f'- 01:30 [review-b] REVIEWED {url_b} approved B\n'+
            '- 01:40 [review-ambiguous] REVIEWED PR #7 ambiguous review\n'+
            f'- 01:45 [hub-1-await] @hub PASSED {url_a} — https://ci.example/a (exit 0, 10m, log /tmp/a)\n'+
            f'- 01:50 [hub-1-await] @hub PASSED {url_b} — https://ci.example/b (exit 0, 20m, log /tmp/b)\n'+
            '- 01:55 [hub-1-await] @hub PASSED PR #7 — https://ci.example/unknown (exit 0, 30m, log /tmp/unknown)\n'+
            f'- 02:00 [hub-1] MERGED {url_a}\n'+
            f'- 02:05 [hub-1] MERGED {url_b}\n'+
            '- 02:10 [hub-1] MERGED PR #7 ambiguous observation\n')
        flow = measure('repo-ambiguity')
        assert len(flow) == 3 and len({row['id'] for row in flow}) == 3, ('R1-4 distinct repository keys', flow)
        for line, role, ci_minutes in [(10, 'build-a', 10), (11, 'build-b', 20)]:
            source = str(stage/'coordinator/work/journal-2026-01-01.md')+f':{line}'
            matches = [row for row in flow if row['source'] == source]
            assert len(matches) == 1, ('R1-4 qualified item missing', source, flow)
            row = matches[0]
            assert row['exec_role'] == role, ('R1-4 cross-repository executor join', row)
            assert int(row['review_rounds']) == 1 and int(row['ci_awaits']) == 1, ('R1-4 ambiguous bare evidence must not join', row)
            assert float(row['ci_min']) == ci_minutes, ('R1-4 cross-repository CI join', row)
        ambiguous = [row for row in flow if row['source'] == str(stage/'coordinator/work/journal-2026-01-01.md')+':12']
        assert len(ambiguous) == 1 and not ambiguous[0]['exec_role'] and ambiguous[0]['needs_review'].lower() == 'true', ('R1-4 bare number must remain ambiguous', ambiguous)
    finally:
        if previous is None:
            os.environ.pop('AGENT_HUB_HOME', None)
        else:
            os.environ['AGENT_HUB_HOME'] = previous
    print('PASS R1-4 bare and qualified journal joins, review/CI/queue timing, repository ambiguity')

def test_r1_5_half_open_hub_overlap():
    """R1-5: hub registrations intersect retrospective windows as [start, end)."""
    previous = os.environ.get('AGENT_HUB_HOME')
    def scenario(label, start, end, expected_hours, since='2026-01-02', until='2026-01-03'):
        isolated = (out/('r1-5-home-'+label)).resolve()
        stage = isolated/'boundary'
        put(stage/'roles.json', {'roles': {}, 'retired': [dict(role='hub', tag='hub-1',
            engine='claude', set_at=start, retired_at=end)]})
        put(stage/f'coordinator/work/journal-{since}.md', '- 12:00 [hub-1] MERGED PR #5\n')
        os.environ['AGENT_HUB_HOME'] = str(isolated)
        target = out/('r1-5-'+label)
        run('measure', '--out', target, '--since', since, '--until', until)
        metrics, hubs = data(target), rows(target, 'hubs')
        count = int(expected_hours > 0)
        assert value(metrics, 'hubs.registered') == count and len(hubs) == count, ('R1-5', label, hubs, metrics['hubs.registered'])
        assert value(metrics, 'flow.merged_observed') == 1, ('R1-5 merge positive control', label)
        registered_hours = sum(float(row['registered_h']) for row in hubs)
        assert math.isclose(registered_hours, expected_hours, abs_tol=1e-10), ('R1-5 clipped overlap', label, registered_hours, expected_hours)
        assert value(metrics, 'flow.per_shift') == (1 if count else None), ('R1-5 shift denominator', label, metrics['flow.per_shift'])
    try:
        scenario('end-at-since', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 0)
        scenario('previous-window', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 24,
                 since='2026-01-01', until='2026-01-02')
        scenario('one-second-overlap', '2026-01-01T00:00:00Z', '2026-01-02T00:00:01Z', 1/3600)
        scenario('start-at-until', '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z', 0)
        scenario('end-before-since', '2026-01-01T00:00:00Z', '2026-01-01T23:59:59Z', 0)
    finally:
        if previous is None:
            os.environ.pop('AGENT_HUB_HOME', None)
        else:
            os.environ['AGENT_HUB_HOME'] = previous
    print('PASS R1-5 half-open registration boundaries, prior window, one-second overlap, shift denominator')

def test_r1_6_missing_classifications():
    """R1-6: missing classification directories cannot erase reviewed results."""
    previous = os.environ.get('AGENT_HUB_HOME')
    isolated = (out/'r1-6-home').resolve()
    target = out/'r1-6-measured'
    classifications = out/'r1-6-classifications'
    empty = out/'r1-6-empty-classifications'
    empty.mkdir()
    classifications.mkdir()
    put(isolated/'classified/roles.json', {'roles': {}, 'retired': []})
    put(isolated/'classified/coordinator/work/journal-2026-01-01.md',
        '- 10:00 [owner] Please continue the implementation\n')
    def snapshot_outputs():
        return {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in target.rglob('*') if p.is_file()}
    def rejected(label, *args, destination=target):
        result = run('measure', '--out', destination, *args, ok=False)
        error = (result.stdout+'\n'+result.stderr).lower()
        assert 'classif' in error and 'director' in error, ('R1-6 actionable directory error', label, error)
        assert snapshot_outputs() == reviewed, ('R1-6 classified outputs modified on failure', label)
    try:
        os.environ['AGENT_HUB_HOME'] = str(isolated)
        run('measure', '--out', target, '--since', '2026-01-01', '--until', '2026-01-02',
            '--classifications', empty)
        assert value(data(target), 'touches.count') == 1 and value(data(target), 'touches.nudge') is None
        touches = rows(target, 'touches')
        touches[0].update(needs_review='false', **{'class': 'nudge', 'evidence': 'fixture owner request verified'})
        with (classifications/'touches.csv').open('w') as f:
            writer = csv.DictWriter(f, fieldnames=touches[0].keys())
            writer.writeheader()
            writer.writerows(touches)
        # Other classification families are intentionally absent: partial directories are supported.
        run('measure', '--out', target, '--classifications', classifications)
        assert value(data(target), 'touches.nudge') == 1, 'R1-6 partial directory must apply classification'
        reviewed = snapshot_outputs()
        assert 'metrics.json' in reviewed and 'window.json' in reviewed and 'touches.csv' in reviewed

        classifications.rename(out/'r1-6-moved-classifications')
        rejected('saved-missing-directory')
        rejected('explicit-missing-directory', '--classifications', out/'r1-6-typo')
        regular_file = out/'r1-6-regular-file'
        put(regular_file, 'This path is a file, not a classification directory.\n')
        rejected('explicit-regular-file', '--classifications', regular_file)
        fresh = out/'r1-6-invalid-new-output'
        rejected('new-output-missing-directory', '--since', '2026-01-01', '--until', '2026-01-02',
                 '--classifications', out/'r1-6-typo', destination=fresh)
        assert not any(p.is_file() for p in fresh.rglob('*')), 'R1-6 invalid directory must not produce result files'

        # An explicit existing empty directory is a deliberate request to measure without classifications.
        run('measure', '--out', target, '--classifications', empty)
        assert value(data(target), 'touches.count') == 1 and value(data(target), 'touches.nudge') is None
        assert rows(target, 'touches')[0]['needs_review'].lower() == 'true'
    finally:
        if previous is None:
            os.environ.pop('AGENT_HUB_HOME', None)
        else:
            os.environ['AGENT_HUB_HOME'] = previous
    print('PASS R1-6 partial/empty classification directories, missing saved/explicit paths, immutable failed outputs')

def test_r1_7_fractional_window():
    """R1-7: persisted window precision preserves fractional half-open boundaries."""
    saved = {key: os.environ.get(key) for key in ('AGENT_HUB_HOME', 'CLAUDE_CONFIG_DIR')}
    def scenario(label, since, until):
        isolated = (out/('r1-7-home-'+label)).resolve()
        config = (out/('r1-7-claude-'+label)).resolve()
        stage = isolated/'precision'
        sid = '77777777-1111-2222-3333-444444444444'
        start = dt.datetime.fromisoformat(since.replace('Z', '+00:00'))
        end = dt.datetime.fromisoformat(until.replace('Z', '+00:00'))
        middle = start+(end-start)/2
        put(stage/'roles.json', {'roles': {'hub': dict(tag='hub-1', engine='claude',
            set_at=since, cli_session_id=sid)}, 'retired': []})
        put(stage/'agents/build/meta.json', dict(role='build', engine='claude',
            started_at=middle.isoformat()))
        transcript = [dict(type='user', timestamp=since, message={'content': 'Include owner at since'})]
        for index, timestamp in enumerate((since, middle.isoformat(), until)):
            transcript.append(dict(type='assistant', timestamp=timestamp,
                message=dict(id=f'message-{index}', model='claude-test', content=[],
                             usage={'input_tokens': 1})))
        transcript.append(dict(type='user', timestamp=until, message={'content': 'Exclude owner at until'}))
        jl(config/'projects/precision'/f'{sid}.jsonl', transcript)
        os.environ.update(AGENT_HUB_HOME=str(isolated), CLAUDE_CONFIG_DIR=str(config))
        target = out/('r1-7-'+label)
        def window():
            stored = json.loads((target/'window.json').read_text())
            actual_start = dt.datetime.fromisoformat(stored['since'])
            actual_end = dt.datetime.fromisoformat(stored['until'])
            assert actual_start == start and actual_end == end and actual_start != actual_end, ('R1-7 window precision', label, stored)
            expected_days = (end-start).total_seconds()/86400
            assert math.isclose(stored['days'], expected_days, rel_tol=1e-12, abs_tol=1e-16), ('R1-7 fractional duration', label, stored['days'], expected_days)
            return stored['since'], stored['until'], stored['days']
        run('plan', '--out', target, '--since', since, '--until', until)
        planned = window()
        for repetition in range(2):
            # Both measurements consume the persisted boundaries without overriding them.
            run('measure', '--out', target)
            assert window() == planned, ('R1-7 window changed during measure', label, repetition)
            metrics = data(target)
            assert value(metrics, 'agents.count') == 1, ('R1-7 fractional agent start lost', label, metrics['agents.count'])
            assert value(metrics, 'hubs.messages') == 2, ('R1-7 since included/until excluded', label, metrics['hubs.messages'])
            assert value(metrics, 'touches.count') == 1, ('R1-7 owner boundary inclusion', label, metrics['touches.count'])
            assert rows(target, 'touches')[0]['text'] == 'Include owner at since'
    try:
        scenario('fractional', '2026-01-01T00:00:00.1Z', '2026-01-01T00:00:00.9Z')
        scenario('microseconds', '2026-01-01T00:00:00.123456Z', '2026-01-01T00:00:00.923456Z')
        scenario('whole-seconds', '2026-01-01T00:00:00Z', '2026-01-01T00:00:01Z')
    finally:
        for key, previous in saved.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous
    print('PASS R1-7 fractional/microsecond/whole-second windows, persisted reruns, half-open event boundaries')

def test_r2_1_resumed_hub_cost():
    """R2-1: an older result cannot understate a resumed session's fitted cost."""
    saved = {key: os.environ.get(key) for key in ('AGENT_HUB_HOME', 'CLAUDE_CONFIG_DIR')}
    def scenario(label, known_cost, fitted_cost, worker_cost=0):
        isolated = (out/('r2-1-home-'+label)).resolve()
        config = (out/('r2-1-claude-'+label)).resolve()
        stage = isolated/'resumed'
        sid = '88888888-1111-2222-3333-444444444444'
        put(stage/'roles.json', {'roles': {'hub': dict(tag='hub-41', engine='claude',
            kind='headless', set_at='2026-01-01T00:00:00Z', cli_session_id=sid)}, 'retired': []})
        put(stage/'agents/hub-41/meta.json', dict(role='hub-41', tag='hub-41', engine='claude',
            session_id=sid, cli_session_id=sid, started_at='2026-01-01T00:00:00Z',
            runs=[{'at': '2026-01-01T00:00:00Z'}, {'at': '2026-01-01T01:00:00Z'}]))
        put(stage/'coordinator/work/journal-2026-01-01.md', '- 03:00 [hub-41] MERGED PR #41\n')
        log = []
        for i in range(12):
            tokens = [(i+1)**k*100 for k in range(1, 5)]
            price = sum(x*y for x, y in zip(tokens, [2, 10, .2, 3]))/1e6
            log.append(dict(type='result', timestamp='2026-01-01T00:30:00Z', session_id=sid,
                total_cost_usd=known_cost, modelUsage={'claude-test': dict(zip(
                    ['inputTokens', 'outputTokens', 'cacheReadInputTokens', 'cacheCreationInputTokens'], tokens), costUSD=price)}))
        log.append(dict(type='system', subtype='init', timestamp='2026-01-01T01:00:00Z', session_id=sid))
        if fitted_cost is not None and known_cost > fitted_cost:
            log.append(dict(type='result', timestamp='2026-01-01T02:00:00Z', session_id=sid, total_cost_usd=known_cost))
        jl(stage/'agents/hub-41/log.jsonl', log)
        if fitted_cost is not None:
            # The same SID spent $1 before resuming, then another $4 without a new result.
            costs = [1, fitted_cost-1] if fitted_cost > 1 else [fitted_cost]
            jl(config/'projects/resumed'/f'{sid}.jsonl', [dict(type='assistant',
                timestamp=f'2026-01-01T0{index}:30:00Z', sessionId=sid,
                message=dict(id=f'resumed-{index}', model='claude-test', content=[],
                    usage={'input_tokens': int(cost*1e6/2)})) for index, cost in enumerate(costs)])
        if worker_cost:
            put(stage/'agents/build/meta.json', dict(role='build', engine='claude',
                session_id='distinct-worker', started_at='2026-01-01T00:00:00Z'))
            jl(stage/'agents/build/log.jsonl', [dict(type='result', session_id='distinct-worker', total_cost_usd=worker_cost)])
        os.environ.update(AGENT_HUB_HOME=str(isolated), CLAUDE_CONFIG_DIR=str(config))
        target = out/('r2-1-'+label)
        run('measure', '--out', target, '--since', '2026-01-01', '--until', '2026-01-02')
        metrics = data(target)
        hub_cost = max(known_cost, fitted_cost or 0)
        total = hub_cost+worker_cost
        for key, expected in {'hubs.cost_usd': hub_cost, 'cost.total_usd': total,
                              'cost.per_merge_usd': total, 'agents.claude.cost_usd': worker_cost,
                              'cost.hub_share': hub_cost/total}.items():
            actual = value(metrics, key)
            assert actual is not None and math.isclose(actual, expected, abs_tol=1e-8), ('R2-1', label, key, actual, expected)
        hubs = rows(target, 'hubs')
        assert len(hubs) == 1 and math.isclose(float(hubs[0]['cost_usd']), hub_cost), ('R2-1 single SID cost owner', label, hubs)
        if fitted_cost is not None and fitted_cost > known_cost:
            assert 'fitted' in hubs[0]['cost_source'].lower(), ('R2-1 fitted cost provenance', label, hubs)
    try:
        scenario('resumed-no-new-result', 1, 5)
        scenario('current-result-partial-transcript', 5, 1)
        scenario('missing-transcript', 1, None)
        scenario('resumed-with-distinct-worker', 1, 5, worker_cost=3)
    finally:
        for key, previous in saved.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous
    print('PASS R2-1 resumed SID fitted cost, current result, missing transcript, distinct worker')

regression = os.environ.get('RETRO_REGRESSION')
if regression in (None, '1'):
    test_r1_1_headless_hub_cost()
if regression in (None, '2'):
    test_r1_2_run_tag_and_uncertainty()
if regression in (None, '3'):
    test_r1_3_distinct_owner_touches()
if regression in (None, '4'):
    test_r1_4_journal_item_joins()
if regression in (None, '5'):
    test_r1_5_half_open_hub_overlap()
if regression in (None, '6'):
    test_r1_6_missing_classifications()
if regression in (None, '7'):
    test_r1_7_fractional_window()
if regression in (None, '2-1'):
    test_r2_1_resumed_hub_cost()
if regression in ('1', '2', '3', '4', '5', '6', '7', '2-1'):
    sys.exit(0)

st = home/'alpha'
sid='aaaaaaaa-1111-2222-3333-444444444444'
put(st/'roles.json', {'roles':{'hub':{'tag':'hub-1','engine':'claude','set_at':'2026-01-01T00:00:00Z','cli_session_id':sid}},'retired':[]})
put(home/'beta/roles.json', {'roles':{},'retired':[{'role':'hub','tag':'hub-2','set_at':'2026-01-01T00:00:00Z','retired_at':'2026-01-02T12:00:00Z'}]})
put(home/'beta/stage.json', {'closed':{'at':'2026-01-02T12:00:00Z','why':'finished'}})
put(st/'coordinator/work/journal-2026-01-01.md', '''# Journal
- 00:00 [hub-1] started headless agent build (sonnet/high)
- 01:00 [build] DONE MR !7 implemented
- 01:01 [build] DONE same finish
- 01:02 [hub-1] accepted
- 01:04 [build] discussing DONE is not a terminal event
- 01:05 [hub-1-await] @hub FAILED MR !7 — https://forge/a/merge_requests/7 (exit 1, 2m30s, log /tmp/x)
- 01:06 [hub-1] @hub FAILED quoted await (exit 1, 2m30s, log /tmp/x)
- 01:07 [hub-1-await] @hub PASSED MR !7 — https://forge/a/merge_requests/7 (exit 0, 1h2m3s, log /tmp/x)
- 01:08 [hub-1-await] @hub FAILED train MR !99 (killed by signal 15 after 3m, log /tmp/x)
- 02:00 [hub-1] MERGED MR !7
- 02:01 [hub-1] started headless agent next (sonnet/high)
- 03:00 [next] DONE next item
- 03:01 [hub-1] ready
- 04:00 [watchdog] woke hub-1 (send): dead turn
- 04:01 [watchdog] jwait does not match waiting lines
- 04:02 [other] the watchdog woke hub-1 (not an outcome)
- 05:00 [beta-hub-2] @hub QUESTION ready?
- 05:30 [hub-1] reply
- 23:59 [owner] a distinct journal owner touch
''')
put(home/'beta/coordinator/work/journal-2026-01-01.md', '- 05:10 [alpha-hub-1] @hub response\n- 05:11 [hub-2] ack\n')
put(st/'coordinator/work/journal-2026-01-03.md', '- 00:00 [build] DONE exactly until excluded\n')
put(st/'agents/build/meta.json', {'role':'build','tag':'build','engine':'claude','model':'claude-test','effort':'high','mcp':'none',
    'started_at':'2026-01-01T00:00:00Z','runs':[{'at':'2026-01-01T00:00:00Z'}],'worktree':{'branch':'feature-seven'}})
results=[]
for i in range(12):
    v=[(i+1)**k*100 for k in range(1,5)]
    cost=sum(x*y for x,y in zip(v,[2,10,.2,3]))/1e6
    results.append({'type':'result','session_id':'worker','num_turns':100,'total_cost_usd':i+1,
        'modelUsage':{'claude-test':dict(zip(['inputTokens','outputTokens','cacheReadInputTokens','cacheCreationInputTokens'],v),costUSD=cost)}})
messages=[{'type':'assistant','message':{'id':f'worker-{i}','model':'claude-test','content':[], 'usage':{}}} for i in range(12)]
jl(st/'agents/build/log.jsonl',messages+results)
put(st/'agents/codex/meta.json', {'role':'codex','engine':'codex','started_at':'2026-01-01T00:00:00Z'})
jl(st/'agents/codex/log.jsonl', [
    {'type':'thread.started','thread_id':'thread-one'}, {'type':'turn.started'},
    {'type':'turn.completed','usage':{'input_tokens':1000,'cached_input_tokens':800,'output_tokens':10}},
    {'type':'thread.started','thread_id':'thread-one'}, {'type':'turn.started'},
    {'type':'turn.completed','usage':{'input_tokens':2500,'cached_input_tokens':2000,'output_tokens':25}},
])
put(st/'agents/old/meta.json',{'role':'old','engine':'claude','started_at':'2025-12-01T00:00:00Z'})
put(st/'agents/build.20251201-000000/meta.json',{'role':'build','engine':'claude','started_at':'2025-12-01T00:00:00Z','worktree':{'branch':'old-feature'}})
jl(st/'agents/old/log.jsonl',[{'type':'result','total_cost_usd':10000}])
put(st/'agents/until/meta.json',{'role':'until','started_at':'2026-01-03T00:00:00Z'})
put(st/'agents/next/meta.json',{'role':'next','engine':'claude','started_at':'2026-01-01T02:01:00Z','model':'haiku','effort':'high'})
jl(st/'agents/next/log.jsonl',[])
def user(t, c, **kw):
    return dict(type='user',timestamp='2026-01-01T'+t+'Z',message={'content':c},**kw)
def assistant(t, id, c, **kw):
    return dict(type='assistant',timestamp='2026-01-01T'+t+'Z',message={'id':id,'model':'claude-test','content':c,
        'usage':{'input_tokens':100,'output_tokens':10,'cache_read_input_tokens':1000,'cache_creation_input_tokens':50}},**kw)
transcript=[user('00:01:00','A new feature, please'),
    assistant('00:02:00','a',[{'type':'text','text':'okay'}]),
    assistant('00:02:01','a',[{'type':'text','text':'duplicate streamed chunk'}]),
    user('00:03:00','[delamain watchdog] waiting lines'),
    assistant('00:04:00','b',[{'type':'text','text':'nothing to do'}]),
    user('00:05:00','<task-notification>done</task-notification>',origin={'kind':'task-notification'}),
    assistant('00:06:00','c',[{'type':'tool_use','id':'tool','name':'Bash','input':{'command':'hub status '}}]),
    user('00:07:00',[{'type':'tool_result','tool_use_id':'tool','content':'PreToolUse:Bash hook error: polling guard refused','is_error':True}]),
    user('00:08:00',[{'type':'tool_result','content':'the phrase PreToolUse:Bash hook error: polling guard is quoted','is_error':False}]),
    assistant('00:09:00','side',[{'type':'text','text':'side chain'}],isSidechain=True),
    {'type':'system','timestamp':'2026-01-01T00:10:00Z','subtype':'compact_boundary'},
    user('00:11:00','fake owner',isMeta=True),
    user('00:12:00','ordinary internal harness message',origin={'kind':'internal'}),
    {'type':'user','timestamp':'2026-01-03T00:00:00Z','message':{'content':'until boundary'}}]
jl(Path(os.environ['CLAUDE_CONFIG_DIR'])/'projects/project'/f'{sid}.jsonl',transcript)
put(st/'questions.md','''# Questions
## Q-X-001 — A product decision
- asked: 2026-01-01 00:00
- due: 2026-01-02
- blocks: work
- default: wait
- status: answered: yes (2026-01-01 06:00)
## D-X-002 — An implementation decision
- asked: 2026-01-01 01:00
- status: standing
## Q-X-003 — Outside window
- asked: 2026-01-03 00:00
- status: open
''')
put(st/'lessons.md','''# Lessons
## L-001 — Reuse the existing parser
- status: proposed
- lesson: Keep parsing in one place.
- verdict: hub-1 helped — proved useful
- verdict: hub-2 helped — repeat useful
```
## L-999 — Not a lesson inside a fence
- verdict: hurt
```
## L-002 — Retire on harm
- status: confirmed
- verdict: hub-1 hurt — regression
''')
put(home/'.state/watchdog/log.md','''- 2026-01-01 04:00 alpha: woke hub-1 (send): dead turn
- 2026-01-01 04:01 alpha: wake of hub-1 failed (send): no activity
- 2026-01-01 04:02 alpha: notify "hello" via osascript ok
- 2026-01-01 04:03 alpha: has a live jwait that does not match 2 waiting lines: not woken
- 2026-01-01 04:04 alpha: would wake hub-1 (dry run)
- 2026-01-03 00:00 alpha: woke hub-1 (excluded): dead turn
''')
jl(home/'.state/guard-decisions.jsonl',[{'ts':'2026-01-01T01:00:00Z','hook':'poll_guard','decision':'deny'},
    {'ts':'2025-12-01T00:00:00Z','hook':'poll_guard','decision':'deny'}])
forge=out/'forge'
put(forge/'forge-cache-mrs.json',{'repo':[{'iid':7,'title':'Feature','created_at':'2026-01-01T00:30:00Z',
    'merged_at':'2026-01-01T02:00:00Z','source_branch':'feature-seven'},
    {'iid':8,'merged_at':'2026-01-03T00:00:00Z'}]})
put(forge/'forge-cache-pipelines.json',{'repo!7':[{'status':'failed','created_at':'2026-01-01T01:00:00Z'},
    {'status':'failed','created_at':'2026-01-04T01:00:00Z'}]})
before=snapshot()
current=out/'current'
run('plan','--since','2026-01-01','--until','2026-01-03','--readers',2,'--out',current)
w=json.loads((current/'window.json').read_text())
assert sorted(s for r in w['readers'] for s in r['stages'])==['alpha','beta']
assert sum(r['bytes'] for r in w['readers'])==sum(w['journal_bytes'].values())
assert (current/'reader-01.md').is_file() and '{{' not in (current/'reader-01.md').read_text()
assert len(w['readers'])==2
run('plan','--out',out/'bad','--readers',0,ok=False)
run('measure','--out',current,'--forge',forge)
m=data(current)
for k,want in {'agents.count':3,'agents.claude.cost_usd':12,'agents.claude.turns':12,
    'agents.codex.turns':2,'agents.codex.input_tokens':2500,'agents.codex.cached_tokens':2000,'agents.codex.output_tokens':25,
    'hubs.active':1,'hubs.messages':3,
    'hubs.compactions':1,'wakes.watchdog':1,'wakes.watchdog.no_tool':1,'wakes.notif':1,'wakes.notif.no_tool':0,
    'latency.events':2,'watchdog.wakes':1,'watchdog.dead_turn_wakes':1,'watchdog.failed_wakes':1,'watchdog.notifications':1,
    'watchdog.jwait_mismatches':1,'guards.decisions':1,'await.FAILED.count':2,'await.PASSED.count':1,
    'questions.asked':1,'questions.decided':1,'lessons.count':2,'lessons.promotable':1,'lessons.retired':1,
    'tells.count':2,'flow.merged_observed':1,'friction.plugin hook: polling guard':1,'stages.closed':1}.items():
    assert value(m,k)==want,(k,value(m,k),want)
assert value(m,'await.FAILED.duration_min')==5.5
assert value(m,'await.PASSED.duration_min')==62.05
assert value(m,'flow.first_time_right') is None
assert value(m,'flow.red_cycles_per_merge')==1
assert rows(current,'flow')[0]['stage']=='alpha' and rows(current,'flow')[0]['join_method']=='unique branch', 'an archived role must not overwrite its live metadata'
assert value(m,'questions.self_decided_share')==.5
assert m['agents.count']['per_day']==1.5
assert value(m,'hubs.cost_usd')>0 and value(m,'hubs.unpriced_messages')==0
assert value(m,'touches.nudge') is None
assert any(r['needs_review']=='True' for r in rows(current,'gaps'))
assert all(r['needs_review']=='True' for r in rows(current,'touches'))
assert not any('ordinary internal harness message' in r['text'] for r in rows(current,'touches'))
assert rows(current,'latency')[0]['latency_min']=='2.0'
assert value(m,'gaps.total_h')>=value(m,'gaps.needs_review_h')>0
base=home/'audit/coordinator/work/retro-previous'
base.mkdir(parents=True)
put(home/'audit/roles.json',{'roles':{},'retired':[]})
raw=json.loads((current/'metrics.json').read_text())
raw['window'].update(since='2025-12-31T00:00:00Z',until='2026-01-01T00:00:00Z',days=1)
raw['metrics']['agents.count'].update(value=4,per_day=4)
put(base/'metrics.json',raw)
put(base/'CHECK-NEXT-test.md','# Metric: agents.count\n')
planned=out/'next'
run('plan','--until','2026-01-03','--out',planned)
w=json.loads((planned/'window.json').read_text())
assert w['since']=='2026-01-01T00:00:00+00:00' and w['baseline']==str(base.resolve()),w
assert (planned/'CHECK-NEXT-test.md').exists()
run('measure','--out',planned)
assert data(planned)['agents.count']['baseline']==4
assert data(planned)['agents.count']['baseline_per_day']==4
assert 'baseline' not in data(planned)['flow.merged_observed'], 'forge universe cannot compare to journal-only coverage'
explicit=out/'explicit'
run('measure','--out',explicit,'--since','2026-01-01','--until','2026-01-03','--baseline',base,'--exclude-stage','alpha')
assert data(explicit)['agents.count']['baseline']==4
assert value(data(explicit),'agents.count')==0
assert 'beta' in {r['stage'] for r in rows(explicit,'stages')}
assert 'alpha' not in {r['stage'] for r in rows(explicit,'stages')}
classify=out/'classify'
classify.mkdir()
ts=rows(current,'touches')
for r in ts:
    r.update(needs_review='false', **{'class':'nudge','evidence':r['source']})
with (classify/'touches.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=ts[0].keys());writer.writeheader();writer.writerows(ts)
run('measure','--out',current,'--forge',forge,'--classifications',classify)
assert value(data(current),'touches.nudge')==len(ts)
flow=rows(current,'flow')
flow[0].update(needs_review='false', **{'class':'verified','evidence':'fixture branch and pipeline export','queue_start':'2026-01-01T01:30:00Z'})
with (classify/'flow.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=flow[0].keys());writer.writeheader();writer.writerows(flow)
stages=rows(current,'stages')
for row in stages:
    row.update(needs_review='false', **{'class':'complete','evidence':'fixture plan complete','plan_done':2,'plan_dropped':1,'plan_carried':0,'plan_total':3})
with (classify/'stages.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=stages[0].keys());writer.writeheader();writer.writerows(stages)
run('measure','--out',current)
assert value(data(current),'flow.first_time_right')==0
assert value(data(current),'flow.queue_h.median')==.5
assert value(data(current),'stages.plan_total')==3
assert json.loads((current/'window.json').read_text())['readers'], 'measure must retain the plan reader split'
ts[0]['evidence']=''
with (classify/'touches.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=ts[0].keys());writer.writeheader();writer.writerows(ts)
run('measure','--out',current,'--classifications',classify,ok=False)
run('measure','--out',out/'badtime','--since','2026-01-03','--until','2026-01-01',ok=False)
run('measure','--out',out/'badstamp','--since','not-a-date','--until','2026-01-03',ok=False)
foreign=out/'foreign'
foreign.mkdir()
put(foreign/'window.json',dict(w, home=str(out/'other-home')))
run('measure','--out',foreign,ok=False)
run('measure','--out',out/'badbase','--baseline',out/'missing',ok=False)
after=snapshot()
assert all(after[p]==digest for p,digest in before.items()), 'real evidence modified by retro'
assert set(after)-set(before)=={str(p) for p in (home/'audit').rglob('*') if p.is_file()}, 'unexpected state/cache write'
for manifest in ('.claude-plugin/plugin.json','.codex-plugin/plugin.json'):
    root=b.parent
    skill=root/json.loads((root/manifest).read_text()).get('skills','./skills/')/'retro/SKILL.md'
    assert 'name: retro' in skill.read_text() and 'ретроспектива' in skill.read_text()
assert len((b.parent/'skills/retro/SKILL.md').read_text().splitlines())<=90
print('PASS retro metric families, negative controls, baseline, whole-stage split, classification, read-only evidence, both hosts')
PY
