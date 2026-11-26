#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
export HUB_STAGE=stage-a CODEX_BIN="$T/fake_codex.py" AGENT_HUB_LIMIT_PACE=off
P="$AGENT_HUB_HOME/project"
mkdir -p "$P"
printf '# Catalog fixture\n' > "$P/brief.md"
cp "$T/fixtures/codex-model-catalog.json" "$CODEX_HOME/models_cache.json"
out="$P/out"
err="$P/err"
spawn() { "$B/agent" spawn --engine codex --role catalog --cwd "$P" --brief "$P/brief.md" "$@" >"$out" 2>"$err"; }
dry() { spawn --dry-run "$@"; }
stale='STALE MODEL gpt-6.1-sol: newest sol is gpt-6.10-sol (use "sol" or pin deliberately via AGENT_HUB_MODEL_PINS)'

dry --model sol; check $? 0 'a family can launch'
grep -Fq 'gpt-6.10-sol/high, asked for sol' "$out"; check $? 0 'highest numeric version wins over priority and excludes hidden and preview IDs'
grep -Fq "CLI $CODEX_BIN" "$out"; check $? 0 'the configured Codex CLI is used'
dry --model terra; check $? 0 'terra can launch'
grep -Fq '(gpt-6-terra/' "$out"; check $? 0 'lower priority wins among equivalent versions'
AGENT_HUB_CODEX_MODEL_MAP='sol=astra' dry --model sol; check $? 0 'reserved families still work with a map'
grep -Fq '(gpt-6.10-sol/' "$out"; check $? 0 'a map cannot redirect a built-in family to another family'
grep -Fq "'sol' is reserved" "$err"; check $? 0 'a reserved family key warns'
AGENT_HUB_CODEX_MODEL_MAP='gpt-6.1-sol=astra' dry --model gpt-6.1-sol
grep -Fq "'gpt-6.1-sol' is reserved" "$err"; check $? 0 'a reserved full ID key warns'
grep -Fq '(gpt-6.1-sol/' "$out"; check $? 0 'a reserved full ID mapping leaves the pin in force'
AGENT_HUB_CODEX_DEFAULT_MODEL=sol dry; check $? 0 'a configured default accepts a family'
grep -Fq 'gpt-6.10-sol/high, asked for sol' "$out"; check $? 0 'the default family resolves'
AGENT_HUB_CODEX_DEFAULT_MODEL=judge AGENT_HUB_CODEX_MODEL_MAP='{"judge":"astra"}' dry
check $? 0 'a configured alias can target a family'
grep -Fq 'gpt-6.2-astra/high, asked for judge' "$out"; check $? 0 'the alias and resolved family ID are shown'
grep -Fq 'is reserved' "$err"; check $? 1 'an ordinary alias passes without a reserved-key warning'

dry --model luna; check $? 2 'hidden-only family refused'
grep -Fq "$CODEX_HOME/models_cache.json has no listed model for family 'luna'" "$err"
check $? 0 'missing family diagnostic names the catalog'
missing="$P/missing"
CODEX_HOME="$missing" dry --model sol; check $? 2 'missing catalog refuses a family'
grep -Fq "$missing/models_cache.json is missing or unreadable" "$err"; check $? 0 'missing catalog diagnostic names the alternate home'
mkdir "$missing"
printf '{invalid' > "$missing/models_cache.json"
CODEX_HOME="$missing" dry --model sol; check $? 2 'unreadable catalog refuses a family'
CODEX_HOME="$missing" dry --model gpt-6.1-sol; check $? 0 'a full ID runs with an unreadable catalog'
grep -Fq '(gpt-6.1-sol/' "$out"; check $? 0 'full ID passes through'
grep -q 'STALE MODEL' "$err"; check $? 1 'no stale warning without evidence from a catalog'

