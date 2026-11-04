-- Позначки на великому графіку: «додав другу лінію» тощо. Зберігається момент (тік), тож позначка
-- стоїть на своєму місці за будь-якого проміжку. Спільні для всіх ресурсів гравця.
--   data.marks = {{tick = число, text = рядок}, ...} (від старих до нових)
local M = {}

local MAX_MARKS = 50
local TEXT_MAX = 60 -- символів

-- Залежності з control.lua: player_data(player), redraw(player), ago_caption(seconds)
local ctx

function M.init(context)
  ctx = context
end

local function marks_of(data)
  data.marks = data.marks or {}
  return data.marks
end

-- Позначки, що потрапляють у вікно графіка (range секунд назад): {{ago = секунд, text = рядок}}
function M.visible(data, range)
  local list = {}
  for _, mark in ipairs(marks_of(data)) do
    local ago = (game.tick - mark.tick) / 60
    if ago >= 0 and ago <= range then list[#list + 1] = {ago = ago, text = mark.text} end
  end
  return list
end

function M.add_button(parent)
  parent.add{type = "button", name = "resbal_marks_open", caption = {"resbal.marks"}, tooltip = {"resbal.marks-tooltip"}}
end

local function clean_text(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local out, count = {}, 0
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    count = count + 1
    if count > TEXT_MAX then break end
    out[count] = char
  end
  return table.concat(out)
end

local function dialog(player)
  return player.gui.screen.resbal_marks
end

local function close_dialog(player)
  local frame = dialog(player)
  if frame then frame.destroy() end
end

local function fill_list(frame, data)
  local tbl = frame.inner.scroll.resbal_marks_list
  tbl.clear()
  local list = marks_of(data)
  if #list == 0 then
    local empty = tbl.add{type = "label", caption = {"resbal.marks-empty"}}
    empty.style.font_color = {0.7, 0.7, 0.7}
    tbl.add{type = "empty-widget"}
    tbl.add{type = "empty-widget"}
    return
  end
  for i = #list, 1, -1 do -- новіші зверху
    local mark = list[i]
    local ago = tbl.add{type = "label", caption = ctx.ago_caption((game.tick - mark.tick) / 60)}
    ago.style.font_color = {0.7, 0.7, 0.7}
    ago.style.minimal_width = 90
    local text = tbl.add{type = "label", caption = mark.text ~= "" and mark.text or "—"}
    text.style.maximal_width = 300
    tbl.add{type = "sprite-button", sprite = "utility/close", style = "tool_button_red", tooltip = {"resbal.marks-delete"},
            tags = {resbal_mark_del = i}}
  end
end

local function open_dialog(player)
  close_dialog(player)
  local frame = player.gui.screen.add{type = "frame", name = "resbal_marks", direction = "vertical"}
  frame.auto_center = true
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", style = "frame_title", caption = {"resbal.marks-title"}, ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_marks_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical", style = "inside_shallow_frame_with_padding"}
  local row = inner.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 8
  local field = row.add{type = "textfield", name = "resbal_mark_text", tooltip = {"resbal.marks-text-tooltip"}}
  field.style.width = 300
  field.focus()
  row.add{type = "button", name = "resbal_mark_add", caption = {"resbal.marks-add"}, tooltip = {"resbal.marks-add-tooltip"}}
  local hint = inner.add{type = "label", caption = {"resbal.marks-hint", MAX_MARKS}}
  hint.style.single_line = false
  hint.style.maximal_width = 420
  hint.style.font_color = {0.7, 0.7, 0.7}
  hint.style.top_margin = 4
  local scroll = inner.add{type = "scroll-pane", name = "scroll"}
  scroll.style.maximal_height = 300
  scroll.style.top_margin = 8
  local tbl = scroll.add{type = "table", name = "resbal_marks_list", column_count = 3}
  tbl.style.horizontal_spacing = 12
  tbl.style.vertical_spacing = 4
  fill_list(frame, ctx.player_data(player))
end

local function add_mark(player)
  local frame = dialog(player)
  if not frame then return end
  local field = frame.inner.children[1].resbal_mark_text
  local data = ctx.player_data(player)
  local list = marks_of(data)
  list[#list + 1] = {tick = game.tick, text = clean_text(field.text)}
  while #list > MAX_MARKS do table.remove(list, 1) end
  field.text = ""
  fill_list(frame, data)
  ctx.redraw(player)
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_marks_open" then
    open_dialog(player)
  elseif name == "resbal_marks_close" then
    close_dialog(player)
  elseif name == "resbal_mark_add" then
    add_mark(player)
  else
    local index = element.tags and element.tags.resbal_mark_del
    if not index then return false end
    local data = ctx.player_data(player)
    table.remove(marks_of(data), index)
    local frame = dialog(player)
    if frame then fill_list(frame, data) end
    ctx.redraw(player)
  end
  return true
end

-- Enter у полі — додати позначку
function M.on_confirmed(player, element)
  if element.name ~= "resbal_mark_text" then return false end
  add_mark(player)
  return true
end

return M
