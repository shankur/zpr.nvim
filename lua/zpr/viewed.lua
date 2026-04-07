-- viewed.lua: tracks which files have been marked as viewed in the current review.
-- Persisted to disk alongside comments so state survives session restarts.

local M = {}

local cfg = require("zpr.config")

if not _G.zpr_state then _G.zpr_state = {} end
if not _G.zpr_state.viewed_files then _G.zpr_state.viewed_files = {} end

local function viewed() return _G.zpr_state.viewed_files end

local function viewed_path()
  local s = _G.zpr_state
  if not s or not s.repo_path or not s.head_ref then return nil end
  return cfg.viewed_file(s.repo_path, s.head_ref)
end

-- Load viewed set from disk into _G.zpr_state.viewed_files.
-- Called once per review open (when repo/ref changes).
function M.load()
  local path = viewed_path()
  if not path then return end
  local f = io.open(path, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return end
  _G.zpr_state.viewed_files = data
end

local function save()
  local path = viewed_path()
  if not path then return end
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(path, "w")
  if f then f:write(vim.json.encode(viewed())); f:close() end
  require("zpr.sidebar").refresh()
end

function M.is_viewed(file_path)
  return viewed()[file_path] == true
end

function M.toggle(file_path)
  if viewed()[file_path] then
    viewed()[file_path] = nil
  else
    viewed()[file_path] = true
  end
  save()
end

return M
