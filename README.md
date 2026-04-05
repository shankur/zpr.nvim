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
```
