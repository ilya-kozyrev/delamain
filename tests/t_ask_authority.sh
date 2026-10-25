#!/bin/bash
# ask: an owner's yes said for a day ends with that day (Q-MC-009: «сегодняшний релиз» of 23.10 shipped on 24.10), and
# a hub never approves its own plan (P-DL-025: `approved, by: agent`, source the hub's own handoff).
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; F=$R/stage-a/questions.md
block(){ python3 - "$F" "$1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith(f"## {sys.argv[2]} "))
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
print("\n".join(lines[start:end]))
PY
}
yesterday=$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).date() - d.timedelta(days=1))')

# ---- 1. a standing permission whose words name a day is bound to that day
$B/ask allow --stage stage-a --scope stage --class release --words "«сегодняшний релиз»" --asked 2026-10-23 --at 14:05 \
  "release of the day" > $R/a1.out 2> $R/a1.err; check $? 0 "allow with day words"
block A-A-001 | grep -qx -- '- until: 2026-10-23'; check $? 0 "«сегодняшний релиз» given 23.10: until is the end of 23.10"
grep -q 'bound to a day («сегодняшний»): in force until 2026-10-23 23:59' $R/a1.err; check $? 0 "…and allow says so"
$B/ask in-force A-A-001 --as-of 2026-10-23T20:00 > $R/f1.out; check $? 0 "in force on 23.10"
$B/ask in-force A-A-001 --as-of 2026-10-24T20:25 > $R/f2.out; check $? 4 "not in force on 24.10 (exit 4)"
grep -q '^A-A-001 NOT in force: expired 2026-10-23 23:59: ask the owner again' $R/f2.out; check $? 0 "…and says to ask again"
$B/ask allow --stage stage-a --scope stage --class merge --words "«мержи зелёные сам»" --asked 2026-10-23 "merge" \
  > /dev/null 2> $R/a2.err
block A-A-002 | grep -qx -- '- until: not set'; check $? 0 "words without a day: no until"
$B/ask in-force A-A-002 --as-of 2099-01-01T00:00 > /dev/null; check $? 0 "…in force until revoked"
grep -q 'bound to a day' $R/a2.err; check $? 1 "negative: no day note for words without a day"
# the list and the covered check of `ask add` treat an expired grant as not in force
$B/ask allow --stage stage-a --scope stage --class deploy --words "«сегодня можно катить»" --asked "$yesterday" \
  "deploy" > /dev/null 2>&1
$B/ask allow --list --stage stage-a > $R/l1.out 2>&1
grep -q '^A-A-003' $R/l1.out; check $? 1 "allow --list: yesterday's «сегодня» grant is not listed"
grep -q '^A-A-002' $R/l1.out; check $? 0 "…a grant without a day is"
$B/ask allow --list --stage stage-a --all | grep -q '^A-A-003 \[stage-a\] expired'; check $? 0 "…--all shows it expired"
$B/ask add --stage stage-a --class deploy "Deploy now?" > /dev/null 2> $R/c1.err; check $? 0 "add --class deploy: the expired grant does not cover it"
grep -q 'not covered: deploy' $R/c1.err; check $? 0 "…the question goes to the owner"
$B/ask allow --stage stage-a --scope stage --class hotfix --words "«сегодня хотфиксы без вопросов»" "hotfix" > /dev/null 2>&1
$B/ask add --stage stage-a --class hotfix "Hotfix now?" > /dev/null 2>&1; check $? 3 "…while a grant given today still covers (exit 3)"
# the phrase table: tomorrow, the week, a named date, a clock time; a bare stamp binds nothing
lim(){ $B/ask allow --stage stage-a --scope stage --class "x$1" --words "$2" --asked "$3" ${4:+--at $4} "x" --print-id 2>/dev/null; }
id=$(lim 1 "«завтра можно»" 2026-10-23); block $id | grep -qx -- '- until: 2026-10-24'; check $? 0 "«завтра» → the end of the next day"
id=$(lim 2 "«до конца недели без вопросов»" 2026-10-22); block $id | grep -qx -- '- until: 2026-10-25'; check $? 0 "«до конца недели» → Sunday"
id=$(lim 3 "«можно до 25.10»" 2026-10-23); block $id | grep -qx -- '- until: 2026-10-25'; check $? 0 "«до 25.10» → that day"
id=$(lim 4 "«ok until 3 nov»" 2026-10-23); block $id | grep -qx -- '- until: 2026-11-03'; check $? 0 "\"until 3 nov\" → that day"
id=$(lim 5 "«катите до 18:00»" 2026-10-23 14:05); block $id | grep -qx -- '- until: 2026-10-23T18:00'; check $? 0 "«до 18:00» → that time"
id=$(lim 6 "владелец 23.10 14:05: «мержи всё»" 2026-10-23); block $id | grep -qx -- '- until: not set'; check $? 0 "negative: a bare date stamp binds nothing"
id=$(lim 7 "«release today»" 2026-10-23); block $id | grep -qx -- '- until: 2026-10-23'; check $? 0 "English \"today\""
$B/ask allow --stage stage-a --scope stage --class x8 --words "«сегодня»" --asked 2026-10-23 --until 2026-10-30 "x" \
  > /dev/null 2> $R/a8.err
