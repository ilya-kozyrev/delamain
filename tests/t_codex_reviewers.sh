#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
export CODEX_BIN="$T/fake_codex.py"
cp "$T/fixtures/codex-model-catalog.json" "$CODEX_HOME/models_cache.json"
AGENT_HUB_ENGINE=codex "$B/hub" reviewer --json > "$AGENT_HUB_HOME/default.json"; check $? 0 'Codex default reviewer resolves'
python3 - "$AGENT_HUB_HOME/default.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));s=r['start']
assert '--engine codex' in s and '--sandbox workspace-write' in s,s
assert '--model opus' not in s and '--model None' not in s,s
assert '--model astra' in s,s
assert r['entries'][0]['resolved_model'] == 'gpt-6.2-astra',r
assert '--cwd <HUB_WORK> --target-repo <REPO>' in s,s
PY
check $? 0 'Codex reviewer defaults to Astra high workspace-write'
AGENT_HUB_ENGINE=codex AGENT_HUB_CODEX_DEFAULT_MODEL=sol "$B/hub" reviewer --json > "$AGENT_HUB_HOME/sol-author.json"
python3 - "$AGENT_HUB_HOME/sol-author.json" <<'PY'
import json,sys
assert '--model astra' in json.load(open(sys.argv[1]))['start']
PY
check $? 0 'Sol implementation default does not downgrade reviewer'
AGENT_HUB_REVIEWERS='[{"name":"codex","kind":"agent","engine":"codex","model":"gpt-fixture","effort":"high"}]' "$B/hub" reviewer --json > "$AGENT_HUB_HOME/explicit.json"; check $? 0 'mixed engine reviewer config'
python3 - "$AGENT_HUB_HOME/explicit.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert r['chosen']=='codex';assert '--engine codex --sandbox workspace-write --model gpt-fixture' in r['start']
PY
check $? 0 'Codex reviewer selection and start line'
AGENT_HUB_ENGINE=codex AGENT_HUB_REVIEWERS='[{"name":"claude","kind":"agent","engine":"claude","model":"opus","effort":"high"}]' "$B/hub" reviewer --json > "$AGENT_HUB_HOME/mixed.json"; check $? 0 'Claude reviewer from Codex coordinator'
python3 - "$AGENT_HUB_HOME/mixed.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert '--engine claude' in r['start'];assert '--sandbox' not in r['start']
PY
check $? 0 'explicit Claude engine preserved'
mixed='[{"name":"codex","kind":"agent","engine":"codex","model":"opus"},{"name":"claude","kind":"agent","engine":"claude","model":"opus"}]'
for map_case in invalid valid; do
    mapping='{"opus":"astra"}'
    [ "$map_case" = valid ] || mapping='{broken'
    AGENT_HUB_REVIEWERS="$mixed" AGENT_HUB_CODEX_MODEL_MAP="$mapping" AGENT_HUB_REVIEW_MODEL=opus \
        "$B/hub" reviewer --author claude/opus --all --json > "$AGENT_HUB_HOME/$map_case.json" 2>"$AGENT_HUB_HOME/$map_case.err"
    check $? 0 "reviewer walk completes with $map_case map"
done
python3 - "$AGENT_HUB_HOME" <<'PY_MAP'
import json
from pathlib import Path
import sys

home = Path(sys.argv[1])
invalid, valid = (json.loads((home / f'{case}.json').read_text()) for case in ('invalid', 'valid'))
assert invalid['chosen'] == 'claude', invalid
assert [e['available'] for e in invalid['entries']] == [False, True], invalid
assert 'AGENT_HUB_CODEX_MODEL_MAP' in invalid['entries'][0]['why'], invalid
assert any('AGENT_HUB_CODEX_MODEL_MAP' in problem for problem in invalid['invalid']), invalid
assert valid['chosen'] == 'codex' and valid['entries'][0]['resolved_model'] == 'gpt-6.2-astra', valid
assert valid['invalid'] == [], valid
PY_MAP
check $? 0 'a malformed map disables only Codex entries; a valid map resolves the alias'
AGENT_HUB_REVIEWERS="$mixed" AGENT_HUB_CODEX_MODEL_MAP='{}' \
    "$B/hub" reviewer --author claude/opus --all --json > "$AGENT_HUB_HOME/unmapped.json" 2>/dev/null
