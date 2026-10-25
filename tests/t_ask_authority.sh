#!/bin/bash
# Authority in the `ask` register: an owner's answer authorises the action its question asked, once (`ask done` spends
# it); a standing permission keeps covering repeats; `ask plan` records an approval only with the owner's words and a
# source that is not an agent's file; a normal autopilot shift adds no owner question. Stand-in CLIs; no model called.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; F=$R/stage-a/questions.md

# ---- 1. an answer is single-use
$B/ask add --stage stage-a --print-id "Release prod today?" > /dev/null
$B/ask close Q-A-001 --answer "да на прод-тег сегодняшнего релиза" > /dev/null
$B/ask check Q-A-001 > $R/c1.out; check $? 0 "an answered question not yet done authorises its action"
grep -q 'authorises once what it asked' $R/c1.out; check $? 0 "…once, and it says so"
$B/ask done Q-A-001 --evidence "v2.0.128 tagged, deploy green" > $R/d1.out; check $? 0 "done"
grep -q '^Q-A-001 is spent' $R/d1.out; check $? 0 "done says the answer is now spent"
$B/ask check Q-A-001 > $R/c2.out; check $? 4 "a spent answer is refused for a second action (exit 4)"
grep -q 'is spent' $R/c2.out && grep -q 'ask allow' $R/c2.out && grep -q 'ask add' $R/c2.out
check $? 0 "…and points to a standing permission or a new question"
grep -q 'other ready work' $R/c2.out; check $? 0 "…and to going on with other ready work meanwhile"
$B/ask done Q-A-001 --evidence "healthz build_sha checked" > /dev/null 2> $R/d2.err; check $? 0 "more evidence of the same action is still accepted"
grep -q 'already spent' $R/d2.err; check $? 0 "…with a note that a second action needs ask allow or a new question"
$B/ask digest --stage stage-a | grep -q '^Q-A-001 spent: да на прод-тег'; check $? 0 "digest marks the executed answer spent"
$B/ask search release | grep -q '^Q-A-001 \[stage-a\] answered, spent'; check $? 0 "search marks it spent"
$B/ask list --stage stage-a --all | grep -q '^Q-A-001 .* SPENT — Release prod today?'; check $? 0 "list --all marks it SPENT"
python3 - "$B" > $R/hd.out <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hub_cli", sys.argv[1] + "/hub")
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("hub_cli", loader))
sys.modules["hub_cli"] = mod
loader.exec_module(mod)
print(mod.ask_digest("stage-a"))
PY
grep -q '^Q-A-001 owner, spent: да на прод-тег' $R/hd.out; check $? 0 "the takeover digest marks it spent"
$B/ask add --stage stage-a --print-id "Rename the service?" > /dev/null
$B/ask close Q-A-002 --answer "yes" > /dev/null
$B/ask digest --stage stage-a | grep -q '^Q-A-002 yes'; check $? 0 "control: an answer not yet done is not marked spent"
$B/ask check Q-A-002 > /dev/null; check $? 0 "control: …and still authorises"
$B/ask add --stage stage-a --print-id "Open question" > /dev/null
$B/ask check Q-A-003 > /dev/null; check $? 4 "an unanswered question authorises nothing"
$B/ask decided --stage stage-a --print-id "Export as Parquet" > /dev/null
$B/ask check D-A-001 > $R/c3.out; check $? 4 "an agent's decision is not the owner's word"

# ---- 2. a standing permission still covers the repeat
$B/ask allow --stage stage-a --scope stage --class release --until 2099-01-01 \
  --words "релизы в прод выпускай сам до конца года" "production releases" > /dev/null
$B/ask check A-A-001 > /dev/null; check $? 0 "a permission in force authorises"
$B/ask check A-A-001 > /dev/null; check $? 0 "…as often as needed"
$B/ask add --stage stage-a --class release "Another release today?" > /dev/null 2> $R/a1.err; check $? 3 "a repeated release under the permission is no question (exit 3)"
grep -c '^## Q-' $F | grep -qx 3; check $? 0 "…and nothing was recorded"
$B/ask revoke A-A-001 --reason "test" > /dev/null
$B/ask check A-A-001 > /dev/null; check $? 4 "a revoked permission authorises nothing"

