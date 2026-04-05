-- diff.lua: opens full file versions from git and uses Neovim's diff mode

local M = {}

local ns = vim.api.nvim_create_namespace("zpr_diff")

-- Persist state across module reloads so keymaps keep working
if not _G.zpr_state then
  _G.zpr_state = {
    file_path  = nil,
    repo_path  = nil,
    base_ref   = nil,
    head_ref   = nil,
    hunks      = {},    -- parsed hunk tables for the current file
    hunk_index = 0,
    files      = {},    -- all files in the current commit/PR
    file_index = 0,
    left_buf   = nil,
    right_buf  = nil,
    left_win   = nil,
    right_win  = nil,
  }
end
local review = _G.zpr_state

M.review = review

-- Run a shell command and return lines, or nil + error string
local function git_file_lines(repo_path, ref, file_path)
  local cmd = { "git", "-C", repo_path, "show", ref .. ":" .. file_path }
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(result, "\n")
  end
  return result
end

-- Parse the @@ header for hunk start positions (used for status / jump)
local function parse_hunk_header(hunk_text)
  local first = hunk_text:match("^[^\n]*")
  local old_start, new_start = first:match("@@ %-(%d+)[,%d]* %+(%d+)")
  return {
    header    = first,
    old_start = tonumber(old_start) or 1,
    new_start = tonumber(new_start) or 1,
  }
end

-- Create or reuse a named scratch buffer
local function get_or_create_buf(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):match(vim.pesc(name) .. "$") then
      return buf
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

-- Set buffer content and options, then enable diff mode
local function setup_diff_buf(buf, lines, file_path)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].swapfile   = false
  -- Filetype for syntax highlighting
  local ft = vim.filetype.match({ filename = file_path }) or ""
  if ft ~= "" then vim.bo[buf].filetype = ft end
end

