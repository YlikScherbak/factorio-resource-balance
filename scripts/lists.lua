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
-- далі «новий» і «налаштування списку» (один діалог: назва, експорт, видалення)
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
  local tabs = scroll.add{type = "flow", name = "resbal_tabs", direction = "horizontal"}
  tabs.style.horizontal_spacing = 4
  -- закріплена перша вкладка «Дефіцит» (замість режиму «Тільки мінус»); лічильник оновлює панель
  local deficit = tabs.add{type = "button", name = "resbal_list_deficit", tooltip = {"resbal.deficit-tab-tooltip"},
                           caption = {"", "[img=utility/warning_icon] ", {"resbal.deficit-tab"},
                                      data.deficit_count and (" (" .. data.deficit_count .. ")") or ""}}
  deficit.toggled = data.negative_only == true
  deficit.style.right_margin = 8
  for i, list in ipairs(data.lists) do
    local broken = violated_count(list)
    local caption = {"", M.caption(list), " (" .. #list.entries .. ")"}
    if broken > 0 then caption = {"", "[img=utility/status_not_working] ", caption} end
    if list.watch_paused then caption = {"", "[img=utility/pause] ", caption} end
    local tooltip = broken > 0 and {"resbal.list-tooltip-broken", broken} or {"resbal.list-tooltip"}
    if list.watch_paused then tooltip = {"", tooltip, "\n", {"resbal.list-tooltip-paused"}} end
    local button = tabs.add{type = "button", name = "resbal_list_" .. i, caption = caption, tooltip = tooltip}
    button.toggled = i == data.active and not data.negative_only
  end
  if #data.lists > 1 and not data.negative_only then
    scroll.scroll_to_element(tabs["resbal_list_" .. data.active], "in-view")
  end
  -- керування списками: «+» — новий (або імпорт рядком), олівець — назва, експорт, видалення відкритого
  row.add{type = "sprite-button", name = "resbal_list_new", sprite = "utility/add", style = "tool_button",
          tooltip = {"resbal.list-new"}}
  row.add{type = "sprite-button", name = "resbal_list_edit", sprite = "utility/rename_icon", style = "tool_button",
          tooltip = {"resbal.list-edit"}}
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

-- Діалог «Список» (редизайн 1.7: один діалог замість чотирьох).
--   mode "new"  — «+»: назва з іконкою, або вставити рядок експорту (імпорт як новий список);
--   mode "edit" — олівець: назва, рядок експорту (кнопка «Виділити»), «Видалити список» у два кліки.
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
               caption = mode == "edit" and {"resbal.list-edit-title", M.caption(list)} or {"resbal.list-new-title"}}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_list_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical",
                          style = "inside_shallow_frame_with_padding"}
  local fields = inner.add{type = "table", name = "fields", column_count = 2}
  fields.style.horizontal_spacing = 12
  fields.style.vertical_spacing = 8
  fields.style.column_alignments[1] = "top-left"

  fields.add{type = "label", caption = {"resbal.list-name"}}
  local name = fields.add{type = "textfield", name = "resbal_list_name", icon_selector = true,
                          text = mode == "edit" and list.name or ""}
  name.style.width = 420
  if mode == "new" then
    name.focus()
  end

  if mode == "edit" then
    -- рядок експорту: буфера обміну в грі немає — «Виділити», далі Ctrl+C
    fields.add{type = "label", caption = {"resbal.list-export-label"}, tooltip = {"resbal.list-export-hint", M.caption(list)}}
    local export = fields.add{type = "flow", direction = "horizontal"}
    export.style.vertical_align = "center"
    local box = export.add{type = "textfield", name = "resbal_list_text", text = export_string(list),
                           tooltip = {"resbal.list-export-hint", M.caption(list)}}
    box.style.width = 330
    export.add{type = "button", name = "resbal_list_select", caption = {"resbal.list-select"},
               tooltip = {"resbal.list-export-hint", M.caption(list)}}
  else
    fields.add{type = "label", caption = {"resbal.list-import-label"}, tooltip = {"resbal.list-import-hint", ""}}
    local box = fields.add{type = "text-box", name = "resbal_list_text", tooltip = {"resbal.list-import-hint", ""}}
    box.style.width = 420
    box.style.height = 64
    box.word_wrap = true
  end

  local problem = inner.add{type = "label", name = "resbal_list_error", caption = {"resbal.list-import-error"}}
  problem.style.font_color = {1, 0.4, 0.4}
  problem.visible = false
  local full = mode == "new" and #data.lists >= MAX_LISTS
  if full then
    local note = inner.add{type = "label", caption = {"resbal.chain-full"}}
    note.style.font_color = {1, 0.4, 0.4}
  end

  if mode == "edit" then
    -- видалення — окремо від «Зберегти», червоне, у два кліки (другий — підтвердження)
    local delete = inner.add{type = "button", name = "resbal_list_delete", style = "red_button",
                             caption = {"resbal.list-delete-button"}, tooltip = {"resbal.list-delete"}}
    delete.style.top_margin = 8
    delete.enabled = #data.lists > 1
  end

  local buttons = frame.add{type = "flow", direction = "horizontal", style = "dialog_buttons_horizontal_flow"}
  buttons.add{type = "button", name = "resbal_list_close", style = "back_button", caption = {"resbal.list-cancel"}}
  local filler = buttons.add{type = "empty-widget", style = "draggable_space", ignored_by_interaction = true}
  filler.style.horizontally_stretchable = true
  filler.style.height = 32
  local confirm_button = buttons.add{type = "button", name = "resbal_list_confirm", style = "confirm_button",
                                     caption = mode == "edit" and {"resbal.list-save"} or {"resbal.list-create"}}
  confirm_button.enabled = not full
