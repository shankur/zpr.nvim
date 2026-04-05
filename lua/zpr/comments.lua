-- comments.lua: inline comment management
-- Comments render as virt_lines below the commented line in the after buffer,
-- with matching blank virt_lines in the before buffer to preserve alignment.

local M = {}

local cfg = require("zpr.config")
local ns_comment = vim.api.nvim_create_namespace("zpr_comments")
local ns_filler  = vim.api.nvim_create_namespace("zpr_fillers")

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

-- Persist serialisable fields to disk
local function save()
  local path = comments_path()
  if not path then return end
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local out = {}
  for _, c in ipairs(comments()) do
    table.insert(out, {
      file       = c.file,
      new_line   = c.new_line,
      old_line   = c.old_line,
      body       = c.body,
      hunk_index = c.hunk_index,
    })
  end
  local f = io.open(path, "w")
  if f then f:write(vim.json.encode(out)); f:close() end
end

-- Render the comment virt_line below `line_0` (0-based) in the after buffer
local function render_comment(buf, line_0, body)
  return vim.api.nvim_buf_set_extmark(buf, ns_comment, line_0, 0, {
    virt_lines = {
      {
        { "  ▎ ", "ZprCommentBar" },
        { body,   "ZprComment" },
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

-- Re-render all stored comments for the current file.
-- Reads buffers from _G.zpr_state directly so it's always fresh.
function M.render_all(file_path)
  local after_buf  = _G.zpr_state and _G.zpr_state.right_buf
  local before_buf = _G.zpr_state and _G.zpr_state.left_buf
  if type(after_buf)  ~= "number" or not vim.api.nvim_buf_is_valid(after_buf)  then return end
  if type(before_buf) ~= "number" or not vim.api.nvim_buf_is_valid(before_buf) then return end
  vim.api.nvim_buf_clear_namespace(after_buf,  ns_comment, 0, -1)
  vim.api.nvim_buf_clear_namespace(before_buf, ns_filler,  0, -1)
  for _, c in ipairs(comments()) do
    if c.file == file_path then
      c.comment_id = render_comment(after_buf,  c.new_line - 1, c.body)
      c.filler_id  = render_filler(before_buf, c.old_line - 1)
      c.after_buf  = after_buf
      c.before_buf = before_buf
    end
  end
end

-- Add a comment interactively on new_line (1-based) of the after buffer.
-- hunk: { old_start, new_start } used to find the mirror line in before.
function M.add(file_path, new_line, hunk_index, hunk)
  local prompt = ("Comment [%s:%d]: "):format(
    vim.fn.fnamemodify(file_path, ":t"), new_line)

  vim.ui.input({ prompt = prompt, default = "" }, function(text)
    if not text or vim.trim(text) == "" then return end
    vim.schedule(function()
      -- Look up buffers fresh inside vim.schedule — avoids stale handles
      -- that were nil at keymap-trigger time but valid by render time.
      local after_buf  = _G.zpr_state and _G.zpr_state.right_buf
      local before_buf = _G.zpr_state and _G.zpr_state.left_buf
      if not after_buf  or not vim.api.nvim_buf_is_valid(after_buf)  then return end
      if not before_buf or not vim.api.nvim_buf_is_valid(before_buf) then return end

      local old_line   = map_to_old_line(new_line, hunk)
      local comment_id = render_comment(after_buf,  new_line - 1, text)
      local filler_id  = render_filler(before_buf, old_line - 1)

      table.insert(comments(), {
        file       = file_path,
        new_line   = new_line,
        old_line   = old_line,
        body       = text,
        hunk_index = hunk_index,
        comment_id = comment_id,
        filler_id  = filler_id,
        after_buf  = after_buf,
        before_buf = before_buf,
      })

      save()
    end)
  end)
end

-- Delete the comment on new_line (1-based) in the after buffer
function M.delete_at(after_buf, file_path, new_line)
  local remaining = {}
  local deleted = false
  for _, c in ipairs(comments()) do
    if not deleted and c.file == file_path and c.new_line == new_line then
      pcall(vim.api.nvim_buf_del_extmark, after_buf,  ns_comment, c.comment_id)
      pcall(vim.api.nvim_buf_del_extmark, c.before_buf or after_buf, ns_filler, c.filler_id)
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
      file       = c.file,
      line       = c.new_line,
      body       = c.body,
      hunk_index = c.hunk_index,
    })
  end
  return out
end

-- Wipe all comments and their extmarks
function M.clear()
  for _, c in ipairs(comments()) do
    pcall(vim.api.nvim_buf_del_extmark, c.after_buf,  ns_comment, c.comment_id)
    pcall(vim.api.nvim_buf_del_extmark, c.before_buf, ns_filler,  c.filler_id)
  end
  _G.zpr_state.comments = {}
  save()
end

return M
