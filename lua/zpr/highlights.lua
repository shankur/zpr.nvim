local M = {}

function M.setup()
  -- Added lines (green)
  vim.api.nvim_set_hl(0, "ZprDiffAdd", { fg = "#b8db87", bg = "#1e2718", bold = false })
  -- Removed lines (red)
  vim.api.nvim_set_hl(0, "ZprDiffDelete", { fg = "#e06c75", bg = "#2d1b1e", bold = false })
  -- Changed words within a line (stronger highlight)
  vim.api.nvim_set_hl(0, "ZprDiffAddInline", { fg = "#d4f0a0", bg = "#3a4d20", bold = true })
  vim.api.nvim_set_hl(0, "ZprDiffDeleteInline", { fg = "#f0a0a0", bg = "#4d2020", bold = true })
  -- Hunk header
  vim.api.nvim_set_hl(0, "ZprHunkHeader", { fg = "#61afef", bg = "#1e2030", italic = true })
  -- File header
  vim.api.nvim_set_hl(0, "ZprFileHeader", { fg = "#c678dd", bg = "#1e1e2e", bold = true })
  -- Status line info
  vim.api.nvim_set_hl(0, "ZprStatus", { fg = "#98c379", bold = true })
  -- Inline review comments
  vim.api.nvim_set_hl(0, "ZprComment",     { fg = "#e5c07b", italic = true })
  vim.api.nvim_set_hl(0, "ZprCommentBar",  { fg = "#61afef", bold = true })
  -- Commented source lines: subtle amber tint + sign column glyph
  vim.api.nvim_set_hl(0, "ZprCommentLine", { bg = "#2d2a1e" })
end

return M
