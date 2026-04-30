# zpr-review skill

You are performing a deep, multi-agent inline code review using the zpr Neovim plugin.
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
git -C <repo_path> diff <base> <head> | zpr-parse-diff
```

Save the output — you will pass it to the review agents.

## Step 4 — Multi-agent parallel review

Spawn **7 parallel agents** using the `Agent` tool with `subagent_type="general-purpose"`. Each agent is a principal engineer reviewing from a specific angle. Launch all 7 in a single message (parallel tool calls).

**CRITICAL RULES for all agents:**
- Agents MUST read the full changed files (`git -C <repo_path> show <head_ref>:<file>`) to understand context
- Agents MUST explore related code (imports, callers, tests, similar functions) to detect duplication
- Agents MUST NOT modify any files or apply fixes — review only
- Agents output a JSON array of findings (or empty array if nothing found)
- Each finding MUST reference a line that exists within a diff hunk's changed lines

### Agent prompts

For each agent, provide in the prompt:
1. The repo path, base_ref, head_ref
2. The full parsed diff JSON (from Step 3)
3. The list of changed files
4. Their specific review focus (below)
5. The output format specification

### The 7 review angles

**Agent 1 — Functional Correctness:**
Look for logic bugs, incorrect conditions, off-by-one errors, unhandled edge cases, race conditions, incorrect state transitions, wrong return values, and missing null/empty checks. Verify the code does what it claims.

**Agent 2 — Code Quality & Duplication:**
Look for dead code introduced by this change, functions that duplicate existing utilities (read the full codebase to find them), unnecessarily complex implementations where simpler patterns exist, violations of DRY, and code that should be extracted or reused.

**Agent 3 — Test Coverage & Strategy:**
Analyze test changes (or lack thereof). Flag missing test cases for new functionality, redundant tests that test the same thing multiple ways, insufficient edge case coverage, tests that would break silently if the implementation changes, and untested error paths.

**Agent 4 — Security & Data Integrity:**
Look for injection vulnerabilities (SQL, command, template), authentication/authorization bypasses, unsafe deserialization, data validation gaps at trust boundaries, sensitive data exposure, and TOCTOU issues.

**Agent 5 — Performance & Scalability:**
Look for N+1 queries, unnecessary allocations in hot paths, missing indexes for new queries, O(n²) algorithms where O(n) exists, unbounded growth, missing pagination, and cacheable computations done repeatedly.

**Agent 6 — API Design & Contracts:**
Look for breaking changes to public interfaces, inconsistent naming, missing or misleading documentation for public APIs, backwards-incompatible serialization changes, unclear error contracts, and leaky abstractions.

**Agent 7 — Error Handling & Observability:**
Look for swallowed errors, missing error propagation, panics/crashes in non-fatal paths, missing logging for debuggability, unclear error messages, missing metrics for new operations, and retry logic without backoff.

### Output format for each agent

Instruct each agent to return ONLY a JSON array (no markdown, no explanation):

```json
[
  {
    "file_path": "src/foo.py",
    "line": 42,
    "line_end": 45,
    "body": "Concise, actionable comment about the issue",
    "severity": "high|medium|low",
    "category": "functional|quality|testing|security|performance|api|errors"
  }
]
```

Rules for comments:
- `line` is 1-based, relative to the **after** (new) file
- `line` MUST fall within a diff hunk's changed region (+ lines)
- `body` should be 1-3 sentences: what's wrong and what to do about it
- Do NOT comment on style, formatting, or trivial issues
- Do NOT suggest changes that would be purely cosmetic
- Only report findings with >80% confidence

## Step 5 — Senior engineer filter

After all 7 agents return, spawn **1 more agent** (the senior engineer filter). Pass it ALL findings from all agents concatenated together.

The senior filter agent's job:
1. **Remove false positives** — findings that are incorrect, theoretical, or not actually problematic in context
2. **Deduplicate** — if multiple agents flagged the same issue, keep the best-written one
3. **Remove noise** — low-value findings that would waste the reviewer's time
4. **Assign hunk_index** — for each surviving comment, determine which hunk (1-based) within its file the line belongs to (by checking which hunk's line range contains the comment's line)
5. **Prioritize** — order the final list by importance (high severity first, then by file order)

The filter agent returns the cleaned JSON array with `hunk_index` added to each entry.

## Step 6 — Intelligent hunk ordering for human review

The default file-by-file, top-to-bottom order is not optimal for large PRs. Spawn **1 agent** to produce a review order that tells a coherent story and groups related changes together.

Pass the agent:
- The full parsed diff (file list with hunks)
- The filtered comments from Step 5 (so it knows where issues are)
- The file dependency graph (imports, callers)

The ordering agent must follow these principles:

1. **Dependency-aware grouping**: Group related hunks across files together. If a PR changes an interface and all its callers, the interface change should come first, followed by each caller's adaptation. The reviewer should see the "cause" before the "effects."

2. **Logical story order**: Arrange hunks so they tell the story of the change. A new type definition comes before the function that uses it. A configuration change comes before the code that reads it. The reviewer should never see a reference to something they haven't encountered yet.

3. **Tests always last**: Test files (`*_test.*`, `*_spec.*`, `test_*`, `tests/`, `spec/`) are always placed at the end of the review order. Within tests, order them to match the implementation files they test.

The ordering agent returns a JSON array representing the review walk order:

```json
[
  { "file_path": "src/types.go", "hunk_indices": [1, 2] },
  { "file_path": "src/handler.go", "hunk_indices": [3, 1, 2] },
  { "file_path": "src/handler.go", "hunk_indices": [4] },
  { "file_path": "src/config.go", "hunk_indices": [1] },
  { "file_path": "src/handler_test.go", "hunk_indices": [1, 2, 3] }
]
```

Note: A file can appear multiple times if its hunks belong to different logical groups. The `hunk_indices` within each entry define the sub-order within that file for that group.

Use this ordering to set the intelligent walk order via RPC:

```sh
zpr-call set_walk_order '{"steps": [{"file_path": "src/types.go", "hunk_index": 1}, {"file_path": "src/types.go", "hunk_index": 2}, {"file_path": "src/handler.go", "hunk_index": 3}, ...]}'
```

Each step is a `{ file_path, hunk_index }` pair. The walk order enables `]h`/`[h` to navigate across files following this intelligent sequence.

Then reorder the `files` array to match the first-appearance order of files in the walk, and open zpr.

## Step 7 — Open zpr with the ordered file list

Open zpr:
```sh
zpr-call open_file '<json>'
```

The JSON must include:
- `file_path` — first file to show
- `hunks` — that file's hunks
- `repo_path` — absolute path to the repo
- `base_ref` — e.g. `abc123~1`
- `head_ref` — e.g. `abc123`
- `files` — the full reordered file list: `[{ "file_path": "...", "hunks": [...] }, ...]`
- `file_index` — 1
- `start_hunk` — index of the first relevant hunk within the first file

## Step 8 — Add inline comments

For each filtered comment, call:
```sh
zpr-call add_comment '<json>'
```

Parameters:
```json
{
  "file_path": "src/foo.lua",
  "line": 42,
  "line_end": 45,
  "hunk_index": 2,
  "body": "[Security] SQL injection via unsanitized user input in query builder"
}
```

Prefix the body with `[Category]` (e.g. `[Functional]`, `[Security]`, `[Performance]`) so the user can see which review angle found the issue.

Add comments for the currently open file first (they render immediately), then switch files with `zpr-call next_file` and add comments there.

## Step 9 — Report to the user

After all comments are placed, summarize:
- How many files and hunks were reviewed
- How many total findings from the 7 agents vs how many survived the filter
- The review order chosen and why (brief explanation of the logical grouping)
- A brief list of the comments added, grouped by category
- Any overall architectural concerns about the change

Remind the user they can navigate with:
- `]h`/`[h` — follow the intelligent walk order (cross-file, logical grouping)
- `]H`/`[H` — next/prev hunk within the current file only
- `]f`/`[f` — next/prev file
- `<leader>zt` — open the sidebar showing the full review order

Both `]h` and `]H` can be mixed freely — the walk position stays in sync.

## Step 10 — Optionally push to GitHub

If the target was a PR (not just a commit), ask the user:

> "Would you like to push these comments to GitHub as a PR review?"

If yes, run:
```sh
zpr-push-review <pr-number>
```

Or from Neovim: `:ZprPushReview <pr-number>` (use `:ZprPushReview! <pr-number>` to submit as REQUEST_CHANGES instead of COMMENT).

Note: GitHub only accepts review comments on lines that appear in the PR diff. Comments you placed on unchanged context lines will cause the API call to fail — remove them first or re-add them on a changed line.
