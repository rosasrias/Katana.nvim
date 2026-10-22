---@mod katana.plugin Comando y atajos de Katana
---
--- Se crea como módulo (y no sólo como `plugin/katana.lua`) para poder invocarlo
--- desde `katana.setup()`: así el atajo se respeta aunque el usuario tenga ya el
--- suyo definido.

local M = {}

local commands_ready = false

--- Crea los comandos de usuario (`:CodeActions`, `:KatanaSource`).
function M.ensure_commands()
  if commands_ready then
    return
  end
  commands_ready = true

  pcall(vim.api.nvim_create_user_command, "CodeActions", function(opts)
    local scope = opts.args and opts.args:lower() or ""

    if scope == "" then
      require("katana").code_action()
      return
    end

    require("katana").open({ scope = scope })
  end, {
    desc = "Katana: show code actions",
    nargs = "?",
    complete = function()
      return { "cursor", "line", "visual" }
    end,
  })

  pcall(vim.api.nvim_create_user_command, "KatanaSource", function()
    require("katana").source_action()
  end, {
    desc = "Katana: show source actions",
  })

  pcall(vim.api.nvim_create_user_command, "KatanaDebug", function()
    require("katana.core.debug").report()
  end, {
    desc = "Katana: diagnose the code action request",
  })
end

---@return string|nil
local function configured_keymap()
  local ok, config = pcall(require, "katana.config")
  if not ok then
    return nil
  end

  local value = config.options and config.options.keymap
  if type(value) ~= "string" or value == "" then
    return nil
  end

  return value
end

--- Define el atajo de apertura (si el usuario no tiene ya uno).
function M.ensure_keymap()
  local lhs = configured_keymap()
  if not lhs then
    return
  end

  -- No se pisa un mapeo previo del usuario (`maparg` expande `<leader>`).
  if vim.fn.maparg(lhs, "n") ~= "" then
    return
  end

  local function open()
    require("katana").code_action()
  end

  vim.keymap.set("n", lhs, open, { desc = "Katana: code actions" })
  vim.keymap.set("v", lhs, open, { desc = "Katana: code actions" })
end

--- Crea los comandos y el atajo.
function M.ensure()
  M.ensure_commands()
  M.ensure_keymap()
end

return M
