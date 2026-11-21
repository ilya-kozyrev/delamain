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

test_r1_1_headless_hub_cost()
if os.environ.get('RETRO_REGRESSION') == '1':
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