dry --model gpt-6.1-sol; check $? 0 'using a stale pin is allowed'
grep -Fxc "$stale" "$err" > "$P/count"; check "$(cat "$P/count")" 1 'spawn gives one stale warning'
grep -Fq '(gpt-6.1-sol/' "$out"; check $? 0 'a stale pin is still used'
AGENT_HUB_CODEX_MODEL_MAP='judge=gpt-6.1-sol' dry --model judge
grep -Fxq "$stale" "$err"; check $? 0 'a stale mapped ID is flagged'
AGENT_HUB_CODEX_DEFAULT_MODEL=gpt-6.1-sol dry
grep -Fxq "$stale" "$err"; check $? 0 'a stale default ID is flagged'
printf '{"AGENT_HUB_MODEL_PINS":["gpt-6.1-sol"]}\n' > "$AGENT_HUB_HOME/config.json"
dry --model gpt-6.1-sol; check $? 0 'a hub config can declare a deliberate pin'
grep -q 'STALE MODEL' "$err"; check $? 1 'the declared pin silences the warning'
rm "$AGENT_HUB_HOME/config.json"
dry --model gpt-6.10-sol; check $? 0 'the newest ID runs'
grep -q 'STALE MODEL' "$err"; check $? 1 'the newest ID is not flagged'

export AGENT_HUB_REASON_POLICY=refuse
AGENT_HUB_REASON_MODELS='["sol"]' dry --model gpt-6.1-sol; check $? 2 'reason family matches a pinned version'
grep -Fq '(AGENT_HUB_REASON_MODELS: sol)' "$err"; check $? 0 'family refusal identifies the policy'
AGENT_HUB_REASON_MODELS='["sol"]' dry --model astra; check $? 0 'reason family does not match another family'
AGENT_HUB_REASON_MODELS='["sol"]' dry --model gpt-9-sol-preview; check $? 0 'a family match requires a family ID'
AGENT_HUB_REASON_MODELS='["gpt-6.10-sol"]' dry --model sol; check $? 2 'reason pin matches resolved ID'
AGENT_HUB_REASON_MODELS='["gpt-6.1-sol"]' dry --model sol; check $? 0 'reason pin does not match a different version'
AGENT_HUB_REASON_MODELS='["gpt-6.1-sol"]' dry --model gpt-6.1-sol-preview; check $? 0 'reason pin is not a substring match'
CLAUDE_BIN="$T/fake_claude.py" AGENT_HUB_REASON_MODELS='["sol"]' AGENT_HUB_MODEL_MAP='sol=claude-sonnet-5-5' \
    "$B/agent" spawn --engine claude --role catalog --cwd "$P" --brief "$P/brief.md" --model sol --dry-run >"$out" 2>"$err"
check $? 2 'Claude custom aliases keep their existing reason matching'
grep -Fq '(AGENT_HUB_REASON_MODELS: sol)' "$err"; check $? 0 'Claude refusal identifies the policy'
unset AGENT_HUB_REASON_POLICY

spawn --model sol; check $? 0 'resolved family launches the configured CLI'
python3 - "$AGENT_HUB_HOME/$HUB_STAGE/agents/catalog/meta.json" "$P/codex-argv.jsonl" <<'PY'
import json
from pathlib import Path
import sys

meta, argv = (json.loads(Path(path).read_text()) for path in sys.argv[1:])
assert argv[argv.index('-m') + 1] == 'gpt-6.10-sol', argv
assert (meta['requested_model'], meta['resolved_model'], meta['model']) == ('sol', 'gpt-6.10-sol', 'gpt-6.10-sol'), meta
PY
check $? 0 'meta and CLI argv preserve requested alias and resolved identity'
"$B/agent" status catalog >"$out"
grep -Fq 'gpt-6.10-sol (asked for sol)' "$out"; check $? 0 'status displays resolved ID alongside its alias'

AGENT_HUB_REVIEWERS='[{"name":"pin","kind":"agent","engine":"codex","model":"gpt-6.1-sol"}]' \
    "$B/hub" reviewer --author catalog >"$out" 2>"$err"
check $? 0 'reviewers can pin an ID'
grep -Fxq "$stale" "$err"; check $? 0 'reviewer entry warns about its stale pin'
grep -Fq -- '--model gpt-6.1-sol' "$out"; check $? 0 'reviewer start line keeps the full pin'
AGENT_HUB_REVIEWERS='[{"name":"judge","kind":"agent","engine":"codex","model":"review"}]' \
    AGENT_HUB_CODEX_MODEL_MAP='review=astra' "$B/hub" reviewer --author catalog >"$out" 2>"$err"
