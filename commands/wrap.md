---
description: 'End-of-session workflow: summarize, update the task file, save learnings to memory, clean up, optional git commit, write a handoff note, then run and VERIFY a backup. Use when the user says "wrap", "wrap quick", "wrap commit", or ends a work session.'
argument-hint: '[quick|commit]'
---

# /wrap — end-of-session routine

Run this when a work session ends. It leaves the project in a state the next session (or another person) can pick
up cold: tasks marked, learnings saved, workspace clean, data backed up and proven backed up, and a note saying
where things stand.

## Ground rules (apply to every step)

1. **Verify, don't claim.** Never report a step as done unless you checked its result. "Backup OK" means you looked
   at the files on the target, not that a script exited 0. "Tasks updated" means you re-read the file after writing.
2. **Atomic file writes.** Never open a file you are rewriting in truncating mode and then build its content. Build the
   full new content first, write it to `<file>.tmp`, then rename over the original (`os.replace`, `mv`,
   `Move-Item -Force`). A crash mid-write must leave the original intact, never an empty file. Prefer the Edit tool
   for small changes; it replaces exact strings and fails loudly instead of truncating.
3. **Check every rewrite.** After any scripted rewrite of a file, print its byte count and grep for one anchor
   string you expect to survive (a heading, the first task ID). A file that got shorter than expected, or lost its
   anchor, is a failure: restore it before doing anything else.
4. **Never delete user data during cleanup.** Cleanup removes only what this session created and can name: scratch
   files, temp scripts, debug output. If you are not sure a file is yours, list it and ask. Never bulk-delete by
   pattern outside the scratch locations, and never "tidy" folders the user owns.
5. **Report gaps as gaps.** If a step was skipped, partial or failed, say so in the final report with the reason.
   Do not fix it by starting services, waking containers or running anything that has side effects the user did not
   ask for.
6. **Ask before anything external.** No `git push`, no uploads, no messages sent, no remote API writes without an
   explicit yes in this session.

## Variants

The word after `/wrap` selects the variant (the harness passes it as the command arguments).

| Command        | Steps run                                   | Backup                              |
| -------------- | ------------------------------------------- | ----------------------------------- |
| `/wrap`        | 1 Summary · 2 Tasks · 3 Memory · 4 Cleanup · 6 Handoff · 7 Backup | Run + verify (if configured), last |
| `/wrap quick`  | 1 Summary · 3 Memory                        | Skipped                             |
| `/wrap commit` | Full `/wrap` plus step 5 Git commit         | Run + verify (if configured)        |

Any other text after `/wrap` (for example "explain this command") is an instruction about the command, not a wrap
run. Do that instead.

## Configuration

Read settings in this order; the first value found wins:

1. Environment variables (check with `printenv WRAP_TASK_FILE` / `$env:WRAP_TASK_FILE`).
2. `.claude/wrap.json` in the project root, keys in lower camel case (`taskFile`, `handoffDir`, ...).
3. The defaults below.

| Variable                | Default                                  | Meaning                                                       |
| ----------------------- | ---------------------------------------- | ------------------------------------------------------------- |
| `WRAP_TASK_FILE`        | `TASKS.md`                               | Task list to update in step 2                                 |
| `WRAP_DONE_ARCHIVE`     | *(unset)*                                | Optional file that receives completed rows when the task file grows past `WRAP_DONE_KEEP` |
| `WRAP_DONE_KEEP`        | `25`                                     | Completed rows kept in the task file                          |
| `WRAP_HANDOFF_DIR`      | `.claude/handoffs`                       | Where step 6 writes `YYYY-MM-DD-HHMM.md`                      |
| `WRAP_MEMORY_DIR`       | the project's Claude Code memory dir     | `~/.claude/projects/<project-slug>/memory/`                   |
| `WRAP_MEMORY_INDEX_MAX` | `180`                                    | Max lines in `MEMORY.md` (Claude Code loads only the start of it) |
| `WRAP_SCRATCH_DIRS`     | `tmp;.scratch`                           | Folders (relative to project root) that cleanup may empty     |
| `WRAP_BACKUP_CMD`       | *(unset = backup step skipped)*          | Command that runs the user's backup, e.g. `bash scripts/backup.sh` |
| `WRAP_BACKUP_STATUS`    | *(unset)*                                | JSON status file the backup writes (format below)             |
| `WRAP_BACKUP_TARGETS`   | *(unset)*                                | `;`-separated `source=>target` pairs to verify directly       |
| `WRAP_BACKUP_MAX_AGE_MIN` | `30`                                   | The status file's `lastRun` must be younger than this         |

---

## Step 1: SUMMARIZE

Show this (on screen, not saved yet; step 6 saves it):

```
SESSION SUMMARY - [YYYY-MM-DD]
==============================
Done:     [what was accomplished, one line each]
Progress: [what is started but not finished, and its state]
Next:     [the single most useful next step, then anything else queued]
Learned:  [non-obvious insights worth keeping]
Blockers: [anything waiting on the user or an outside party]
```

