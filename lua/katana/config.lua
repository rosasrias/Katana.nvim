local M = {}

---@class KatanaOptions
---@field preview boolean Muestra el panel de previsualización del diff
---@field preview_split '"vertical"'|'"horizontal"' Orientación del preview
---@field preview_max_height integer Alto máximo del preview (filas); el resto se scrollea
---@field width number Fracción del ancho del editor ocupada por el picker
---@field height number Fracción del alto del editor ocupada por el picker
---@field border string Estilo del borde de las ventanas flotantes
---@field prompt string Prompt del filtro en vivo (el prefijo no cuenta como filtro)
---@field show_server_name boolean Muestra el origen de la acción
---@field show_preferred boolean Marca las acciones `isPreferred`
---@field num_shortcuts boolean Muestra los atajos numéricos
---@field auto_preview boolean Actualiza el preview al mover la selección
---@field group_by_kind boolean Agrupa las acciones por kind
---@field group_order string[] Orden de los grupos
---@field kinds_priority string[] Orden de prioridad de los kinds (índice 0 = mayor)
---@field dedupe boolean Elimina acciones duplicadas (mismo título y kind)
---@field hide_disabled boolean Oculta las acciones deshabilitadas
---@field ts { enabled: boolean } Proveedor de Tree-sitter
---@field diff_backend '"vim"'|'"delta"'|'"difftastic"' Motor de diff del preview
---@field keymap string Atajo para abrir el picker
---@field lsp_weights table<string, integer> Peso por cliente LSP
---@field kind_weights table<string, integer> Peso por kind
---@field icons table<string, string> Iconos por kind
---@field resolve_on_open boolean Resuelve las acciones al abrir
---@field resolve_limit integer Máximo de acciones resueltas al abrir
---@field code_action_range '"auto"'|'"cursor"'|'"line"' Rango pedido al servidor
---@field pull_diagnostics boolean Pide los diagnósticos al servidor si el buffer no los tiene
---@field pull_timeout integer Milisegundos de espera de la petición de diagnósticos
---@field selection_color string|nil Fondo de la fila seleccionada (`nil` = derivarlo del tema)
---@field selection_accent string|nil Barra izquierda de la fila seleccionada (`nil` = derivarla del tema)

M.defaults = {
  preview = true,
  -- "horizontal" deja el preview **debajo** de la lista de acciones (por
  -- defecto); "vertical" lo pone a la derecha.
  preview_split = "horizontal",
  -- Alto máximo del preview en filas. Si el diff es más largo, la ventana no
  -- crece: el contenido se desplaza dentro de ella (rueda del ratón,
  -- `<C-f>`/`<C-b>` en el prompt o `<C-d>`/`<C-u>` en la lista).
  preview_max_height = 12,
  width = 0.85,
  height = 0.85,
  prompt = " > ",
  show_server_name = true,
  show_preferred = true,
  num_shortcuts = true,
  auto_preview = true,
  group_by_kind = true,
  group_order = {
    "quickfix",
    "refactor.extract",
    "refactor.inline",
    "refactor.rewrite",
    "refactor.convert",
    "refactor",
    "source.organizeImports",
    "source.fixAll",
    "source",
    "command",
    "other",
  },
  lsp_weights = {
    ["ts_ls"] = 20,
    ["vtsls"] = 20,
    ["typescript-tools"] = 20,
    ["eslint"] = 19,
    ["biome"] = 19,
    ["oxlint"] = 19,
    ["rust_analyzer"] = 18,
    ["gopls"] = 17,
    ["pyright"] = 16,
    ["basedpyright"] = 16,
    ["ruff"] = 16,
    ["roslyn_ls"] = 16,
    ["lua_ls"] = 15,
    ["clangd"] = 15,
    ["zls"] = 15,
    ["volar"] = 14,
    ["tailwindcss"] = 12,
    ["jsonls"] = 12,
    ["yamlls"] = 12,
  },
  kind_weights = {
    ["quickfix"] = 25,
    ["refactor.extract"] = 20,
    ["refactor.inline"] = 19,
    ["refactor.rewrite"] = 18,
    ["refactor.convert"] = 17,
    ["source.organizeImports"] = 16,
    ["source.fixAll"] = 15,
    ["source"] = 14,
    ["refactor"] = 13,
    ["command"] = 10,
  },
  -- Un icono distinto por kind: así se distinguen de un vistazo, y cada uno lleva
  -- además su propio color (ver `katana.ui.highlights`).
  --
  -- Se escriben como escapes `\u{...}` para que el fichero no dependa de la
  -- codificación: la LLM/editor no puede corromper el glifo.
  icons = {
    quickfix = "\u{f0ad6}",                  -- llave inglesa
    refactor = "\u{f0455}",                  -- martillo
    ["refactor.extract"] = "\u{f06f9}",      -- sacar de un contenedor
    ["refactor.inline"] = "\u{f0622}",       -- meter en un contenedor
    ["refactor.rewrite"] = "\u{f0219}",      -- reciclar
    ["refactor.convert"] = "\u{f0277}",      -- convertir
    source = "\u{f0493}",                    -- engranaje
    ["source.organizeImports"] = "\u{f02fa}",-- ordenar
    ["source.fixAll"] = "\u{f04a9}",         -- escoba
    command = "\u{f0633}",                   -- consola
    other = "\u{f0eb}",                      -- bombilla
    preferred = "★",
  },
  border = "rounded",
  hide_disabled = false,

  -- Prioridad de los kinds (índice 0 = máxima). Los kinds no listados quedan al
  -- final. Los kinds con sufijo heredan el rango de su padre
  -- ("refactor.extract.function" -> "refactor.extract").
  kinds_priority = {
    "quickfix",
    "refactor.extract",
    "refactor.inline",
    "refactor.rewrite",
    "refactor.convert",
    "source.organizeImports",
    "source.fixAll",
    "source",
    "refactor",
    "command",
    "other",
  },
  dedupe = true,

  -- Proveedor basado en Tree-sitter.
  ts = {
    enabled = true,
  },

  -- Motor de diff de la previsualización: "vim" (interno), "delta" o "difftastic".
  diff_backend = "vim",

  -- Atajo para abrir el picker (no se pisa si el usuario ya tiene uno).
  keymap = "<leader>ca",

  resolve_on_open = true,
  resolve_limit = 20,

  -- Rango que se pide al servidor en `textDocument/codeAction`:
  --   "auto"  -> rango real de los diagnósticos de la línea del cursor, el
  --              identificador bajo el cursor y la línea completa (se piden
  --              todos y se fusionan las respuestas).
  --   "cursor" -> sólo el cursor (comportamiento antiguo, más restrictivo).
  --   "line"  -> la línea completa.
  code_action_range = "auto",

  -- Pide los diagnósticos al servidor (*pull diagnostics*) cuando el buffer no
  -- tiene ninguno. Es lo que hace que Roslyn ofrezca "Generar método X" desde
  -- el momento en que se abre el picker, sin esperar a que el proyecto termine
  -- de cargar.
  pull_diagnostics = true,

  -- Milisegundos de espera para la petición de diagnósticos.
  pull_timeout = 2000,
  -- Milisegundos de espera para cada petición de codeAction.
  lsp_request_timeout = 3000,

  -- Aspecto de la fila seleccionada. Por defecto se derivan del tema; si el tema
  -- no tiene un color de selección suficientemente distinto (es el caso de
  -- muchos temas de NvChad, donde `one_bg3` y `one_bg2` son casi iguales), se
  -- puede fijar aquí uno propio.
  selection_color = nil,
  selection_accent = nil,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
