-- zpr/init.lua: main module

local M = {}

-- Absolute path to the plugin root (used to locate bin/ scripts)
local _plugin_root = vim.fn.fnamemodify(
  debug.getinfo(1, "S").source:sub(2), ":h:h:h")

-- RPC method registry — Claude calls these via zpr_rpc()
M.handlers = {}

function M.setup()
  require("zpr.highlights").setup()
  require("zpr.server").publish_socket()

  -- Live requires so handlers survive module reloads
  local function diff()     return require("zpr.diff")     end
  local function comments() return require("zpr.comments") end

  -- RPC handlers
  M.handlers["open_file"]      = function(p) return diff().open_file(p) end
  M.handlers["next_hunk"]      = function(p) return diff().next_hunk(p) end
  M.handlers["prev_hunk"]      = function(p) return diff().prev_hunk(p) end
  M.handlers["close"]          = function(_) vim.schedule(function() diff().close() end); return {} end
  M.handlers["ping"]           = function(_) return { pong = true } end
  M.handlers["next_file"]      = function(p) return diff().next_file(p) end
  M.handlers["prev_file"]      = function(p) return diff().prev_file(p) end
  M.handlers["get_comments"]   = function(_) return comments().get_all() end
  M.handlers["clear_comments"]   = function(_) comments().clear(); return {} end
  M.handlers["reload_comments"]  = function(_)
    _G.zpr_state.comments = {}
    comments().load()
    local r = diff().review
    if r.file_path then comments().render_all(r.file_path) end
    require("zpr.sidebar").refresh()
    return {}
  end
  M.handlers["add_comment"]    = function(p)
    local hunks = diff().review.hunks
    if hunks and #hunks > 0 then
      local in_diff = false
      for _, h in ipairs(hunks) do
        if h.new_count > 0 and p.line >= h.new_start and p.line <= h.new_end then
          in_diff = true; break
        end
      end
      if not in_diff then
        return { ok = false, error = ("line %d is outside the diff"):format(p.line) }
      end
    end
    local ok = comments().add_direct(
      p.file_path, p.line, p.line_end, p.hunk_index or 1, p.body)
    return { ok = ok }
  end
  M.handlers["state"]          = function(_)
    local r = diff().review
    return {
      repo_path = r.repo_path,
      base_ref  = r.base_ref,
      head_ref  = r.head_ref,
      file_path = r.file_path,
    }
  end
  M.handlers["status"]         = function(_)
    local r = diff().review
    return {
      file       = r.file_path,
      file_index = r.file_index,
      file_total = #r.files,
      hunk       = r.hunk_index,
      hunk_total = #r.hunks,
      comments   = #comments().get_all(),
    }
  end

  -- User-facing commands
  vim.api.nvim_create_user_command("ZprNext", function()
    diff().next_hunk({})
  end, { desc = "zpr: next diff hunk" })

  vim.api.nvim_create_user_command("ZprPrev", function()
    diff().prev_hunk({})
  end, { desc = "zpr: previous diff hunk" })

  vim.api.nvim_create_user_command("ZprClose", function()
    diff().close()
  end, { desc = "zpr: close review" })

  vim.api.nvim_create_user_command("ZprStatus", function()
    local r = diff().review
    if r.file_path then
      vim.notify(
        ("[zpr] file %d/%d  %s  hunk %d/%d  comments: %d"):format(
          r.file_index, #r.files, r.file_path, r.hunk_index, #r.hunks, #comments().get_all()),
        vim.log.levels.INFO
      )
    else
      vim.notify("[zpr] no active review", vim.log.levels.WARN)
    end
  end, { desc = "zpr: show current review status" })

  -- Keymaps for zpr buffers.
  -- nowait=true ensures our buffer-local maps beat Neovim's built-in
  -- operators (gc comment toggle, gD etc.) without waiting for a motion.
  local function set_zpr_keymap(buf)
    local opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "]h", function() diff().next_hunk({}) end, vim.tbl_extend("force", opts, { desc = "zpr: next hunk" }))
    vim.keymap.set("n", "[h", function() diff().prev_hunk({}) end, vim.tbl_extend("force", opts, { desc = "zpr: prev hunk" }))
    vim.keymap.set("n", "]f", function() diff().next_file({}) end, vim.tbl_extend("force", opts, { desc = "zpr: next file" }))
    vim.keymap.set("n", "[f", function() diff().prev_file({}) end, vim.tbl_extend("force", opts, { desc = "zpr: prev file" }))
    vim.keymap.set("n", "q",  function() diff().close()       end, vim.tbl_extend("force", opts, { desc = "zpr: close review" }))

    -- Returns true when `line` (1-based, new file) falls inside at least one
    -- hunk range for the current file.  When no hunks are loaded we allow it
    -- so the plugin still works outside a normal review flow.
    local function line_in_diff(line)
      local hunks = diff().review.hunks
      if not hunks or #hunks == 0 then return true end
      for _, h in ipairs(hunks) do
        if h.new_count > 0 and line >= h.new_start and line <= h.new_end then
          return true
        end
      end
      return false
    end

    -- Helper: check we're in the after pane, then add/edit a comment
    local function comment_on_range(line_start, line_end)
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if not buf_name:match("zpr://after$") then
        vim.notify("[zpr] move to the AFTER (right) pane to add a comment", vim.log.levels.WARN)
        return
      end
      local r = diff().review
      if not line_in_diff(line_start) then
        vim.notify(
          ("[zpr] line %d is outside the diff — GitHub review comments must be on lines within a hunk"):format(line_start),
          vim.log.levels.WARN)
        return
      end
      -- line_end is nil for single-line; only set when it differs from start
      local end_line = (line_end and line_end > line_start) and line_end or nil
      if comments().find_at(r.file_path, line_start) then
        comments().edit_at(r.file_path, line_start)
      else
        local hunk = r.hunks and r.hunks[r.hunk_index]
        comments().add(r.file_path, line_start, end_line, r.hunk_index, hunk)
      end
    end

    -- <leader>zc (normal): add/edit comment on current line
    vim.keymap.set("n", "<leader>zc", function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      comment_on_range(line, nil)
    end, vim.tbl_extend("force", opts, { desc = "zpr: add/edit comment" }))

    -- <leader>zc (visual): add comment on selected line range
    vim.keymap.set("v", "<leader>zc", function()
      -- Exit visual mode first so '< and '> marks are set
      local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
      vim.api.nvim_feedkeys(esc, "x", false)
      local line_start = vim.fn.line("'<")
      local line_end   = vim.fn.line("'>")
      comment_on_range(line_start, line_end)
    end, vim.tbl_extend("force", opts, { desc = "zpr: add/edit range comment" }))

    -- <leader>zr: resolve / unresolve an imported GitHub comment thread
    vim.keymap.set("n", "<leader>zr", function()
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if not buf_name:match("zpr://after$") then return end
      local r    = diff().review
      local line = vim.api.nvim_win_get_cursor(0)[1]
      comments().resolve_at(r.file_path, line)
    end, vim.tbl_extend("force", opts, { desc = "zpr: resolve/unresolve GitHub comment thread" }))

    -- <leader>zd: delete inline comment on current line (with confirmation)
    vim.keymap.set("n", "<leader>zd", function()
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if not buf_name:match("zpr://after$") then return end
      local r    = diff().review
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local c    = comments().find_at(r.file_path, line)
      if not c then return end
      vim.ui.input({ prompt = ('Delete comment "%s"? [y/N]: '):format(c.body) }, function(ans)
        if ans and ans:lower() == "y" then
          comments().delete_at(r.right_buf, r.file_path, line)
        end
      end)
    end, vim.tbl_extend("force", opts, { desc = "zpr: delete comment" }))
  end

  -- Wire keymaps and re-render comments after each layout open/reuse.
  -- Triggered by diff.lua via nvim_exec_autocmds("User", {pattern="ZprLayoutReady"}).
  -- Using a User event avoids autocmd pattern-matching issues with zpr:// URIs.
  vim.api.nvim_create_autocmd("User", {
    pattern = "ZprLayoutReady",
    callback = function()
      local r = diff().review
      if r.left_buf  and vim.api.nvim_buf_is_valid(r.left_buf)  then
        set_zpr_keymap(r.left_buf)
      end
      if r.right_buf and vim.api.nvim_buf_is_valid(r.right_buf) then
        set_zpr_keymap(r.right_buf)
        -- Re-render any comments already stored for this file
        if r.file_path then
          comments().render_all(r.file_path)
        end
      end
    end,
  })

  -- Sidebar: full refresh on file change, cursor-only refresh on hunk change
  vim.api.nvim_create_autocmd("User", {
    pattern  = "ZprFileChanged",
    callback = function() require("zpr.sidebar").refresh() end,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern  = "ZprHunkChanged",
    callback = function() require("zpr.sidebar").refresh_cursor() end,
  })

  -- <leader>zt: toggle sidebar (global keymap)
  vim.keymap.set("n", "<leader>zt", function()
    require("zpr.sidebar").toggle()
  end, { silent = true, desc = "zpr: toggle sidebar" })

  vim.api.nvim_create_user_command("ZprSidebar", function()
    require("zpr.sidebar").toggle()
  end, { desc = "zpr: toggle file/hunk sidebar" })

  vim.api.nvim_create_user_command("ZprPullReview", function(opts)
    local pr = vim.trim(opts.args)
    if pr == "" then
      vim.notify("[zpr] usage: :ZprPullReview <pr-number>", vim.log.levels.WARN)
      return
    end
    local script = _plugin_root .. "/bin/zpr-pull-review"
    local extra  = opts.bang and { "--replace" } or {}
    local cmd    = vim.list_extend({ script, pr }, extra)
    vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        local msg = vim.trim(table.concat(data, "\n"))
        if msg ~= "" then vim.notify("[zpr] " .. msg, vim.log.levels.INFO) end
      end,
      on_stderr = function(_, data)
        local msg = vim.trim(table.concat(data, "\n"))
        if msg ~= "" then vim.notify("[zpr] " .. msg, vim.log.levels.WARN) end
      end,
      on_exit = function(_, code)
        if code == 0 then
          -- Script already called reload_comments via zpr-call; also reload
          -- in-process in case this Neovim is the one being reviewed in.
          _G.zpr_state.comments = {}
          comments().load()
          local r = diff().review
          if r.file_path then comments().render_all(r.file_path) end
          require("zpr.sidebar").refresh()
        end
      end,
    })
  end, { nargs = 1, bang = true, desc = "zpr: import GitHub PR review comments (! = replace local)" })

  vim.api.nvim_create_user_command("ZprPushReview", function(opts)
    local pr = vim.trim(opts.args)
    if pr == "" then
      vim.notify("[zpr] usage: :ZprPushReview <pr-number>", vim.log.levels.WARN)
      return
    end
    local script = _plugin_root .. "/bin/zpr-push-review"
    local event  = opts.bang and "REQUEST_CHANGES" or "COMMENT"
    vim.fn.jobstart({ script, pr, "--event", event }, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        local msg = vim.trim(table.concat(data, "\n"))
        if msg ~= "" then vim.notify("[zpr] " .. msg, vim.log.levels.INFO) end
      end,
      on_stderr = function(_, data)
        local msg = vim.trim(table.concat(data, "\n"))
        if msg ~= "" then vim.notify("[zpr] " .. msg, vim.log.levels.WARN) end
      end,
    })
  end, { nargs = 1, bang = true, desc = "zpr: push review comments to GitHub PR (! = REQUEST_CHANGES)" })

  vim.api.nvim_create_user_command("ZprReload", function()
    _G.zpr_state = nil
    for _, mod in ipairs({ "zpr", "zpr.config", "zpr.diff", "zpr.comments",
                           "zpr.server", "zpr.highlights", "zpr.sidebar", "zpr.viewed" }) do
      package.loaded[mod] = nil
    end
    require("zpr").setup()
    vim.notify("[zpr] reloaded", vim.log.levels.INFO)
  end, { desc = "zpr: reload all modules" })

end

return M
