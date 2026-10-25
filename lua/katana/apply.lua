---@mod katana.apply Ejecución de acciones
---
--- Fachada pública del executor. La implementación está separada por
--- responsabilidades:
---
---   * `katana.apply.edit`          valida y aplica `WorkspaceEdit`.
---   * `katana.apply.command`       selecciona el cliente y ejecuta comandos.
---   * `katana.apply.run`           invoca `execute_fn`.
---   * `katana.apply.notifications` centraliza los mensajes de resultado.
---   * `katana.apply.execute`       orquesta resolución y efectos.
---
--- Se mantiene esta fachada para conservar la API que usan la UI, `katana.init`,
--- los tests y los usuarios que requieran `katana.apply` directamente.

---@alias KatanaResultStatus '"success"'|'"failed"'|'"partial"'|'"cancelled"'|'"timed_out"'

---@class KatanaResultEffects
---@field edit boolean
---@field command boolean
---@field execute_fn boolean
---@field buffers string[]

---@class KatanaResult
---@field status KatanaResultStatus
---@field action KatanaAction|nil
---@field title string|nil
---@field message string|nil
---@field error any
---@field stage string|nil
---@field reason string|nil
---@field rollback '"not_needed"'|'"restored"'|'"failed"'
---@field effects KatanaResultEffects
---@field duration_ms number
---@field notification_error string|nil
---@field callback_error string|nil

---@class KatanaExecution
---@field action KatanaAction
---@field result KatanaResult|nil
---@field finished boolean
---@field cancel fun(reason: string|nil)
---@field timer any

---@class KatanaExecutorOptions
---@field bufnr integer
---@field win integer
---@field timeout integer|nil Milisegundos de espera para la resolución (por defecto 5000)
---@field notify boolean|nil `false` desactiva la notificación centralizada
---@field on_result fun(result: KatanaResult)|nil
---@field client_id integer|nil Cliente LSP explícito para `workspace/executeCommand`

local command = require("katana.apply.command")
local edit = require("katana.apply.edit")
local execute = require("katana.apply.execute")
local notifications = require("katana.apply.notifications")
local run = require("katana.apply.run")

local M = {}

M.notify_result = notifications.notify_result
M.validate_edit = edit.validate
M.apply_edit = edit.apply
M.run_command = command.run
M.run_execute_fn = run.execute_fn
M.execute = execute.execute
M.run_current = execute.run_current

return M
