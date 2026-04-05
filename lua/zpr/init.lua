-- zpr/init.lua: main module

local M = {}

-- RPC method registry — Claude calls these via zpr_rpc()
M.handlers = {}

function M.setup()
  require("zpr.highlights").setup()
  require("zpr.server").publish_socket()

  -- Always do a live require("zpr.diff") so handlers survive module reloads.
  local function diff() return require("zpr.diff") end

  -- Register RPC handlers
  M.handlers["open_file"]  = function(p) return diff().open_file(p) end
  M.handlers["next_hunk"]  = function(p) return diff().next_hunk(p) end
  M.handlers["prev_hunk"]  = function(p) return diff().prev_hunk(p) end
  M.handlers["close"]      = function(_) vim.schedule(function() diff().close() end); return {} end
  M.handlers["ping"]       = function(_) return { pong = true } end
  M.handlers["status"]     = function(_)
    local r = diff().review
    return {
      file       = r.file_path,
      hunk       = r.hunk_index,
      hunk_total = #r.hunks,
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
        ("[zpr] %s  hunk %d/%d"):format(r.file_path, r.hunk_index, #r.hunks),
        vim.log.levels.INFO
      )
    else
      vim.notify("[zpr] no active review", vim.log.levels.WARN)
    end
  end, { desc = "zpr: show current review status" })

  -- Keymaps (only when inside a zpr buffer)
  local function set_zpr_keymap(buf)
    local opts = { buffer = buf, silent = true }
    vim.keymap.set("n", "]h", function() diff().next_hunk({}) end, opts)
    vim.keymap.set("n", "[h", function() diff().prev_hunk({}) end, opts)
    vim.keymap.set("n", "q",  function() diff().close()       end, opts)
  end

  -- Wire keymaps when zpr buffers are created
  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = "zpr://*",
    callback = function(ev)
      set_zpr_keymap(ev.buf)
    end,
  })

  vim.notify("[zpr] ready — socket: " .. require("zpr.server").socket_path(), vim.log.levels.INFO)
end

return M
