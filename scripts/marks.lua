-- Позначки на великому графіку: «додав другу лінію» тощо. Зберігається момент (тік), тож позначка
-- стоїть на своєму місці за будь-якого проміжку. Ручні — спільні для всіх ресурсів гравця.
-- Автопозначки сторожа (auto = вид) — лише на графіку свого ресурсу (resource).
--   data.marks = {{tick = число, text = рядок або локалізований рядок, auto = nil | "alert" | "recover" |
--                  "pause" | "snooze" | "changed", resource = {type, name, surface}?}, ...} (від старих до нових)
local M = {}

local MAX_MARKS = 50 -- ручних
local AUTO_MAX = 30  -- автоматичних (окремий ліміт: сторож не витісняє ручні позначки)
local TEXT_MAX = 60 -- символів

-- Колір лінії й тексту: ручні — блакитні, спрацювання сторожа — помаранчеві, відновлення — зелені, решта — сірі
local COLORS = {manual = {0.4, 0.75, 1}, alert = {1, 0.6, 0.2}, recover = {0.45, 0.9, 0.45}, other = {0.7, 0.7, 0.7}}

function M.color(auto)
  return COLORS[auto or "manual"] or COLORS.other
end

-- Текст у кольорі позначки (rich text)
function M.colored(auto, text)
  local c = M.color(auto)
  return {"", string.format("[color=%g,%g,%g]", c[1], c[2], c[3]), text, "[/color]"}
end

-- Залежності з control.lua: player_data(player), redraw(player), ago_caption(seconds), duration_caption(seconds)
local ctx

function M.init(context)
  ctx = context
end

local function marks_of(data)
  data.marks = data.marks or {}
  return data.marks
end

-- Лишає не більше max позначок свого виду (ручних або автоматичних), видаляючи найстаріші
local function prune(list, auto, max)
  local count = 0
  for _, mark in ipairs(list) do
    if (mark.auto ~= nil) == auto then count = count + 1 end
  end
  local i = 1
  while count > max and i <= #list do
    if (list[i].auto ~= nil) == auto then
      table.remove(list, i)
      count = count - 1
    else
      i = i + 1
    end
  end
end

local function same_resource(a, b)
  return a.type == b.type and a.name == b.name and a.surface == b.surface
end

-- Позначки, що потрапляють у вікно графіка (range секунд назад): {{ago = секунд, text, auto}}.
-- panels — ресурси на графіку: автопозначки показуються лише для них.
function M.visible(data, range, panels)
  local list = {}
  for _, mark in ipairs(marks_of(data)) do
    local ago = (game.tick - mark.tick) / 60
    local shown = not mark.resource
    if not shown then
      for _, panel in ipairs(panels or {}) do
        if same_resource(mark.resource, panel) then shown = true end
      end
    end
    if shown and ago >= 0 and ago <= range then list[#list + 1] = {ago = ago, text = mark.text, auto = mark.auto} end
  end
  return list
end

function M.add_button(parent)
  parent.add{type = "button", name = "resbal_marks_open", caption = {"resbal.marks"}, tooltip = {"resbal.marks-tooltip"}}
end

-- Обрізка до TEXT_MAX знаків; тег іконки ([item=…]) — один знак і не ріжеться (lists.clip)
local clip = require("scripts.lists").clip

local function clean_text(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return clip(text, TEXT_MAX)
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
    local caption = mark.text ~= "" and mark.text or "—"
    if mark.auto then caption = M.colored(mark.auto, caption) end
    local text = tbl.add{type = "label", caption = caption}
    text.style.maximal_width = 300
    text.style.single_line = false -- довгий текст автопозначки сторожа переноситься, а не обрізається
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
  local field = row.add{type = "textfield", name = "resbal_mark_text", icon_selector = true,
                        tooltip = {"resbal.marks-text-tooltip"}}
  field.style.width = 300
  field.focus()
  row.add{type = "button", name = "resbal_mark_add", caption = {"resbal.marks-add"}, tooltip = {"resbal.marks-add-tooltip"}}
  local hint = inner.add{type = "label", caption = {"resbal.marks-hint", MAX_MARKS, AUTO_MAX}}
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
  prune(list, false, MAX_MARKS)
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

-- Автопозначка сторожа (якщо гравець не вимкнув у налаштуваннях).
-- kind: "alert" (info.reasons — що порушено) або "recover" / "pause" / "snooze" / "changed" (info.since — тік початку)
function M.add_auto(player, entry, kind, info)
  if not player.mod_settings["resbal-watch-marks"].value then return end
  local icon = "[" .. entry.type .. "=" .. entry.name .. "]"
  local text
  if kind == "alert" then
    text = {"resbal.mark-watch-alert", icon, info.reasons}
  else
    local since = info and info.since
    local duration = since and ctx.duration_caption((game.tick - since) / 60) or "?"
    text = {"resbal.mark-watch-" .. kind, icon, duration}
  end
  local data = ctx.player_data(player)
  local list = marks_of(data)
  list[#list + 1] = {tick = game.tick, text = text, auto = kind,
                     resource = {type = entry.type, name = entry.name, surface = entry.surface}}
  prune(list, true, AUTO_MAX)
  local frame = dialog(player)
  if frame then fill_list(frame, data) end
  ctx.redraw(player)
end

-- Enter у полі — додати позначку
function M.on_confirmed(player, element)
  if element.name ~= "resbal_mark_text" then return false end
  add_mark(player)
  return true
end

return M
