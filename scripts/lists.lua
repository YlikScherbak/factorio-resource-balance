-- Кілька списків ресурсів гравця — вкладки над таблицею в режимі «Мій список».
--   data.lists  = {{name = рядок|nil, entries = {...}}, ...}  (name = nil — назва за замовчуванням)
--   data.active = індекс відкритого списку
--   data.entries — завжди посилання на entries відкритого списку: решта коду працює з ним, як і раніше.
local M = {}

local MAX_LISTS = 12
local NAME_MAX = 40 -- символів
local EXPORT_PREFIX = "resbal1:" -- рядок експорту: префікс + стиснутий JSON (helpers.encode_string)
local WATCH_WINDOWS = {[1] = true, [5] = true, [10] = true, [30] = true}

-- Залежності з control.lua: build(player), player_data(player), after_change(player)
local ctx

function M.init(context)
  ctx = context
end

-- Створює data.lists зі старого data.entries (до 1.5) і наводить лад в індексі
function M.normalize(data)
  if not data.lists then
    data.lists = {{entries = data.entries or {}}}
    data.active = 1
  end
  if #data.lists == 0 then data.lists[1] = {entries = {}} end
  if data.watch_paused then -- 1.4: одна пауза на все → пауза кожного списку
    for _, list in ipairs(data.lists) do list.watch_paused = true end
    data.watch_paused = nil
  end
  data.active = math.max(1, math.min(data.active or 1, #data.lists))
  data.entries = data.lists[data.active].entries
end

function M.caption(list)
  return list.name or {"resbal.list-default"}
end

local function violated_count(list)
  local count = 0
  for _, entry in ipairs(list.entries) do
    if entry.watch and entry.watch.violated then count = count + 1 end
  end
  return count
end

-- Рядок вкладок: кнопка на список (назва, кількість ресурсів, червона позначка — порушення сторожа),
-- далі «новий», «перейменувати», «видалити», «експорт», «імпорт»
local TABS_MAX_WIDTH = 900 -- ширше — вкладки прокручуються, панель не розтягується

function M.add_tabs(parent, data)
  local row = parent.add{type = "flow", name = "resbal_lists", direction = "horizontal"}
  row.style.top_margin = 8
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 4
  -- вкладки — у горизонтальній прокрутці; кнопки керування лишаються видимими праворуч
  local scroll = row.add{type = "scroll-pane", name = "resbal_lists_scroll", style = "naked_scroll_pane",
                         horizontal_scroll_policy = "auto", vertical_scroll_policy = "never"}
  scroll.style.maximal_width = TABS_MAX_WIDTH
  local tabs = scroll.add{type = "flow", direction = "horizontal"}
  tabs.style.horizontal_spacing = 4
  for i, list in ipairs(data.lists) do
    local broken = violated_count(list)
    local caption = {"", M.caption(list), " (" .. #list.entries .. ")"}
    if broken > 0 then caption = {"", "[img=utility/status_not_working] ", caption} end
    if list.watch_paused then caption = {"", "[img=utility/pause] ", caption} end
    local tooltip = broken > 0 and {"resbal.list-tooltip-broken", broken} or {"resbal.list-tooltip"}
    if list.watch_paused then tooltip = {"", tooltip, "\n", {"resbal.list-tooltip-paused"}} end
    local button = tabs.add{type = "button", name = "resbal_list_" .. i, caption = caption, tooltip = tooltip}
    button.toggled = i == data.active
  end
  if #data.lists > 1 then scroll.scroll_to_element(tabs["resbal_list_" .. data.active], "in-view") end
  local new = row.add{type = "sprite-button", name = "resbal_list_new", sprite = "utility/add", style = "tool_button",
                      tooltip = {"resbal.list-new"}}
  new.enabled = #data.lists < MAX_LISTS
  row.add{type = "sprite-button", name = "resbal_list_rename", sprite = "utility/rename_icon", style = "tool_button",
          tooltip = {"resbal.list-rename"}}
  local delete = row.add{type = "sprite-button", name = "resbal_list_delete", sprite = "utility/trash",
                         style = "tool_button_red", tooltip = {"resbal.list-delete"}}
  delete.enabled = #data.lists > 1
  local export = row.add{type = "sprite-button", name = "resbal_list_export", sprite = "utility/export",
                         style = "tool_button", tooltip = {"resbal.list-export"}}
  export.style.left_margin = 8
  local import = row.add{type = "sprite-button", name = "resbal_list_import", sprite = "utility/import",
                         style = "tool_button", tooltip = {"resbal.list-import"}}
  import.enabled = #data.lists < MAX_LISTS
end

local function dialog(player)
  return player.gui.screen.resbal_list_dialog
end

local function close_dialog(player)
  local frame = dialog(player)
  if frame then frame.destroy() end
end

-- Обрізає текст до max знаків: літера UTF-8 — один знак (не ріжеться посередині), тег rich text
-- ([item=…], [color=…], [/color]) — теж один знак, щоб не обрізати іконку на півслові
function M.clip(text, max)
  local out, count, i = {}, 0, 1
  while i <= #text and count < max do
    local token = text:match("^%[/?[%w%-_]+=?[^%[%]]*%]", i) or text:match("^[%z\1-\127\194-\244][\128-\191]*", i)
    if token then
      count = count + 1
      out[count] = token
      i = i + #token
    else
      i = i + 1 -- зламаний байт — пропускаємо
    end
  end
  return table.concat(out)
end

-- Обрізає назву до NAME_MAX знаків і прибирає пробіли по краях
local function clean_name(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local name = M.clip(text, NAME_MAX)
  return name ~= "" and name or nil
end

-- Рядок експорту: назва списку, ресурси з поверхнями й пороги сторожа (без стану сповіщень)
local function export_string(list)
  local entries = {}
  for _, entry in ipairs(list.entries) do
    local item = {t = entry.type, n = entry.name, s = entry.surface}
    local watch = entry.watch
    if watch then item.w = {p = watch.min_produced, b = watch.min_balance, m = watch.window} end
    item.g = entry.target -- ціль випуску (необов'язково)
    entries[#entries + 1] = item
  end
  return EXPORT_PREFIX .. helpers.encode_string(helpers.table_to_json({name = list.name, entries = entries}))
end

-- Розбирає рядок; повертає список і скільки ресурсів пропущено (немає в цій грі / пошкоджені), або nil
local function import_string(text)
  text = (text or ""):gsub("%s", "")
  if text:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then return nil end
  local ok, json = pcall(helpers.decode_string, text:sub(#EXPORT_PREFIX + 1))
  if not (ok and type(json) == "string") then return nil end
  local parsed
  ok, parsed = pcall(helpers.json_to_table, json)
  if not (ok and type(parsed) == "table" and type(parsed.entries) == "table") then return nil end

  local list = {name = type(parsed.name) == "string" and clean_name(parsed.name) or nil, entries = {}}
  local skipped, seen = 0, {}
  for _, item in ipairs(parsed.entries) do
    local valid = type(item) == "table" and (item.t == "item" or item.t == "fluid")
                  and type(item.n) == "string" and type(item.s) == "string"
    local proto = valid and (item.t == "fluid" and prototypes.fluid[item.n] or prototypes.item[item.n])
    local key = valid and (item.t .. "/" .. item.n .. "@" .. item.s)
    if proto and not seen[key] then
      seen[key] = true
      local entry = {type = item.t, name = item.n, surface = item.s}
      local target = tonumber(item.g)
      if target and target > 0 then entry.target = target end
      if type(item.w) == "table" then
        local produced, balance, window = tonumber(item.w.p), tonumber(item.w.b), tonumber(item.w.m)
        if produced or balance then
          entry.watch = {min_produced = produced and math.max(0, produced), min_balance = balance,
                         window = WATCH_WINDOWS[window] and window or 5}
        end
      end
      list.entries[#list.entries + 1] = entry
    else
      skipped = skipped + 1
    end
  end
  return list, skipped
end

-- mode: "new" | "rename" | "delete" | "export" | "import"
local function open_dialog(player, mode)
  close_dialog(player)
  local data = ctx.player_data(player)
  local list = data.lists[data.active]
  local frame = player.gui.screen.add{type = "frame", name = "resbal_list_dialog", direction = "vertical",
                                      tags = {mode = mode, list = data.active}}
  frame.auto_center = true

  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", style = "frame_title", ignored_by_interaction = true,
               caption = {"resbal.list-" .. mode .. "-title"}}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_list_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical",
                          style = "inside_shallow_frame_with_padding"}
  if mode == "delete" then
    local text = inner.add{type = "label", caption = {"resbal.list-delete-confirm", M.caption(list), #list.entries}}
    text.style.single_line = false
    text.style.maximal_width = 380
  elseif mode == "export" or mode == "import" then
    local hint = inner.add{type = "label", caption = {"resbal.list-" .. mode .. "-hint", M.caption(list)}}
    hint.style.single_line = false
    hint.style.maximal_width = 420
    local box = inner.add{type = "text-box", name = "resbal_list_text",
                          text = mode == "export" and export_string(list) or ""}
    box.style.width = 420
    box.style.height = 120
    box.word_wrap = true
    box.read_only = mode == "export"
    box.focus()
    box.select_all()
    local problem = inner.add{type = "label", name = "resbal_list_error", caption = {"resbal.list-import-error"}}
    problem.style.font_color = {1, 0.4, 0.4}
    problem.visible = false
  else
    local row = inner.add{type = "flow", name = "row", direction = "horizontal"}
    row.style.vertical_align = "center"
    row.style.horizontal_spacing = 12
    row.add{type = "label", caption = {"resbal.list-name"}}
    local field = row.add{type = "textfield", name = "resbal_list_name", icon_selector = true,
                          text = (mode == "rename" and list.name) or ""}
    field.style.width = 260
    field.focus()
    field.select_all()
  end

  local buttons = frame.add{type = "flow", direction = "horizontal", style = "dialog_buttons_horizontal_flow"}
  buttons.add{type = "button", name = "resbal_list_close", style = "back_button",
              caption = mode == "export" and {"resbal.list-done"} or {"resbal.list-cancel"}}
  local filler = buttons.add{type = "empty-widget", style = "draggable_space", ignored_by_interaction = true}
  filler.style.horizontally_stretchable = true
  filler.style.height = 32
  if mode == "export" then
    -- лише «Готово»
  elseif mode == "import" then
    buttons.add{type = "button", name = "resbal_list_confirm", caption = {"resbal.list-import-button"},
                style = "confirm_button"}
  elseif mode == "delete" then
    buttons.add{type = "button", name = "resbal_list_confirm", caption = {"resbal.list-delete-button"}, style = "red_button"}
  else
    buttons.add{type = "button", name = "resbal_list_confirm", caption = {"resbal.list-save"}, style = "confirm_button"}
  end
end

local function confirm(player)
  local frame = dialog(player)
  if not frame then return end
  local tags = frame.tags
  local data = ctx.player_data(player)
  local list = data.lists[tags.list]
  if tags.mode == "import" then
    local imported, skipped = import_string(frame.inner.resbal_list_text.text)
    if not imported then
      frame.inner.resbal_list_error.visible = true -- лишаємо вікно відкритим, щоб виправити рядок
      return
    end
    if #data.lists >= MAX_LISTS then return end
    data.lists[#data.lists + 1] = imported
    data.active = #data.lists
    player.create_local_flying_text{text = {"resbal.list-imported", #imported.entries, skipped}, create_at_cursor = true}
  elseif tags.mode == "new" then
    if #data.lists < MAX_LISTS then
      data.lists[#data.lists + 1] = {name = clean_name(frame.inner.row.resbal_list_name.text), entries = {}}
      data.active = #data.lists
    end
  elseif list and tags.mode == "rename" then
    list.name = clean_name(frame.inner.row.resbal_list_name.text)
  elseif list and tags.mode == "delete" and #data.lists > 1 then
    table.remove(data.lists, tags.list)
    if data.active >= tags.list then data.active = data.active - 1 end
  end
  frame.destroy()
  M.normalize(data)
  ctx.build(player)
  ctx.after_change(player)
end

-- Обробка кліку; повертає true, якщо клік був по елементу списків
function M.on_click(player, element)
  local name = element.name
  if name:sub(1, 12) ~= "resbal_list_" then return false end
  if name == "resbal_list_new" then
    open_dialog(player, "new")
  elseif name == "resbal_list_rename" then
    open_dialog(player, "rename")
  elseif name == "resbal_list_delete" then
    open_dialog(player, "delete")
  elseif name == "resbal_list_export" then
    open_dialog(player, "export")
  elseif name == "resbal_list_import" then
    open_dialog(player, "import")
  elseif name == "resbal_list_close" then
    close_dialog(player)
  elseif name == "resbal_list_confirm" then
    confirm(player)
  else
    local index = tonumber(name:match("^resbal_list_(%d+)$"))
    if not index then return false end
    local data = ctx.player_data(player)
    data.active = index
    M.normalize(data)
    ctx.build(player)
  end
  return true
end

-- Enter у полі назви — зберегти
function M.on_confirmed(player, element)
  if element.name ~= "resbal_list_name" then return false end
  confirm(player)
  return true
end

-- Чи можна додати ще одну вкладку
function M.can_add(data)
  return #data.lists < MAX_LISTS
end

-- Нова вкладка з готовими ресурсами (напр., «список з інгредієнтів»), робиться активною.
-- Повертає false, якщо вкладок уже максимум.
function M.add_list(player, name, entries)
  local data = ctx.player_data(player)
  if not M.can_add(data) then return false end
  data.lists[#data.lists + 1] = {name = clean_name(name), entries = entries}
  data.active = #data.lists
  M.normalize(data)
  ctx.build(player)
  ctx.after_change(player)
  return true
end

-- Усі записи всіх списків (для сторожа): ітератор entry, list
function M.each_entry(data)
  local li, ei = 1, 0
  return function()
    while data.lists[li] do
      ei = ei + 1
      local entry = data.lists[li].entries[ei]
      if entry then return entry, data.lists[li] end
      li, ei = li + 1, 0
    end
  end
end

return M
