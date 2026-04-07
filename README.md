# zpr.nvim — zero-friction PR review

A Neovim plugin for reviewing git commits and pull requests inline, with support for threaded comments, multi-file navigation, and Claude AI integration.

## Features

- Side-by-side diff view using Neovim's built-in diff engine
- Navigate hunks and files with keyboard shortcuts
- Inline comments with visual line highlighting
  - Single-line and multi-line (visual selection) comments
  - Amber background tint + sign column bracket (`│` / `╭`/`│`/`╰`) on commented lines
  - Comments persisted per-repo per-ref in `~/.zpr/reviews/`
- Sidebar panel showing all files and hunks with comment and viewed-state indicators
- Mark files as viewed to collapse their hunks and track review progress
- RPC server so Claude (or any script) can drive the review from the terminal

## Claude AI integration

zpr.nvim ships a `/zpr-review` Claude Code skill that drives a full AI-assisted review:
Claude reads the diff, prioritizes hunks by risk and complexity, opens them in
order, and adds inline comments — all without leaving Neovim.

The skill is symlinked automatically by the lazy.nvim `build` hook. Then in any Claude Code session:
```
/zpr-review abc1234        # review a commit
/zpr-review 42             # review PR #42
```

## Requirements

- Neovim 0.9+
- Git
- Python 3 (for the CLI helpers)
- Nerd Fonts (for the comment icon)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "shankur/zpr.nvim",
  build = function()
    local src = vim.fn.stdpath("data") .. "/lazy/zpr.nvim"
    local bin = vim.fn.expand("~/.local/bin")
    vim.fn.mkdir(bin, "p")
    for _, script in ipairs({ "zpr-call", "zpr-parse-diff", "zpr-push-review", "zpr-pull-review" }) do
      vim.fn.system("ln -sf " .. src .. "/bin/" .. script .. " " .. bin .. "/" .. script)
    end
    vim.fn.system("ln -sf " .. src .. "/skills/zpr-review ~/.claude/skills/zpr-review")
    local path = vim.fn.getenv("PATH")
    if not path:find(bin, 1, true) then
      vim.notify("zpr.nvim: add " .. bin .. " to your PATH", vim.log.levels.WARN)
    end
  end,
}
```

The `build` hook runs automatically on install and update. It symlinks the CLI helpers into `~/.local/bin` (creating it if needed) and the Claude skill into `~/.claude/skills/`. A warning is shown in Neovim if `~/.local/bin` is not on your `$PATH`.

The plugin auto-loads via `plugin/zpr.lua`.

## Configuration

By default all state is stored under `~/.zpr/`. Override with:

```sh
export ZPR_CONFIG_DIR=/path/to/your/dir
```

| Path | Purpose |
|---|---|
| `$ZPR_CONFIG_DIR/nvim.sock` | Neovim RPC socket location |
| `$ZPR_CONFIG_DIR/reviews/<repo>/comments_<ref>.json` | Persisted comments |
| `$ZPR_CONFIG_DIR/reviews/<repo>/viewed_<ref>.json` | Persisted viewed-file state |

## Keymaps

Keymaps are buffer-local and only active inside zpr diff buffers.

| Key | Mode | Action |
|---|---|---|
| `]h` | n | Next hunk |
| `[h` | n | Previous hunk |
| `]f` | n | Next file in commit |
| `[f` | n | Previous file in commit |
| `q` | n | Close review |
| `<leader>zc` | n | Add / edit comment on current line |
| `<leader>zc` | v | Add / edit comment on selected line range |
| `<leader>zd` | n | Delete comment (with confirmation) |
| `<leader>zt` | n | Toggle sidebar |

### Sidebar keymaps

The sidebar opens with `<leader>zt` or `:ZprSidebar`.

| Key | Action |
|---|---|
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `<CR>` | Jump to file / hunk under cursor |
| `v` | Toggle viewed state for file under cursor |
| `q` | Close sidebar |

## CLI helpers

Two scripts in `bin/` let Claude (or you) drive the plugin from the terminal.

### `zpr-parse-diff`

Reads a unified diff from stdin and outputs a JSON array of files with hunks:

```sh
git diff HEAD~1 HEAD | zpr-parse-diff
```

### `zpr-pull-review`

Imports existing GitHub PR review comments into the local zpr comments file:

```sh
zpr-pull-review 42              # merge GitHub comments with local ones
zpr-pull-review 42 --replace   # discard local comments, import only GitHub's
zpr-pull-review 42 --repo-path /path/to/repo
```

Comments are deduplicated by file + line + body. After writing the file, the script calls `zpr-call reload_comments` to update any running Neovim session automatically.

All comment types are imported as **locked** (they belong to GitHub, not your local session):

| Type | Imported as |
|---|---|
| RIGHT-side with `line` field | Locked, precise line number |
| LEFT-side | Locked, line approximated from diff hunk |
| Position-only (legacy) | Locked, line approximated from diff hunk |

Locked comments render with a `⊘` sign and muted gray color. The author's GitHub login (`@username`) is shown in the prefix. Pressing `<leader>zc` on a locked comment opens a reply prompt that posts a **threaded reply** directly to GitHub via `gh api` — no need to push a review separately. Locked comments cannot be edited locally but can be deleted.

Only comments with truly no usable line information (malformed diff hunk + no line field) are skipped.

### `zpr-push-review`

Pushes the inline comments from the current review to GitHub as a PR review:

```sh
zpr-push-review 42
zpr-push-review 42 --event APPROVE
zpr-push-review 42 --event REQUEST_CHANGES --body "A few things to address"
zpr-push-review 42 --repo-path /path/to/repo   # override cwd
```

Reads comment from `$ZPR_CONFIG_DIR/reviews/` and posts them via `gh api`. Requires the `gh` CLI to be authenticated.

> **Note**: GitHub only accepts review comments on lines that are part of the PR diff. Comments on unchanged context lines will cause the API call to fail.

### `zpr-call`

Sends an RPC call to the running Neovim instance:

```sh
zpr-call ping
zpr-call status
zpr-call next_hunk
zpr-call next_file
zpr-call get_comments
zpr-call close
```

Open a commit for review:

```sh
zpr-call open_file '{
  "file_path": "src/foo.lua",
  "repo_path": "/path/to/repo",
  "base_ref": "abc123~1",
  "head_ref": "abc123",
  "hunks": ["@@ -1,3 +1,4 @@\n ..."],
  "files": [{ "file_path": "src/foo.lua", "hunks": [...] }, ...],
  "file_index": 1
}'
```

## Commands

| Command | Action |
|---|---|
| `:ZprNext` | Next hunk |
| `:ZprPrev` | Previous hunk |
| `:ZprClose` | Close review |
| `:ZprStatus` | Show current file / hunk / comment count |
| `:ZprReload` | Hot-reload all plugin modules |
| `:ZprPullReview <n>` | Import GitHub PR review comments for PR #n (merge) |
| `:ZprPullReview! <n>` | Same, but replace local comments instead of merging |
| `:ZprPushReview <n>` | Push inline comments to GitHub PR #n |
| `:ZprPushReview! <n>` | Same, but submit as REQUEST_CHANGES |

## Sidebar

Toggle with `<leader>zt` or `:ZprSidebar`. The panel lists every file and its hunks for the active review.

**Indicators shown on each line:**

| Indicator | Meaning |
|---|---|
| `▶` | Currently open file |
| `✓` | File marked as viewed |
| `●` | Currently active hunk |
| `○` | Inactive hunk |
| `✎` (amber) | File or hunk has at least one comment |

Press `v` on any file or hunk line to toggle that file's viewed state. Viewed files are dimmed and their hunks are collapsed, giving you a compact view of what still needs attention.

## Comment storage

Comments are saved to:

```
~/.zpr/reviews/<repo-name>/comments_<head-ref>.json
```

Viewed-file state is saved alongside:

```
~/.zpr/reviews/<repo-name>/viewed_<head-ref>.json
```

Both are automatically restored when you reopen the same commit/ref.

## Architecture

```
plugin/zpr.lua        auto-load entry point
lua/zpr/
  init.lua            keymaps, RPC handlers, autocmds
  diff.lua            git file fetching, split layout, hunk/file navigation
  comments.lua        comment CRUD, extmark rendering, persistence
  viewed.lua          viewed-file state: toggle, persistence, load/save
  sidebar.lua         file/hunk tree panel with comment and viewed indicators
  highlights.lua      highlight group definitions
  config.lua          ZPR_CONFIG_DIR resolution and path helpers
  server.lua          Neovim RPC socket + global zpr_rpc() entry point
bin/
  zpr-call            send RPC calls from the terminal
  zpr-parse-diff      parse unified diffs to JSON
  zpr-push-review     push zpr comments to a GitHub PR review
  zpr-pull-review     import GitHub PR review comments into zpr
```