Base it on what actually happened in this conversation: files changed, commands run, results seen. Do not list
work as done if its verification failed or never ran.

---

## Step 2: UPDATE THE TASK FILE

Target: `WRAP_TASK_FILE` (default `TASKS.md`). If it does not exist, create it with this skeleton:

```markdown
# Tasks

## In Progress

## Todo

## Done
```

Actions:

- Mark items completed this session as done (`- [x]`, or move them under `## Done` with today's date) using the
  file's existing convention. Match its format; do not reformat the whole file.
- Update the status line of in-progress items.
- Add new tasks discovered during the session under `## Todo`.
- If `## Done` holds more than `WRAP_DONE_KEEP` rows and `WRAP_DONE_ARCHIVE` is set, move the oldest rows to that
  archive file (append, never overwrite).

Then apply rule 3: print the byte count of the task file, confirm the top heading and at least one untouched task are
still present, and confirm every task you marked done actually changed.

Other project docs (a changelog, a component's README, a decision log) get updated only where the session changed
something they describe.

---

## Step 3: MEMORY

Claude Code's file-based memory lives in `WRAP_MEMORY_DIR`: one topic file per fact plus an index, `MEMORY.md`,
that is loaded into every new session.

### 3a: Write the facts (one fact per file)

| What changed  | Action                                                                     |
| ------------- | -------------------------------------------------------------------------- |
| New fact      | Create `kebab-case-slug.md` with the frontmatter below                     |
| Existing fact | Update that topic file in place; never create a near-duplicate             |
| Stale/wrong   | Delete the topic file **and** its `MEMORY.md` line                         |

```markdown
---
name: short-kebab-name
description: One line that says when this memory is relevant
type: feedback
---

The fact, stated plainly.

**Why:** the reason or the incident class it prevents.
**How to apply:** the concrete behaviour next time.
```

- `type` is one of `user` (who the user is, preferences), `feedback` (how to work with them, corrections),
  `project` (state of ongoing work), `reference` (where to find things).
- `feedback` and `project` memories carry the **Why** and **How to apply** lines.
- Link related memories with `[[other-name]]`.
- Convert relative dates to absolute dates ("today" becomes the actual date).
- Save only what is reusable. Skip what the repo, its docs or the git history already record, and anything that only
  mattered inside this conversation.
- Never store secrets, tokens or passwords in memory.

### 3b: Index hygiene gate (every wrap)

The index is only useful if it loads in full.

1. Every memory you touched has exactly one index line, at most ~200 characters:
   `- [Title](file.md) — short hook`. Detail lives in the topic file, never in the index.
2. Count the lines of `MEMORY.md`. If it exceeds `WRAP_MEMORY_INDEX_MAX`, shorten the longest lines and remove
   lines whose topic file no longer exists. Never grow the index without trimming it.
3. Check that every index line points at a file that exists, and every topic file has an index line.

```bash
wc -l "$WRAP_MEMORY_DIR/MEMORY.md"
grep -oE '\(([^)]+\.md)\)' "$WRAP_MEMORY_DIR/MEMORY.md" | tr -d '()' | while read -r f; do
  [ -f "$WRAP_MEMORY_DIR/$f" ] || echo "MISSING: $f"; done
```

---

## Step 4: CLEANUP

Remove only what this session created:

- Temp scripts, scratch files and debug output you wrote (you know their names from this conversation).
- The contents of `WRAP_SCRATCH_DIRS` if the session used them. Never delete the folders' parents or anything outside
  them.
- Leftover `*.tmp` files from atomic writes in this session.
- Background processes you started for this session (dev servers, watchers), unless the user wants them kept.

Do **not** delete: anything the user created, untracked files you did not create, data directories, logs you did not
write, or anything you are unsure about. List those under "Blockers" or ask.

If the harness keeps an in-session todo list, close out finished items so it matches step 2.

---

## Step 5: GIT COMMIT (`/wrap commit` only)

Skip this step entirely when the project is not a git repository (`git rev-parse --is-inside-work-tree` fails).

1. `git status` and `git branch --show-current`. If on the default branch (`main`/`master`) and the project uses
   feature branches, create one (`git switch -c wrap/<short-topic>`) before committing.
2. `git diff` and review it. Do not stage files that look like secrets (`.env`, keys, credentials), large binaries or
   build output; report them instead.
3. Stage the session's changes by explicit path (avoid `git add -A` when unrelated changes are present).
4. Commit with a message that describes the change, not the session: a short subject line plus a body listing the
   main changes.
5. **Never push without asking.** Report the branch and commit hash and ask whether to push.
6. Never use `--no-verify`. If a hook fails, fix the cause and commit again.

---

## Step 6: HANDOFF

Write the handoff note to `WRAP_HANDOFF_DIR/YYYY-MM-DD-HHMM.md` (create the folder if needed; write atomically):

```markdown
# Handoff — YYYY-MM-DD HH:MM

## Where we left off
[state of the work in 2-5 lines: what is finished, what is half-done and in which file]

## Next step
[the one concrete action to take first next session, with file paths or commands]

## Open questions / blockers
[anything waiting on the user or on someone else]

## Session summary
[the step 1 block]

## Verification
Tasks: [file, bytes, items marked done]
Memory: [files written/updated/deleted, index line count]
Backup: [runs after this note (step 7); its per-target result goes in the final report]
Git: [branch + commit hash, "not a repo", or "not requested"]
```

Then ask:

> "Anything else to remember before this session ends?"

If the user adds something, save it per step 3 and append it to the handoff note.

---

## Step 7: BACKUP AND VERIFY (skipped for `/wrap quick`)

This step runs last, so the task file, memory and handoff note written above are part of the backup.

If `WRAP_BACKUP_CMD` is not set, report `Backup: not configured` and move on.

### 7a: Run it

- Run `WRAP_BACKUP_CMD` in the foreground and capture its output and exit code.
- If the output says another run is already in progress (lock held), do **not** start a second one. Wait for the
  running one to finish, then verify that run.
- If the script refuses to run because of a safety guard (for example "mass deletion detected" on a mirror), stop.
  Report the guard message. Do not re-run it with an override flag unless the user confirms the source is intact and
  the deletion is intended.

### 7b: Verify it landed (do not skip)

A zero exit code and an `"ok": true` summary prove nothing on their own: a mirror can "succeed" while skipping its
target, and a summary flag can be true while half the targets were not written. Check each target separately.

**From the status file** (if `WRAP_BACKUP_STATUS` is set) — read the per-target entries, never just a top-level flag:

```json
{
  "lastRun": "2026-01-31T18:04:11Z",
  "targets": {
    "project": { "ok": true, "rc": 1, "detail": "mirror rc=1",
                 "newestFile": "notes/plan.md", "newestMtime": "2026-01-31T18:03:58Z",
                 "newestSize": 4812, "sourceNewestMtime": "2026-01-31T18:03:58Z", "fileCount": 1534 }
  }
}
```

- `lastRun` is younger than `WRAP_BACKUP_MAX_AGE_MIN`. This is the only "ran recently" check: mirrors keep the
  source's mtimes, so a target whose files were not edited lately is still a good backup.
- Every target has `ok: true` and a `detail` that does not contain `skip`, `abort` or `error`.
- Every target has a `newestSize` greater than 0, and its `newestMtime` is not older than its `sourceNewestMtime`
  minus a small tolerance (2 minutes covers coarse timestamps on FAT/exFAT and network shares). An older target
  newest file means recent source changes did not land.
- A target that is missing from the file counts as failed.

**Directly on the targets** (if `WRAP_BACKUP_TARGETS` is set, and always when there is no status file) — for each
`source=>target` pair, take the files this session changed most recently in the source and confirm each exists on
the target with the same size:

```bash
# bash (GNU find/stat; on macOS install coreutils+findutils or use the PowerShell version)
# newest 5 files in source, checked on target
src="$1"; dst="$2"
find "$src" -type f -not -path '*/.git/*' -printf '%T@ %s %P\n' | sort -rn | head -5 |
while read -r _ size rel; do
  if [ ! -f "$dst/$rel" ]; then echo "MISSING  $rel"
  elif [ "$(stat -c %s "$dst/$rel")" != "$size" ]; then echo "SIZE     $rel"
  else echo "OK       $rel ($size B)"; fi
done
```

```powershell
# PowerShell: same check
$src = $args[0]; $dst = $args[1]
Get-ChildItem $src -Recurse -File | Where-Object FullName -notmatch '\\\.git\\' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
    $rel = $_.FullName.Substring((Resolve-Path $src).Path.Length).TrimStart('\','/')
    $t = Join-Path $dst $rel
    if (-not (Test-Path $t)) { "MISSING  $rel" }
    elseif ((Get-Item $t).Length -ne $_.Length) { "SIZE     $rel" }
    else { "OK       $rel ($($_.Length) B)" }
  }
```

Pass conditions, all must hold: fresh `lastRun`, every target present, every target's newest file not older than
its source's newest file minus the tolerance, every spot-checked file `OK`.
Any `MISSING`, `SIZE`, stale or absent target is a failed backup: report which target and why. Do not delete
anything on the target to "fix" it, and do not re-run with override flags on your own.

---

## Final report

End with a compact block. Report the backup per target, never as a bare "backup done".

```
---
Updated: TASKS.md (3 done, 2 added; 6,214 B, anchor OK)
Memory:  wrote feedback-run-tests-before-commit.md; MEMORY.md 74 lines
Cleanup: removed 4 scratch files in tmp/
Git:     not requested
Handoff: .claude/handoffs/2026-01-31-1810.md
Backup:  project mirror rc=1, target newest = source newest, 5/5 spot checks OK; docs target 5/5 OK
```
