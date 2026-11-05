-- Вікно «Діагностика фабрики» (редизайн 1.7): вкладки «Простої» і «Журнал сторожа» замість двох окремих вікон.
-- Вміст будується лише для відкритої вкладки (як у вікні ресурсу); відкрита вкладка — у даних гравця.
local M = {}

-- Залежності з control.lua: player_data, surface_caption(surface, name), idle (модуль), watchlog (модуль)
local ctx

function M.init(context)
  ctx = context
end

local TABS = {"idle", "log"}

local function frame_of(player)
  return player.gui.screen.resbal_diag
end

-- Вміст відкритої вкладки key або nil (вкладка закрита / вікна немає)
function M.inner(player, key)
  local frame = frame_of(player)
  if not frame then return nil end
  if (ctx.player_data(player).diag_tab or "idle") ~= key then return nil end
  local tabs = frame.resbal_diag_tabs
  return tabs and tabs.resbal_diag_inner
end

function M.open(player)
  local old = frame_of(player)
  local location = old and old.location
  if old then old.destroy() end
  local data = ctx.player_data(player)
  local current = data.diag_tab or "idle"

  local frame = player.gui.screen.add{type = "frame", name = "resbal_diag", direction = "vertical"}
  if location then frame.location = location else frame.auto_center = true end
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", style = "frame_title", ignored_by_interaction = true,
               caption = {"resbal.diag-title", ctx.surface_caption(player.surface, player.surface.name)}}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_diag_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local tabbed = frame.add{type = "tabbed-pane", name = "resbal_diag_tabs"}
  local inner, selected = nil, 1
  for index, key in ipairs(TABS) do
    local tab = tabbed.add{type = "tab", name = "resbal_diag_tab_" .. key, caption = {"resbal.diag-tab-" .. key}}
    local content
    if key == current then
      content = tabbed.add{type = "frame", name = "resbal_diag_inner", direction = "vertical",
                           style = "inside_shallow_frame_with_padding"}
      inner, selected = content, index
    else
      content = tabbed.add{type = "empty-widget", name = "resbal_diag_empty_" .. key}
    end
    tabbed.add_tab(tab, content)
  end
  tabbed.selected_tab_index = selected -- лише після додавання всіх вкладок

  if current == "idle" then ctx.idle.build_into(inner, player) else ctx.watchlog.build_into(inner, player) end
end

function M.add_button(parent)
  local button = parent.add{type = "button", name = "resbal_diag_open", caption = {"resbal.diag"},
                            tooltip = {"resbal.diag-tooltip"}}
  button.style.left_margin = 4
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_diag_open" then
    local frame = frame_of(player)
    if frame then frame.destroy() else M.open(player) end
  elseif name == "resbal_diag_close" then
    local frame = frame_of(player)
    if frame then frame.destroy() end
  else
    return false
  end
  return true
end

-- Перемикання вкладок вікна; повертає true, якщо подія стосувалась його
function M.on_tab_changed(player, element)
  if element.name ~= "resbal_diag_tabs" then return false end
  local key = TABS[element.selected_tab_index]
  local data = ctx.player_data(player)
  if key and (data.diag_tab or "idle") ~= key then
    data.diag_tab = key
    M.open(player)
  end
  return true
end

return M
