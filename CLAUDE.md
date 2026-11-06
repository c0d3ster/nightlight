# nightlight

This repo is tooling for unattended overnight sessions against target repos. When a session runs, this repo is the working directory and the target repo is attached via --add-dir — except when nightlight is dogfooding itself, where there is no separate --add-dir and nightlight is its own target repo for that run.

## Design principles

- Weigh efficiency (token/API cost, run time) and cleanliness (output noise, code surface) on every change to this repo. Prefer the leaner option unless there's a concrete reason not to.

## Session topology

- NEVER commit to, branch in, or modify the nightlight repo itself during a session — unless nightlight IS the target repo for that run (dogfooding). In that case, treat it exactly like any other target repo: this rule does not apply, and everything below (branching, PRs, TASKS.md maintenance, etc.) proceeds normally against nightlight's own working directory. Otherwise, all code work, branches, commits, and PRs happen in the separate added target repo (use its path explicitly for git operations).
- The target repo's own CLAUDE.md defines that repo's code conventions and test/lint commands. Follow it for all code written there. Never modify the target repo's CLAUDE.md.

## Overnight Agent Workflow

### Execution model

- `overnight.sh` dispatches ONE fresh `claude -p` subprocess per open task (Agent-Ready/Verify/Research, in file order, filtered by `--stack`/`--stop-after`/`--limit`), plus one more at the end for housekeeping — not one continuous session across the whole run. Each task subprocess starts with no memory of any other task, so context (and cache-read cost) is bounded by one task's own work, never the whole run's.
- Interrupted attempts are detected by `overnight.sh` itself, not written to TASKS.md: before dispatching each open task it scans local and pushed (`origin`) `overnight/*/r<R>-<PP>-t<NN>-*` branches for that task's `#<n>`. A matching branch with no PR (checked via `gh pr list --state all`) means the session died mid-task, so the runner discards it (locally and on `origin`) and dispatches the task once from a clean state, noting the retry in the prompt (the retry-once rule under Retry-worthy failures). A branch that has a PR is "done, housekeeping hasn't run yet" and is left alone.
- Stacked tasks (non-`solo`) still need predecessor context without paying for a full diff/commit read. Maintain `docs/stack-notes/<stack-name>.md` in the target repo: the first task in a stack creates it, every later task in that stack appends (never rewrites) its own entry — a heading with the task's number and title, a `Branch: <branch-name>` line, key decisions, interfaces/exports created, and any deviation from acceptance criteria — committed on that task's own branch. A stacked task's prompt embeds only the latest entry (the last `## ` block) plus the headings of earlier entries, with a pointer to the file on disk, not the whole file or a raw diff or commit dump. Entries use `###` or lower for any inner headings. `solo` tasks never create or touch a stack-notes file. Lifecycle: housekeeping `git rm`s the file once its stack is finished (see TASKS.md maintenance); a stack resumed later with no file takes the "starts stack" path and recreates it.
- Each task subprocess ends its final message with one machine-parsed line: `TASK_RESULT: #<n> status=<done|blocked|needs-human> branch=<branch-name-or-none> pr=<number-or-none> note="<one-line summary>"`. The housekeeping subprocess is handed every task's `TASK_RESULT` line (collected by `overnight.sh` itself across the run) as a starting point, and confirms actual PR/branch state via `git`/`gh` before trusting it — a task session can misreport.

### Turn efficiency

- Batch independent read-only tool calls (`Read`/`Glob`/`Grep`) into a single turn when their inputs don't depend on each other's output. Each turn pays a full cache-read of the accumulated conversation, so fewer turns cuts cost directly.
- Making 2+ edits to the same file? Use `MultiEdit` instead of issuing sequential `Edit` calls one per turn.
- Chain verification commands (typecheck/lint/test) into one `Bash` invocation via `&&` where the target repo's tooling supports it, rather than issuing each as its own turn.
- Prefer a targeted `Grep`/`Glob` over a full-file `Read` during investigation, unless the whole file's content is actually needed to answer the question.

### Branching & PRs

