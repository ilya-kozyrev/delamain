#!/bin/bash
# The watchdog does not hit a wall and does not repeat itself (w1121 audit § 7 items 1 and 3):
# 1. a hub whose last turn hit the usage limit is not woken (nor the owner notified) before the reset its error names + 5 min,
#    and is woken once after it; a usage limit that names no reset keeps the old backoff
# 2. an account-level error (verification_required, …) is never woken; the owner is notified once per episode
# 3. "wake failed" reaches the owner once per episode (resume exits 1; resume ok but no activity), the log keeps every attempt
# 4. a Desktop hub that cannot be woken: notified on the first attempt, then only when more lines wait, at most every 4 h
# 5. "jwait does not match" counts only lines at least 3 min old (a younger one may sit in the live waiter's settle)
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
export HOME=$R/home; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR=$R/claude-home CLAUDE_SESSIONS_DIR=$R/desktop
export CLAUDE_BIN=$T/fake_claude_wd.py FAKE_WD_ROWS=$R/rows.json FAKE_WD_LOG=$R/claude.log
export AGENT_HUB_WATCHDOG=on
unset AGENT_HUB_NOTIFY_CMD AGENT_HUB_WATCHDOG_NOW AGENT_HUB_WATCHDOG_WAKE_AFTER AGENT_HUB_WATCHDOG_BACKOFF_MAX FAKE_WD_RESUME
FB=$R/fakebin; mkdir -p "$FB"; : > "$R/notify.log"; : > "$R/claude.log"
for n in osascript notify-send; do printf '#!/bin/sh\necho "local: $*" >> "%s"\n' "$R/notify.log" > "$FB/$n"; chmod +x "$FB/$n"; done
export PATH="$FB:$PATH"
FX(){ python3 "$T/watchdog_fixture.py" "$@"; }
J(){ cat "$R/$1"/coordinator/work/journal-*.md 2>/dev/null; }
count(){ local n; n=$(grep -c -- "$1" 2>/dev/null); echo "${n:-0}"; }
resumed(){ FX claude-calls "$R/claude.log" | grep -c '^resume'; }
CWD=$R/hubcwd; mkdir -p "$CWD"; export FX_CWD=$CWD
U(){ printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }
WAITER=
trap '[ -n "$WAITER" ] && kill $WAITER 2>/dev/null; test_cleanup' EXIT
# one base minute for every tick of the file; FX_NOW makes the fixtures count "minutes ago" from it
T0=$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M"))'); export FX_NOW=$T0
at(){ python3 -c 'import datetime as d,sys; print((d.datetime.fromisoformat(sys.argv[1])+d.timedelta(seconds=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M:%S"))' "$T0" "$1"; }
tick(){ AGENT_HUB_WATCHDOG_NOW=$(at $(( $2 * 60 ))) "$B/watchdog" run --stage "$1" >> "$R/tick.out" 2>&1; }  # STAGE MINUTES-after-T0
# bhub STAGE SID: a `claude --bg` hub (tag hub-4), listed idle, with saved options, silent 20 min
bhub(){
  mkdir -p "$R/$1/coordinator/work"
  "$B/roles" set --stage "$1" hub "$2" --kind cli --tag hub-4 > /dev/null
  FX backdate "$1" 300; FX hubfield "$1" host bg
  FX transcript "$2" 20 ok; FX job "$2" "$CWD"
  FX rows "$FAKE_WD_ROWS" "${2:0:8}" "$2" background idle "$CWD"
}

