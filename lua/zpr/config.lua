-- config.lua: resolves ZPR_CONFIG_DIR and provides path helpers

local M = {}

function M.config_dir()
  return os.getenv("ZPR_CONFIG_DIR") or vim.fn.expand("~/.zpr")
end

-- Per-repo directory: ~/.zpr/reviews/<repo-slug>/
function M.reviews_dir(repo_path)
  local slug = vim.fn.fnamemodify(repo_path, ":t")
  return M.config_dir() .. "/reviews/" .. slug
end

-- Comments file for a specific review: comments_<key>.json
-- key is sanitised so slashes, tildes, colons become dashes.
function M.comments_file(repo_path, head_ref)
  local key = tostring(head_ref):gsub("[/~:^%s]", "-")
  return M.reviews_dir(repo_path) .. "/comments_" .. key .. ".json"
end

function M.viewed_file(repo_path, head_ref)
  local key = tostring(head_ref):gsub("[/~:^%s]", "-")
  return M.reviews_dir(repo_path) .. "/viewed_" .. key .. ".json"
end

function M.socket_file()
  return M.config_dir() .. "/nvim.sock"
end

function M.rpc_payload_file()
  return M.config_dir() .. "/rpc_payload.json"
end

return M