-- Update status lines with file + hunk position
local function update_statuslines()
  local file      = review.file_path or ""
  local file_pos  = #review.files > 0
    and (" [%d/%d]"):format(review.file_index, #review.files) or ""
  local hunk_pos  = #review.hunks > 0
    and ("  hunk %d/%d"):format(review.hunk_index, #review.hunks) or ""
  local info = file_pos .. "  " .. file .. hunk_pos
  if review.left_win and vim.api.nvim_win_is_valid(review.left_win) then
    vim.wo[review.left_win].statusline  = (" BEFORE " .. info)
  end
  if review.right_win and vim.api.nvim_win_is_valid(review.right_win) then
    vim.wo[review.right_win].statusline = (" AFTER  " .. info)
  end
end

-- Find all windows currently showing a zpr:// buffer
local function find_zpr_wins()
  local found = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match("^zpr://") then table.insert(found, win) end
  end
  return found
end

-- Open or reuse the split layout
local function open_layout(before_lines, after_lines, file_path)
  -- Always scan for existing zpr windows by buffer name — stored handles
  -- may be stale after a module reload (_G.zpr_state reset).
  local existing = find_zpr_wins()
  for _, win in ipairs(existing) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match("zpr://before$") then review.left_win  = win end
    if name:match("zpr://after$")  then review.right_win = win end
  end

  local left_valid  = review.left_win  and vim.api.nvim_win_is_valid(review.left_win)
  local right_valid = review.right_win and vim.api.nvim_win_is_valid(review.right_win)

  review.left_buf  = get_or_create_buf("zpr://before")
  review.right_buf = get_or_create_buf("zpr://after")

  setup_diff_buf(review.left_buf,  before_lines, file_path)
  setup_diff_buf(review.right_buf, after_lines,  file_path)

  if left_valid and right_valid then
    -- Reuse existing windows: point them at the updated buffers
    vim.api.nvim_win_set_buf(review.left_win,  review.left_buf)
    vim.api.nvim_win_set_buf(review.right_win, review.right_buf)
    for _, win in ipairs({ review.left_win, review.right_win }) do
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
  else
    -- First time: create the split layout
    vim.cmd("edit zpr://before")
    review.left_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit zpr://after")
    review.right_win = vim.api.nvim_get_current_win()
  end

  -- Ensure filler lines are on so added/deleted blocks are padded to align
  vim.opt.diffopt:append("filler")

  -- Enable Neovim's built-in diff on both windows, then force scrollbind
  -- so the padded filler lines actually stay in sync as you scroll.
  for _, win in ipairs({ review.left_win, review.right_win }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
      vim.wo.scrollbind = true
      vim.wo.cursorbind = true
    end)
  end

  -- Snap both windows to the same scroll position
  vim.api.nvim_win_call(review.left_win, function() vim.cmd("syncbind") end)

  update_statuslines()

  -- Notify init.lua to wire keymaps on the fresh buffers
  vim.api.nvim_exec_autocmds("User", { pattern = "ZprLayoutReady", modeline = false })
end

-- Jump to next/prev hunk using Neovim's built-in diff motions.
-- Uses feedkeys so ]c/[c executes in the current focused window,
-- which is required for diff motions to work correctly.
local function jump_diff(direction)
  local keys = vim.api.nvim_replace_termcodes(direction .. "zz", true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

-- Public: open a file and show its full before/after via git
-- params: { file_path, hunks, repo_path, base_ref, head_ref }
function M.open_file(params)
  local file_path = params.file_path
  local repo_path = params.repo_path
  local base_ref  = params.base_ref
  local head_ref  = params.head_ref

  if not repo_path or not base_ref or not head_ref then
    return { error = "open_file requires repo_path, base_ref, and head_ref" }
  end

  -- Fetch file content from git (blocking — runs before vim.schedule).
  -- For added files the before ref won't exist; for deleted files the after
  -- ref won't exist. Use empty content for the missing side.
  local before_lines = git_file_lines(repo_path, base_ref, file_path) or {}
  local after_lines  = git_file_lines(repo_path, head_ref, file_path) or {}

  -- Update review state
  review.file_path  = file_path
  review.repo_path  = repo_path
  review.base_ref   = base_ref
  review.head_ref   = head_ref
  review.hunks      = {}
  review.hunk_index = 0

  -- Store the full file list when provided (first open_file call for a commit)
  if params.files then
    review.files      = params.files
    review.file_index = params.file_index or 1
  end

  for _, h in ipairs(params.hunks or {}) do
    table.insert(review.hunks, parse_hunk_header(h))
  end

  vim.schedule(function()
    open_layout(before_lines, after_lines, file_path)
    if #review.hunks > 0 then
      M.next_hunk({})
    end
  end)

  return { file = file_path, file_index = review.file_index, file_total = #review.files, hunk_count = #review.hunks }
end

-- Public: jump to next file in the commit
function M.next_file(_params)
  if #review.files == 0 then return { error = "no file list loaded" } end
  if review.file_index >= #review.files then
    return { error = "already at last file" }
  end
  review.file_index = review.file_index + 1
  local f = review.files[review.file_index]
  return M.open_file({
    file_path  = f.file_path,
    hunks      = f.hunks,
    repo_path  = review.repo_path,
    base_ref   = review.base_ref,
    head_ref   = review.head_ref,
    file_index = review.file_index,
  })
end

-- Public: jump to previous file in the commit
function M.prev_file(_params)
  if #review.files == 0 then return { error = "no file list loaded" } end
  if review.file_index <= 1 then
    return { error = "already at first file" }
  end
  review.file_index = review.file_index - 1
  local f = review.files[review.file_index]
  return M.open_file({
    file_path  = f.file_path,
    hunks      = f.hunks,
    repo_path  = review.repo_path,
    base_ref   = review.base_ref,
    head_ref   = review.head_ref,
    file_index = review.file_index,
  })
end

-- Public: jump to next hunk
function M.next_hunk(_params)
  if #review.hunks == 0 then return { error = "no hunks loaded" } end
  review.hunk_index = math.min(review.hunk_index + 1, #review.hunks)
  jump_diff("]c")
  update_statuslines()
  return { hunk = review.hunk_index, total = #review.hunks }
end

-- Public: jump to previous hunk
function M.prev_hunk(_params)
  if #review.hunks == 0 then return { error = "no hunks loaded" } end
  review.hunk_index = math.max(review.hunk_index - 1, 1)
  jump_diff("[c")
  update_statuslines()
  return { hunk = review.hunk_index, total = #review.hunks }
end

-- Public: close the review layout
function M.close()
  local wins  = find_zpr_wins()
  local total = #vim.api.nvim_list_wins()
  for i, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    if total - (i - 1) > 1 then
      vim.api.nvim_win_close(win, true)
    else
      vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
    end
  end
  review.left_win  = nil
  review.right_win = nil
end

return M
