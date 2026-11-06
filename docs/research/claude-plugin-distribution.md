# Shipping nightlight as a Claude Code marketplace plugin

Task `NITE-20`, feeds `NITE-4`. Run 2026-11-06 on the dev machine (Windows 11, Git Bash, Claude Code 2.1.319).

## Summary

Skills and agents ship cleanly in a plugin and load for `claude -p` with another repo as cwd. The bash runner can ride along in `bin/`, but a marketplace install does not make it work out of the box: the runner assumes its own checkout is the cwd (it `cd`s to its own dir, reads `.env`, `.claude/settings.json`, `format-stream.jq`, `lib/*`, writes `logs/` and `stats/`), and a plugin cannot ship the permissions or the `CLAUDE.md` workflow rules that the sessions depend on. For a single-user, multi-machine setup, clone-only plus a `git pull` is cheaper than any packaged option; a plugin is worth it only if the skills alone need syncing.

## Findings

### Doc facts (re-checked 2026-11-06 on the code.claude.com plugins reference, marketplace and discover-plugins pages)

All the "already verified" claims in the task still hold:

- `bin/` files are on the Bash tool's `PATH` while the plugin is enabled. Nothing is documented for a user's own terminal, nor about the executable bit or Windows handling of `bin/`.
- `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` are substituted inline in skill, command and agent markdown and exported to hooks and MCP/LSP servers. They are not in the Bash tool environment, in the main session or a subagent.
- `${CLAUDE_PLUGIN_DATA}` is `~/.claude/plugins/data/<id>/`, survives updates, and is deleted on uninstall from the last scope unless `--keep-data` is passed.
- A plugin-root `CLAUDE.md` is not loaded (`claude plugin validate` warns). The docs say to put instructions in a skill. Plugin `settings.json` keeps only `agent` and `subagentStatusLine`.
- Install copies to `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. Files outside the plugin directory are not copied, and a symlink that leaves the plugin root is rejected. Version comes from the manifest, then the marketplace entry, then a 12-char commit SHA for git sources. Old versions are removed 14 days after an update.
- Skills are `/<plugin>:<skill>`, agents `<plugin>:<agent>`.
- A marketplace is a git repo with `.claude-plugin/marketplace.json` (`name`, `owner`, `plugins[]` each with `name` and `source`). Add with `claude plugin marketplace add <owner>/<repo>[#ref]`, install with `claude plugin install <plugin>@<marketplace>`. Scopes: user, project, local.
- In `-p` mode `/plugin` does not run, but already-installed plugins load. Third-party marketplaces do not auto-update by default. Background update behavior in `-p` runs is undocumented.
- Not documented: dotfile handling inside a copied plugin.
- Anthropic directory submission (claude.ai/directory/manage, paid plan) is a separate path, not needed for a self-hosted marketplace and not re-checked here.

### Prototype results

A throwaway plugin was built in a temp dir outside the repo (not committed): `.claude-plugin/plugin.json`, `bin/nlprobe` (bash, uses `BASH_SOURCE`), `lib/x.sh`, a `.hidden-dot` file, and `skills/probe/SKILL.md`. It was loaded with `claude -p --plugin-dir <plugin>` from a different git repo as cwd, prompt `/nlprobe:probe` on stdin, model haiku.

| # | Question | Result |
| --- | --- | --- |
| 1 | Skill launches a multi-hour runner in the background and it survives the night | **Not tested.** Needs an interactive session left open for hours. Risk: the runner is a child of the Bash tool, so closing the session, a sleep, or a sign-in expiry (the CLI already warns this one ends in days) can kill it. |
| 2 | `bin/` scripts under Git Bash on Windows | **Pass.** `nlprobe` ran as a bare command from the Bash tool and `jq` was found. A first attempt named `nltest` hit Windows' own `nltest.exe` instead, so bare names in `bin/` can collide with system executables. Use a prefixed name. |
| 3 | Plugin copy includes `lib/`, `format-stream.jq`, dotfiles | **Partly.** `lib/` and the dotfile were visible, but `--plugin-dir` loads in place, so the install-time copy was not exercised. A real `marketplace add` + `install` writes to the user's Claude config, so it was not run unattended. |
| 4 | Runner finds its own files via `BASH_SOURCE`; `--settings` / `--append-system-prompt-file` from the plugin dir; logs in the data dir | **`BASH_SOURCE` works** (resolved the plugin root, read `lib/x.sh` and the dotfile). `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA` were both unset inside the script, as documented, so the data dir has to come from elsewhere (convention `~/.claude/plugins/data/<id>`, or a user-set `NIGHTLIGHT_STATE_DIR`). The two flags were not exercised. |
| 5 | User-scope plugin loads skills/agents for `claude -p` with another cwd and `--add-dir` | **Skill loaded from another cwd** via `--plugin-dir`, and `${CLAUDE_PLUGIN_ROOT}` was substituted in skill text with forward slashes (`C:/...`). `--add-dir` together with an installed user-scope plugin was not tested. |
| 6 | Stable shim from a skill for terminal or cron | **Not tested.** Mechanically fine (a skill writes `~/.local/bin/nightlight` pointing at the resolved root), but the shim goes stale once the old version dir is pruned 14 days after an update, so it needs a glob or a pointer file the skill refreshes. |

### What the runner needs today

From `overnight.sh` and siblings: `cd "$(dirname "$0")"` (all seven scripts), `source .env`, `source lib/task-source.sh`, `--settings .claude/settings.json`, `jq -f format-stream.jq`, `logs/`, `stats/`, `docs/stats-schema.json`, `lib/stack-notes.sh`. Sessions rely on cwd being nightlight so its 22 KB `CLAUDE.md` loads as project instructions, so the workflow rules are not in any prompt file. Housekeeping prompts also say "run it from this repo, nightlight". The four skills and two agents live in `.claude/` and are invoked by the scripts.

### Refactor by option

| Concern | Plugin ships the runner | npm package | Clone-only (today) |
| --- | --- | --- | --- |
| Location independence | Resolve root from `BASH_SOURCE`, drop `cd "$(dirname "$0")"`, make every relative path root-relative | Same, plus a `bin` entry and a Windows shim story | None |
| State (`.env`, `logs/`, `stats/`) | Must leave the version dir (it changes per version and is pruned). Needs `NIGHTLIGHT_STATE_DIR`, default `~/.claude/plugins/data/nightlight` | Move to e.g. `~/.nightlight` or an XDG dir | Stays in the clone |
| Workflow rules (`CLAUDE.md`) | Not loaded from a plugin. Extract to a file passed via `--append-system-prompt-file`, or into a skill | Same extraction, file ships in the package | Stays in `CLAUDE.md` |
| Permissions | Plugin `settings.json` cannot carry them. Runner passes `--settings <plugin>/settings.json`, fine for runner-launched sessions, not for interactive use of the skills | Same `--settings` approach | Already works |
| Skills and agents | Native, namespaced `/nightlight:plan-tasks`. Scripts and docs naming `/plan-tasks` need updating | Not distributed, needs a separate copy into `.claude/` | Already works |
| Invocation | Bare command only inside Claude's Bash tool, or a shim for a plain terminal or cron | `npx` / global install works everywhere | `bash overnight.sh` or `pnpm` |
| Updates | Manual `plugin update`, no auto-update for third-party marketplaces by default | `npm update` | `git pull` |
| Windows | Git Bash needed, `bin/` name-collision risk | Needs bash anyway | Same as today |

Any packaged option needs the same core: a `NIGHTLIGHT_HOME` lookup, a state dir, and workflow rules in a file instead of `CLAUDE.md`. The plugin adds skill renaming; npm adds a separate path for skills.

### Multi-machine use alone

A second machine today needs a clone, `pnpm install`, a `.env`, `claude` auth, and the Linear MCP and `gh` setup. A plugin removes only the clone step and adds version pinning, at the cost of the refactor above. The expensive part of a new machine (auth, MCP, `.env`, `PROJECT_REPOS_DIR`) is untouched by any packaging.

## Recommendation

This is a recommendation, not a decision. `NITE-4` stays human-only.

1. Do not move the runner into a plugin or npm package for the current single-user case. Clone-only costs nothing, and a second machine is one `git clone` away.
2. If marketplace distribution is wanted later, ship only the skills and agents as a plugin (low risk, loading confirmed in `-p` from another cwd) and keep the runner in the clone. Expect to rename skill references to the `/nightlight:` namespace.
3. If the runner is ever packaged, do the prerequisite refactor first, since it is useful on its own: `NIGHTLIGHT_HOME` resolved from `BASH_SOURCE`, a `NIGHTLIGHT_STATE_DIR` for `.env`/`logs`/`stats`, and the workflow rules moved out of `CLAUDE.md` into a file passed with `--append-system-prompt-file`. Prefer a plugin over npm only if skills and runner must version together, and launch it from a terminal or cron through a shim, not from a skill's background Bash call.

## Open Questions

- Does a real `marketplace add` + `install` copy dotfiles and `lib/` intact on Windows?
- Does a background runner started from a skill survive a night, a closed terminal, and sign-in expiry?
- Do `--add-dir` and an installed user-scope plugin combine for `claude -p`?
- Is `--append-system-prompt-file` honored in `-p` with `--output-format stream-json` the way the runner would use it?
- Can a mid-run plugin update swap the version dir under a running runner?

## Sources

- https://code.claude.com/docs/en/plugins-reference (bin, variables, cache, settings, CLAUDE.md, namespacing)
- https://code.claude.com/docs/en/plugin-marketplaces (marketplace.json, add and install)
- https://code.claude.com/docs/en/discover-plugins (scopes, headless, auto-update)
- Local prototype, 2026-11-06, described above (not committed).
- Local code: `overnight.sh`, `nightlight.sh`, `lib/`, `CLAUDE.md`.
- Caveat: pages were read via a fetch subagent. Two reference pages were truncated and partly summarized, so the exact `github`/`git-subdir` field tables were not verified.
