-- Вкладка «Першопричини» вікна ресурсу (редизайн 1.7: замість окремого діалогу): дерево дефіцитних ресурсів
-- від відкритого ресурсу вглиб ланцюжка (алгоритм — flow.root_causes). На кінцях гілок — пояснення,
-- чому ланцюжок тут закінчився. Дані — зі сканування машин (спільне з «Виробниками й споживачами»).
local M = {}

-- Залежності з control.lua: find(player) → {root, surface, precision} або nil, format_balance(value),
-- big_inner(player) — вміст відкритої вкладки, ensure_tracker(player) — запустити сканування для ресурсу
local ctx

function M.init(context)
  ctx = context
end

local INDENT = 22 -- px на рівень дерева
local EPSILON = 0.05
local COLOR_NEGATIVE = {1, 0.45, 0.4}
-- Колір несе значок (як у станах машин), текст — звичайний; «вже розглянуто» / «обмеження» — сірі службові
local VERDICT_ICON = {capacity = "utility/warning_icon", idle = "utility/status_inactive",
                      none = "utility/status_inactive", buffer = "utility/status_blue"}

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
    local icon = VERDICT_ICON[node.verdict]
    local label = row.add{type = "label", style = icon and "resbal_cause_label" or "resbal_quiet_label",
                          caption = icon and {"", "[img=" .. icon .. "] ", verdict_caption(node)} or verdict_caption(node)}
    label.style.single_line = false
    label.style.maximal_width = 420
    if node.verdict == "capacity" or node.verdict == "idle" or node.verdict == "none" then found = 1 end
  end
  for _, child in ipairs(node.children) do found = found + add_rows(list, child, depth + 1, surface) end
  return found
end

-- Заповнити (або оновити) дерево у вкладці; до кінця сканування — напис про сканування
function M.fill(player)
  local inner = ctx.big_inner(player)
  local head = inner and inner.resbal_root_head
  if not head then return end
  local list = inner.resbal_root_scroll.resbal_root_list
  list.clear()
  local result = ctx.find(player)
  if not result then
    head.resbal_root_summary.caption = {"resbal.root-scanning"}
    return
  end
  head.resbal_root_tip.tooltip = {"resbal.root-hint", {"resbal.p-" .. result.precision}}
  if result.root.balance >= -EPSILON then
    head.resbal_root_summary.caption = {"resbal.root-no-deficit"}
    return
  end
  local found = add_rows(list, result.root, 1, result.surface)
  head.resbal_root_summary.caption = found > 0 and {"resbal.root-summary", found} or {"resbal.root-summary-none"}
end

function M.build_tab(inner, player)
  ctx.ensure_tracker(player)
  local head = inner.add{type = "flow", name = "resbal_root_head", direction = "horizontal"}
  head.style.vertical_align = "center"
  head.style.horizontal_spacing = 8
  head.add{type = "label", name = "resbal_root_summary", caption = "", style = "bold_label"}
  head.add{type = "empty-widget"}.style.horizontally_stretchable = true
  local tip = head.add{type = "sprite", name = "resbal_root_tip", sprite = "utility/tip_icon"}
  tip.style.size = 16
  tip.style.stretch_image_to_widget_size = true
  head.add{type = "button", name = "resbal_root_refresh", caption = {"resbal.root-refresh"},
           tooltip = {"resbal.root-refresh-tooltip"}}
  local scroll = inner.add{type = "scroll-pane", name = "resbal_root_scroll"}
  scroll.style.maximal_height = 560
  scroll.style.minimal_width = 760
  scroll.style.top_margin = 8
  local list = scroll.add{type = "flow", name = "resbal_root_list", direction = "vertical"}
  list.style.vertical_spacing = 2
  M.fill(player)
end

function M.on_click(player, element)
  if element.name ~= "resbal_root_refresh" then return false end
  M.fill(player)
  return true
end

return M
