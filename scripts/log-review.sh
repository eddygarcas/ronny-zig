#!/usr/bin/env bash
# Runs the ronny-log-review agent over the last day of logs, once.
#
# Started by the ronny-log-review user timer (systemd/ronny-log-review.*).
# The agent works in a worktree of its own, on a fresh branch cut from
# origin/main, so the running binary in the main checkout and whatever the
# owner has in progress there are never touched. What it commits is pushed
# as that branch -- never main -- and only when the tests pass; the owner
# merges and deploys. The report goes to data/log-reviews/ and to Telegram.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worktree="${RONNY_REVIEW_WORKTREE:-$repo-logreview}"
stamp="$(date +%F-%H%M)"
branch="logreview/$stamp"
reports="$repo/data/log-reviews"
report="$reports/$stamp.txt"
errors="$reports/$stamp.stderr"
mkdir -p "$reports"

log() { printf '%s %s\n' "$(date +%T)" "$*"; }

notify() {
    # sendMessage only; never getUpdates, which would steal the bot's updates.
    # The token goes to curl on stdin so it never shows in the process list.
    local token chat outgoing code
    token="$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$repo/.env" | cut -d= -f2-)"
    chat="$(grep -m1 '^TELEGRAM_OWNER_CHAT_ID=' "$repo/.env" | cut -d= -f2-)"
    if [ -z "$token" ] || [ -z "$chat" ]; then
        log "no Telegram token or chat id in .env; report left in $report"
        return 0
    fi
    # Telegram caps a message at 4096 characters; iconv drops a UTF-8
    # sequence the byte cut may have split, which Telegram would refuse.
    outgoing="$reports/$stamp.send"
    head -c 3900 "$1" | iconv -c -f utf-8 -t utf-8 > "$outgoing"
    # Logged from this process, not from the end of the pipe: journald
    # cannot tie a line from a subshell that has already exited to the unit,
    # so `journalctl --user -u ronny-log-review` did not show it.
    code="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
        curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -K - \
            --data-urlencode "chat_id=$chat" --data-urlencode "text@$outgoing")"
    log "telegram answered ${code:-nothing}"
    rm -f "${outgoing:?}"
}

tests_pass() {
    local out
    out="$(cd "$worktree" && zig build test -Doptimize=ReleaseSafe \
        -Dwhisper-prefix="$HOME/.local/opt/whisper-cuda" 2>&1)"
    # The wrapper can say "failed command" when everything passed; the run
    # line is what counts.
    grep -Eq 'run test [0-9]+ pass \([0-9]+ total\)' <<< "$out" &&
        ! grep -Eq 'run test [0-9]+ pass, [0-9]+ fail' <<< "$out"
}

log "fetching origin"
git -C "$repo" fetch -q origin main || { log "fetch failed"; exit 1; }
if [ ! -d "$worktree" ]; then
    git -C "$repo" worktree add -q --detach "$worktree" origin/main || exit 1
fi
# Only the agent ever writes here, so yesterday's leftovers are safe to drop.
# Its commits survive on their own branch; ignored files (the zig cache) stay.
git -C "$worktree" reset -q --hard
git -C "$worktree" clean -qfd
git -C "$worktree" checkout -q -b "$branch" origin/main || exit 1

log "running the agent on $branch"
prompt="Review the last 24 hours of Ronny's logs and apply the fixes they justify. Today is $(date +%F). You are on branch $branch in $worktree."
(
    cd "$worktree" &&
    timeout 45m claude -p --agent ronny-log-review \
        --permission-mode dontAsk \
        --allowedTools Read Grep Glob Edit Write WebFetch \
            "Bash(journalctl *)" "Bash(zig build *)" "Bash(zig version)" "Bash(readelf *)" \
            "Bash(git status *)" "Bash(git status)" "Bash(git diff *)" "Bash(git diff)" \
            "Bash(git log *)" "Bash(git show *)" "Bash(git add *)" "Bash(git commit *)" \
            "Bash(grep *)" "Bash(sed -n *)" "Bash(wc *)" "Bash(ls *)" "Bash(head *)" "Bash(tail *)" \
        --disallowedTools "Read(**/.env)" "Bash(git push *)" "Bash(sudo *)" "Bash(zig build probe*)" \
        --output-format text \
        "$prompt"
) > "$report" 2> "$errors"
status=$?
[ -s "$errors" ] || rm -f "${errors:?}"
log "agent exited $status"

commits="$(git -C "$worktree" rev-list --count origin/main..HEAD)"
footer=""
if [ "$status" -ne 0 ]; then
    footer="The review did not finish (exit $status); see $reports on the server."
elif [ "$commits" -gt 0 ]; then
    if tests_pass; then
        if git -C "$worktree" push -q origin "$branch"; then
            footer="$commits commit(s) pushed as branch $branch, not deployed. Merge it into main and restart to apply."
        else
            footer="$commits commit(s) on $branch, but the push failed; they are in $worktree."
        fi
    else
        footer="$commits commit(s) on $branch left unpushed: the tests do not pass on it."
    fi
fi
[ -n "$footer" ] && printf '\n\n%s\n' "$footer" >> "$report"
[ -s "$report" ] || printf 'The log review produced no report (exit %s).\n' "$status" > "$report"

notify "$report"
exit "$status"
