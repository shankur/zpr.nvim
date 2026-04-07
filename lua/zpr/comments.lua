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
      locked       = c.locked    or nil,
      gh_id        = c.gh_id     or nil,
      gh_author    = c.gh_author or nil,
      gh_pr        = c.gh_pr     or nil,
    })
  end
  local f = io.open(path, "w")
  if f then f:write(vim.json.encode(out)); f:close() end
  -- Refresh sidebar markers
  require("zpr.sidebar").refresh()
end

-- Word-wrap `text` to `width` characters per line, respecting explicit newlines.
-- Returns a list of strings (at least one).
local function wrap_body(text, width)
  if width <= 0 then return { text } end
  local result = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    if para == "" then
      table.insert(result, "")
    else
      local cur = ""
      for word in (para .. " "):gmatch("(%S+)%s") do
        if cur == "" then
          cur = word
        elseif #cur + 1 + #word <= width then
          cur = cur .. " " .. word
        else
          table.insert(result, cur)
          cur = word
        end
      end
      if cur ~= "" then table.insert(result, cur) end
    end
  end
  return #result > 0 and result or { text }
end

-- Build the prefix shown before the comment body.
-- Normal:   "  │ :5 "          Range: "  │ [5–8] "
-- Locked:   "  ⊘ @alice :5 "   Range: "  ⊘ @alice [5–8] "
local function comment_prefix(new_line, new_line_end, locked, gh_author)
  local icon   = locked and "⊘" or "│"
  local author = (locked and gh_author and gh_author ~= "") and (" @" .. gh_author) or ""
  if new_line_end and new_line_end > new_line then
    return ("  %s%s [%d–%d] "):format(icon, author, new_line, new_line_end)
  end
  return ("  %s%s :%d "):format(icon, author, new_line)
end