grep -q 'later than the day the owner.s words name' $R/a8.err; check $? 0 "an explicit --until past the words' day warns"

# ---- 2. an answered question used as a permission carries the same bound
q=$($B/ask add --stage stage-a --print-id "Релиз прода сегодня?" 2>/dev/null)
$B/ask close $q --answer "да" --date 2026-10-23 --at 14:17 > /dev/null 2> $R/q1.err
block $q | grep -qx -- '- until: 2026-10-23'; check $? 0 "a bare «да» to «Релиз … сегодня?» is bound to that day"
grep -q "$q: the owner.s words are bound to a day" $R/q1.err; check $? 0 "…and close says so"
$B/ask in-force $q --as-of 2026-10-23T18:30 > /dev/null; check $? 0 "the answer is in force on 23.10"
$B/ask in-force $q --as-of 2026-10-24T20:25 > $R/q2.out; check $? 4 "…not on 24.10"
q=$($B/ask add --stage stage-a --print-id "Прибыль итога сегодня считается иначе — так и оставить?" 2>/dev/null)
$B/ask close $q --answer "оставить как есть, это правильно" --date 2026-10-23 > /dev/null 2>&1
block $q | grep -q -- '- until:'; check $? 1 "negative: a full answer does not take the question's descriptive «сегодня»"
# an entry recorded before `until` existed (Q-MC-009 as written) takes its bound from its words
cat >> $F <<'EOF'

## Q-A-090 — Релиз прода Чура (и Доли) сегодня: максимум стабильного функционала
- kind: question
- status: answered: владелец 23.10 14:05: «подбейте релизец с хабами в ближайшие пол часа» — да на прод-тег сегодняшнего релиза (2026-10-23 14:17)
- asked: 2026-10-23 14:17
- by: agent
- due: 2026-10-23T14:40
- blocks: not set
- default: not set
- source: not set
EOF
$B/ask in-force Q-A-090 --as-of 2026-10-23T18:32 > /dev/null; check $? 0 "Q-MC-009 replay: in force on 23.10 18:32"
$B/ask in-force Q-A-090 --as-of 2026-10-24T20:25 > $R/q3.out; check $? 4 "Q-MC-009 replay: not in force at the 24.10 20:25 release"
grep -q 'bound to 2026-10-23 23:59 and has expired' $R/q3.out; check $? 0 "…says why"
$B/ask digest | grep -q '^Q-A-090 \[expired 2026-10-23 23:59, not in force\]'; check $? 0 "digest marks the lapsed answer"
$B/ask search релизец | grep -q 'expired 2026-10-23 23:59, not in force'; check $? 0 "search marks it too"
$B/ask decided --stage stage-a "Релиз 2 под Q-A-090" > /dev/null 2> $R/d1.err
grep -q 'cites Q-A-090 .*not the owner.s word for today' $R/d1.err; check $? 0 "a decision citing a lapsed answer warns"
$B/ask decided --stage stage-a "Мерж под A-A-002" > /dev/null 2> $R/d2.err
grep -q 'cites' $R/d2.err; check $? 1 "negative: citing a grant in force does not warn"
$B/ask in-force D-A-001 > /dev/null; check $? 4 "a decision is not an owner's answer or permission"

