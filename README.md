# zpr — zero-friction PR review

A Neovim plugin for reviewing git commits and pull requests inline, with support for threaded comments, multi-file navigation, and Claude AI integration.

## Features

- Side-by-side diff view using Neovim's built-in diff engine
- Navigate hunks and files with keyboard shortcuts
- Inline comments with visual line highlighting
  - Single-line and multi-line (visual selection) comments
  - Amber background tint + sign column bracket (`│` / `╭`/`│`/`╰`) on commented lines
  - Comments persisted per-repo per-ref in `~/.zpr/reviews/`
- RPC server so Claude (or any script) can drive the review from the terminal

## Claude AI integration

zpr ships a `/zpr-review` Claude Code skill that drives a full AI-assisted review:
Claude reads the diff, prioritizes hunks by risk and complexity, opens them in
order, and adds inline comments — all without leaving Neovim.

To activate the skill, symlink it into your Claude knowledge base:

```sh
ln -s ~/Repository/zpr/skills/zpr-review ~/.claude-kb/skills/zpr-review
# or wherever your claude-kb skills directory lives
```

Then in any Claude Code session:
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
{ dir = "~/Repository/zpr" }
```

Or any plugin manager pointing at the repo. The plugin auto-loads via `plugin/zpr.lua`.

## Configuration

By default all state is stored under `~/.zpr/`. Override with:

```sh
export ZPR_CONFIG_DIR=/path/to/your/dir
```

| Path | Purpose |
|---|---|
| `$ZPR_CONFIG_DIR/nvim.sock` | Neovim RPC socket location |
| `$ZPR_CONFIG_DIR/reviews/<repo>/comments_<ref>.json` | Persisted comments |

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

## CLI helpers

Two scripts in `bin/` let Claude (or you) drive the plugin from the terminal.

### `zpr-parse-diff`

Reads a unified diff from stdin and outputs a JSON array of files with hunks:

```sh
git diff HEAD~1 HEAD | zpr-parse-diff
```

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
| `:ZprPushReview <n>` | Push inline comments to GitHub PR #n |
| `:ZprPushReview! <n>` | Same, but submit as REQUEST_CHANGES |

## Comment storage

Comments are saved to:

```
~/.zpr/reviews/<repo-name>/comments_<head-ref>.json
```

They are automatically restored when you reopen the same commit/ref. Clearing comments (`zpr-call clear_comments`) deletes the file.

## Architecture

```
plugin/zpr.lua        auto-load entry point
lua/zpr/
  init.lua            keymaps, RPC handlers, autocmds
  diff.lua            git file fetching, split layout, hunk/file navigation
  comments.lua        comment CRUD, extmark rendering, persistence
  highlights.lua      highlight group definitions
  config.lua          ZPR_CONFIG_DIR resolution and path helpers
  server.lua          Neovim RPC socket + global zpr_rpc() entry point
bin/
  zpr-call            send RPC calls from the terminal
  zpr-parse-diff      parse unified diffs to JSON
  zpr-push-review     push zpr comments to a GitHub PR review
```
