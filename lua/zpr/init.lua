-- zpr/init.lua: main module

local M = {}

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
  M.handlers["clear_comments"] = function(_) comments().clear(); return {} end
  M.handlers["add_comment"]    = function(p)
    local ok = comments().add_direct(
      p.file_path, p.line, p.line_end, p.hunk_index or 1, p.body)
    return { ok = ok }
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

    -- Helper: check we're in the after pane, then add/edit a comment
    local function comment_on_range(line_start, line_end)
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if not buf_name:match("zpr://after$") then
        vim.notify("[zpr] move to the AFTER (right) pane to add a comment", vim.log.levels.WARN)
        return
      end
      local r = diff().review
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

  vim.api.nvim_create_user_command("ZprReload", function()
    _G.zpr_state = nil
    for _, mod in ipairs({ "zpr", "zpr.config", "zpr.diff", "zpr.comments",
                           "zpr.server", "zpr.highlights", "zpr.sidebar" }) do
      package.loaded[mod] = nil
    end
    require("zpr").setup()
    vim.notify("[zpr] reloaded", vim.log.levels.INFO)
  end, { desc = "zpr: reload all modules" })

  vim.notify("[zpr] ready — socket: " .. require("zpr.server").socket_path(), vim.log.levels.INFO)
end

return M