- Every task carries `#<n>` (assigned during planning, permanent — see Task numbering) and `[stack: <name>]`. `solo` is reserved for genuinely independent tasks — never invent another name for "no dependencies."
- Same-named stacks (other than `solo`) chain in file order: first branches from main, each next from the previous tip; PRs target the predecessor (first targets main). The exact predecessor branch to build from is resolved by `overnight.sh`'s dispatch loop and told to each task's subprocess (the stack's most recent branch this run, or — resuming a stack from an earlier run — the last `Branch:` line in its stack-notes file; see Execution model above). When resolving that stack-notes fallback, the dispatch loop checks whether the recorded branch's own PR already merged into main (`gh pr view <branch>`); if it has, it re-roots the new branch on main instead of chaining onto a now-dead-end branch — this is what stops a stack from silently landing work on an orphaned branch once its parent PR has merged and the branch itself was never deleted or re-targeted.
- `solo` is exempt from chaining: every `solo`-tagged task branches from and PRs to main independently, no matter how many share the tag — solo tasks are never chained to each other.
- No stack tag = inherit the previous task's stack (safe default), including `solo`'s exemption if that's what the previous task was.
- Task turns out to depend on another stack mid-implementation? Stop, annotate blocked with the reason, move on. Never silently re-stack.
- Branch: `overnight/<YYYY-MM-DD>/r<R>-<PP>-t<NN>-<task-slug>` — `R` = that date's run number (1 + the highest `r<N>` already on a local or remote `overnight/<date>/` branch; picked by `overnight.sh`), `PP` = the task's zero-padded 1-based dispatch position in this run (told to each task's subprocess by `overnight.sh`, so branches sort in PR order), `NN` = the task's own permanent `#<n>`. One task = one branch = one PR; commit in logical, revertable chunks.
- Task branches never touch TASKS.md, `docs/nightlight-meta.json`, or `docs/tasks-archive/` — record progress in commit messages.
- Never push to or merge main.
- In any commit message or PR body (task PRs and the housekeeping PR alike), wrap a task number reference in backticks — `` `#48` ``, not `#48` — so GitHub's autolinker doesn't cross-link it to that repo's issue/PR #48. Applies wherever `#<n>` shows up outside TASKS.md/stack-notes/archive files (which GitHub doesn't autolink).

### GitHub mode (`taskSource: "github"`)

Opt-in per target repo via `docs/nightlight-meta.json`; local `TASKS.md` mode stays the default and everything above describes it. Where GitHub mode differs:

- Tasks are open issues carrying an `nl:agent-ready` / `nl:verify` / `nl:research` label. The issue number is the task id, so `#<n>` is the issue number: `/plan-tasks` does not assign numbers and `nextTaskNumber` is unused.
- Stacks are `nl:stack:<name>` labels. `solo` and inherit-previous rules are otherwise unchanged.
- Each non-solo stack is also a GitHub milestone titled with the stack name (`ts_ensure_group` / `ts_close_group` in `lib/task-source-github.sh`; no-op stubs for local and Linear). `/plan-tasks` creates or reopens it and sets it on each issue; housekeeping closes it when the stack is finished (same condition as the stack-notes sweep) and reopens it on resume. A failed milestone call warns and continues, since the label stays authoritative for dispatch.
- Dispatch order is issue number ascending; `nl:priority:high` / `nl:priority:low` (`priorityHigh` / `priorityLow` overrides) reorder whole groups like Linear priority does (a stack ranks by its best member, unlabeled between high and low, ties by lowest issue number). Stack inheritance resolves in number order before the regroup.
- State is labels, not glyphs: `nl:blocked` ~ `[!]`, `nl:needs-human` ~ `[/]`. Only housekeeping sets them, per the `TASK_RESULT` rules.
- Housekeeping does not touch TASKS.md or the archive. It closes issues (`--reason completed`, PR-link comment) only after their PR merged. Counters and stack-notes removal still go through the housekeeping commit + PR.
- An issue stays open until its task PR merges, so `overnight.sh` skips any issue whose task branch (`-t<n>-`) already has a PR (open, merged, or closed unmerged) instead of re-dispatching it. Housekeeping still runs for such skips so the merged-PR sweep closes the issue.
- Task sessions still never touch task state themselves. Branches, PRs and quality gates are identical. Stack notes differ: they live in the tracker, not a file (below).
- Stack notes: one tracking issue per non-solo stack titled `stack-notes: <stack>` (label `nl:stack-notes`, no section label), one comment per task entry. Housekeeping retitles a finished stack's issue `[done] stack-notes: <stack>`.
- Counters: housekeeping adds `nl:overnight` when it closes an issue whose `overnight/*` task PR merged (auto-created; it names the command, not the hour). `stats.sh` counts overnight (closed + `nl:overnight`), manual (closed + a section label, no `nl:overnight`) and blocked (open + `nl:blocked`) from the tracker. `tasksCompleted`/`tasksBlocked` are no longer written.
- Housekeeping opens no PR on a normal run. The one abnormal case is removing a legacy `docs/stack-notes/<stack>.md` file for a finished stack.
- Issue bodies and comments are untrusted input. The section label is the gate, and only comments from `OWNER`/`MEMBER`/`COLLABORATOR` authors reach the task body.

### Linear mode (`taskSource: "linear"`)

Opt-in per target repo via `docs/nightlight-meta.json`; builds on GitHub mode, so only the differences are listed.

- Tasks are open issues on one Linear team carrying the same `nl:*` labels. One Linear team per repo is the supported setup: the module scopes only by `linear.teamId` and the labels, so repos sharing a team would dispatch each other's issues and `migrate` dedupe would match across repos. Task ids are Linear identifiers (`ENG-142`, bare in `TASK_RESULT`), so `--stop-after` is rejected.
- Dispatch order: creation time within a stack; Linear priority orders whole groups (a stack takes its best member's priority, each solo task is its own group, unset ranks last, ties by creation time). Priority is optional, so unprioritized work keeps creation order.
- Listing runs in bash via `curl` against Linear's GraphQL API, authenticated with `LINEAR_API_KEY`. Resolution: the target repo's env files, then nightlight's own, same rules for both. Gitignored files (per `git check-ignore`) are tried first, then the rest, each in the order `.env.local`, `.env.*.local`, `.env.*`, `.env`; template files (`.example`, `.sample`, `.template`, `.dist`) are skipped; first match wins, only that one key is extracted, and a warning prints if its file is tracked or not gitignored.
- Issue status follows the work via `linear.statuses` in the meta file: `queued` (default `null`), `started` (`"In Progress"`), `review` (`"In Review"`), `done` (`"Done"`), each a status name or `null` to leave the issue alone (all `null` means no status writes). `overnight.sh` writes `queued` (exactly the issues in this run's dispatch list, at run start) and `started` (as each task is dispatched) with one GraphQL `issueUpdate` and records each issue's original status in `logs/<repo>/status-ledger.json`; housekeeping writes `review` and `done` and restores ledger issues left in a runner-set status with no open or merged PR (crash, `--limit`, blocked, PR closed unmerged) to their original. The runner prunes the ledger itself. A status the team lacks warns and skips. Dispatch ignores status beyond completed/canceled; the existing-PR branch check is what keeps an In Review issue from re-dispatching.
- Every tracker write (labels, comments, status) happens in the `claude -p` subprocess through the Linear MCP server (`mcp__linear__*`), never `gh issue`, except the runner's own `queued`/`started` status writes above. `gh` is still required for task PRs, branch and PR checks, and housekeeping's merge-state checks; only `gh issue` / `gh label` calls go away.
- Milestones: a non-solo stack is a Linear project milestone (one level, same contract as GitHub; `ts_ensure_group` / `ts_close_group` stay no-op stubs in `lib/task-source-linear.sh`). Milestones only exist inside a Project (the team is the repo, a Project is a PRD), and nothing is auto-created from the repo name. No stored stack-to-project map: the milestone is found by name via `list_projects` with `includeMilestones`, and the same name in two Projects warns and skips. Only `/plan-tasks` creates (`save_project`, `save_milestone`, then `project`/`milestone` on each `save_issue`), after approval. A stack with no Project is skipped with a warning; `solo` gets none; the label stays authoritative for dispatch. `save_milestone` has no state parameter, so Linear derives completed/open from the milestone's issues and housekeeping only reads and reports a missing or ambiguous milestone.
- Stack notes are one Linear document per stack titled `stack-notes: <stack>`, attached to the stack's Project (found through its milestone) or, with no Project, to the team. A task appends its entry with `save_document` and an `append` patch; the runner reads documents over GraphQL. Housekeeping retitles a finished stack's document `[done] stack-notes: <stack>` with `save_document`.
- Permissions: `.claude/settings.json` allows only the specific `mcp__linear__` tools the prompts use (including `get_document`, `list_documents`, `save_document`, which cannot be limited to append-only) and denies the delete tools. No server-level MCP allow.
- Linear's own GitHub integration is separate and not needed.

### Task numbering

- Every checkbox line gets `#<n>` right after it — e.g. `- [ ] #48 [stack: auth] Add rate limiting to login endpoint` — across every section, not just Agent-Ready. Assigned only by `/plan-tasks`, never during a work session.
- Numbers come from `docs/nightlight-meta.json`'s `nextTaskNumber`, incrementing monotonically — never reused, never renumbered, even after a task is completed and archived. This is what lets a PR, commit, or `## Discovered` note reference a specific task unambiguously forever.

### Quality gates

- Lint runs via the target repo's pre-commit hooks — never bypass (no --no-verify); fix the code, not the hook.
- Run the target repo's full test suite locally before every PR. CI also runs it, but don't rely on that. Never commit failing tests.

### Task breakdown rules

- Task decomposition happens in a separate planning session, not during execution — don't restructure, reorder, or reprioritize TASKS.md mid-session.
- Exception: sub-checkboxes under the single task you're actively working, to track your implementation plan and progress. Check them off as you go.
- Mid-session work not covered by an existing task goes under `## Discovered` at the bottom of TASKS.md: one-line description + where you found it. Don't implement Discovered items the same session.

#### Retry-worthy failures vs. genuine blocks

- Retry-worthy: an implementation was attempted and tests or acceptance criteria failed, but nothing about the failure indicates the task is ambiguous or externally blocked (e.g. a flaky test, a wrong first approach, a transient tool hiccup). Reset the branch to its starting point, discarding the failed attempt's commits, and retry once from that clean state — carry forward the diagnostic info the failed attempt surfaced (error output, which approach didn't work and why) into the retry. Only fall back to blocked if the retry also fails.
- Genuine block: ambiguity in the task's intent, a missing prerequisite, a cross-stack dependency discovered mid-task, or a decision that requires human input. No retry — annotate blocked with the reason and move on immediately, per the existing "never guess on judgment calls" rule.

### TASKS.md maintenance

- TASKS.md holds only open, blocked, or in-progress items. It has exactly one writer per run: the housekeeping subprocess.
- Checkbox glyphs are housekeeping's alone to write: `- [ ]` open/normal, `- [!]` blocked, `- [/]` NEEDS HUMAN. A task session never sets `[!]`/`[/]` itself — it reports status via its `TASK_RESULT` line and housekeeping translates that into the glyph.
- At the end of a run, create `overnight/<YYYY-MM-DD>/r<R>-housekeeping` from main and make one commit that: checks off/removes completed tasks; sets `[!]` (blocked) or `[/]` (NEEDS HUMAN) with a free-text annotation from the run's dispatched tasks (per their `TASK_RESULT` lines, confirmed against actual PR/branch state — see Execution model above); adds Discovered items; archives completed tasks (task number, text, PR number, notes) to a NEW `docs/tasks-archive/<YYYY-MM-DD>.md` (never append to an existing archive file); updates `tasksCompleted`/`tasksBlocked` in `docs/nightlight-meta.json` (create it with `nextTaskNumber: 1, tasksCompleted: 0, tasksBlocked: 0` if missing); `git rm`s the `docs/stack-notes/<stack>.md` of every finished stack (see the sweep bullet below).
- Every run, before opening the housekeeping PR, also check merge state of every `[/]`-annotated task's PR (`gh pr view <PR> --json state,mergedAt`). If merged, archive it as completed to that run's `docs/tasks-archive/<YYYY-MM-DD>.md` (task number, text, PR number, and a note that it required a human step) and remove its line from TASKS.md — no manual edit required beyond merging the PR itself. If still open, leave the `[/]` line as-is.
- Every run, also sweep every `[!]` line whose annotation blocks on a dependency (another task `#<n>` or a PR number), whether or not it was dispatched this run: nothing dispatches `[!]` items, so a block that has since resolved would otherwise stay forever. Check each referenced PR with `gh pr view <PR> --json state,mergedAt` (for a task reference, the PR chain recorded in `docs/tasks-archive/` or its open `[/]` line). If every dependency has merged, set the line back to `- [ ]` and remove the BLOCKED annotation. Blocks for ambiguity, missing prerequisites, or a `gh` failure stay `[!]` untouched.
- Every run, also sweep for stray `[x]` lines in TASKS.md, whether or not they were dispatched this run: a task checked off by hand, or left checked by an earlier run, is complete but was never archived, and nothing else will ever pick it up. For each one, archive it to that run's `docs/tasks-archive/<YYYY-MM-DD>.md` (task number, text, PR chain, notes; confirm the PR state with `gh pr view` first), remove it from TASKS.md, and count it in `tasksCompleted`. If its PR is not merged yet, it is not complete: set it back to `[/]` with the pending step instead.
- Remote task sources (`taskSource: "github"` or `"linear"`): housekeeping does not touch TASKS.md or the archive. It closes issues (`--reason completed`, PR-link comment) only after their PR merged and labels them `nl:overnight`, sets `nl:blocked` / `nl:needs-human` with comments, sweeps every open section-labeled issue (not just this run's) and closes it once its task PR merged, and flags contradictory labels without resolving them. It writes no counters and holds no stack-notes file: the stack-notes sweep (`bash lib/stack-notes.sh <repo> --remote <dir>`) deletes merged stack branches and reports finished stacks, whose tracker notes get a `[done]` title. No PR on a normal run; the only commit is `git rm` of a leftover legacy notes file. See `build_housekeeping_prompt_github()` / `_linear()`.
- Open it as its own PR, `chore: session housekeeping <date>`, targeting main — the only PR touching TASKS.md, `docs/nightlight-meta.json`, the archive, or `docs/stack-notes/`, so task PRs merge in any order across any number of nights with zero conflicts.
- Code-complete but needs a human step (env var, API key, dashboard config)? Mark it `[/]` in TASKS.md with `NEEDS HUMAN: <exact steps>` (via housekeeping), same note in the task PR description — still open the PR.
- Ambiguous or blocked for non-human reasons: mark it `[!]` and annotate why (via housekeeping), skip it, move on. Never guess on judgment calls.
- Every run, before opening the housekeeping PR, run the stack-notes sweep: `bash lib/stack-notes.sh <target-repo-path> [--keep <stack>]...` (`lib/stack-notes.sh`, shared by all three task sources and `/migrate-tasks`; the prompts call it, nothing re-implements it). For every `docs/stack-notes/*.md` it checks each `Branch:` line's PR (`gh pr view`), deletes branches whose PR merged (locally and on `origin`, even when the file is kept), and `git rm`s each finished stack's file, staged for the housekeeping commit; list the removals in the PR body. A stack is finished only when every `Branch:` PR is MERGED and it has no open work: the script reads open `[ ]`/`[!]`/`[/]` tasks from a local `TASKS.md` itself, and the caller adds one `--keep <stack>` for each stack dispatched this run and, in remote modes, each stack with an open `nl:stack:<name>` issue. A `gh` failure, an unmerged PR, or zero `Branch:` lines keeps the file. A removed stack resumed later takes the "starts stack" path and recreates its file.

### Research deliverables

- Every Research task's deliverable is a markdown doc — that doc IS the PR; no .md output means the task isn't done.
- Location: path given in the task, defaulting to `docs/research/<topic>.md` in the target repo.
- Structure: ## Summary (2-3 sentences), ## Findings, ## Recommendation (clearly marked as recommendation, not decision), ## Open Questions, ## Sources.
- Cite sources with links. If web access is unavailable or a claim can't be verified, say so explicitly. Never fabricate sources, prices, API limits, or version numbers.
- Research PRs touch only docs/ — no code changes, no default changes, no new dependencies.

### Section semantics in TASKS.md

- Checkbox glyphs (set only by housekeeping — see TASKS.md maintenance): `[ ]` open, ready to dispatch; `[!]` blocked, with a free-text reason; `[/]` NEEDS HUMAN, code-complete pending a manual step, auto-archived once its PR merges.
- "Agent-Ready": implement, in order. Acceptance criteria included per task.
- "Verify (may already be done)": confirm whether the work exists. If done, mark complete with a note (archived at session end). If not, implement.
- "Research": write findings per the Research deliverables rules above. Do not implement or change defaults.
- "Decisions (human only)": never attempt. These require my input.
- "Discovered": raw, un-triaged candidates (no `#<n>`, no `[stack]`) added by `/discover-tasks` or found mid-session. `/plan-tasks` triages each into one of the sections above; nothing stays here once planned.
