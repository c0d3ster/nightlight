# Linear MCP: OAuth persistence gate and tool inventory

## Summary

The OAuth persistence test could not run. The headless session (`--permission-mode acceptEdits`) denied the first read-only Linear calls (`whoami`, `list_teams`) because `.claude/settings.json` has no `mcp__linear__*` allow entries. Nothing was created, edited, or deleted in the Linear workspace. Persistence is neither passed nor failed: it is untested. The tool inventory below comes from the session's tool list and the schemas of four read-only tools.

## Findings

### Persistence test: NOT RUN

- Evidence: `mcp__linear__whoami` and `mcp__linear__list_teams` both returned `Claude requested permissions to use mcp__linear__<tool>, but you haven't granted it yet.` The server was registered and its tools were listed, so the human's `claude mcp add` step appears done. The denial is a permission-gate issue, not an auth lapse.
- No evidence either way about whether the OAuth session survives many independent `claude -p` launches. Do not treat this as a pass.

### Tool inventory (names as exposed, prefix `mcp__linear__`)

Read-only (safe for unattended listing and lookup):
`whoami`, `list_teams`, `get_team`, `list_issues`, `get_issue`, `list_issue_statuses`, `get_issue_status`, `list_issue_labels`, `list_comments`, `list_projects`, `get_project`, `list_users`, `get_user`, `list_cycles`, `list_milestones`, `get_milestone`, `list_documents`, `get_document`, `list_custom_views`, `list_templates`, `get_template`, `get_workspace`, `get_notifications`, `get_status_updates`, `get_attachment`, `list_project_labels`, `list_releases`, `get_release`, `list_release_notes`, `get_release_note`, `list_release_pipelines`, `list_agent_skills`, `get_agent_skill`, `search_documentation`, `extract_images`, `get_triage_responsibility`, `list_diffs`, `get_diff`, `get_diff_threads`.

Write (never allow without a reviewed need): `save_issue` (create and update), `save_comment`, `create_issue_label`, `save_issue_label`, `retire_issue_label`, `restore_issue_label`, `save_project`, `save_milestone`, `save_document`, `save_status_update`, `save_release`, `save_release_note`, `create_attachment`, `create_attachment_from_upload`, `prepare_attachment_upload`, `prepare_file_upload`, `share_issue`, `unshare_issue`, `mark_notification`, `merge_diff`, `update_diff`, `submit_diff_review`, `save_diff_comment`, `resolve_diff_thread`, `save_project_label`, `retire_project_label`, `restore_project_label`.

Destructive: `delete_comment`, `delete_attachment`, `delete_diff_comment`, `delete_status_update`.

### Verified parameters (from schemas)

- `whoami`: optional `source`. Returns the authenticated user and workspace.
- `list_teams`: optional `query`, `limit` (default 50, max 250), `cursor`, `includeArchived`, `orderBy`, `parentTeam`, `ancestorTeam`, `createdAt`, `updatedAt`.
- `get_team`: required `query` (team UUID, key, or name).
- `list_issues`: all optional: `team`, `assignee` (`"me"` or `null`), `state`, `label`, `project`, `cycle`, `parentId`, `priority` (0 to 4), `query`, `limit` (max 250), `cursor`, `includeArchived`, `orderBy`, `createdAt`/`updatedAt`/`completedAt` (ISO-8601 or duration like `-P1D`), and `fields`, an array that selects extra fields (`title`, `description`, `status`, `labels`, `url`, and so on). `id` is always returned. Pagination uses `cursor` when `hasNextPage` is true.
- Other tools' parameters were not inspected. Task `#23` onward should load their schemas before relying on them.

## Recommendation

Recommendation, not decision:

1. Human adds narrow read-only allows to `.claude/settings.json` for the persistence test only: `mcp__linear__whoami`, `mcp__linear__list_teams`, `mcp__linear__get_team`, `mcp__linear__list_issues`, `mcp__linear__get_issue`. No server-level `mcp__linear` or `mcp__linear__*` entry.
2. Rerun this task. Pass criterion: `whoami` plus `list_teams` succeed from at least five separate `claude -p` launches spread over more than a day, with no re-auth prompt.
3. Until then, do not build or enable an unattended Linear mode. If any launch hits an auth prompt, recommend against unattended Linear mode.
4. When Linear mode is built, allow only the read tools it needs plus the specific write tools (likely `save_issue`, `save_comment`, `list_issue_labels`, `create_issue_label`) after review. Keep delete tools out.

## Open Questions

- Does the hosted MCP OAuth token refresh silently across independent headless launches, and for how long?
- Does `claude -p` in a different working directory or user scope see the same server registration?
- Are the write tools' parameters (`save_issue` especially) enough to set labels and status in one call?

## Sources

- Session tool list (names) and tool schemas for `whoami`, `list_teams`, `get_team`, `list_issues`, observed 2026-11-02.
- Denial output from the two attempted calls, same session.
- No web sources were consulted.
