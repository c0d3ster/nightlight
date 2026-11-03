# Linear MCP: OAuth persistence and tool inventory

Plan Phase 3.6 and 3.3, task `#22`. Run 2026-11-02/03 on the dev machine (Windows, Git Bash).

## Summary

Persistence test: **PASS**. Seven independent headless `claude -p` launches against the hosted Linear MCP server (`https://mcp.linear.app/mcp`, HTTP) all authenticated with no re-prompt and returned data. The existing `.claude/settings.json` allow entries covered the calls, so no permission denial occurred and no settings change was needed. The real tool names and params are listed below. Caveat: seven launches over about two minutes proves cold-start reuse of the stored token, not long-term refresh behavior.

## Findings

### Persistence evidence

Setup: Linear added once via `claude mcp add` (`claude mcp list` shows `linear: https://mcp.linear.app/mcp (HTTP) - Connected`). Each test was a fresh `claude -p --permission-mode acceptEdits --model haiku` process, prompt on stdin, told to call `mcp__linear__whoami` then `mcp__linear__list_teams` (limit 3) and print one line.

| Runs | Setup | Result |
| --- | --- | --- |
| 6 sequential, ~10s apart | `--allowedTools mcp__linear__whoami mcp__linear__list_teams` | all `OK 1` (one team) |
| 1 | no `--allowedTools`, relying on `.claude/settings.json` allow list, `list_teams` only | `OK 1` |

No OAuth prompt, auth error, or permission denial in any run. Only read-only calls were made (`whoami`, `list_teams`); nothing was created, edited, commented on, or closed in the workspace. The OAuth credential lives in the user's Claude config (`~/.claude/.credentials.json` exists), shared by every launch, which is why independent processes reuse it.

Not covered: a multi-hour or multi-day gap, token refresh after expiry, or concurrent launches. Run an overnight pass and check the first morning run before trusting it fully.

### Tool inventory (from the live tool list)

Read tools, with params that matter:

- `mcp__linear__whoami` (optional `source`): user, workspace, connection info. Best auth canary.
- `mcp__linear__list_teams` (`query`, `limit` max 250, `cursor`, `includeArchived`, `parentTeam`, `ancestorTeam`).
- `mcp__linear__get_team` (`query`: UUID, key, or name; required).
- `mcp__linear__list_issues` (`team`, `state`, `label`, `assignee` (`"me"`/`"null"`), `project`, `parentId`, `query`, `createdAt`/`updatedAt` (ISO date or duration like `-P1D`), `limit` max 250, `cursor`, `fields[]`, `includeArchived`, `orderBy`).
- `mcp__linear__get_issue` (`id` identifier like `ABC-123`, required; `fields[]` including `attachments`, `relations`, `stateHistory`; `includeRelations`).
- `mcp__linear__list_issue_labels` (`team`, `name`, `includeGroups`, `limit`, `cursor`).
- `mcp__linear__list_issue_statuses` (`team` required).
- `mcp__linear__list_comments` (exactly one of `issueId`, `projectId`, `milestoneId`, ...; `limit`, `cursor`).
- `mcp__linear__list_projects` (`team`, `query`, `state`, `fields[]`, `includeMilestones`, `limit` max 50).
- `mcp__linear__list_milestones` (`project` required).

Write tools (not exercised):

- `mcp__linear__save_issue`: create (needs `team`, `title`) or update (`id`). Params include `description`, `labels` (replace set), `addLabels`/`removeLabels` (incremental), `state`, `project`, `milestone`, `parentId`, `blockedBy`/`blocks`, `links[{url,title}]`, `assignee`, `priority`. One tool covers both create and edit.
- `mcp__linear__save_comment` (`body` plus exactly one parent such as `issueId`; `id` to edit, `parentId` to reply).
- `mcp__linear__create_issue_label` (`name`, `teamId`, `color`, `parent`, `isGroup`). Marked deprecated; `mcp__linear__save_issue_label` is the replacement and also updates.
- `mcp__linear__save_project`, `mcp__linear__save_milestone` (`project` plus `name`/`id`): create or update, relevant to the stack-as-milestone and project-per-repo items.

Other tools exist (documents, cycles, releases, diffs, attachments, notifications, users, `search_documentation`, ...) and are out of scope.

### Observations later tasks should know

- Correction (2026-11-03): the `delete_comment`, `delete_attachment`, `delete_status_update` and `delete_diff_comment` tools do exist in an interactive session's tool list, so the `deny` entries for them in `.claude/settings.json` are live protection, not dead rules. The headless task session's list may have differed. The remaining real risk is `save_issue` and `save_comment` with an `id` (they overwrite), which are allowed on purpose, and the `retire_*` label tools, which are not in the allow list.
- Because `save_issue` is create-or-edit, allowing it lets a session rewrite any issue in the real workspace, not just ones nightlight made. Mitigation has to be in prompts and by always reading before writing.
- Headless runs print many `Permission allow/deny rule ... mixes * with the trailing :* prefix` warnings from `.claude/settings.json` (`Bash(git -C * add:*)` and similar). They are stderr noise, but they also say those rules "will likely never match", so the `git -C` allows are probably not working. Separate cleanup, not done here.
- `--allowedTools` is variadic and swallows a positional prompt; pass the prompt on stdin.

## Recommendation

Recommendation, not decision:

1. Proceed with an unattended Linear mode. Persistence passed and the current allow list already covers the calls the later tasks need (`whoami`, `list_teams`, `get_team`, `list_issues`, `get_issue`, `list_issue_labels`, `list_issue_statuses`, `list_comments`, `list_projects`, `list_milestones`, `save_issue`, `save_comment`, `create_issue_label`).
2. Add `mcp__linear__save_project` and `mcp__linear__save_milestone` to the allow list only when the stack-as-milestone task is implemented.
3. Make `overnight.sh` call `whoami` once per run before dispatching and abort Linear mode with a clear message if it fails, so an expired token costs one cheap call instead of a whole night of failed tasks.
4. Use `mcp__linear__save_issue_label` instead of the deprecated `create_issue_label` when adding labels.

## Open Questions

- Does the token survive multi-day idle and refresh cleanly? Only a real overnight run can show it.
- Do parallel `claude -p` launches race on token refresh? Dispatch is sequential today, so likely moot.
- Exact response shape (issue identifiers, cursor format) was not captured; the next task should record one sample of `list_issues` with `fields`.
- Should `retire_issue_label` and `retire_project_label` also be denied? They are not in the allow list, so headless runs cannot call them anyway; a deny would only be belt and braces.

## Sources

- Live results from this session's `claude mcp list`, `claude -p` runs, and the tool list as served by the Linear MCP server.
- `.claude/settings.json` in this repo (allow and deny lists).
- Linear MCP server endpoint: https://mcp.linear.app/mcp (not independently fetched; no external docs were consulted).