python3 - "$AGENT_HUB_HOME/unmapped.json" <<'PY_UNMAPPED'
import json
import sys

result = json.load(open(sys.argv[1]))
assert result['chosen'] == 'claude' and [entry['name'] for entry in result['entries']] == ['claude'], result
assert any('Claude alias' in problem for problem in result['invalid']), result
PY_UNMAPPED
check $? 0 'a Claude name without a Codex alias is still an invalid Codex entry'
AGENT_HUB_ENGINE=codex "$B/hub" reviewer --stage stage-a --json > "$AGENT_HUB_HOME/stage.json"
python3 - "$AGENT_HUB_HOME/stage.json" "$AGENT_HUB_HOME" <<'PY_STAGE'
import json,shlex,sys
from pathlib import Path
s=shlex.split(json.load(open(sys.argv[1]))['start'])
assert s[s.index('--cwd')+1] == str(Path(sys.argv[2])/'stage-a/coordinator/work'),s
assert '--worktree' not in s,s
assert s[s.index('--target-repo')+1] == '<REPO>',s
PY_STAGE
check $? 0 'Codex reviewer uses the stage work directory under the hub home'
# Reviewer output permissions are narrower than executor permissions, on spawn and resume.
CODEX_BIN="$T/fake_codex.py" python3 - "$B" "$AGENT_HUB_HOME" <<'PY_SCOPE'
import json, os, subprocess, sys, time, tomllib
from pathlib import Path
bins, home = map(Path, sys.argv[1:])
work = (home/'stage-a/coordinator/work').resolve()
work.mkdir(parents=True, exist_ok=True)
brief = home/'brief.md'
brief.write_text('Write a report, leave the repository unchanged.\n')
base = [str(bins/'agent'), 'spawn', '--stage', 'stage-a', '--engine', 'codex', '--role', 'review-scope',
        '--cwd', str(work), '--model', 'gpt-fixture', '--brief', str(brief)]
def run(args):
    return subprocess.run(args, text=True, capture_output=True)
def wait():
    end=time.monotonic()+15
    while time.monotonic()<end:
        r=run([str(bins/'agent'),'status','--stage','stage-a','review-scope'])
        if r.returncode==0 and 'ALIVE' not in r.stdout: return
        time.sleep(.1)
    raise AssertionError('reviewer did not finish')
r=run(base+['--sandbox','workspace-write']); assert r.returncode==0,r.stderr
wait()
r=run([str(bins/'agent'),'send','--stage','stage-a','review-scope','continue']); assert r.returncode==0,r.stderr
wait()
rows=[json.loads(l) for l in (work/'codex-argv.jsonl').read_text().splitlines()]
assert len(rows)==2 and rows[1][:2]==['exec','resume'],rows
for row in rows:
    config=tomllib.loads('\n'.join(row[i+1] for i,a in enumerate(row) if a=='-c'))
    policy=config['sandbox_workspace_write']
    assert policy['writable_roots']==[str(work)],policy
    assert policy['exclude_tmpdir_env_var'] and policy['exclude_slash_tmp'],policy
for extra in [
    ['--cwd',str(home.parent),'--sandbox','workspace-write'],
    ['--cwd',str(home),'--sandbox','workspace-write'],
    ['--sandbox-policy',json.dumps({'type':'workspace-write','writable_roots':[str(home)]})],
]:
    r=run(base+extra+['--dry-run'])
    assert r.returncode==2 and 'reviewer' in r.stderr,r.stderr
print('PASS review-role cwd-only roots persist on resume; wider roots/cwd are refused')
PY_SCOPE
check $? 0 'M1 reviewer report/journal scope excludes home config and other inboxes'
python3 - "$B/../templates/brief-review.md" <<'PY_TEMP'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
assert 'temporary copies' in text and 'subdirectory of its cwd' in text and '`/tmp`' in text
PY_TEMP
check $? 0 'N2 reviewer template places temporary copies inside Codex cwd'
exit $fail