# ---------------------------------------------------------------- 1. usage limit: not before the reset + 5 min
RESET=$(python3 -c 'import datetime as d,sys; t=d.datetime.fromisoformat(sys.argv[1])+d.timedelta(minutes=60); print(t.strftime("%I:%M%p").lstrip("0").lower())' "$T0")
L1=$(U 1); bhub slim $L1; FX transcript $L1 16 error rate_limit "You've hit your 5-hour limit · resets $RESET (UTC)"
: > "$R/claude.log"; : > "$R/notify.log"
for m in 0 15 30 45 60 64; do tick slim $m; done
check "$(resumed)" 0 "limit: no wake before the reset + 5 min (ticks at +0…+64, reset at +60)"
check "$(count slim < "$R/notify.log")" 0 "limit: …and no notification before it"
check "$(J slim | count 'woke\|failed')" 0 "limit: …and no wake record in the journal"
tick slim 66; check "$(resumed)" 1 "limit: one wake after the reset + 5 min"
L2=$(U 2); bhub slim2 $L2; FX transcript $L2 16 error rate_limit "You've hit your 5-hour limit"
: > "$R/claude.log"; tick slim2 0; check "$(resumed)" 1 "limit control: a usage limit that names no reset is woken as before"
python3 - "$B" <<'PY'
import datetime as dt, importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("wd", f"{sys.argv[1]}/watchdog")
wd = importlib.util.module_from_spec(importlib.util.spec_from_loader("wd", loader)); loader.exec_module(wd)
at = dt.datetime(2026, 11, 12, 13, 10, tzinfo=dt.timezone.utc)  # 16:10 in Moscow
want = {"You've hit your 5-hour limit · resets 6:20pm (Europe/Moscow)": "2026-11-12T15:20+00:00",
        "You've hit your session limit · resets 1pm (Europe/Moscow)": "2026-11-13T10:00+00:00",
        "You've hit your weekly limit · resets Nov 24, 2am (Europe/Moscow)": "2026-11-23T23:00+00:00",
        "You've hit your session limit · resets 12:20am (Europe/Volgograd)": "2026-11-12T21:20+00:00"}
for text, iso in want.items():
    got = wd.limit_reset(at, text).astimezone(dt.timezone.utc).isoformat(timespec="minutes")
    assert got == iso, (text, got, iso)
assert wd.limit_reset(at, "API Error") is None
PY
check $? 0 "limit: the reset is read from the error text (time, hour only, a date, midnight, the zone named)"

# ---------------------------------------------------------------- 2. account-level error: never woken, notified once
k=10; for e in verification_required authentication_failed oauth_org_not_allowed; do
  k=$((k + 1)); A=$(U $k); bhub "sacc-$e" $A; FX transcript $A 16 error $e "API Error: Your account can't receive replies"
  FX jline "sacc-$e" 16 "[exec-1] DONE a line for the blocked hub"
  : > "$R/claude.log"; : > "$R/notify.log"
  for m in 0 15 45 105 165 225 400; do tick "sacc-$e" $m; done
  check "$(resumed)" 0 "account ($e): never woken, across 7 ticks"
  check "$(count "sacc-$e — account blocked" < "$R/notify.log")" 1 "account ($e): …the owner notified once"
  check "$(count "sacc-$e" < "$R/notify.log")" 1 "account ($e): …and nothing else (no 'wake failed', no 'hub silent')"
done
FX transcript $A 0 ok; tick "sacc-oauth_org_not_allowed" 410
FX transcript $A 0 error oauth_org_not_allowed "blocked again"; tick "sacc-oauth_org_not_allowed" 430
check "$(count "account blocked" < "$R/notify.log")" 2 "account: a new block after the hub recovered is a new episode (notified again)"

