---@mod katana.lsp.edit_apply Aplicación y rollback de un plan
---
--- No es una transacción entre ficheros. Si falla un grupo, intenta revertir los
--- grupos ya aplicados y devuelve información verificable sobre lo ocurrido.
--- Los errores detectables antes de escribir ya se rechazaron en
--- `katana.lsp.edit_plan.prepare`.

local buffer = require("katana.lsp.buffer")
local text_edit = require("katana.lsp.text_edit")

local M = {}

---@param lines_a string[]
---@param lines_b string[]
---@return boolean
local function lines_equal(lines_a, lines_b)
  if #lines_a ~= #lines_b then
    return false
  end
  for i = 1, #lines_a do
    if lines_a[i] ~= lines_b[i] then
      return false
    end
  end
  return true
end

--- Intenta revertir un grupo aplicado.
---
--- Sólo se revierte si el buffer sigue exactamente en el `changedtick` que dejó
--- la operación. Si el usuario (o otro plugin) lo modificó, se conserva su
--- cambio y se informa de que no se pudo revertir.
---@param group KatanaPreparedGroup
---@return boolean restored
---@return string method
---@return string|nil error
local function rollback_group(group)
  if not vim.api.nvim_buf_is_valid(group.bufnr) then
    return false, "none", "el buffer ya no es válido"
  end

  local tick = vim.api.nvim_buf_get_changedtick(group.bufnr)
  if group.post_tick == nil or tick ~= group.post_tick then
    return false, "none", "el buffer cambió después de la edición; no se revierte para no pisar cambios concurrentes"
  end

  -- Preferimos `undo` porque revierte también metadatos (marks, undo tree) de
  -- forma coherente. Si no deja el contenido esperado, se usa el snapshot de
  -- líneas como respaldo. La reversión no es transaccional entre ficheros: sólo
  -- se intenta y se verifica buffer a buffer.
  local levels = vim.bo[group.bufnr].undolevels
  if levels ~= -1 then
    local ok_undo = pcall(vim.api.nvim_buf_call, group.bufnr, function()
      vim.cmd("silent undo")
    end)
    local current = vim.api.nvim_buf_get_lines(group.bufnr, 0, -1, false)
    if ok_undo and lines_equal(current, group.lines) then
      return true, "undo", nil
    end
  end

  -- El `undo` pudo cambiar el `changedtick` (es un cambio más). No se usa como
  -- condición: el tick ya se comprobó al entrar, así que cualquier cambio desde
  -- entonces lo ha hecho esta misma reversión.
  local ok_restore = pcall(vim.api.nvim_buf_set_lines, group.bufnr, 0, -1, false, group.lines)
  if not ok_restore then
    return false, "none", "no se pudo restaurar el contenido anterior"
  end

  if lines_equal(vim.api.nvim_buf_get_lines(group.bufnr, 0, -1, false), group.lines) then
    return true, "snapshot", nil
  end

  return false, "none", "no se pudo verificar la restauración"
end

---@class KatanaApplyInfo
---@field applied_buffers string[]
---@field failed_buffer string|nil
---@field rollback '"not_needed"'|'"restored"'|'"failed"'
---@field rollback_details string[]

---@class KatanaApplyHooks
---@field apply_edits fun(bufnr: integer, edits: lsp.TextEdit[], encoding: KatanaEncoding)|nil
---@field close_undo fun(bufnr: integer)|nil

--- Aplica un plan preparado.
---
--- `hooks` permite que la fachada pública inyecte sus propias funciones de
--- aplicación/undo (las pruebas sustituyen `apply_edits_to_buffer` para simular
--- fallos). Sin hooks se usan las implementaciones por defecto.
---@param plan KatanaEditPlan
---@param hooks KatanaApplyHooks|nil
---@return boolean ok
---@return string|nil error
---@return KatanaApplyInfo info
function M.apply(plan, hooks)
  hooks = hooks or {}
  local apply_edits = hooks.apply_edits or text_edit.apply_to_buffer
  local close_undo = hooks.close_undo or buffer.close_undo_block

  local info = {
    applied_buffers = {},
    failed_buffer = nil,
    rollback = "not_needed",
    rollback_details = {},
  }

  if type(plan) ~= "table" or type(plan.groups) ~= "table" or #plan.groups == 0 then
    return false, "plan de edición inválido", info
  end

  if plan.applied then
    return false, "el plan de edición ya se aplicó (se evita duplicarlo)", info
  end

  plan.applied = true

  local applied = {}

  local function fail(message, group)
    info.failed_buffer = group and group.filename or nil
    info.rollback = "failed"

    local rolled_back = 0
    local attempted = 0

    for index = #applied, 1, -1 do
      local entry = applied[index]
      -- `post_tick == nil` significa que la escritura ni siquiera empezó: no
      -- hay nada que revertir en ese buffer.
      if entry.post_tick ~= nil then
        attempted = attempted + 1
        local restored, method, rollback_err = rollback_group(entry)
        if restored then
          rolled_back = rolled_back + 1
          info.rollback_details[#info.rollback_details + 1] = string.format("%s: revertido (%s)", entry.filename, method)
        else
          info.rollback_details[#info.rollback_details + 1] = string.format(
            "%s: NO revertido (%s)",
            entry.filename,
            tostring(rollback_err)
          )
        end
      end
    end

    if attempted == 0 then
      info.rollback = "not_needed"
    elseif rolled_back == attempted then
      info.rollback = "restored"
    else
      info.rollback = "failed"
    end

    return false, message, info
  end

  for _, group in ipairs(plan.groups) do
    -- Revalida lo que puede haber cambiado entre la preparación y la escritura
    -- (autocommands de carga, por ejemplo).
    if not vim.api.nvim_buf_is_valid(group.bufnr) then
      return fail(string.format("el buffer de %s dejó de ser válido", group.filename), group)
    end

    if vim.api.nvim_buf_get_changedtick(group.bufnr) ~= group.changedtick then
      return fail(
        string.format("el buffer de %s cambió durante la preparación; edición cancelada", group.filename),
        group
      )
    end

    if group.version ~= nil then
      local current_version = buffer.version(group.bufnr)
      if current_version ~= nil and current_version ~= group.version then
        return fail(
          string.format(
            "versión incompatible para %s (edición=%d, buffer=%d)",
            group.filename,
            group.version,
            current_version
          ),
          group
        )
      end
    end

    close_undo(group.bufnr)

    -- El grupo entra en la lista de reversión antes de escribir: si
    -- `nvim_buf_set_text` falla a mitad, el buffer puede haber quedado
    -- parcialmente modificado y también hay que intentar restaurarlo.
    applied[#applied + 1] = group

    local ok_apply, apply_err = pcall(
      apply_edits,
      group.bufnr,
      group.edits,
      group.encoding or plan.encoding or "utf-16"
    )
    if not ok_apply then
      local tick_after_failure = vim.api.nvim_buf_get_changedtick(group.bufnr)
      if tick_after_failure ~= group.changedtick then
        group.post_tick = tick_after_failure
      end
      return fail(string.format("error al aplicar cambios en %s: %s", group.filename, tostring(apply_err)), group)
    end

    group.post_tick = vim.api.nvim_buf_get_changedtick(group.bufnr)
    info.applied_buffers[#info.applied_buffers + 1] = group.filename
  end

  -- Cierra el bloque de undo para que un único `u` revierta la acción completa.
  for _, group in ipairs(applied) do
    close_undo(group.bufnr)
  end

  return true, nil, info
end

return M
