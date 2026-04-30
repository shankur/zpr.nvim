-- viewed.lua: tracks which files have been marked as viewed in the current review.
-- Also tracks which hunks have been visited (navigated to) during the review.
-- Persisted to disk alongside comments so state survives session restarts.

local M = {}

local cfg = require("zpr.config")

if not _G.zpr_state then _G.zpr_state = {} end
if not _G.zpr_state.viewed_files then _G.zpr_state.viewed_files = {} end
if not _G.zpr_state.visited_hunks then _G.zpr_state.visited_hunks = {} end

local function viewed() return _G.zpr_state.viewed_files end
local function visited() return _G.zpr_state.visited_hunks end

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
  _G.zpr_state.viewed_files = data.files or data
  _G.zpr_state.visited_hunks = data.hunks or {}
end

local function save()
  local path = viewed_path()
  if not path then return end
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local data = { files = viewed(), hunks = visited() }
  local f = io.open(path, "w")
  if f then f:write(vim.json.encode(data)); f:close() end
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

-- Mark a hunk as visited (called automatically on navigation)
function M.mark_visited(file_path, hunk_index)
  if not file_path or not hunk_index then return end
  local key = file_path .. ":" .. tostring(hunk_index)
  if not visited()[key] then
    visited()[key] = true
    save()
  end
end

-- Check if a specific hunk has been visited
function M.is_hunk_visited(file_path, hunk_index)
  local key = file_path .. ":" .. tostring(hunk_index)
  return visited()[key] == true
end

-- Get unvisited hunks across all files
function M.get_unvisited()
  local files = _G.zpr_state.files or {}
  local unvisited = {}
  for _, f in ipairs(files) do
    for hi = 1, #(f.hunks or {}) do
      if not M.is_hunk_visited(f.file_path, hi) then
        table.insert(unvisited, { file_path = f.file_path, hunk_index = hi })
      end
    end
  end
  return unvisited
end

-- Get visit progress: { visited = N, total = M }
function M.progress()
  local files = _G.zpr_state.files or {}
  local total = 0
  local vis = 0
  for _, f in ipairs(files) do
    for hi = 1, #(f.hunks or {}) do
      total = total + 1
      if M.is_hunk_visited(f.file_path, hi) then
        vis = vis + 1
      end
    end
  end
  return { visited = vis, total = total }
end

return M
