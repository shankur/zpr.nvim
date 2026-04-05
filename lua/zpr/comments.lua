-- comments.lua: inline comment management
-- Comments render as virt_lines below the commented line in the after buffer,
-- with matching blank virt_lines in the before buffer to preserve alignment.
-- Range comments (visual selection) anchor below the last line of the range.

local M = {}

local cfg = require("zpr.config")
local ns_comment = vim.api.nvim_create_namespace("zpr_comments")
local ns_filler  = vim.api.nvim_create_namespace("zpr_fillers")
local ns_lines   = vim.api.nvim_create_namespace("zpr_comment_lines")

if not _G.zpr_state then _G.zpr_state = {} end
if not _G.zpr_state.comments then _G.zpr_state.comments = {} end

local function comments() return _G.zpr_state.comments end

-- Resolve the current comments file path from the active review state.
-- Returns nil if no review is open yet.
local function comments_path()
  local s = _G.zpr_state
  if not s or not s.repo_path or not s.head_ref then return nil end
  return cfg.comments_file(s.repo_path, s.head_ref)
end

-- Load comments from disk into _G.zpr_state.comments.
-- Called once per review open (when repo/ref changes).
function M.load()
  local path = comments_path()
  if not path then return end
  local f = io.open(path, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return end
  _G.zpr_state.comments = data
end

-- Persist serialisable fields to disk
local function save()
  local path = comments_path()
  if not path then return end
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local out = {}
  for _, c in ipairs(comments()) do
    table.insert(out, {
      file         = c.file,
      new_line     = c.new_line,
      new_line_end = c.new_line_end,
      old_line     = c.old_line,
      body         = c.body,
      hunk_index   = c.hunk_index,
    })
  end
  local f = io.open(path, "w")
  if f then f:write(vim.json.encode(out)); f:close() end
end

-- Build the prefix shown before the comment body.
-- Single-line: "  💬 :5 "   Range: "  💬 [5–8] "
local function comment_prefix(new_line, new_line_end)
  if new_line_end and new_line_end > new_line then
    return ("  💬 [%d–%d] "):format(new_line, new_line_end)
  end
  return ("  💬 :%d "):format(new_line)
end

-- Render the comment virt_line below `line_0` (0-based) in the after buffer.
local function render_comment(buf, line_0, body, new_line, new_line_end)
  return vim.api.nvim_buf_set_extmark(buf, ns_comment, line_0, 0, {
    virt_lines = {
      {
        { comment_prefix(new_line, new_line_end), "ZprCommentBar" },
        { body, "ZprComment" },
      },
    },
  })
end

-- Render a blank filler virt_line below `line_0` in the before buffer
-- so the two panes stay visually aligned.
local function render_filler(buf, line_0)
  return vim.api.nvim_buf_set_extmark(buf, ns_filler, line_0, 0, {
    virt_lines = { { { "", "Normal" } } },
  })
end

-- Map a line number in the after file to the corresponding line in the
-- before file using the hunk's old_start / new_start offset.
-- For lines added in this hunk (no before equivalent) we anchor to old_start.
local function map_to_old_line(new_line, hunk)
  if not hunk then return new_line end
  local offset = new_line - hunk.new_start
  if offset < 0 then return hunk.old_start end
  return math.max(1, hunk.old_start + offset)
end

-- Highlight the source lines the comment refers to with a background tint
-- and a sign column glyph. Returns a list of extmark IDs.
local function render_comment_lines(buf, new_line, new_line_end)
  local last = new_line_end or new_line
  local ids  = {}
  for lnum = new_line, last do
    local sign
    if new_line == last then
      sign = "│"
    elseif lnum == new_line then
      sign = "╭"
    elseif lnum == last then
      sign = "╰"
    else
      sign = "│"
    end
    local id = vim.api.nvim_buf_set_extmark(buf, ns_lines, lnum - 1, 0, {
      sign_text     = sign,
      sign_hl_group = "ZprCommentBar",
      line_hl_group = "ZprCommentLine",
    })
    table.insert(ids, id)
  end
  return ids
end

-- Place the comment extmark and filler, returning their IDs.
local function place(after_buf, before_buf, new_line, new_line_end, old_line, body)
  -- Anchor below the last line of the range (0-based)
  local anchor = (new_line_end or new_line) - 1
  local comment_id = render_comment(after_buf, anchor, body, new_line, new_line_end)
  local before_lines = vim.api.nvim_buf_line_count(before_buf)
  local filler_line  = math.min(old_line - 1, math.max(0, before_lines - 1))
  local filler_id    = before_lines > 0 and render_filler(before_buf, filler_line) or nil
  local line_ids     = render_comment_lines(after_buf, new_line, new_line_end)
  return comment_id, filler_id, line_ids
end

-- Re-render all stored comments for the current file.
function M.render_all(file_path)
  local after_buf  = _G.zpr_state and _G.zpr_state.right_buf
  local before_buf = _G.zpr_state and _G.zpr_state.left_buf
  if type(after_buf)  ~= "number" or not vim.api.nvim_buf_is_valid(after_buf)  then return end
  if type(before_buf) ~= "number" or not vim.api.nvim_buf_is_valid(before_buf) then return end
  vim.api.nvim_buf_clear_namespace(after_buf,  ns_comment, 0, -1)
  vim.api.nvim_buf_clear_namespace(before_buf, ns_filler,  0, -1)
  for _, c in ipairs(comments()) do
    if c.file == file_path then
      c.comment_id, c.filler_id, c.line_ids = place(
        after_buf, before_buf, c.new_line, c.new_line_end, c.old_line, c.body)
      c.after_buf  = after_buf
      c.before_buf = before_buf
    end
  end
end

-- Add a comment interactively on new_line..new_line_end (1-based) of the after buffer.
-- new_line_end may be nil for single-line comments.
function M.add(file_path, new_line, new_line_end, hunk_index, hunk)
  local fname = vim.fn.fnamemodify(file_path, ":t")
  local range  = (new_line_end and new_line_end > new_line)
    and ("%d–%d"):format(new_line, new_line_end) or tostring(new_line)
  local prompt = ("Comment [%s:%s]: "):format(fname, range)

  vim.ui.input({ prompt = prompt, default = "" }, function(text)
    if not text or vim.trim(text) == "" then return end
    vim.schedule(function()
      local after_buf  = _G.zpr_state and _G.zpr_state.right_buf
      local before_buf = _G.zpr_state and _G.zpr_state.left_buf
      if not after_buf  or not vim.api.nvim_buf_is_valid(after_buf)  then return end
      if not before_buf or not vim.api.nvim_buf_is_valid(before_buf) then return end

      -- Anchor old_line to the end of the range
      local anchor_line = new_line_end or new_line
      local old_line    = map_to_old_line(anchor_line, hunk)
      local comment_id, filler_id, line_ids = place(
        after_buf, before_buf, new_line, new_line_end, old_line, text)

      table.insert(comments(), {
        file         = file_path,
        new_line     = new_line,
        new_line_end = new_line_end,
        old_line     = old_line,
        body         = text,
        hunk_index   = hunk_index,
        comment_id   = comment_id,
        filler_id    = filler_id,
        line_ids     = line_ids,
        after_buf    = after_buf,
        before_buf   = before_buf,
      })

      save()
    end)
  end)
end

-- Return the comment whose range contains `line` (1-based), or nil.
function M.find_at(file_path, line)
  for _, c in ipairs(comments()) do
    if c.file == file_path then
      local last = c.new_line_end or c.new_line
      if line >= c.new_line and line <= last then return c end
    end
  end
end

-- Edit the comment that covers `new_line` interactively.
function M.edit_at(file_path, new_line)
  local c = M.find_at(file_path, new_line)
  if not c then return end

  local fname  = vim.fn.fnamemodify(file_path, ":t")
  local last   = c.new_line_end or c.new_line
  local range  = last > c.new_line
    and ("%d–%d"):format(c.new_line, last) or tostring(c.new_line)
  local prompt = ("Edit comment [%s:%s]: "):format(fname, range)

  vim.ui.input({ prompt = prompt, default = c.body }, function(text)
    if not text then return end
    if vim.trim(text) == "" then
      M.delete_at(c.after_buf, file_path, c.new_line)
      return
    end
    vim.schedule(function()
      c.body = text
      if c.after_buf and vim.api.nvim_buf_is_valid(c.after_buf) then
        pcall(vim.api.nvim_buf_del_extmark, c.after_buf, ns_comment, c.comment_id)
      end
      c.comment_id = render_comment(c.after_buf, last - 1, text, c.new_line, c.new_line_end)
      save()
    end)
  end)
end

-- Delete the comment starting at new_line (1-based).
function M.delete_at(after_buf, file_path, new_line)
  local remaining = {}
  local deleted = false
  for _, c in ipairs(comments()) do
    if not deleted and c.file == file_path and c.new_line == new_line then
      pcall(vim.api.nvim_buf_del_extmark, after_buf, ns_comment, c.comment_id)
      pcall(vim.api.nvim_buf_del_extmark, c.before_buf or after_buf, ns_filler, c.filler_id)
      for _, id in ipairs(c.line_ids or {}) do
        pcall(vim.api.nvim_buf_del_extmark, after_buf, ns_lines, id)
      end
      deleted = true
    else
      table.insert(remaining, c)
    end
  end
  _G.zpr_state.comments = remaining
  save()
end

-- Return all comments as a plain table (for RPC / Claude)
function M.get_all()
  local out = {}
  for _, c in ipairs(comments()) do
    table.insert(out, {
      file         = c.file,
      line         = c.new_line,
      line_end     = c.new_line_end,
      body         = c.body,
      hunk_index   = c.hunk_index,
    })
  end
  return out
end

-- Wipe all comments and their extmarks
function M.clear()
  for _, c in ipairs(comments()) do
    pcall(vim.api.nvim_buf_del_extmark, c.after_buf,  ns_comment, c.comment_id)
    pcall(vim.api.nvim_buf_del_extmark, c.before_buf, ns_filler,  c.filler_id)
    for _, id in ipairs(c.line_ids or {}) do
      pcall(vim.api.nvim_buf_del_extmark, c.after_buf, ns_lines, id)
    end
  end
  _G.zpr_state.comments = {}
  save()
end

return M