-- Render the comment virt_line below `line_0` (0-based) in the after buffer.
-- Long bodies are word-wrapped; set vim.g.zpr_comment_wrap to change the width
-- (default 80). Set to 0 to disable wrapping.
local function render_comment(buf, line_0, body, new_line, new_line_end, locked, gh_author)
  local bar_hl  = locked and "ZprCommentBarLocked" or "ZprCommentBar"
  local body_hl = locked and "ZprCommentLocked"    or "ZprComment"
  local prefix   = comment_prefix(new_line, new_line_end, locked, gh_author)
  local prefix_w = vim.fn.strdisplaywidth(prefix)
  local wrap     = vim.g.zpr_comment_wrap or 80
  local chunks   = wrap_body(body, wrap > 0 and math.max(20, wrap - prefix_w) or 0)
  local indent   = string.rep(" ", prefix_w)

  local virt_lines = {}
  for i, chunk in ipairs(chunks) do
    table.insert(virt_lines, {
      { i == 1 and prefix or indent, bar_hl },
      { chunk, body_hl },
    })
  end

  return vim.api.nvim_buf_set_extmark(buf, ns_comment, line_0, 0, {
    virt_lines = virt_lines,
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
local function render_comment_lines(buf, new_line, new_line_end, locked)
  local buf_lines = vim.api.nvim_buf_line_count(buf)
  local last      = math.min(new_line_end or new_line, buf_lines)
  local first     = math.min(new_line, buf_lines)
  local sign_hl   = locked and "ZprCommentBarLocked" or "ZprCommentBar"
  local line_hl   = locked and "ZprCommentLineLocked" or "ZprCommentLine"
  local ids = {}
  for lnum = first, last do
    local sign
    if first == last then
      sign = locked and "⊘" or "│"
    elseif lnum == first then
      sign = "╭"
    elseif lnum == last then
      sign = "╰"
    else
      sign = "│"
    end
    local id = vim.api.nvim_buf_set_extmark(buf, ns_lines, lnum - 1, 0, {
      sign_text     = sign,
      sign_hl_group = sign_hl,
      line_hl_group = line_hl,
    })
    table.insert(ids, id)
  end
  return ids
end

-- Place the comment extmark and filler, returning their IDs.
local function place(after_buf, before_buf, new_line, new_line_end, old_line, body, locked, gh_author)
  -- Clamp anchor to buffer bounds (important for approximate locked lines)
  local after_lines = vim.api.nvim_buf_line_count(after_buf)
  local anchor = math.min((new_line_end or new_line) - 1, math.max(0, after_lines - 1))
  local comment_id = render_comment(after_buf, anchor, body, new_line, new_line_end, locked, gh_author)
  local before_lines = vim.api.nvim_buf_line_count(before_buf)
  local filler_line  = math.min(old_line - 1, math.max(0, before_lines - 1))
  local filler_id    = before_lines > 0 and render_filler(before_buf, filler_line) or nil
  local line_ids     = render_comment_lines(after_buf, new_line, new_line_end, locked)
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
        after_buf, before_buf, c.new_line, c.new_line_end, c.old_line, c.body, c.locked, c.gh_author)
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

-- Add a comment directly (non-interactive, for RPC / Claude).
-- Renders immediately if the file is currently open in the diff view.
-- Pass locked=true for imported comments that should not be editable.
function M.add_direct(file_path, new_line, new_line_end, hunk_index, body, locked)
  if not body or vim.trim(body) == "" then return false end
  local after_buf  = _G.zpr_state and _G.zpr_state.right_buf
  local before_buf = _G.zpr_state and _G.zpr_state.left_buf
  local r          = _G.zpr_state

  local anchor_line = new_line_end or new_line
  local hunk        = r and r.hunks and r.hunks[hunk_index]
  local old_line    = map_to_old_line(anchor_line, hunk)

  local comment_id, filler_id, line_ids
  if after_buf  and vim.api.nvim_buf_is_valid(after_buf)
  and before_buf and vim.api.nvim_buf_is_valid(before_buf)
  and (r and r.file_path == file_path) then
    comment_id, filler_id, line_ids = place(
      after_buf, before_buf, new_line, new_line_end, old_line, body, locked, nil)
  end

  table.insert(comments(), {
    file         = file_path,
    new_line     = new_line,
    new_line_end = new_line_end,
    old_line     = old_line,
    body         = body,
    hunk_index   = hunk_index,
    locked       = locked,
    comment_id   = comment_id,
    filler_id    = filler_id,
    line_ids     = line_ids or {},
    after_buf    = after_buf,
    before_buf   = before_buf,
  })

  save()
  return true
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

-- Post a threaded reply to a locked (GitHub-imported) comment.
local function reply_to(c)
  if not c.gh_id or not c.gh_pr then
    vim.notify(
      "[zpr] cannot reply: comment has no GitHub ID (imported with an older zpr-pull-review?)",
      vim.log.levels.WARN)
    return
  end
  local who    = (c.gh_author and c.gh_author ~= "") and ("@" .. c.gh_author) or "comment"
  local prompt = ("Reply to %s: "):format(who)
  vim.ui.input({ prompt = prompt }, function(text)
    if not text or vim.trim(text) == "" then return end
    vim.schedule(function()
      local repo = vim.trim(vim.fn.system("gh repo view --json nameWithOwner -q .nameWithOwner"))
      if repo == "" then
        vim.notify("[zpr] could not determine GitHub repo", vim.log.levels.ERROR)
        return
      end
      local endpoint = ("repos/%s/pulls/%d/comments/%d/replies"):format(repo, c.gh_pr, c.gh_id)
      vim.fn.jobstart({ "gh", "api", endpoint, "--method", "POST", "-f", "body=" .. text }, {
        on_exit = function(_, code)
          if code == 0 then
            vim.notify("[zpr] reply posted to GitHub", vim.log.levels.INFO)
          else
            vim.notify("[zpr] failed to post reply — check gh auth", vim.log.levels.ERROR)
          end
        end,
      })
    end)
  end)
end

-- Edit the comment that covers `new_line` interactively.
-- For locked (GitHub-imported) comments, posts a threaded reply instead.
function M.edit_at(file_path, new_line)
  local c = M.find_at(file_path, new_line)
  if not c then return end
  if c.locked then
    reply_to(c)
    return
  end

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
      c.comment_id = render_comment(c.after_buf, last - 1, text, c.new_line, c.new_line_end, c.locked, c.gh_author)
      save()
    end)
  end)
end

-- Delete the comment starting at new_line (1-based).
function M.delete_at(after_buf, file_path, new_line)
  local target = M.find_at(file_path, new_line)
  if target and target.locked then
    vim.notify("[zpr] imported GitHub comments cannot be deleted", vim.log.levels.WARN)
    return
  end
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
