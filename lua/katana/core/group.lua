local M = {}
local config = require("katana.config")
local utils = require("katana.utils")

function M.build(actions)
  local opts = config.options
  local groups_map = {}

  for _, action in ipairs(actions) do
    if opts.hide_disabled and action.disabled then
      goto continue
    end

    local gk = utils.kind_group_key(action.kind)
    if not groups_map[gk] then
      groups_map[gk] = {
        key = gk,
        kind = action.kind,
        label = utils.kind_label(action.kind),
        actions = {},
      }
    end
    table.insert(groups_map[gk].actions, action)

    ::continue::
  end

  local groups = {}
  for _, g in pairs(groups_map) do
    table.insert(groups, g)
  end

  table.sort(groups, function(a, b)
    local order = opts.group_order
    local ia, ib = nil, nil
    for i, k in ipairs(order) do
      if k == a.key then ia = i end
      if k == b.key then ib = i end
    end
    ia = ia or (#order + 1)
    ib = ib or (#order + 1)
    if ia ~= ib then
      return ia < ib
    end
    return a.label < b.label
  end)

  -- El orden global ya viene calculado por `prioritize.filter_and_sort`: dentro
  -- de cada grupo se conserva ese orden (no se reordena aquí).
  return groups
end

function M.flatten(groups)
  local flat = {}
  for _, g in ipairs(groups) do
    table.insert(flat, { type = "header", group = g })
    for _, a in ipairs(g.actions) do
      table.insert(flat, { type = "action", action = a, group_key = g.key })
    end
  end
  return flat
end

return M