check $? 0 'a reviewer can use a mapped family'
grep -Fq 'reviewer: judge (agent gpt-6.2-astra/high)' "$out"; check $? 0 'reviewer displays the resolved model'
grep -Fq -- '--model astra' "$out"; check $? 0 'reviewer start command resolves the family again at spawn'
CODEX_HOME="$missing" "$B/hub" reviewer --author claude/opus >"$out" 2>"$err"
check $? 0 'the built-in reviewer falls back with an unreadable catalog'
grep -Fq 'reviewer: agent (agent opus/high)' "$out"; check $? 0 'an unreadable catalog selects Claude'
grep -Fq "$missing/models_cache.json is missing or unreadable" "$err"; check $? 0 'reviewer fallback names the catalog'
AGENT_HUB_REVIEWERS='[{"name":"astra","kind":"agent","engine":"codex","model":"astra"}]' \
    CODEX_HOME="$missing" "$B/hub" reviewer --author claude/opus >"$out" 2>"$err"
check $? 1 'an explicit family entry is unavailable with an unreadable catalog'
CODEX_BIN="$P/no-codex" "$B/hub" reviewer --author claude/opus >"$out" 2>"$err"
check $? 0 'the built-in reviewer falls back with no CLI even with a usable catalog'
grep -Fq 'codex not found' "$err"; check $? 0 'fallback explains the missing CLI'
"$B/hub" reviewer --author claude/opus >"$out" 2>"$err"
check $? 0 'installed CLI and listed Astra choose Codex'
grep -Fq 'agent gpt-6.2-astra/high' "$out"; check $? 0 'the built-in Codex reviewer resolves the latest Astra'
grep -Fq 'using Claude' "$err"; check $? 1 'available Astra gives no fallback warning'

printf 'Use `gpt-6.1-sol` for routine work. Use codex/gpt-6-astra. Example: gpt-6.1-sol-preview.\n' > "$AGENT_HUB_HOME/$HUB_STAGE/hub-rules.md"
python3 - "$CODEX_HOME/models_cache.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['fetched_at'] = '2020-01-01T00:00:00Z'
path.write_text(json.dumps(data))
PY
sid=22222222-2222-2222-2222-222222222222
"$B/hub" start --dry-run --stage "$HUB_STAGE" --session "$sid" --goal 'Catalog model warnings' >"$out" 2>"$err"
check $? 0 'start can render its model diagnostics'
grep -Fxq "$stale" "$out"; check $? 0 'start digest warns about the stale Sol pin in stage rules'
grep -Fq 'STALE MODEL gpt-6-astra: newest astra is gpt-6.2-astra' "$out"; check $? 0 'start digest reads a pin followed by punctuation'
grep -Fq "STALE CATALOG $CODEX_HOME/models_cache.json: older than 7 days" "$out"
check $? 0 'old fetched_at wins over recent file mtime'
AGENT_HUB_MODEL_PINS='["gpt-6.1-sol"]' "$B/hub" takeover --dry-run --stage "$HUB_STAGE" --session "$sid" >"$out" 2>"$err"
check $? 0 'takeover can render its model diagnostics'
grep -Fq 'STALE MODEL gpt-6-astra' "$out"; check $? 0 'takeover digest warns about the other stale pin'
grep -Fq 'STALE MODEL gpt-6.1-sol' "$out"; check $? 1 'takeover silences a deliberate pin'
cp "$T/fixtures/codex-model-catalog.json" "$CODEX_HOME/models_cache.json"
"$B/hub" start --dry-run --stage "$HUB_STAGE" --session "$sid" --goal 'Catalog model warnings' >"$out" 2>"$err"
grep -Fq 'STALE MODEL' "$out"; check $? 0 'the fresh catalog was still consulted'
grep -Fq 'STALE CATALOG' "$out"; check $? 1 'a recent mtime suffices when fetched_at is absent'

