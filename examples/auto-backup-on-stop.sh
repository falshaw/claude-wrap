#!/usr/bin/env bash
# Optional Stop hook: runs your backup in the background at most once per DEBOUNCE seconds.
# Claude never waits on it. /wrap still runs and VERIFIES a fresh backup at session end;
# this hook only narrows the gap between wraps.
#
# Wire it up with examples/settings.stop-hook.json. Configure via env:
#   WRAP_BACKUP_CMD   command to run (required, e.g. "bash scripts/backup-rsync.sh")
#   WRAP_BACKUP_DEBOUNCE  seconds between runs (default 3600)

set -u
cmd="${WRAP_BACKUP_CMD:-}"
[ -z "$cmd" ] && exit 0

root="${CLAUDE_PROJECT_DIR:-$PWD}"
state="$root/.claude/.last-auto-backup"
log="$root/.claude/auto-backup.log"
debounce="${WRAP_BACKUP_DEBOUNCE:-3600}"

if [ -f "$state" ]; then
  last=$(date -r "$state" +%s 2>/dev/null || stat -c %Y "$state")
  now=$(date +%s)
  [ $((now - last)) -lt "$debounce" ] && exit 0
fi

# Touch the state file before forking so two quick stops do not both fire.
mkdir -p "$root/.claude" && touch "$state"
( cd "$root" && nohup bash -c "$cmd" > "$log" 2>&1 & ) >/dev/null 2>&1
exit 0