end

local function confirm(player)
  local frame = dialog(player)
  if not frame then return end
  local tags = frame.tags
  local data = ctx.player_data(player)
  local list = data.lists[tags.list]
  local fields = frame.inner.fields
  local name = clean_name(fields.resbal_list_name.text)
  if tags.mode == "new" then
    if #data.lists >= MAX_LISTS then return end
    local text = fields.resbal_list_text.text or ""
    if text:gsub("%s", "") ~= "" then
      local imported, skipped = import_string(text)
      if not imported then
        frame.inner.resbal_list_error.visible = true -- лишаємо вікно відкритим, щоб виправити рядок
        return
      end
      if name then imported.name = name end -- назва з поля важливіша за назву з рядка
      data.lists[#data.lists + 1] = imported
      player.create_local_flying_text{text = {"resbal.list-imported", #imported.entries, skipped}, create_at_cursor = true}
    else
      data.lists[#data.lists + 1] = {name = name, entries = {}}
    end
    data.active = #data.lists
  elseif list then
    list.name = name
  end
  frame.destroy()
  M.normalize(data)
  ctx.build(player)
  ctx.after_change(player)
end

-- «Видалити список»: перший клік — підтвердження на самій кнопці, другий — видалення
local function delete_list(player, button)
  local frame = dialog(player)
  if not frame then return end
  local tags = frame.tags
  local data = ctx.player_data(player)
  local list = data.lists[tags.list]
  if not list or #data.lists <= 1 then return end
  if not tags.sure then
    tags.sure = true
    frame.tags = tags
    button.caption = {"resbal.list-delete-sure", #list.entries}
    return
  end
  table.remove(data.lists, tags.list)
  if data.active >= tags.list then data.active = data.active - 1 end
  frame.destroy()
  M.normalize(data)
  ctx.build(player)
  ctx.after_change(player)
end

-- ---------- «+» з «Дефіциту»: вікно вибору списку (як список назв у вікні залізничної станції) ----------
-- Кожен список — рядок; де ресурс уже є — неактивний із галочкою, куди можна — клік додає. Вікно не
-- закривається: можна додати в кілька списків одразу.
local function pin_frame(player)
  return player.gui.screen.resbal_pin_dialog
end

local function has_entry(list, resource)
  for _, entry in ipairs(list.entries) do
    if entry.type == resource.type and entry.name == resource.name and entry.surface == resource.surface then return true end
  end
  return false
end

local function fill_pin(player, frame)
  local data = ctx.player_data(player)
  local resource = frame.tags.resource
  local rows = frame.inner.resbal_pin_rows
  rows.clear()
  for i, list in ipairs(data.lists) do
    local present = has_entry(list, resource)
    local button = rows.add{type = "button", name = "resbal_list_pin_" .. i, style = "list_box_item",
                            caption = {"", present and "[img=utility/check_mark_green] " or "",
                                       M.caption(list), " (" .. #list.entries .. ")"},
                            tooltip = present and {"resbal.pin-present"} or {"resbal.pin-add"}}
    button.style.horizontally_stretchable = true
    button.enabled = not present
  end
end

function M.open_pin(player, resource)
  local old = pin_frame(player)
  if old then old.destroy() end
  local frame = player.gui.screen.add{type = "frame", name = "resbal_pin_dialog", direction = "vertical",
                                      tags = {resource = resource}}
  frame.auto_center = true
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  local proto = (resource.type == "fluid" and prototypes.fluid or prototypes.item)[resource.name]
  titlebar.add{type = "label", style = "frame_title", ignored_by_interaction = true,
               caption = {"resbal.pin-title", "[" .. resource.type .. "=" .. resource.name .. "]",
                          proto and proto.localised_name or resource.name}}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_list_pin_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}
  local inner = frame.add{type = "frame", name = "inner", direction = "vertical", style = "inside_deep_frame"}
  local rows = inner.add{type = "scroll-pane", name = "resbal_pin_rows"}
  rows.style.minimal_width = 320
  rows.style.maximal_height = 420
  rows.style.vertically_stretchable = false
  fill_pin(player, frame)
end

-- Обробка кліку; повертає true, якщо клік був по елементу списків
function M.on_click(player, element)
  local name = element.name
  if name:sub(1, 12) ~= "resbal_list_" then return false end
  local pin_index = tonumber(name:match("^resbal_list_pin_(%d+)$"))
  if pin_index then
    local frame = pin_frame(player)
    local data = ctx.player_data(player)
    local list = frame and data.lists[pin_index]
    if list then
      local resource = frame.tags.resource
      if not has_entry(list, resource) then
        list.entries[#list.entries + 1] = {type = resource.type, name = resource.name, surface = resource.surface}
        player.create_local_flying_text{text = {"resbal.pinned-to", M.caption(list)}, create_at_cursor = true}
      end
      fill_pin(player, frame)
      ctx.build(player) -- лічильники ресурсів на вкладках
    end
    return true
  elseif name == "resbal_list_pin_close" then
    local frame = pin_frame(player)
    if frame then frame.destroy() end
    return true
  end
  if name == "resbal_list_new" then
    open_dialog(player, "new")
  elseif name == "resbal_list_deficit" then
    local data = ctx.player_data(player)
    data.negative_only, data.sort_key = true, nil
    ctx.build(player)
  elseif name == "resbal_list_edit" then
    open_dialog(player, "edit")
  elseif name == "resbal_list_delete" then
    delete_list(player, element)
  elseif name == "resbal_list_select" then
    local frame = dialog(player)
    local box = frame and frame.inner.fields.children[4].resbal_list_text
    if box then
      box.focus()
      box.select_all()
    end
  elseif name == "resbal_list_close" then
    close_dialog(player)
  elseif name == "resbal_list_confirm" then
    confirm(player)
  elseif name == "resbal_list_text" or name == "resbal_list_name" then
    return true -- клік у поле — нічого
  else
    local index = tonumber(name:match("^resbal_list_(%d+)$"))
    if not index then return false end
    local data = ctx.player_data(player)
    data.active = index
    if data.negative_only then data.negative_only, data.sort_key = nil, nil end -- з «Дефіциту» на список
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
