---@mod katana.lsp.diff Diff de previsualización
---
--- Calcula el diff de un `WorkspaceEdit` sin crear buffers ni cargar ficheros:
--- si el destino no está abierto se lee del disco (sólo si existe). La
--- previsualización no debe tener efectos secundarios sobre el estado de
--- Neovim.

local workspace_edit = require("katana.lsp.workspace_edit")
local buffer = require("katana.lsp.buffer")
local uri = require("katana.lsp.uri")
local text_edit = require("katana.lsp.text_edit")

local M = {}

--- Genera un diff unificado entre `before` y `after`.
---
--- `vim.diff` no incluye las cabeceras `--- a/fichero` / `+++ b/fichero`, así
--- que se añaden manualmente para que el buffer de previsualización
--- (`filetype=diff`) los coloree como corresponde.
---@param before string[]
---@param after string[]
---@param filename string
---@return string
function M.unified(before, after, filename)
  -- Neovim no incluye el salto final en `nvim_buf_get_lines`, pero el fichero sí
  -- suele acabarlo: se añade para que el diff no muestre
  -- "\ No newline at end of file" de forma engañosa.
  local before_text = table.concat(before, "\n") .. "\n"
  local after_text = table.concat(after, "\n") .. "\n"

  local diff = vim.diff(before_text, after_text, { result_type = "unified", ctxlen = 3 })
  if diff == "" then
    return ""
  end

  return string.format("--- a/%s\n+++ b/%s\n%s", filename, filename, diff)
end

--- Ejecuta una herramienta externa de diff sobre dos ficheros temporales.
---@param before string[]
---@param after string[]
---@param backend '"delta"'|'"difftastic"'
---@return string|nil diff `nil` si la herramienta no está disponible
function M.external(before, after, backend)
  local commands = {
    delta = { "delta", "--paging=never", "--color=never" },
    difftastic = { "difftastic", "--color=never", "--output=short" },
  }

  local base = commands[backend]
  if not base then
    return nil
  end

  local before_file = vim.fn.tempname()
  local after_file = vim.fn.tempname()

  vim.fn.writefile(before, before_file)
  vim.fn.writefile(after, after_file)

  local cmd = vim.list_extend(vim.deepcopy(base), { before_file, after_file })

  local ok, output = pcall(function()
    if vim.system then
      local result = vim.system(cmd, { text = true }):wait()
      if result.code ~= 0 then
        return nil
      end
      return result.stdout
    end
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      return nil
    end
    return out
  end)

  pcall(vim.fn.delete, before_file)
  pcall(vim.fn.delete, after_file)

  if not ok or not output or output == "" then
    return nil
  end

  return output
end

--- Calcula el diff de un `WorkspaceEdit` para la previsualización.
---@param edit vim.lsp.WorkspaceEdit|nil
---@param bufnr integer|nil buffer actual
---@param encoding KatanaEncoding
---@param backend '"vim"'|'"delta"'|'"difftastic"'
---@return string[]
function M.preview_lines(edit, bufnr, encoding, backend)
  backend = backend or "vim"

  local groups = workspace_edit.collect(edit)
  local output = {}

  for _, group in ipairs(groups) do
    local target = buffer.find(group, bufnr)
    local before

    if target then
      before = vim.api.nvim_buf_get_lines(target, 0, -1, false)
    elseif uri.is_readable_file(group.filename) then
      local ok_read, lines = pcall(vim.fn.readfile, group.filename)
      if ok_read and type(lines) == "table" then
        before = lines
      end
    end

    if before then
      local after = text_edit.apply_to_lines(before, group.edits, encoding)

      local text
      if backend == "vim" then
        text = M.unified(before, after, group.filename)
      else
        text = M.external(before, after, backend)
        if not text then
          -- La herramienta externa no está disponible: fallback al diff interno.
          text = M.unified(before, after, group.filename)
        end
      end

      if text and text ~= "" then
        vim.list_extend(output, vim.split(text, "\n", { plain = true }))
      end
    else
      output[#output + 1] = string.format("# (destino no disponible: %s)", group.filename)
    end
  end

  if #output == 0 then
    output = { "(no changes)" }
  end

  return output
end

return M
