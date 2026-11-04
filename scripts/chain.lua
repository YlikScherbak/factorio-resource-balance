-- «Створити список з інгредієнтів»: з вкладки «Виробники й споживачі» — попередній перегляд ресурсу та
-- безпосередніх інгредієнтів його рецептів-виробників із прапорцями, далі нова вкладка списку.
local M = {}

-- Залежності з control.lua: player_data, lists (модуль списків), candidates(player) → {items, recipes,
-- from_scan, surface} або nil, open_panel(player)
local ctx

function M.init(context)
  ctx = context
end

local function dialog(player)
  return player.gui.screen.resbal_chain_dialog
end

local function close_dialog(player)
  local frame = dialog(player)
  if frame then frame.destroy() end
end

local function prototype_of(type, name)
  return (type == "fluid" and prototypes.fluid or prototypes.item)[name]
end

local function open_dialog(player)
  local found = ctx.candidates(player)
  if not found or #found.items == 0 then return end
  close_dialog(player)
  local data = ctx.player_data(player)
  local first = found.items[1]

  local frame = player.gui.screen.add{type = "frame", name = "resbal_chain_dialog", direction = "vertical",
                                      tags = {surface = found.surface}}
  frame.auto_center = true
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", style = "frame_title", caption = {"resbal.chain-title"}, ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_chain_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical", style = "inside_shallow_frame_with_padding"}
  local row = inner.add{type = "flow", name = "row", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 12
  row.add{type = "label", caption = {"resbal.list-name"}}
  -- назва за замовчуванням — іконка ресурсу (локалізовану назву в текстове поле не вписати); можна дописати
  local field = row.add{type = "textfield", name = "resbal_chain_name", icon_selector = true,
                        text = "[" .. first.type .. "=" .. first.name .. "]"}
  field.style.width = 260

  local info = inner.add{type = "label", caption = found.from_scan and {"resbal.chain-from-scan", found.recipes}
                                                    or {"resbal.chain-all-recipes", found.recipes}}
  info.style.single_line = false
  info.style.maximal_width = 420
  info.style.font_color = found.from_scan and {0.7, 0.7, 0.7} or {1, 0.85, 0.3}
  info.style.top_margin = 6

  local scroll = inner.add{type = "scroll-pane", name = "scroll"}
  scroll.style.maximal_height = 360
  scroll.style.top_margin = 6
  local items = scroll.add{type = "flow", name = "resbal_chain_items", direction = "vertical"}
  items.style.vertical_spacing = 2
  for i, item in ipairs(found.items) do
    local proto = prototype_of(item.type, item.name)
    local recipe = item.recipe and prototypes.recipe[item.recipe]
    items.add{type = "checkbox", state = true,
              caption = {"", "[" .. item.type .. "=" .. item.name .. "] ", proto and proto.localised_name or item.name},
              tooltip = i == 1 and {"resbal.chain-target"}
                        or {"resbal.chain-from-recipe", recipe and recipe.localised_name or item.recipe or "?"},
              tags = {type = item.type, name = item.name}}
  end

  local full = not ctx.lists.can_add(data)
  if full then
    local problem = inner.add{type = "label", caption = {"resbal.chain-full"}}
    problem.style.font_color = {1, 0.4, 0.4}
    problem.style.top_margin = 6
  end

  local buttons = frame.add{type = "flow", direction = "horizontal", style = "dialog_buttons_horizontal_flow"}
  buttons.add{type = "button", name = "resbal_chain_close", style = "back_button", caption = {"resbal.list-cancel"}}
  local filler = buttons.add{type = "empty-widget", style = "draggable_space", ignored_by_interaction = true}
  filler.style.horizontally_stretchable = true
  filler.style.height = 32
  local create = buttons.add{type = "button", name = "resbal_chain_create", style = "confirm_button",
                             caption = {"resbal.chain-create"}}
  create.enabled = not full
end

local function create_list(player)
  local frame = dialog(player)
  if not frame then return end
  local surface = frame.tags.surface
  local entries = {}
  for _, box in ipairs(frame.inner.scroll.resbal_chain_items.children) do
    if box.state then entries[#entries + 1] = {type = box.tags.type, name = box.tags.name, surface = surface} end
  end
  if #entries == 0 then return end -- нічого не вибрано — лишаємо вікно відкритим
  local name = frame.inner.row.resbal_chain_name.text
  frame.destroy()
  if ctx.lists.add_list(player, name, entries) then
    ctx.open_panel(player)
    player.create_local_flying_text{text = {"resbal.chain-created", #entries}, create_at_cursor = true}
  end
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_chain_open" then
    open_dialog(player)
  elseif name == "resbal_chain_close" then
    close_dialog(player)
  elseif name == "resbal_chain_create" then
    create_list(player)
  else
    return false
  end
  return true
end

-- Enter у полі назви — створити
function M.on_confirmed(player, element)
  if element.name ~= "resbal_chain_name" then return false end
  create_list(player)
  return true
end

return M
