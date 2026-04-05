# zpr-review skill

You are performing an inline code review using the zpr Neovim plugin.
The user has invoked `/zpr-review` with a commit hash or PR number as the argument.

## Step 1 — Identify the target

Parse the argument from the user's message:
- If it looks like a commit hash (7-40 hex chars) or `HEAD~N` → treat as a commit
- If it looks like a number → treat as a GitHub PR number (use `gh pr view <N>` to get repo context)
- If it is a branch name or GitHub URL → resolve accordingly

Determine the working repo path. Use the current working directory unless the user specified a path.

## Step 2 — Get the diff

**For a commit:**
```sh
git -C <repo_path> diff <commit>~1 <commit>
```

**For a PR:**
```sh
gh pr diff <number>
```

## Step 3 — Parse the diff

Pipe the diff through `zpr-parse-diff` to get a structured JSON array of files and hunks:

```sh
git -C <repo_path> diff <base> <head> | /Users/ansharma/Repository/zpr/bin/zpr-parse-diff
```

Read the full hunk content carefully — you will need it for analysis.

## Step 4 — Analyze and prioritize

For each file and hunk, reason about:
- **Risk**: logic changes, security implications, data mutations, error handling gaps
- **Complexity**: non-obvious code, subtle interactions, algorithmic changes
- **Importance**: core path vs. test/config/cosmetic

Produce a prioritized ordering of `(file_index, hunk_index)` pairs — highest-risk/most-important first. This becomes the review order the user will follow.

Also decide which hunks warrant inline comments. Good comments:
- Flag bugs, edge cases, or security issues
- Ask clarifying questions about intent
- Note non-obvious assumptions or side effects
- Suggest improvements where meaningful

Do NOT comment on style, formatting, or trivial things unless they affect correctness.

## Step 5 — Open zpr with the prioritized file order

Reorder the `files` array so that the file containing the highest-priority hunk comes first, then the next, etc. Open zpr via `zpr-call open_file` passing the reordered `files` list:

```sh
/Users/ansharma/Repository/zpr/bin/zpr-call open_file '<json>'
```

The JSON must include:
- `file_path` — first file to show (highest priority)
- `hunks` — that file's hunks
- `repo_path` — absolute path to the repo
- `base_ref` — e.g. `abc123~1`
- `head_ref` — e.g. `abc123`
- `files` — the full reordered file list: `[{ "file_path": "...", "hunks": [...] }, ...]`
- `file_index` — 1
- `start_hunk` — index of the highest-priority hunk within the first file

## Step 6 — Add inline comments

For each hunk that warrants a comment, call:

```sh
/Users/ansharma/Repository/zpr/bin/zpr-call add_comment '<json>'
```

Parameters:
```json
{
  "file_path": "src/foo.lua",
  "line": 42,
  "line_end": 45,
  "hunk_index": 2,
  "body": "Your comment here"
}
```

- `line` is 1-based, relative to the **after** (new) file
- `line_end` is optional — omit for single-line comments, set for range comments
- `hunk_index` is the hunk's position within this file (1-based)
- `body` should be concise and actionable

Add comments for the currently open file first (they render immediately), then switch files with `zpr-call next_file` and add comments there.

## Step 7 — Report to the user

After all comments are placed, summarize:
- How many files and hunks were reviewed
- The priority order and why (1-2 sentences per file)
- A brief list of the comments added and what they flag
- Any overall concerns about the change

Remind the user they can navigate with `]f`/`[f` (files), `]h`/`[h` (hunks), and `<leader>zt` to open the sidebar showing the full review order.
