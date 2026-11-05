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
-- ручні — білі (синій зайнятий значком «вихід повний»), сторож — помаранчеві / зелені / сірі
local COLORS = {manual = {1, 1, 1}, alert = {1, 0.6, 0.2}, recover = {0.45, 0.9, 0.45}, other = {0.7, 0.7, 0.7}}

function M.color(auto)
  return COLORS[auto or "manual"] or COLORS.other
end

-- Текст у кольорі позначки (rich text)
function M.colored(auto, text)
  local c = M.color(auto)
  return {"", string.format("[color=%g,%g,%g]", c[1], c[2], c[3]), text, "[/color]"}
end

-- Залежності з control.lua: player_data(player), redraw(player), ago_caption(seconds), duration_caption(seconds),
-- big_inner(player) — вміст відкритої вкладки великого вікна (там панель позначок)
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

-- Скільки позначок видно на графіку цих ресурсів: ручні + автопозначки сторожа саме цих ресурсів
function M.count_for(data, panels)
  local count = 0
  for _, mark in ipairs(marks_of(data)) do
    local shown = not mark.resource
    for _, item in ipairs(shown and {} or panels or {}) do
      if same_resource(mark.resource, item) then shown = true end
    end
    if shown then count = count + 1 end
  end
  return count
end

-- Кнопка «Позначки (N)» у рядку ресурсів графіка: розгортає / згортає панель (стан — у даних гравця)
function M.add_button(parent, player)
  local data = ctx.player_data(player)
  local button = parent.add{type = "button", name = "resbal_marks_open", caption = {"resbal.marks-count", M.count_for(data, ctx.panels(player))},
                            tooltip = {"resbal.marks-tooltip"}}
  button.toggled = data.marks_open == true
end

-- Обрізка до TEXT_MAX знаків; тег іконки ([item=…]) — один знак і не ріжеться (lists.clip)
local clip = require("scripts.lists").clip

local function clean_text(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return clip(text, TEXT_MAX)
end

-- Панель позначок на вкладці «Графік» великого вікна (редизайн 1.7: замість окремого діалогу)
local function panel_of(player)
  local inner = ctx.big_inner(player)
  return inner and inner.resbal_marks_panel
end

-- panels — ресурси на графіку: автопозначки сторожа інших ресурсів у списку не показуємо (як і лінії)
local function fill_list(panel, data, panels)
  local tbl = panel.resbal_marks_scroll.resbal_marks_list
  tbl.clear()
  local list = marks_of(data)
  local function shown(mark)
    if not mark.resource then return true end
    for _, item in ipairs(panels or {}) do
      if same_resource(mark.resource, item) then return true end
    end
    return false
  end
  local any = false
  for _, mark in ipairs(list) do
    if shown(mark) then any = true end
  end
  if not any then
    tbl.add{type = "label", caption = {"resbal.marks-empty"}, style = "resbal_quiet_label"}
    tbl.add{type = "empty-widget"}
    tbl.add{type = "empty-widget"}
    return
  end
  for i = #list, 1, -1 do -- новіші зверху
    local mark = list[i]
    if shown(mark) then
    local ago = tbl.add{type = "label", caption = ctx.ago_caption((game.tick - mark.tick) / 60), style = "resbal_quiet_label"}
    ago.style.minimal_width = 90
    local caption = mark.text ~= "" and mark.text or "—"
    if mark.auto then caption = M.colored(mark.auto, caption) end
    local text = tbl.add{type = "label", caption = caption}
    text.style.maximal_width = 640
    text.style.single_line = false -- довгий текст автопозначки сторожа переноситься, а не обрізається
    local delete = tbl.add{type = "sprite-button", sprite = "utility/close", style = "resbal_row_remove",
                           tooltip = {"resbal.marks-delete"}, tags = {resbal_mark_del = i}}
    delete.style.size = 24
    end
  end
end

-- Оновити список у панелі й лічильник на кнопці (після додавання / видалення / автопозначки)
local function refresh(player)
  local data = ctx.player_data(player)
  local panel = panel_of(player)
  if panel then fill_list(panel, data, ctx.panels(player)) end
  local inner = ctx.big_inner(player)
  local button = inner and inner.resbal_big_chips and inner.resbal_big_chips.resbal_marks_open
  if button then button.caption = {"resbal.marks-count", M.count_for(data, ctx.panels(player))} end
end

function M.add_panel(inner, player)
  local data = ctx.player_data(player)
  local panel = inner.add{type = "frame", name = "resbal_marks_panel", direction = "vertical", style = "bordered_frame",
                          caption = {"resbal.marks-title"}, tooltip = {"resbal.marks-hint", MAX_MARKS, AUTO_MAX}}
  panel.style.horizontally_stretchable = true
  panel.style.top_margin = 6
  panel.visible = data.marks_open == true
  local row = panel.add{type = "flow", name = "resbal_marks_row", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 8
  local field = row.add{type = "textfield", name = "resbal_mark_text", icon_selector = true,
                        tooltip = {"resbal.marks-text-tooltip"}}
  field.style.width = 420
  row.add{type = "button", name = "resbal_mark_add", caption = {"resbal.marks-add"}, tooltip = {"resbal.marks-add-tooltip"}}
  local scroll = panel.add{type = "scroll-pane", name = "resbal_marks_scroll"}
  scroll.style.maximal_height = 170 -- ≈ 6 рядків, далі прокрутка
  scroll.style.top_margin = 6
  local tbl = scroll.add{type = "table", name = "resbal_marks_list", column_count = 3}
  tbl.style.horizontal_spacing = 12
  tbl.style.vertical_spacing = 2
  fill_list(panel, data, ctx.panels(player))
end

local function add_mark(player)
  local panel = panel_of(player)
  if not panel then return end
  local field = panel.resbal_marks_row.resbal_mark_text
  local data = ctx.player_data(player)
  local list = marks_of(data)
  list[#list + 1] = {tick = game.tick, text = clean_text(field.text)}
  prune(list, false, MAX_MARKS)
  field.text = ""
  refresh(player)
  ctx.redraw(player)
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_marks_open" then
    local data = ctx.player_data(player)
    data.marks_open = not data.marks_open
    element.toggled = data.marks_open
    local panel = panel_of(player)
    if panel then
      panel.visible = data.marks_open
      if data.marks_open then panel.resbal_marks_row.resbal_mark_text.focus() end
    end
  elseif name == "resbal_mark_add" then
    add_mark(player)
  else
    local index = element.tags and element.tags.resbal_mark_del
    if not index then return false end
    table.remove(marks_of(ctx.player_data(player)), index)
    refresh(player)
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
  refresh(player)
  ctx.redraw(player)
end

-- Enter у полі — додати позначку
function M.on_confirmed(player, element)
  if element.name ~= "resbal_mark_text" then return false end
  add_mark(player)
  return true
end

return M
