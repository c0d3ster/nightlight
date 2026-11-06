# Git worktree isolation for env-var-gated tasks

Task `NITE-3` (migrated from TASKS.md `#6`). Research only, no code or defaults changed.

## Summary

The NEEDS HUMAN round trip for env-gated tasks is real but small in the evidence we have, and worktrees do not remove the hard part, which is deciding which secrets an unattended agent may hold. In a sequential runner a worktree adds nothing for isolation, because there is never a second agent to isolate from. Recommendation: do not build this now; watch the bottleneck and revisit if it becomes frequent or if parallel dispatch returns.

## Findings

### Current behavior and cost

- A task that needs a live env var or API key finishes the code, opens the PR, and housekeeping marks it `[/]` NEEDS HUMAN with exact steps (`CLAUDE.md`, "Section semantics"). The code work is not lost; what costs a morning round trip is the human step plus verification.
- Evidence of frequency is thin. Grepping `docs/tasks-archive/` for "NEEDS HUMAN" finds only a handful of tasks across all archives, and the ones found are mostly not secret-gated: the schema/migration rule (a deliberate policy), a settings-permission change, and a supervised cost trial. None archived in this repo shows a task blocked purely because a pre-approvable API key was missing. This count is a rough grep, not a rigorous measurement, and tasks that moved to Linear are not covered.
- So the bottleneck is plausible but not demonstrated in this repo's history. Target repos (e.g. c0d3ster) may differ and were not audited here.

### What the runner already does with secrets

- `overnight.sh` sources nightlight's `.env` into its own shell (`set -a; source .env`), so every `claude -p` subprocess inherits those variables. Anything exported there is already visible to every task session.
- `LINEAR_API_KEY` is resolved by `lib/task-source.sh` from the target repo's or nightlight's env files and exported to the runner, again process-wide.
- `.claude/settings.json` denies `Read(.env)` and `Read(.env.*)` to the agent, so the current model is: secrets reach tools through the environment, not through files the agent can read.
- Task subprocesses are launched with `--add-dir <target repo>` on the target's real checkout. Gitignored files already live there. They are not isolated from the agent by anything except the Read deny rules.

### What a worktree would and would not do

- A `git worktree add` checkout contains only tracked files. Gitignored files such as `.env.local` are not copied. This is standard git behavior (worktrees check out tracked content), stated from general knowledge; I could not verify it against current docs in this session because web access was denied. Claude Code has its own worktree feature that may offer a way to carry selected ignored files into a worktree; I could not confirm its exact name or semantics, so treat that as unverified.
- Therefore a worktree gives a clean-by-default workspace: the agent sees no secrets unless something puts them there. The "mechanism for shipping a pre-approved subset" would be an allowlist of files or variables copied or injected per task, ideally per-task scoped and deleted afterward.
- That mechanism is the actual feature. The worktree itself is the cheap part. The hard parts are the allowlist policy, per-repo and per-task approval metadata, and making sure copied secrets do not end up in commits, logs, or the stream-json raw logs the runner keeps under `logs/`.
- Env injection (set the variable only in the one task subprocess's environment) delivers the same pre-approved-subset result without a worktree and without writing secrets to disk. It fits the existing model better than file copying.

### Fit with sequential execution

- The runner dispatches one fresh session per task, in order. With one agent at a time there is no concurrent checkout to protect, so the isolation benefit of a worktree is close to zero.
- Real benefits of worktrees show up only with parallelism: two agents on one repo need separate working directories, and each needs its own secret subset. Nightlight's CLAUDE.md and the user's global rules also say not to create worktrees unless explicitly requested, and past notes record that worktrees lock the user out of the branch. A worktree-per-task default would add friction with no sequential payoff.
- Stacked tasks branch from predecessor tips. Per-task worktrees would need the predecessor branch available, which works but adds setup and cleanup (and a stale-worktree failure mode when a run dies mid-task) for no gain.

### Risk side

- Pre-approving secrets for unattended agents widens blast radius: a prompt-injected issue body or comment could exfiltrate anything the session holds. Issue bodies are already treated as untrusted input. A secret that is live (real billing or write access) is a different risk class from a test key, which is the case a per-task allowlist would have to distinguish.
- Today's human gate also serves as a review of whether the live call should run at all. Removing it for approved secrets trades review for speed.

## Recommendation

This is a recommendation, not a decision.

1. Do not build worktree isolation or a secret-shipping mechanism now.
2. Watch the bottleneck. Cheap signal: count tasks closed with a NEEDS HUMAN step whose only blocker was a missing env var or key. If it reaches a threshold the owner picks (for example several per month across target repos), reopen this.
3. If it does become real, try the lighter option first: a per-repo allowlist of variable names in `docs/nightlight-meta.json`, injected into that task subprocess's environment only, with test or sandbox keys only. No worktree, nothing written to disk.
4. Revisit worktrees only if parallel dispatch is reintroduced, where per-agent working directories are needed anyway; design secret scoping at the same time.

## Open Questions

- How often are tasks actually blocked solely on a pre-approvable secret, across all target repos, including Linear-era history?
- Does Claude Code's built-in worktree support have a way to carry selected gitignored files, and what are its limits?
- Can raw stream-json logs and PR bodies be guaranteed free of injected values (redaction)?
- Should live-key tasks ever be unattended, or is the human gate the feature?
- What threshold of manual round trips justifies the build?

## Sources

- Local evidence: `overnight.sh` (env sourcing, `claude -p --add-dir` dispatch), `lib/task-source.sh` (`LINEAR_API_KEY` resolution), `.claude/settings.json` (`Read(.env*)` deny rules), `CLAUDE.md` (Overnight Agent Workflow), `docs/tasks-archive/`.
- Web verification was not possible: the WebSearch tool was denied in this session. Claims about git worktree and Claude Code worktree behavior come from general knowledge and are marked unverified above. Official references to check: git-worktree documentation (https://git-scm.com/docs/git-worktree) and Claude Code's documentation on worktrees.
