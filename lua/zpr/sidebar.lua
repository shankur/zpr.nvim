-- sidebar.lua: file/hunk tree panel for zpr reviews
-- Shows all files and their hunks; navigate with j/k, jump with <CR>.

local M = {}

local ns       = vim.api.nvim_create_namespace("zpr_sidebar")
local WIDTH    = 42
local sbuf     = nil   -- sidebar buffer
local swin     = nil   -- sidebar window
local line_map = {}    -- line (1-based) → { kind, file_index, hunk_index? }
local display_mode = "walk"  -- "walk" (intelligent order) or "files" (file order)

-- ── helpers ────────────────────────────────────────────────────────────────

local function is_open()
  return swin ~= nil and vim.api.nvim_win_is_valid(swin)
end

local function file_has_comments(file_path)
  local cs = _G.zpr_state and _G.zpr_state.comments or {}
  for _, c in ipairs(cs) do
    if c.file == file_path then return true end
  end
  return false
end

local function hunk_has_comments(file_path, hunk_index)
  local cs = _G.zpr_state and _G.zpr_state.comments or {}
  for _, c in ipairs(cs) do
    if c.file == file_path and c.hunk_index == hunk_index then return true end
  end
  return false
end

local function hunk_header(h)
  local diff = require("zpr.diff")
  return diff.parse_hunk_header(h).header or h
end

local function short_path(file_path)
  local fname = vim.fn.fnamemodify(file_path, ":t")
  local fdir  = vim.fn.fnamemodify(file_path, ":h")
  if fdir == "." then return fname end
  -- Truncate dir so total fits within sidebar width
  local max_dir = WIDTH - #fname - 6
  if #fdir > max_dir then fdir = "…" .. fdir:sub(-max_dir + 1) end
  return fname .. "  " .. fdir
end

-- ── render ─────────────────────────────────────────────────────────────────

