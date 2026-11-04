-- Діалог «Можливі першопричини»: дерево дефіцитних ресурсів від відкритого ресурсу вглиб ланцюжка
-- (алгоритм — flow.root_causes). На кінцях гілок — пояснення, чому ланцюжок тут закінчився.
local M = {}

-- Залежності з control.lua: find(player) → {root, surface, precision} або nil, format_balance(value)
local ctx

function M.init(context)
  ctx = context
end

local INDENT = 22 -- px на рівень дерева
local COLOR_NEGATIVE = {1, 0.45, 0.4}
local VERDICT_COLOR = {capacity = {1, 0.85, 0.3}, idle = {1, 0.85, 0.3}, none = {1, 0.85, 0.3},
                       seen = {0.7, 0.7, 0.7}, limit = {0.7, 0.7, 0.7}, buffer = {0.6, 0.8, 1}}

local function dialog(player)
  return player.gui.screen.resbal_rootcause
end

local function close_dialog(player)
  local frame = dialog(player)
  if frame then frame.destroy() end
end

local function prototype_of(type, name)
  return (type == "fluid" and prototypes.fluid or prototypes.item)[name]
end

local function verdict_caption(node)
  if node.verdict == "capacity" or node.verdict == "idle" then
    return {"resbal.root-" .. node.verdict, node.working, node.total}
  end
  return {"resbal.root-" .. node.verdict}
end

-- Рядки дерева; повертає кількість кінців із «справжньою» причиною (capacity / idle / none)
local function add_rows(list, node, depth, surface)
  local row = list.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.left_padding = (depth - 1) * INDENT
  row.style.horizontal_spacing = 8
  local proto = prototype_of(node.type, node.name)
  local prefix = depth > 1 and "└ " or ""
  local button = row.add{type = "button", style = "resbal_status_button",
                         caption = {"", prefix, "[" .. node.type .. "=" .. node.name .. "] ",
                                    proto and proto.localised_name or node.name, "  ",
                                    {"resbal.root-balance", ctx.format_balance(node.balance)}},
                         tooltip = {"resbal.root-node-tooltip"},
                         tags = {resbal_chart = {type = node.type, name = node.name, surface = surface}}}
  button.style.font_color = COLOR_NEGATIVE
  button.style.hovered_font_color = COLOR_NEGATIVE
  local found = 0
  if node.verdict then
    local label = row.add{type = "label", caption = verdict_caption(node)}
    label.style.font_color = VERDICT_COLOR[node.verdict] or {0.7, 0.7, 0.7}
    label.style.single_line = false
    label.style.maximal_width = 420
    if node.verdict == "capacity" or node.verdict == "idle" or node.verdict == "none" then found = 1 end
  end
  for _, child in ipairs(node.children) do found = found + add_rows(list, child, depth + 1, surface) end
  return found
end

local function open_dialog(player)
  local result = ctx.find(player)
  if not result then return end
  close_dialog(player)
  local frame = player.gui.screen.add{type = "frame", name = "resbal_rootcause", direction = "vertical"}
  frame.auto_center = true
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", style = "frame_title", caption = {"resbal.root-title"}, ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_root_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical", style = "inside_shallow_frame_with_padding"}
  local summary = inner.add{type = "label", caption = ""}
  summary.style.font = "default-bold"
  local hint = inner.add{type = "label", caption = {"resbal.root-hint", {"resbal.p-" .. result.precision}}}
  hint.style.single_line = false
  hint.style.maximal_width = 640
  hint.style.font_color = {0.7, 0.7, 0.7}
  local scroll = inner.add{type = "scroll-pane", name = "scroll"}
  scroll.style.maximal_height = 460
  scroll.style.top_margin = 8
  local list = scroll.add{type = "flow", direction = "vertical"}
  list.style.vertical_spacing = 2
  local found = add_rows(list, result.root, 1, result.surface)
  summary.caption = found > 0 and {"resbal.root-summary", found} or {"resbal.root-summary-none"}
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_root_open" then
    open_dialog(player)
  elseif name == "resbal_root_close" then
    close_dialog(player)
  else
    return false
  end
  return true
end

return M
