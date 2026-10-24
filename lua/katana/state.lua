---@mod katana.state Estado global del picker
---
--- Holds the buffers, windows and data of the currently open picker. `reset()`
--- closes everything and creates fresh namespaces.

local M = {}

---@type integer
M.ns_main = nil
---@type integer
M.ns_sel = nil
---@type integer
M.ns_preview = nil

---@type integer|nil
M.buf_main = nil
---@type integer|nil
M.win_main = nil

---@type integer|nil
M.buf_preview = nil
---@type integer|nil
M.win_preview = nil

--- Todas las acciones recogidas (normalizadas y ordenadas).
---@type KatanaAction[]
M.actions = {}
--- Acciones que se muestran en la lista (todas; el picker ya no filtra).
---@type KatanaAction[]
M.filtered = {}
---@type table[]
M.groups = {}
--- Filas visibles (cabeceras + acciones) de la lista actual.
---@type table[]
M.flat = {}

---@type integer
M.index = 1

--- Ancho de la lista (columnas de contenido).
---@type integer
M.list_width = 40
--- Número máximo de filas visibles en la lista.
---@type integer
M.max_rows = 20

---@type fun(action: KatanaAction)|nil
M.on_select = nil
---@type integer|nil
M.origin_buf = nil
---@type integer|nil
M.origin_win = nil
---@type boolean
M.open = false

---@type integer|nil
M.au_close = nil

--- Valor de `guicursor` antes de abrir el picker (se restaura al cerrar).
---@type string|nil
M.guicursor_prev = nil

--- Último estado conocido del picker, para `:KatanaDebug`.
---
--- Sobrevive a `reset()`: cuando algo va mal en la fase del picker conviene saber
--- qué recibió y qué llegó a pintarse, aunque el picker ya se haya cerrado.
---@type table
M.last = {}

--- Guarda una foto del estado del picker (para `:KatanaDebug`).
---@param phase string
function M.snapshot(phase)
  M.last = {
    phase = phase,
    at = vim.uv.now(),
    open = M.open,
    actions = #M.actions,
    filtered = #M.filtered,
    flat = #M.flat,
    index = M.index,
    error = M.last and M.last.error or nil,
  }
end

--- Cierra todo lo que haya abierto y prepara las namespaces.
function M.reset()
  if M.au_close then
    pcall(vim.api.nvim_del_autocmd, M.au_close)
    M.au_close = nil
  end

  for _, w in ipairs({ M.win_main, M.win_preview }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end

  for _, b in ipairs({ M.buf_main, M.buf_preview }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end

  M.ns_main = vim.api.nvim_create_namespace("KatanaMain")
  M.ns_sel = vim.api.nvim_create_namespace("KatanaSelection")
  M.ns_preview = vim.api.nvim_create_namespace("KatanaPreview")

  M.buf_main = nil
  M.win_main = nil
  M.buf_preview = nil
  M.win_preview = nil

  M.actions = {}
  M.filtered = {}
  M.groups = {}
  M.flat = {}
  M.index = 1
  M.on_select = nil
  M.open = false
  M.guicursor_prev = nil
end

return M
