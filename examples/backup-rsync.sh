#!/usr/bin/env bash
# Example backup for /wrap: rsync mirror per target + per-target verification + JSON status.
#
# Usage:
#   BACKUP_PAIRS="/home/me/project=>/mnt/backup/project;/home/me/notes=>/mnt/backup/notes" \
#   BACKUP_STATUS=.claude/backup-status.json \
#   bash examples/backup-rsync.sh [--accept-prune]
#
# Behaviour:
#   - One run at a time (flock). A second run prints "SKIP - another backup run is in progress" and exits 0.
#   - Mirror with --delete, but a dry run first: if more than MAX_PRUNE files would be deleted on a target,
#     that target is ABORTED (source may be unmounted or damaged). Re-run with --accept-prune only on purpose.
#   - After copying, each target is verified: the newest 5 source files must exist on the target with the same
#     size. The status file records the newest file, its mtime and size, and the file count per target.
#   - The status file is written atomically (tmp + mv).
#   - Needs GNU find/stat/date and flock (Linux; on macOS: brew install coreutils findutils flock).
#   - Exit code 0 only if every target passed.

set -uo pipefail

PAIRS="${BACKUP_PAIRS:?set BACKUP_PAIRS to 'source=>target;source=>target'}"
STATUS="${BACKUP_STATUS:-.claude/backup-status.json}"
MAX_PRUNE="${BACKUP_MAX_PRUNE:-500}"
EXCLUDES=(--exclude node_modules --exclude .venv --exclude __pycache__ --exclude dist --exclude build --exclude '*.tmp')
ACCEPT_PRUNE=0
[ "${1:-}" = "--accept-prune" ] && ACCEPT_PRUNE=1

LOCK="${TMPDIR:-/tmp}/claude-wrap-backup.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "SKIP - another backup run is in progress"
  exit 0
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

all_ok=1
entries=()
IFS=';' read -ra pair_list <<< "$PAIRS"
for pair in "${pair_list[@]}"; do
  src="${pair%%=>*}"; dst="${pair##*=>}"
  name="$(basename "$src")"
  ok=false; rc=-1; detail=""; newest=""; newest_mtime=""; newest_size=0; count=0

  if [ ! -d "$src" ]; then
    detail="skipped - source missing"
  elif ! mkdir -p "$dst"; then
    detail="error - cannot create target"
  else
    # Guard: count what the mirror would delete before deleting anything.
    prune=$(rsync -a --delete --dry-run --itemize-changes "${EXCLUDES[@]}" "$src/" "$dst/" | grep -c '^\*deleting' || true)
    if [ "$prune" -gt "$MAX_PRUNE" ] && [ "$ACCEPT_PRUNE" -eq 0 ]; then
      detail="ABORTED - mirror would delete $prune files (> $MAX_PRUNE); check the source, then use --accept-prune"
    else
      rsync -a --delete "${EXCLUDES[@]}" "$src/" "$dst/"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        detail="rsync error rc=$rc"
      else
        # Verify: newest 5 source files must be on the target with identical size.
        fails=0; checked=0
        while read -r _ size rel; do
          checked=$((checked + 1))
          if [ ! -f "$dst/$rel" ] || [ "$(stat -c %s "$dst/$rel")" != "$size" ]; then
            fails=$((fails + 1)); echo "VERIFY FAIL [$name] $rel"
          fi
        done < <(find "$src" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -printf '%T@ %s %P\n' | sort -rn | head -5)

        read -r _ newest_size newest < <(find "$dst" -type f -printf '%T@ %s %P\n' | sort -rn | head -1)
        newest_mtime=$(date -u -r "$dst/$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        count=$(find "$dst" -type f | wc -l | tr -d ' ')

        if [ "$fails" -eq 0 ] && [ "${newest_size:-0}" -gt 0 ]; then
          ok=true; detail="mirror rc=$rc, $checked/$checked spot checks OK"
        else
          detail="verify failed - $fails of $checked spot checks missing or wrong size"
        fi
      fi
    fi
  fi

  [ "$ok" = true ] || all_ok=0
  echo "$( [ "$ok" = true ] && echo OK || echo FAIL )  $name: $detail"
  entries+=("\"$(json_escape "$name")\": {\"ok\": $ok, \"rc\": $rc, \"detail\": \"$(json_escape "$detail")\", \"newestFile\": \"$(json_escape "$newest")\", \"newestMtime\": \"$newest_mtime\", \"newestSize\": ${newest_size:-0}, \"fileCount\": $count}")
done

# Build the whole status document first, then write it atomically.
body=$(
  printf '{\n  "lastRun": "%s",\n  "targets": {\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for i in "${!entries[@]}"; do
    sep=","; [ "$i" -eq $((${#entries[@]} - 1)) ] && sep=""
    printf '    %s%s\n' "${entries[$i]}" "$sep"
  done
  printf '  }\n}'
)
mkdir -p "$(dirname "$STATUS")"
printf '%s\n' "$body" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
echo "status: $STATUS ($(wc -c < "$STATUS" | tr -d ' ') bytes)"

[ "$all_ok" -eq 1 ]
