---
name: write-prd
description: Drafts a PRD with me in a target repo's docs/prd/, in the standard format /discover-tasks parses into task candidates, and opens a PR for it. Use when planning a feature before breaking it into tasks, or to restructure an older PRD or fold a research doc into one.
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: "Bash|Read|mcp__.*"
      hooks:
        - type: command
          command: 'f="$(cd -P "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && cd ../../.. && pwd)/lib/guard.sh"; [ -f "$f" ] || { echo "nightlight guard not found from $CLAUDE_PLUGIN_ROOT; re-run install.sh" >&2; exit 2; }; exec bash "$f"'
---

## Target repo

`<nl>` below is the nightlight checkout holding this skill, as an absolute path: the skill's base directory with symlinks followed (it may be loaded through a link in `~/.claude/skills`), three levels up: `cd -P <skill base directory> && cd ../../.. && pwd`. The target repo is, in order: the --add-dir repo if one is attached; else the repo the args name (a sibling checkout's name, or a path); else the current working directory's repo (`git rev-parse --show-toplevel`) when it is a git checkout other than `<nl>`; else list the git checkouts beside `<nl>` and ask me to pick. Resolve it to an absolute path. GitHub calls are REST: copy the `gh api` command below as written, and never use `gh issue`, `gh pr`, `gh label` or `gh repo`, which need GraphQL and fail in cloud sessions. `<owner/repo>` is `bash <nl>/lib/github.sh slug <repo-path>`.

The rest of the args are the topic, plus optionally a doc to build on (a research doc, an older PRD) and a second repo the work spans. The PRD is a doc in the repo whatever its `taskSource`; this skill never touches TASKS.md, issues or labels.

## Phase 1: gather

1. Announce: "Drafting a PRD for <topic> in `<repo>`."
2. Read the repo's CLAUDE.md and README, list `docs/prd/`, and read any doc I named. A PRD on the same topic already exists: offer to revise it instead of writing a second one.
3. Look at the code the topic touches with targeted `Grep`/`Glob`, enough to name real files, models and commands in the design and acceptance criteria. Don't read whole trees.
4. Ask me, in one message, only what the code and docs don't answer: the problem, who it's for, goals, non-goals, constraints, and what the first milestone should deliver. Skip what's already clear.

## Phase 2: draft

1. Write the draft in the Format below and show it to me whole. Every milestone and proposed issue gets acceptance criteria I could check by hand or by test. Anything I haven't decided goes in that unit's `Open decision:` or in `## Open questions`; never guess on a judgment call.
2. Iterate until I approve. Keep the PRD to the decisions and the plan: no restating the research, no implementation code.
3. Spans two repos: one PRD per repo, both in this format. The repo that owns most of the design holds the full PRD. The other holds a slim one (Summary, Goal, the contract between the repos, its own Milestones and Proposed issues, Open questions) that links back. Each lists only its own repo's units, both carry a `Related:` line linking the other, and a unit that needs the other repo's work says so in `Depends on:` as `<repo> <unit>` (e.g. `c0d3ster 3a`). `/discover-tasks` reads only its own repo's PRD, and `/plan-tasks` holds a unit that depends on another repo until that work lands.
4. Built on a research doc: once its recommendation is folded in, offer to delete the research doc in the same PR, so it can't surface again as its own work.

## Phase 3: write and open a PR

1. Write `docs/prd/<slug>.md` (`<slug>` from the title, kebab-case). Two repos: write each one, then run steps 2 to 6 per repo.
2. Resolve the default branch: `git -C <repo> symbolic-ref --quiet --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to local `main` then `master`. The current branch (`git -C <repo> branch --show-current`) doesn't match it: STOP, leave the file uncommitted, and tell me which branch it's on.
3. Pull latest, branch off it as `docs/prd-<slug>` (append `-2`, `-3`... if taken locally or on the remote).
4. Stage only the PRD file and any research doc I agreed to delete. Never `git add -A`.
5. Commit as `docs(prd): <title>` (or `docs(prd): revise <title>`), push, and open a PR: `gh api -X POST repos/<owner/repo>/pulls -f head=<branch> -f base=<default> -f title='<title>' -F body=@<file> --jq .html_url`. The body is the Summary plus the milestone list.
6. Report the PR URL. Never merge it: a PRD is reviewed like code. Once it's merged, `/discover-tasks` turns its units into candidates.

Do not implement any code in this session.

## Format

The lines `/discover-tasks` parses are the `Status:` header, the `Stacks:` line, and each unit's title, `Status:`, `Acceptance:`, `Depends on:` and `Open decision:` lines. Keep their spelling exact; everything else is free prose.

```markdown
# PRD: <Title>

Status: draft|active|done, <YYYY-MM-DD>. Owner: <who>.
Related: <other repo> [`docs/prd/<file>.md`](<link>)   (only when it spans two repos)
Inputs: <research docs, issues or PRs this builds on, with links>   (optional)

## Summary

<2-3 sentences: what this builds and why now.>

## Problem

## Goals

1. <outcome, checkable>

## Non-goals

- <out of scope for this PRD, and why>

## Users

## <Design sections, one per topic: data model, API or contract, UI, pipeline, rollout...>

## Milestones

Stacks: `<stack>: M1 -> M2`, `<stack>: M3`, `solo: M4`

### M1: <title>

Status: todo
<What it delivers, in a few lines.>
Acceptance: <checkable criteria>
Depends on: none
Open decision: none

### M2: <title>

Status: todo
...
Depends on: M1

## Proposed issues

Optional. Use it when a milestone is more than one PR; each entry is one PR.

- **M1.1 <title>.** Acceptance: <criteria>. Depends on: none.
- **M1.2 <title>.** Acceptance: <criteria>. Depends on: M1.1. Open decision: <question>.

## Open questions

1. <question, and who or what decides it>
```

- **Status:** `draft` while it's being written, `active` once merged and in progress, `done` when every milestone shipped. `/discover-tasks` skips a `done` PRD and any unit marked `Status: done`; flip a unit to `done` when its work merges.
- **Units:** with `## Proposed issues`, each entry is a unit and its milestone is the prefix (`M1.2`). Without it, each milestone is one unit and should fit one PR, or say "may need splitting".
- **Stacks:** units that build on each other share a stack, in order; independent ones are `solo`. Stacks over proposed issues use their ids (`core: M1.1 -> M1.2`). `/plan-tasks` keeps these by default, and in Linear mode names the Project after the PRD's title.
- **Ids are permanent:** once a PRD is merged, never renumber a unit. Add new ones at the end (`M5`, `M1.4`). Planned tasks point back with `PRD: docs/prd/<file> <unit>`, which is how discover knows a unit is already tracked.
