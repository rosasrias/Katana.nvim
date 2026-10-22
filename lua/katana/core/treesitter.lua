---@mod katana.core.treesitter Proveedor de acciones basado en Tree-sitter
---
--- Genera acciones a partir del nodo de Tree-sitter bajo el cursor. Las acciones
--- son deliberadamente conservadoras (no tocan la estructura del documento más
--- de lo estrictamente necesario) y todas se pueden replicar mediante
--- `katana.register_action()`, que es la vía recomendada para acciones propias.

local M = {}

---@class KatanaTSAction
---@field title string
---@field kind string
---@field source string
---@field raw table
---@field execute_fn fun()

--- Obtiene el nodo de Tree-sitter bajo una posición.
---
--- `vim.treesitter.get_node` existe desde 0.12; en 0.10/0.11 el equivalente era
--- `vim.treesitter.get_node_at_pos`.
---@param bufnr integer
---@param row integer fila (0-based)
---@param col integer columna en bytes
---@return TSNode|nil
function M.get_node(bufnr, row, col)
  if vim.treesitter.get_node then
    local ok, node = pcall(vim.treesitter.get_node, { pos = { row, col }, bufnr = bufnr })
    if ok then
      return node
    end
    return nil
  end

  if vim.treesitter.get_node_at_pos then
    local ok, node = pcall(vim.treesitter.get_node_at_pos, bufnr, row, col)
    if ok then
      return node
    end
  end

  return nil
end

--- Devuelve el prefijo de comentario del buffer (`--`, `//`, `#`, ...).
---@param bufnr integer
---@return string|nil
local function comment_prefix(bufnr)
  local ok, commentstring = pcall(function()
    return vim.bo[bufnr].commentstring
  end)

  if not ok or type(commentstring) ~= "string" or commentstring == "" then
    return nil
  end

  -- `commentstring` tiene la forma "--%s"; el prefijo es la parte previa al `%s`.
  local prefix = commentstring:match("^(.-)%%s")
  if not prefix or prefix == "" then
    return nil
  end

  return prefix
end

--- Devuelve las acciones disponibles para el nodo bajo el cursor.
---@param ctx KatanaContext
---@return KatanaTSAction[]
function M.get_actions(ctx)
  local bufnr = ctx.bufnr
  local node = M.get_node(bufnr, ctx.cursor.row, ctx.cursor.col)

  if not node then
    return {}
  end

  local start_row, start_col, end_row, end_col = node:range()
  local text = table.concat(vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {}), "\n")

  local actions = {}

  -- Copiar el texto del nodo.
  table.insert(actions, {
    title = "Copy node text",
    kind = "source",
    source = "ts",
    raw = { node = node, range = { start_row, start_col, end_row, end_col } },
    execute_fn = function()
      vim.fn.setreg('"', text)
      vim.notify("Katana: node text copied", vim.log.levels.INFO)
    end,
  })

  -- Seleccionar visualmente el nodo.
  table.insert(actions, {
    title = "Select node",
    kind = "source",
    source = "ts",
    raw = { node = node, range = { start_row, start_col, end_row, end_col } },
    execute_fn = function()
      if not vim.api.nvim_win_is_valid(ctx.win) then
        return
      end
      vim.api.nvim_win_set_cursor(ctx.win, { start_row + 1, start_col })
      vim.cmd("normal! v")
      vim.api.nvim_win_set_cursor(ctx.win, { end_row + 1, end_col })
    end,
  })

  -- Comentar el nodo.
  local prefix = comment_prefix(bufnr)
  if prefix then
    table.insert(actions, {
      title = "Comment node",
      kind = "source",
      source = "ts",
      raw = { node = node, range = { start_row, start_col, end_row, end_col } },
      execute_fn = function()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        -- Se recorre de abajo arriba para no invalidar las posiciones.
        for row = end_row, start_row, -1 do
          local line = lines[row + 1]
          if line then
            local indent = line:match("^%s*") or ""
            local rest = line:sub(#indent + 1)
            if rest:sub(1, #prefix) ~= prefix then
              vim.api.nvim_buf_set_text(bufnr, row, #indent, row, #indent, { prefix })
            end
          end
        end
      end,
    })
  end

  return actions
end

return M