# ---------------------------------------------------------------- 3. "wake failed": once per episode
W1=$(U 30); bhub swf $W1; FX jline swf 16 "[exec-1] @hub-4 a line while the wake fails"
: > "$R/claude.log"; : > "$R/notify.log"
for m in 0 15 45 105; do FAKE_WD_RESUME=fail tick swf $m; done
check "$(resumed)" 4 "wake failed: four attempts (the backoff is unchanged)"
check "$(J swf | count 'wake of hub-4 failed')" 4 "wake failed: …every attempt journaled"
check "$(grep -c 'wake of hub-4 failed' "$R/.state/watchdog/log.md")" 4 "wake failed: …and logged"
check "$(count 'swf — wake failed' < "$R/notify.log")" 1 "wake failed: …the owner notified once"
W2=$(U 31); bhub swv $W2; FX jline swv 16 "[exec-1] DONE a line, the wake leaves no trace"
: > "$R/notify.log"
for m in 0 6 15 21 45 51; do tick swv $m; done
check "$(J swv | count 'no activity of the hub within')" 3 "wake failed (verification): three wakes without activity are journaled"
check "$(count 'swv — wake failed' < "$R/notify.log")" 1 "wake failed (verification): …the owner notified once"

# ---------------------------------------------------------------- 4. a Desktop hub: bounded notifications
D1=$(U 40); D1CLI=$(U 41); mkdir -p "$CLAUDE_SESSIONS_DIR/a/b"
printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"Hub desk","isArchived":false}' "$D1" "$D1CLI" > "$CLAUDE_SESSIONS_DIR/a/b/local_$D1.json"
mkdir -p "$R/sdesk/coordinator/work"; "$B/roles" set --stage sdesk hub "local_$D1" --kind desktop --tag hub-5 > /dev/null
FX backdate sdesk 300; FX transcript "$D1CLI" 20 ok; FX jline sdesk 16 "[exec-1] DONE a line for the desktop hub"
: > "$R/notify.log"
for h in $(seq 0 19); do AGENT_HUB_WATCHDOG_BACKOFF_MAX=1h tick sdesk $((h * 60 + 1)); done
n=$(count 'sdesk — hub silent' < "$R/notify.log")
check "$([ "$n" -le 6 ] && echo ok || echo "$n")" ok "desktop: 20 hourly ticks with an unchanged count → at most 6 notifications"
check "$n" 1 "desktop: …in fact one (the first attempt)"
check "$(grep -c 'hub-5 (desktop) is not woken' "$R/.state/watchdog/log.md")" 20 "desktop: …while the log keeps every attempt"
FX_NOW=$(at $((19 * 60 * 60 + 600))) FX jline sdesk 0 "[exec-1] DONE a second line"
AGENT_HUB_WATCHDOG_BACKOFF_MAX=1h tick sdesk $((20 * 60 + 1))
check "$(count 'sdesk — hub silent .* 2 lines waiting' < "$R/notify.log")" 1 "desktop: more lines waiting, 4 h after the last notice → notified again"
AGENT_HUB_WATCHDOG_BACKOFF_MAX=1h tick sdesk $((21 * 60 + 1))
check "$(count 'sdesk — hub silent' < "$R/notify.log")" 2 "desktop: …and not again for the same count"

# ---------------------------------------------------------------- 5. "jwait does not match": only lines >= 3 min old
mism(){  # STAGE SID LINE-AGE-MIN TICK-SECONDS: a hub with a live jwait that does not consume the line, one tick
  bhub "$1" "$2"; FX jline "$1" "$3" "[exec-1] DONE a line in the waiter's settle"
  "$B/jwait" --journal --stage "$1" --caller hub-4 --match NEVER-MATCHES-zq --settle 1 --for 120s > "$R/w-$1.out" 2>&1 & WAITER=$!
  armed "$R/w-$1.out"
  AGENT_HUB_WATCHDOG_NOW=$(at "$4") "$B/watchdog" run --stage "$1" >> "$R/tick.out" 2>&1
  kill -TERM $WAITER 2>/dev/null; wait $WAITER 2>/dev/null; WAITER=
}
mism smm1 "$(U 50)" 0 30
check "$(J smm1 | count 'does not match')" 0 "mismatch: a matching line 30 s old under a live jwait writes no message"
mism smm2 "$(U 51)" 5 0
check "$(J smm2 | count 'does not match 1 lines')" 1 "mismatch: …a line 5 min old does"

exit $fail
