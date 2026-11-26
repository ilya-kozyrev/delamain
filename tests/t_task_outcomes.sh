#!/bin/bash
# Lifecycle and writer controls; only stand-in CLIs, isolated by lib.sh.
. "$(dirname "$0")/lib.sh"
new_home
export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py
python3 "$T/task_outcomes_test.py" "$B"
check $? 0 "task outcomes positive and negative controls"
exit $fail
