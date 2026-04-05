-- zpr: zero-friction PR review
-- Plugin entry point — auto-loaded by Neovim

if vim.g.loaded_zpr then
  return
end
vim.g.loaded_zpr = true

require("zpr").setup()