# ---- 3. a hub never records an approval it did not receive
$B/ask plan --stage stage-a --by hub-2 --source "$R/stage-a/coordinator/HANDOFF-hub-2.md" "Continue the DoD" > /dev/null 2> $R/p1.err
check $? 1 "ask plan without the owner's words is refused"
grep -q 'Nothing to record' $R/p1.err && grep -q 'ask decided' $R/p1.err; check $? 0 "…and points to: nothing to record, or ask decided"
$B/ask plan --stage stage-a --words "продолжай" --source "$R/stage-a/coordinator/HANDOFF-hub-2.md" "Continue" > /dev/null 2> $R/p2.err
check $? 1 "an agent's file as the source is refused even with words"
grep -q 'is a file' $R/p2.err; check $? 0 "…and says why"
$B/ask plan --stage stage-a --words "продолжай" --source "~/agent-hub/stage-a/REPORT.md" "Continue" > /dev/null 2>&1; check $? 1 "a ~ path is a file too"
$B/ask plan --stage stage-a --words "продолжай" "Continue" > /dev/null 2>&1; check $? 1 "no source is refused"
grep -q '^## P-' $F; check $? 1 "…none of the refusals recorded a plan"
check "$($B/ask plan --stage stage-a --words "запускай" --source "owner chat 25.10 19:20" --print-id "Build X, then ship")" "P-A-001" "an owner-quoted plan is approved"
grep -q '^- words: запускай$' $F; check $? 0 "…with the owner's words on record"
$B/ask check P-A-001 > /dev/null; check $? 0 "…and counts"
# older records: no reinterpretation, except a plan an agent took from its own file with no words
mkdir -p $R/stage-b
cat > $R/stage-b/questions.md <<EOF
# Owner questions — stage-b

<!-- ask:v1 prefix=B -->

## P-B-001 — Continue the inherited DoD
- kind: plan
- status: approved
- asked: 2026-10-25 21:32
- by: agent
- source: $R/stage-b/coordinator/HANDOFF-hub-1.md
EOF
has_plan(){ python3 - "$B" "$1" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ask_t", sys.argv[1] + "/ask")
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("ask_t", loader))
sys.modules["ask_t"] = mod
loader.exec_module(mod)
print(mod.has_plan(sys.argv[2]))
PY
}
check "$(has_plan stage-b)" "False" "an old agent-file plan without words does not count"
$B/ask check P-B-001 > /dev/null; check $? 4 "…and check says it is not an approval"
printf '\n## P-B-002 — Old plan\n- kind: plan\n- status: approved\n- asked: 2026-10-01\n- by: agent\n- source: not set\n' >> $R/stage-b/questions.md
check "$(has_plan stage-b)" "True" "an old plan without a file source still counts (no reinterpretation)"

# ---- 4. a normal autopilot shift adds zero owner questions and zero inbox items
export CLAUDE_BIN=$T/fake_claude.py HUB_TAG=hub-2
W=$R/w; mkdir -p $W; printf '# Brief: parser change\n\nbody\n' > $W/b.md
# the first hub, earlier: the owner approved the stage's result and allowed merges
$B/ask plan --stage walk --by hub-1 --words "запускай парсер" --source "owner chat, hub-1" "Parser rewrite" > /dev/null
$B/ask allow --stage walk --scope stage --class merge --words "мержи в main сам после ревью" "merge to main" > /dev/null
before=$(grep -c '^## ' $R/walk/questions.md)
# the successor takes over: continues the DoD (no plan to record), spawns, orders a review, merges under the permission
$B/agent spawn --role exec-1 --stage walk --cwd $W --brief $W/b.md --model haiku > /dev/null 2> $R/w1.err; check $? 0 "walk: spawn"
grep -q 'no owner-approved plan' $R/w1.err; check $? 1 "walk: spawn does not warn — the inherited plan counts"
for i in $(seq 1 60); do $B/agent status exec-1 --stage walk 2>/dev/null | grep -q 'ALIVE' || break; sleep 0.25; done
$B/ask decided --stage walk --by hub-2 "Review by Codex Astra (author is Claude)" > /dev/null; check $? 0 "walk: the review choice is the hub's decision"
$B/ask add --stage walk --by hub-2 --class merge "Merge PR 12 to main?" > /dev/null 2>&1; check $? 3 "walk: the merge is covered, no question"
$B/ask check A-WALK-001 > /dev/null; check $? 0 "walk: the merge rests on the permission"
grep -c '^## Q-' $R/walk/questions.md | grep -qx 0; check $? 0 "walk: zero owner questions in the register"
check "$(grep -c '^## ' $R/walk/questions.md)" "$((before + 1))" "walk: the only new entry is the hub's decision"
$B/ask inbox --stage walk --json --since 2000-01-01 | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = [x for x in d["stages"] if x["stage"] == "walk"]
assert s and s[0]["waiting"] == [], s
assert [x["title"] for x in s[0]["decided"]] == ["Review by Codex Astra (author is Claude)"], s
'; check $? 0 "walk: the owner digest has nothing waiting for the owner; the decision is information"
$B/ask list --stage walk | grep -q '^Q-'; check $? 1 "walk: nothing unresolved for the owner"
exit $fail
