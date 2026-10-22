if vim.g.loaded_katana then
  return
end

vim.g.loaded_katana = true

require("katana.plugin").ensure_commands()
