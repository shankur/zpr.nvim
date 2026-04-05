-- server.lua: registers RPC-callable functions and publishes the socket path
-- Claude communicates with the plugin by calling:
--   nvim --server <socket> --remote-expr 'v:lua.zpr_rpc("<json_payload>")'

local M = {}

local state_dir = vim.fn.expand("~/.local/state/zpr")
local socket_file = state_dir .. "/nvim.sock"

-- Write Neovim's server address to a well-known path so Claude can find it.
function M.publish_socket()
  vim.fn.mkdir(state_dir, "p")
  local addr = vim.v.servername
  if addr == "" then
    -- Neovim wasn't started with --listen; start a server on a fixed socket.
    addr = state_dir .. "/nvim-server.sock"
    vim.fn.serverstart(addr)
  end
  local f = io.open(socket_file, "w")
  if f then
    f:write(addr)
    f:close()
  end
  return addr
end

function M.socket_path()
  return socket_file
end

-- File-based entry point: reads JSON payload from a temp file.
-- Called via --remote-expr 'v:lua.zpr_rpc_file("/tmp/zpr_payload.json")'
-- Avoids all shell quoting issues with special characters in payloads.
_G.zpr_rpc_file = function(path)
  local f = io.open(path, "r")
  if not f then
    return vim.json.encode({ error = "cannot open payload file: " .. path })
  end
  local json_payload = f:read("*a")
  f:close()
  return _G.zpr_rpc(json_payload)
end

-- Global entry point callable via --remote-expr 'v:lua.zpr_rpc("...")'
-- Payload is a JSON string: { "method": "...", "params": { ... } }
_G.zpr_rpc = function(json_payload)
  local ok, payload = pcall(vim.json.decode, json_payload)
  if not ok then
    return vim.json.encode({ error = "invalid json: " .. tostring(payload) })
  end

  local method = payload.method
  local params = payload.params or {}

  local zpr = require("zpr")
  local handler = zpr.handlers[method]
  if not handler then
    return vim.json.encode({ error = "unknown method: " .. tostring(method) })
  end

  local result_ok, result = pcall(handler, params)
  if not result_ok then
    return vim.json.encode({ error = tostring(result) })
  end

  return vim.json.encode({ ok = true, result = result })
end

return M