function M.refresh()
  if not is_open() then return end
  local r     = _G.zpr_state or {}
  local files = r.files or {}

  local lines        = {}
  local new_map      = {}
  local hls          = {}   -- { lnum_0based, hl_group }
  local comment_hls  = {}   -- { lnum_0based, col_start } for ✎ markers

  local function push(text, item, hl, comment_mark)
    table.insert(lines, text)
    local lnum = #lines
    if item         then new_map[lnum] = item end
    if hl           then table.insert(hls, { lnum - 1, hl }) end
    if comment_mark then table.insert(comment_hls, { lnum - 1, #text - #"✎" }) end
    return lnum
  end

  if display_mode == "walk" and #(r.walk_order or {}) > 0 then
    -- Walk order view
    local title = ("  zpr  walk (%d/%d)"):format(r.walk_index or 0, #r.walk_order)
    push(title, { kind = "header" }, "ZprSidebarTitle")
    push("", nil, nil)

    local prev_file = nil
    for si, step in ipairs(r.walk_order) do
      local is_cur = (r.walk_index == si)
      local bullet = is_cur and "● " or "○ "

      -- Show file header when file changes
      if step.file_path ~= prev_file then
        local label = short_path(step.file_path)
        local file_hl = (step.file_path == r.file_path) and "ZprSidebarFileCurrent" or "ZprSidebarFile"
        push("  " .. label, { kind = "file", file_index = si }, file_hl)
        prev_file = step.file_path
      end

      -- Find hunk header text
      local hunk_text = ("hunk %d"):format(step.hunk_index)
      for _, f in ipairs(files) do
        if f.file_path == step.file_path and f.hunks and f.hunks[step.hunk_index] then
          hunk_text = hunk_header(f.hunks[step.hunk_index]):sub(1, WIDTH - 10)
          break
        end
      end

      local h_has_c = hunk_has_comments(step.file_path, step.hunk_index)
      local step_text = ("    %s%s%s"):format(bullet, hunk_text, h_has_c and " ✎" or "")
      push(step_text,
        { kind = "walk_step", walk_index = si, file_path = step.file_path, hunk_index = step.hunk_index },
        is_cur and "ZprSidebarHunkCurrent" or "ZprSidebarHunk",
        h_has_c)
    end
  else
    -- File order view (default)
    push("  zpr  review", { kind = "header" }, "ZprSidebarTitle")
    push("", nil, nil)

    if #files == 0 then
      push("  (no review open)", nil, "ZprSidebarHunk")
    else
      for fi, f in ipairs(files) do
        local is_cur_file = (r.file_index == fi)
        local is_viewed   = require("zpr.viewed").is_viewed(f.file_path)
        local icon        = is_viewed and "✓ " or (is_cur_file and "▶ " or "  ")
        local label       = short_path(f.file_path)
        local f_has_c     = file_has_comments(f.file_path)
        local file_hl     = is_viewed and "ZprSidebarFileViewed"
                            or (is_cur_file and "ZprSidebarFileCurrent" or "ZprSidebarFile")
        local file_text   = ("  %s%s%s"):format(icon, label, f_has_c and " ✎" or "")
        push(file_text,
          { kind = "file", file_index = fi },
          file_hl,
          f_has_c)

        if not is_viewed then
          for hi, h in ipairs(f.hunks or {}) do
            local is_cur    = is_cur_file and r.hunk_index == hi
            local bullet    = is_cur and "● " or "○ "
            local header    = hunk_header(h):sub(1, WIDTH - 8)
            local h_has_c   = hunk_has_comments(f.file_path, hi)
            local hunk_text = ("    %s%s%s"):format(bullet, header, h_has_c and " ✎" or "")
            push(hunk_text,
              { kind = "hunk", file_index = fi, hunk_index = hi },
              is_cur and "ZprSidebarHunkCurrent" or "ZprSidebarHunk",
              h_has_c)
          end
        end
        push("", nil, nil)
      end
    end
  end

  -- Write buffer
  vim.bo[sbuf].modifiable = true
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].modifiable = false
  line_map = new_map

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(sbuf, ns, 0, -1)
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(sbuf, ns, hl[1], 0, {
      line_hl_group = hl[2], priority = 100
    })
  end
  local mark_bytes = #"✎"
  for _, cm in ipairs(comment_hls) do
    vim.api.nvim_buf_set_extmark(sbuf, ns, cm[1], cm[2], {
      end_col  = cm[2] + mark_bytes,
      hl_group = "ZprSidebarCommentMark",
      priority = 110,
    })
  end

  -- Move cursor to current hunk
  M.refresh_cursor()
end

-- Lightweight: just reposition the cursor to the active hunk line.
function M.refresh_cursor()
  if not is_open() then return end
  local r = _G.zpr_state or {}
  for lnum, item in pairs(line_map) do
    if item.kind == "hunk"
      and item.file_index  == r.file_index
      and item.hunk_index  == r.hunk_index then
      pcall(vim.api.nvim_win_set_cursor, swin, { lnum, 0 })
      return
    end
  end
end

-- ── navigation ─────────────────────────────────────────────────────────────

local function move(direction)
  if not is_open() then return end
  local cur = vim.api.nvim_win_get_cursor(swin)[1]
  local max = vim.api.nvim_buf_line_count(sbuf)
  local step = direction == "down" and 1 or -1
  local next = cur + step
  while next >= 1 and next <= max do
    if line_map[next] and line_map[next].kind ~= "header" then
      vim.api.nvim_win_set_cursor(swin, { next, 0 })
      return
    end
    next = next + step
  end
end

local function activate()
  if not is_open() then return end
  local row  = vim.api.nvim_win_get_cursor(swin)[1]
  local item = line_map[row]
  if not item then return end

  -- Clicking a file header jumps to its first hunk
  local fi = item.file_index
  local hi = item.hunk_index or 1

  local diff = require("zpr.diff")
  local r    = diff.review

  if fi == r.file_index then
    -- Same file: drive hunk navigation
    local delta = hi - r.hunk_index
    if delta > 0 then
      for _ = 1, delta  do diff.next_hunk({}) end
    elseif delta < 0 then
      for _ = 1, -delta do diff.prev_hunk({}) end
    end
  else
    -- Different file: open it at the target hunk
    local f = r.files and r.files[fi]
    if not f then return end
    diff.open_file({
      file_path  = f.file_path,
      hunks      = f.hunks,
      repo_path  = r.repo_path,
      base_ref   = r.base_ref,
      head_ref   = r.head_ref,
      file_index = fi,
      start_hunk = hi,
    })
  end

  -- Return focus to the after (right) diff pane
  if r.right_win and vim.api.nvim_win_is_valid(r.right_win) then
    vim.api.nvim_set_current_win(r.right_win)
  end
end

local function toggle_viewed_at_cursor()
  if not is_open() then return end
  local row  = vim.api.nvim_win_get_cursor(swin)[1]
  local item = line_map[row]
  if not item or item.kind == "header" then return end
  local r = _G.zpr_state or {}
  local f = r.files and r.files[item.file_index]
  if not f then return end
  require("zpr.viewed").toggle(f.file_path)
end

-- ── open / close / toggle ──────────────────────────────────────────────────

function M.open()
  if is_open() then return end

  sbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(sbuf, "zpr://sidebar")
  vim.bo[sbuf].buftype   = "nofile"
  vim.bo[sbuf].swapfile  = false
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].modifiable = false

  -- Remember which window was focused so we can return to it
  local prev_win = vim.api.nvim_get_current_win()

  -- Open as a fixed-width right split
  vim.cmd("botright " .. WIDTH .. "vsplit")
  swin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(swin, sbuf)

  vim.wo[swin].number         = false
  vim.wo[swin].relativenumber = false
  vim.wo[swin].signcolumn     = "no"
  vim.wo[swin].wrap           = false
  vim.wo[swin].cursorline     = true
  vim.wo[swin].winfixwidth    = true
  vim.wo[swin].statusline     = "  zpr  review"

  -- Keymaps
  local opts = { buffer = sbuf, silent = true, nowait = true }
  vim.keymap.set("n", "j",      function() move("down") end,   vim.tbl_extend("force", opts, { desc = "zpr sidebar: down" }))
  vim.keymap.set("n", "k",      function() move("up")   end,   vim.tbl_extend("force", opts, { desc = "zpr sidebar: up" }))
  vim.keymap.set("n", "<Down>", function() move("down") end,   vim.tbl_extend("force", opts, { desc = "zpr sidebar: down" }))
  vim.keymap.set("n", "<Up>",   function() move("up")   end,   vim.tbl_extend("force", opts, { desc = "zpr sidebar: up" }))
  vim.keymap.set("n", "<CR>",   activate,                             vim.tbl_extend("force", opts, { desc = "zpr sidebar: jump to hunk" }))
  vim.keymap.set("n", "v",      toggle_viewed_at_cursor,              vim.tbl_extend("force", opts, { desc = "zpr sidebar: toggle file viewed" }))
  vim.keymap.set("n", "q",      function() M.close() end,             vim.tbl_extend("force", opts, { desc = "zpr sidebar: close" }))

  M.refresh()

  -- Restore focus to the previous window
  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end
end

function M.close()
  if is_open() then
    pcall(vim.api.nvim_win_close, swin, true)
  end
  swin     = nil
  sbuf     = nil
  line_map = {}
end

function M.toggle()
  if is_open() then M.close() else M.open() end
end

function M.toggle_walk()
  display_mode = "walk"
  if not is_open() then M.open() else M.refresh() end
end

function M.toggle_files()
  display_mode = "files"
  if not is_open() then M.open() else M.refresh() end
end

return M
