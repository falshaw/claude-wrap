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
#     size, and the target's newest file must not be older than the source's newest file minus
#     BACKUP_MTIME_TOLERANCE seconds (default 120; rsync -a keeps source mtimes). The status file records the
#     newest file, its mtime and size, the source's newest mtime and the file count per target.
#   - node_modules, .venv, __pycache__, dist, build and *.tmp are never copied or checked.
#   - Each source folder name must be unique: it is the target's key in the status file.
#   - rsync exit 24 (source files vanished during the copy) is a warning, not a failure.
#   - The status file is written atomically (tmp + mv).
#   - Needs GNU find/stat/date and flock (Linux). On macOS: brew install coreutils findutils flock, then put the
#     GNU tools first on PATH:
#       export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$(brew --prefix)/opt/findutils/libexec/gnubin:$PATH"
#   - Exit code 0 only if every target passed.

set -uo pipefail

PAIRS="${BACKUP_PAIRS:?set BACKUP_PAIRS to 'source=>target;source=>target'}"
STATUS="${BACKUP_STATUS:-.claude/backup-status.json}"
MAX_PRUNE="${BACKUP_MAX_PRUNE:-500}"
TOLERANCE="${BACKUP_MTIME_TOLERANCE:-120}"
EXCLUDES=(--exclude node_modules --exclude .venv --exclude __pycache__ --exclude dist --exclude build --exclude '*.tmp')
ACCEPT_PRUNE=0
[ "${1:-}" = "--accept-prune" ] && ACCEPT_PRUNE=1

IFS=';' read -ra pair_list <<< "$PAIRS"

# Targets are keyed by the source folder name, so two sources with the same name would overwrite each other.
seen=$'\n'
for pair in "${pair_list[@]}"; do
  name="$(basename "${pair%%=>*}")"
  case "$seen" in
    *$'\n'"$name"$'\n'*)
      echo "ERROR - two sources share the folder name '$name'; rename one so each status entry is unique" >&2
      exit 2 ;;
  esac
  seen+="$name"$'\n'
done

LOCK="${TMPDIR:-/tmp}/claude-wrap-backup.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "SKIP - another backup run is in progress"
  exit 0
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# Source files as "mtime size relpath", skipping .git and everything EXCLUDES keeps out of the copy.
src_files() {
  find "$1" -mindepth 1 \( -name .git -o -name node_modules -o -name .venv -o -name __pycache__ \
    -o -name dist -o -name build \) -prune -o -type f -not -name '*.tmp' -printf '%T@ %s %P\n'
}

all_ok=1
entries=()
for pair in "${pair_list[@]}"; do
  src="${pair%%=>*}"; dst="${pair##*=>}"
  name="$(basename "$src")"
  ok=false; rc=-1; detail=""; newest=""; newest_mtime=""; newest_size=0; src_mtime=""; count=0

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
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
        detail="rsync error rc=$rc"
      else
        warn=""
        if [ "$rc" -eq 24 ]; then
          warn=" (warning: some source files vanished during the copy)"
          echo "WARN  [$name] rsync rc=24 - some source files vanished during the copy"
        fi

        # Verify: newest 5 source files must be on the target with identical size.
        top=$(src_files "$src" | sort -rn | head -5)
        fails=0; checked=0
        while read -r _ size rel; do
          [ -z "$rel" ] && continue
          checked=$((checked + 1))
          if [ ! -f "$dst/$rel" ] || [ "$(stat -c %s "$dst/$rel")" != "$size" ]; then
            fails=$((fails + 1)); echo "VERIFY FAIL [$name] $rel"
          fi
        done <<< "$top"

        # Freshness: the target's newest file must not be older than the source's newest, minus the tolerance.
        read -r src_t _ <<< "$top"
        src_t="${src_t:-0}"
        read -r dst_t newest_size newest < <(find "$dst" -type f -printf '%T@ %s %P\n' | sort -rn | head -1)
        dst_t="${dst_t:-0}"
        src_mtime=$(iso_utc "${src_t%.*}")
        newest_mtime=$(iso_utc "${dst_t%.*}")
        lag=$(( ${src_t%.*} - ${dst_t%.*} ))
        count=$(find "$dst" -type f | wc -l | tr -d ' ')

        if [ "$fails" -ne 0 ] || [ "$checked" -eq 0 ] || [ "${newest_size:-0}" -le 0 ]; then
          detail="verify failed - $fails of $checked spot checks missing or wrong size"
        elif [ "$lag" -gt "$TOLERANCE" ]; then
          detail="verify failed - target newest file is ${lag}s older than source newest (tolerance ${TOLERANCE}s)"
        else
          ok=true; detail="mirror rc=$rc$warn, $checked/$checked spot checks OK"
        fi
      fi
    fi
  fi

  [ "$ok" = true ] || all_ok=0
  echo "$( [ "$ok" = true ] && echo OK || echo FAIL )  $name: $detail"
  entries+=("\"$(json_escape "$name")\": {\"ok\": $ok, \"rc\": $rc, \"detail\": \"$(json_escape "$detail")\", \"newestFile\": \"$(json_escape "$newest")\", \"newestMtime\": \"$newest_mtime\", \"newestSize\": ${newest_size:-0}, \"sourceNewestMtime\": \"$src_mtime\", \"fileCount\": $count}")
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