rm "$AGENT_HUB_HOME/$HUB_STAGE/hub-rules.md"
AGENT_HUB_REASON_MODELS='["gpt-6.1-sol","astra",{}]' AGENT_HUB_EFFORT_DEFAULTS='{"gpt-6-astra":"high","sol":"medium"}' \
    "$B/hub" takeover --dry-run --stage "$HUB_STAGE" --session "$sid" >"$out" 2>"$err"
check $? 0 'takeover accepts family and full ID selectors in policy settings'
grep -Fxq "$stale" "$out"; check $? 0 'the digest warns about a stale reason policy key'
grep -Fq 'STALE MODEL gpt-6-astra' "$out"; check $? 0 'the digest warns about a stale effort policy key'
AGENT_HUB_REASON_MODELS='["sol","gpt-6.10-sol"]' AGENT_HUB_EFFORT_DEFAULTS='{"astra":"high","gpt-6.2-astra":"high"}' \
    "$B/hub" takeover --dry-run --stage "$HUB_STAGE" --session "$sid" >"$out" 2>"$err"
grep -Fq 'STALE MODEL' "$out"; check $? 1 'family selectors and current policy IDs do not warn'

mkdir -p "$CODEX_HOME/sessions"
desktop_takeover() {
    printf '{"type":"session_meta","payload":{"id":"%s"}}\n{"type":"turn_context","payload":{"model":"%s"}}\n' "$sid" "$1" > "$CODEX_HOME/sessions/rollout-desktop.jsonl"
    AGENT_ROLE= CODEX_THREAD_ID="$sid" CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
        CODEX_APP_TOOLS_PIPE_PATH=/no-pipe "$B/hub" takeover --dry-run --stage "$HUB_STAGE" --session self >"$out" 2>"$err"
}
desktop_takeover gpt-6.1-sol; check $? 0 'a Desktop takeover reads the current model from its rollout'
grep -Fxq "$stale" "$out"; check $? 0 'the Desktop digest warns about its own stale model'
desktop_takeover gpt-6.10-sol
grep -Fq 'STALE MODEL' "$out"; check $? 1 'a current Desktop model does not warn'

wait_catalog() {
    for attempt in $(seq 1 30); do
        "$B/agent" status catalog > "$P/status"
        grep -Fq ALIVE "$P/status" || return 0
        sleep 0.2
    done
    return 1
}
wait_catalog; check $? 0 'catalog agent finished before resume'
printf '{"models":[{"slug":"gpt-7-sol","visibility":"list"}]}\n' > "$missing/models_cache.json"
CODEX_HOME="$missing" "$B/agent" send catalog 'Resume with the original model' >"$out" 2>"$err"
check $? 0 'the existing Codex thread resumes'
resume_warning='STALE MODEL gpt-6.10-sol: newest sol is gpt-7-sol'
grep -Fq "$resume_warning" "$err"; check $? 0 'resume prints a stale warning for the original ID'
grep -Fq "$resume_warning" "$(journal "$HUB_STAGE")"; check $? 0 'resume journals the stale warning'
wait_catalog; check $? 0 'the first resume finished'
AGENT_HUB_MODEL_PINS='["gpt-6.10-sol"]' CODEX_HOME="$missing" \
    "$B/agent" send catalog 'Resume with an acknowledged pin' >"$out" 2>"$err"
check $? 0 'an acknowledged pin also resumes'
grep -Fq "$resume_warning" "$err"; check $? 1 'an acknowledged resume pin does not print a warning'
check "$(grep -Fc "$resume_warning" "$(journal "$HUB_STAGE")")" 1 'an acknowledged resume pin does not journal a warning'
python3 - "$P/codex-argv.jsonl" <<'PY_RESUME'
import json
from pathlib import Path
import sys

for argv in map(json.loads, Path(sys.argv[1]).read_text().splitlines()[-2:]):
    assert argv[:2] == ['exec', 'resume'] and argv[argv.index('-m') + 1] == 'gpt-6.10-sol', argv
PY_RESUME
check $? 0 'both resumes keep the same resolved version'
wait_catalog; check $? 0 'the second resume finished'

exit "$fail"
