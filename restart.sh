#!/bin/bash
# Restarts every Ronny service and follows their logs.
#
#   ./restart.sh           restart what is already built
#   ./restart.sh --build   rebuild first, which is what a deploy is
#
# Ctrl-C stops following the logs; the services keep running.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ "${1:-}" = "--build" ]; then
    # Both flags, always: a plain build links a CPU-only whisper. See AGENTS.md.
    zig build -Doptimize=ReleaseSafe -Dwhisper-prefix="$HOME/.local/opt/whisper-cuda"
fi
if ! readelf -d zig-out/bin/ronny | grep -q 'whisper-cuda'; then
    echo "zig-out/bin/ronny is not linked against whisper-cuda; run ./restart.sh --build" >&2
    exit 1
fi

# Unit files may have changed with a pull.
sudo systemctl daemon-reload
sudo systemctl restart ronny-watch ronny-bot ronny-watchdog
systemctl --user daemon-reload
systemctl --user is-enabled --quiet ronny-log-review.timer 2>/dev/null ||
    echo "note: the daily log review timer is not enabled (see systemd/ronny-log-review.service)"

systemctl status ronny-watch ronny-bot ronny-watchdog --no-pager --lines=0 | grep -E '●|Active:'

journalctl -u ronny-watch -u ronny-bot -u ronny-watchdog --user-unit ronny-log-review -f --since "-1min"