# ---- 3. a hub never approves its own plan
$B/ask plan --stage stage-a --by agent --source "$R/stage-a/coordinator/HANDOFF-hub-2026-10-25.md" \
  "Продолжить исходный DoD" > $R/p1.out 2> $R/p1.err; check $? 0 "plan from the hub's handoff: recorded"
block P-A-001 | grep -qx -- '- status: proposed'; check $? 0 "…as proposed, not approved"
grep -q 'PROPOSED, not approved: no owner.s words' $R/p1.err && grep -q 'A hub never approves its own plan' $R/p1.err; check $? 0 "…and tells the hub to ask the owner"
sed -n 2p $R/p1.out | grep -q '^P-A-001 proposed '; check $? 0 "…the journal line says proposed"
$B/ask plan --stage stage-a --words "«да»" --source "/x/HANDOFF-hub.md" "Plan B" > /dev/null 2> $R/p2.err
block P-A-002 | grep -qx -- '- status: proposed'; check $? 0 "owner words retold in a handoff: still proposed"
grep -q "is an agent's file, not the owner's word" $R/p2.err; check $? 0 "…and says the handoff is not the owner's word"
$B/ask list --stage stage-a | grep -q '^P-A-001 \[stage-a\] proposed'; check $? 0 "a proposed plan is unresolved"
$B/ask summary | grep -q "plan proposed, awaiting the owner's yes 2"; check $? 0 "summary counts proposed plans"
$B/ask inbox --stage stage-a 2>/dev/null | grep -q 'P-A-001 plan proposed, awaiting your yes'; check $? 0 "the owner's inbox shows it"
$B/ask plan --stage stage-a --words "«да, делай»" --source "owner, chat 25.10 19:20" "Plan C" > /dev/null 2> $R/p3.err
block P-A-003 | grep -qx -- '- status: approved' && block P-A-003 | grep -qx -- '- words: «да, делай»'; check $? 0 "owner's quoted words with their source: approved"
grep -q PROPOSED $R/p3.err; check $? 1 "negative: no proposed note for an approved plan"
q=$($B/ask add --stage stage-a --print-id "План D?" 2>/dev/null)
$B/ask close $q --answer "да, план D ок" > /dev/null 2>&1
$B/ask plan --stage stage-a --source $q "Plan D" > /dev/null 2>&1
block P-A-004 | grep -qx -- '- status: approved' && block P-A-004 | grep -qx -- '- words: да, план D ок'; check $? 0 "an answered question as the source: approved with its answer"
$B/ask plan --stage stage-a --source Q-A-090 "Plan E" > /dev/null 2> $R/p5.err
block P-A-005 | grep -qx -- '- status: proposed'; check $? 0 "an expired answer as the source: proposed"
$B/ask allow --stage stage-a --scope stage --class "plan" --words "«планы утверждай сам в рамках DoD»" "plans" > /dev/null 2>&1   # A-A-013
$B/ask plan --stage stage-a --source A-A-013 "Plan F" > /dev/null 2>&1
block P-A-006 | grep -qx -- '- status: approved'; check $? 0 "a standing permission naming plan: approved"
$B/ask plan --stage stage-a --source A-A-002 "Plan G" > /dev/null 2> $R/p7.err
block P-A-007 | grep -qx -- '- status: proposed' && grep -q 'does not name plan approval' $R/p7.err; check $? 0 "a permission for merge only: proposed"
$B/ask approve P-A-001 --source "handoff" > /dev/null 2> $R/ap1.err; check $? 1 "approve without the owner's words: refused"
block P-A-001 | grep -qx -- '- status: proposed'; check $? 0 "…the plan stays proposed"
$B/ask approve P-A-001 --words "«да, продолжай»" --source "owner, chat 25.10 21:40" > $R/ap2.out; check $? 0 "approve with the owner's words"
block P-A-001 | grep -qx -- '- status: approved' && block P-A-001 | grep -q -- '^- approved: 20'; check $? 0 "…approved, stamped"
grep -q '^P-A-001 approved ' $R/ap2.out; check $? 0 "…prints a journal line"
$B/ask approve P-A-001 --words x --source "owner, chat" > /dev/null 2>&1; check $? 1 "negative: approving twice refused"
$B/ask close P-A-002 --answer "да" > /dev/null 2> $R/cl.err; check $? 1 "close on a plan: refused"
grep -q 'ask approve' $R/cl.err; check $? 0 "…pointing at ask approve"
exit $fail
