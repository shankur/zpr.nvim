_G.zpr_state = nil
for _, m in ipairs({ "zpr", "zpr.config", "zpr.diff", "zpr.comments", "zpr.server", "zpr.highlights" }) do
  package.loaded[m] = nil
end
require("zpr").setup()
