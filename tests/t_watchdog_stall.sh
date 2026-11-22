#!/bin/bash
# The watchdog wakes a stalled hub once (w1121 audit § 7 item 2): the stage is open, nothing of it runs (no agent, no
# await), the hub has no waiter and no alarm, no owner question blocks, the stage is not quiet, the hub has been silent
# more than 2 h and it is daytime (outside AGENT_HUB_NIGHT, 23:00-08:00 by default) → one wake per stall episode
# ("nothing runs in <stage>: …"); a hub that cannot be woken (Desktop) → one notification instead. A dead turn is no stall.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
export HOME=$R/home; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR=$R/claude-home CLAUDE_SESSIONS_DIR=$R/desktop
export CLAUDE_BIN=$T/fake_claude_wd.py FAKE_WD_ROWS=$R/rows.json FAKE_WD_LOG=$R/claude.log
export AGENT_HUB_WATCHDOG=on
unset AGENT_HUB_NOTIFY_CMD AGENT_HUB_WATCHDOG_NOW AGENT_HUB_WATCHDOG_WAKE_AFTER AGENT_HUB_WATCHDOG_BACKOFF_MAX AGENT_HUB_NIGHT FAKE_WD_RESUME
FB=$R/fakebin; mkdir -p "$FB"; : > "$R/notify.log"; : > "$R/claude.log"
for n in osascript notify-send; do printf '#!/bin/sh\necho "local: $*" >> "%s"\n' "$R/notify.log" > "$FB/$n"; chmod +x "$FB/$n"; done
export PATH="$FB:$PATH"
FX(){ python3 "$T/watchdog_fixture.py" "$@"; }
J(){ cat "$R/$1"/coordinator/work/journal-*.md 2>/dev/null; }
count(){ local n; n=$(grep -c -- "$1" 2>/dev/null); echo "${n:-0}"; }
calls(){ FX claude-calls "$R/claude.log"; }
resumed(){ calls | grep -c '^resume'; }
stall_text(){ python3 -c 'import json,sys; [print(json.loads(l)["argv"][-1]) for l in open(sys.argv[1]) if "--resume" in l]' "$R/claude.log"; }
CWD=$R/hubcwd; mkdir -p "$CWD"; export FX_CWD=$CWD; echo "brief: hold" > "$CWD/b.md"
spawn(){ (cd "$CWD" && FAKE_HOLD=120 "$B/agent" spawn --stage "$1" --role w1 --cwd "$CWD" --model haiku --brief "$CWD/b.md" > "$R/spawn-$1.out" 2>&1); }
U(){ printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; for f in $R/*/agents/*/meta.json; do d=$(dirname "$f"); "$B/agent" stop --stage "$(basename "$(dirname "$(dirname "$d")")")" "$(basename "$d")" >/dev/null 2>&1; done; test_cleanup' EXIT
# the base: noon today (UTC, the tests' zone); "N minutes ago" in the fixtures counts from it
T0=$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT12:00"))'); export FX_NOW=$T0
at(){ python3 -c 'import datetime as d,sys; print((d.datetime.fromisoformat(sys.argv[1])+d.timedelta(minutes=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M"))' "$T0" "$1"; }
tick(){ AGENT_HUB_WATCHDOG_NOW=$(at "$2") "$B/watchdog" run --stage "$1" >> "$R/tick.out" 2>&1; }   # STAGE MINUTES-after-noon
# bhub STAGE SID [SILENT-MIN]: a `claude --bg` hub (hub-4), listed idle, with saved options, silent 150 min by default
bhub(){
  : > "$R/claude.log"
  mkdir -p "$R/$1/coordinator/work"
  "$B/roles" set --stage "$1" hub "$2" --kind cli --tag hub-4 > /dev/null
  FX backdate "$1" 1000; FX hubfield "$1" host bg
  FX transcript "$2" "${3:-150}" ok; FX job "$2" "$CWD"
  FX rows "$FAKE_WD_ROWS" "${2:0:8}" "$2" background idle "$CWD"
}
nowake(){  # STAGE WHY: one daytime tick wakes nobody and writes no stall line
  tick "$1" 0
  check "$(resumed)" 0 "stall negative: $2 → not woken"
  check "$(J "$1" | count 'nothing runs')" 0 "stall negative: $2 → no stall line in the journal"
}

# ---------------------------------------------------------------- one wake per stall episode
bhub sst $(U 1)
for m in 0 5 30 120 300 480; do tick sst $m; done
check "$(resumed)" 1 "stall: a hub silent 150 min with nothing running is woken once across six daytime ticks"
stall_text | grep -q "nothing runs in sst: continue the plan, or \`watchdog quiet --reason …\`, or \`roles retire hub\`"
check $? 0 "stall: …with the text that names the three ways out"
check "$(J sst | count 'woke hub-4 .*nothing runs')" 1 "stall: …and one journal line"
check "$(count sst < "$R/notify.log")" 0 "stall: …and no notification (the wake worked)"
# something runs, then stops: a new episode, woken once more
spawn sst
tick sst 490; check "$(resumed)" 1 "stall: an agent of the stage runs → the episode ends, no wake"
"$B/agent" stop --stage sst w1 > /dev/null 2>&1
tick sst 495; check "$(resumed)" 2 "stall: …when nothing runs again, a new episode wakes it once more"
tick sst 500; check "$(resumed)" 2 "stall: …once"

# ---------------------------------------------------------------- not a stall
bhub syoung $(U 2) 100; nowake syoung "silent 100 min (under 2 h)"
bhub snight $(U 3) 750                                                                # silent since 23:30 the night before
for m in -600 -560 -300 -250; do tick snight $m; done                                 # 02:00, 02:40, 07:00, 07:50
check "$(resumed)" 0 "stall negative: at night (AGENT_HUB_NIGHT 23:00-08:00) → not woken"
tick snight -235; check "$(resumed)" 1 "stall: …the same episode is woken once after 08:00"
bhub sagent $(U 4)
spawn sagent
nowake sagent "an agent of the stage runs"
"$B/agent" stop --stage sagent w1 > /dev/null 2>&1
bhub sawait $(U 5)
python3 -c 'import time; time.sleep(120)' await --wait --log "$R/sawait/coordinator/work/await.log" --label ci-7 & PIDS="$PIDS $!"
sleep 0.3; nowake sawait "an await of the stage runs"
bhub swait $(U 6)
"$B/jwait" --journal --stage swait --caller hub-4 --settle 1 --for 24h > "$R/w1.out" 2>&1 & PIDS="$PIDS $!"
armed "$R/w1.out"; nowake swait "the hub's own jwait is armed"
bhub salarm $(U 7)
"$B/jwait" --stage salarm --caller hub-4 --for 24h --note "look at the import" > "$R/w2.out" 2>&1 & PIDS="$PIDS $!"
armed "$R/w2.out"; nowake salarm "the hub has an alarm (jwait --for, no source)"
bhub sq $(U 8)
"$B/ask" add --stage sq --blocks "the release" --default "wait" "ship on Monday?" > /dev/null
nowake sq "an open owner question that blocks"
bhub sqnb $(U 9)
"$B/ask" add --stage sqnb --default "later" "a note, blocks nothing" > /dev/null
tick sqnb 0; check "$(resumed)" 1 "stall: an open question that blocks nothing does not stop the wake"
bhub squiet $(U 10)
"$B/watchdog" quiet --stage squiet --reason "waiting for the vendor" --for 48h > /dev/null
nowake squiet "watchdog quiet"
bhub sdead $(U 11); FX transcript $(U 11) 150 error verification_required "API Error: Your account can't receive replies"
tick sdead 0; check "$(stall_text | grep -c 'nothing runs')" 0 "stall negative: a dead turn is not a stall (no stall wake)"

# ---------------------------------------------------------------- a Desktop hub: one notification instead
D1=$(U 20); D1CLI=$(U 21); mkdir -p "$CLAUDE_SESSIONS_DIR/a/b"
printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"Hub desk","isArchived":false}' "$D1" "$D1CLI" > "$CLAUDE_SESSIONS_DIR/a/b/local_$D1.json"
mkdir -p "$R/sdesk/coordinator/work"; "$B/roles" set --stage sdesk hub "local_$D1" --kind desktop --tag hub-5 > /dev/null
FX backdate sdesk 600; FX transcript "$D1CLI" 150 ok; : > "$R/claude.log"; : > "$R/notify.log"
for m in 0 60 120 240 480; do tick sdesk $m; done
check "$(count 'sdesk — nothing runs' < "$R/notify.log")" 1 "stall desktop: one notification across five daytime ticks"
check "$(resumed)" 0 "stall desktop: …and never a resume"

exit $fail
