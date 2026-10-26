# claude-wrap

A `/wrap` slash command for [Claude Code](https://docs.claude.com/en/docs/claude-code) that ends a work session
properly: summary, task file updated, learnings saved to memory, workspace cleaned, a handoff note for the next
session, and last a backup run **and verified**.

## What it does

| Step | What happens |
| ---- | ------------ |
| 1 Summary | Done / in progress / next / learned / blockers, based on what actually happened |
| 2 Tasks | Marks finished items in your task file (default `TASKS.md`), adds new ones, archives old done rows |
| 3 Memory | Writes reusable learnings to Claude Code's memory directory, one fact per file, and keeps the `MEMORY.md` index lean |
| 4 Cleanup | Removes scratch files and temp scripts the session created, nothing else |
| 5 Git (`/wrap commit`) | Reviews the diff, commits by explicit path on a branch; never pushes without asking |
| 6 Handoff | Writes `where we left off` + `next step` to a dated note |
| 7 Backup | Runs your backup script last, then checks every target on disk |

| Command        | Runs |
| -------------- | ---- |
| `/wrap`        | All steps except git |
| `/wrap quick`  | Summary + memory only |
| `/wrap commit` | All steps including git commit (git repos only) |

## Why it is different

- **Verified backup, not a green exit code.** A mirror can exit 0 while skipping a target, and an `"ok": true`
  summary can sit on top of half-written targets. `/wrap` checks each target separately: the status file's `lastRun`
  must be recent, every target's newest file must have a non-zero size and must not be older than the source's newest
  file (mirrors keep source mtimes, so file age alone says nothing), and the newest files from the source must exist
  on the target with the same size. Anything else is reported as a failed backup.
- **Atomic writes.** Files are rewritten via `file.tmp` + rename, never by truncating the original and then building
  content. A crash mid-write leaves the old file intact.
- **Rewrite checks.** After rewriting a file, `/wrap` prints its byte count and confirms an anchor string survived,
  so a silently shortened task file is caught on the spot.
- **Memory hygiene.** One fact per file with typed frontmatter (`user` / `feedback` / `project` / `reference`), a
  one-line index entry per memory, a line budget on the index, and a dangling-link check.
- **Safe cleanup.** Only files the session created or the configured scratch folders. Unknown files are listed, not
  deleted.
- **Reports gaps instead of papering over them.** A skipped or partial step shows up in the final report with the
  reason; `/wrap` does not start services or force-override safety guards to make a step look green.

## Install

```bash
mkdir -p .claude/commands
cp commands/wrap.md .claude/commands/wrap.md        # per project
# or: cp commands/wrap.md ~/.claude/commands/wrap.md  # for all projects
```

Then type `/wrap` in Claude Code.

### Optional: backup

1. Copy one example backup script into your project, e.g. `scripts/backup-rsync.sh` (Linux/macOS) or
   `scripts/backup-robocopy.ps1` (Windows), and set `BACKUP_PAIRS` to your `source=>target` pairs.
2. Point `/wrap` at it with `WRAP_BACKUP_CMD` and `WRAP_BACKUP_STATUS` (env or `.claude/wrap.json`).

Both example scripts take a lock so two runs never overlap, abort a target when the mirror would delete more than
500 files (unmounted or damaged source), spot-check the newest files on each target, and write the status JSON
atomically.

- `node_modules`, `.venv`, `__pycache__`, `dist`, `build` and `*.tmp` are never backed up.
- Each source folder name must be unique across `BACKUP_PAIRS` (it is the key in the status file); the scripts stop
  with exit code 2 on a duplicate.

### Optional: Stop hook

`examples/auto-backup-on-stop.sh` runs the backup in the background at most once an hour when Claude stops a turn.
Copy it to `.claude/hooks/` and merge `examples/settings.stop-hook.json` into `.claude/settings.json`. `/wrap` still
runs and verifies a fresh backup at the end of the session; the hook only narrows the gap between wraps.

The hook is a bash script, so it needs bash on the PATH (on Windows: Git Bash). On Windows, point it at the
PowerShell backup:

```bash
WRAP_BACKUP_CMD="pwsh -File scripts/backup-robocopy.ps1"
```

## Configuration

Environment variables win over `.claude/wrap.json` (see `examples/wrap.json`), which wins over the defaults.

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `WRAP_TASK_FILE` | `TASKS.md` | Task list to update |
| `WRAP_DONE_ARCHIVE` | unset | File that receives old completed rows |
| `WRAP_DONE_KEEP` | `25` | Completed rows kept in the task file |
| `WRAP_HANDOFF_DIR` | `.claude/handoffs` | Where handoff notes go |
| `WRAP_MEMORY_DIR` | `~/.claude/projects/<project-slug>/memory/` | Claude Code memory directory |
| `WRAP_MEMORY_INDEX_MAX` | `180` | Line budget for `MEMORY.md` |
| `WRAP_SCRATCH_DIRS` | `tmp;.scratch` | Folders cleanup may empty |
| `WRAP_BACKUP_CMD` | unset (step skipped) | Your backup command |
| `WRAP_BACKUP_STATUS` | unset | JSON status file the backup writes |
| `WRAP_BACKUP_TARGETS` | unset | `source=>target;...` pairs to spot-check directly |
| `WRAP_BACKUP_MAX_AGE_MIN` | `30` | Max age of the status file's `lastRun` |

### Status file format

Any backup tool works as long as it writes this (or you set `WRAP_BACKUP_TARGETS` for direct checks):

```json
{
  "lastRun": "2026-01-31T18:04:11Z",
  "targets": {
    "project": { "ok": true, "rc": 1, "detail": "mirror rc=1, 5/5 spot checks OK",
                 "newestFile": "notes/plan.md", "newestMtime": "2026-01-31T18:03:58Z",
                 "newestSize": 4812, "sourceNewestMtime": "2026-01-31T18:03:58Z", "fileCount": 1534 }
  }
}
```

## Layout

```
commands/wrap.md                    the slash command
examples/backup-rsync.sh            rsync mirror + verify + status JSON
examples/backup-robocopy.ps1        robocopy mirror + verify + status JSON
examples/auto-backup-on-stop.sh     debounced background backup for the Stop hook
examples/settings.stop-hook.json    hook + env snippet for .claude/settings.json
examples/wrap.json                  config file example
```

## Credit

Written by Nick Falshaw. MIT licensed, see [LICENSE](LICENSE).
