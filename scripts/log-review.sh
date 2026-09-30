#!/usr/bin/env bash
# Runs the ronny-log-review agent over the last day of logs, once.
#
# Started by the ronny-log-review user timer (systemd/ronny-log-review.*).
# The agent works in a worktree of its own, on a fresh branch cut from
# origin/main, so the running binary in the main checkout and whatever the
# owner has in progress there are never touched while it works. What it
# commits is pushed as that branch when the tests pass, then deployed: fast-
# forwarded into main, rebuilt, restarted with restart.sh, and rolled back
# if the services do not come back healthy (see deploy below). The report
# goes to data/log-reviews/ and to Telegram.
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

# Paths an unattended deploy never ships, however green the tests are: the
# send gate and the deploy machinery itself. A branch touching any of them
# is pushed and left for the owner to merge by hand.
GUARDED='^(src/decision\.zig|src/mailer\.zig|docs/send-safety\.md|\.env|config/|systemd/|scripts/|restart\.sh|\.claude/)'

# How long the services must stay up after a restart to count as healthy.
# Long enough for the bot to load whisper and poll, and for the watcher to
# log in and select the inbox.
HEALTH_WAIT_SECONDS=90

# Merges the branch into the main checkout, rebuilds, restarts, and checks
# the services came back. Rolls the binary and main back if they did not.
# Sets `footer` to what happened. The owner's checkout is only touched when
# it is on main with nothing uncommitted, so work in progress is never
# merged into or reset.
deploy() {
    local touched old_head since unhealthy=""
    touched="$(git -C "$worktree" diff --name-only origin/main..HEAD)"
    if grep -Eq "$GUARDED" <<< "$touched"; then
        footer="$commits commit(s) pushed as branch $branch, not deployed: they touch the send gate or the deploy scripts, which only you merge."
        return
    fi
    if [ "$(git -C "$repo" branch --show-current)" != "main" ] ||
        [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ] ||
        ! git -C "$repo" merge-base --is-ancestor HEAD "$branch"; then
        footer="$commits commit(s) pushed as branch $branch, not deployed: the main checkout is not on a clean main that the branch builds on."
        return
    fi
    # Without the sudoers rule the restart would fail after the merge and
    # the build; better to find out before touching anything. Tested by
    # running the harmless half of the rule, because `sudo -l` says yes to
    # anything a blanket "(ALL) ALL" permits even when it wants a password,
    # and -k so a login cached from the owner's own sudo does not pass.
    if ! sudo -n -k /usr/bin/systemctl daemon-reload >/dev/null 2>&1; then
        footer="$commits commit(s) pushed as branch $branch, not deployed: the restart needs systemd/ronny-deploy.sudoers installed."
        return
    fi

    old_head="$(git -C "$repo" rev-parse HEAD)"
    cp -p "$repo/zig-out/bin/ronny" "$repo/zig-out/bin/ronny.previous"
    git -C "$repo" merge -q --ff-only "$branch" || {
        footer="$commits commit(s) pushed as branch $branch, not deployed: it does not fast-forward main."
        return
    }

    log "deploying $branch"
    since="$(date '+%F %T')"
    if ! "$repo/restart.sh" --build --no-follow; then
        unhealthy="the build or the restart failed"
    else
        sleep "$HEALTH_WAIT_SECONDS"
        for unit in ronny-watch ronny-bot ronny-watchdog; do
            systemctl is-active --quiet "$unit" || unhealthy="$unit is not running"
        done
        # Each service's own "I am up" line, rather than the absence of an
        # exit: the watcher exits on an IMAP drop by design and systemd
        # restarts it, so "Main process exited" alone would roll back a
        # good deploy over a network blip. A panic is never by design.
        local after
        after="$(journalctl -u ronny-watch -u ronny-bot -u ronny-watchdog --since "$since" --no-pager -o cat)"
        if [ -z "$unhealthy" ] && grep -Eq 'thread [0-9]+ panic|reached unreachable' <<< "$after"; then
            unhealthy="a service panicked after the restart"
        fi
        [ -z "$unhealthy" ] && ! grep -q 'telegram polling started' <<< "$after" &&
            unhealthy="the bot never started polling Telegram"
        [ -z "$unhealthy" ] && ! grep -q 'resuming from uid' <<< "$after" &&
            unhealthy="the watcher never opened the inbox"
        [ -z "$unhealthy" ] && ! grep -q 'watchdog started' <<< "$after" &&
            unhealthy="the watchdog never started"
        if [ -z "$unhealthy" ] && grep 'whisper backend' <<< "$after" | grep -qv CUDA; then
            unhealthy="whisper came up on the CPU"
        fi
    fi

    if [ -z "$unhealthy" ]; then
        if git -C "$repo" push -q origin main; then
            footer="$commits commit(s) deployed: merged into main, rebuilt and restarted, all three services healthy after ${HEALTH_WAIT_SECONDS}s. Main is pushed."
        else
            footer="$commits commit(s) deployed and healthy, but pushing main failed; it is ahead of origin on this machine."
        fi
        return
    fi

    log "rolling back: $unhealthy"
    git -C "$repo" reset -q --hard "$old_head"
    cp -p "$repo/zig-out/bin/ronny.previous" "$repo/zig-out/bin/ronny"
    if "$repo/restart.sh" --no-follow; then
        footer="$commits commit(s) on $branch were deployed and rolled back: $unhealthy. The previous build is running again; the branch is pushed for you to look at."
    else
        footer="$commits commit(s) on $branch were deployed and rolled back ($unhealthy), but restarting the previous build ALSO failed. Ronny may be down: run ./restart.sh."
    fi
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
            deploy
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
