-- Вкладка «Сторож» вікна ресурсу (редизайн 1.7: замість окремого діалогу).
-- Стан сторожа й дії (відкласти, видалити), пороги з поточними значеннями поруч, ціль випуску, вікно
-- усереднення, а знизу — спрацювання саме цього ресурсу з журналу. Сторож — лише для ресурсів зі списку.
local M = {}

-- Залежності з control.lua: player_data, prototype_of, ALL_SURFACES, DEFAULT_WATCH_WINDOW, WATCH_WINDOWS,
-- SNOOZE_MINUTES, snooze_left(watch), format_number, format_balance, ago_caption(seconds),
-- duration_caption(seconds), focused(player) — ресурс у фокусі вікна, current(player, entry, window) —
-- середні вироблено/спожито за вікно, after_change(player) — оновити панель і перевірити сторожів,
-- rebuild(player) — перебудувати вікно ресурсу, marks, watchlog, lists
local ctx

function M.init(context)
  ctx = context
end

local LOG_LINES = 10 -- спрацювань ресурсу у вкладці

-- Запис ресурсу: спершу у відкритому списку, інакше в будь-якому — і номер списку
local function find_entry(data, resource)
  local function search(index)
    for _, entry in ipairs(data.lists[index].entries) do
      if entry.type == resource.type and entry.name == resource.name and entry.surface == resource.surface then
        return entry
      end
    end
  end
  local entry = search(data.active)
  if entry then return entry, data.active end
  for index in ipairs(data.lists) do
    entry = search(index)
    if entry then return entry, index end
  end
  return nil
end

local function container(player)
  local inner = ctx.big_inner(player)
  return inner and inner.resbal_watch
end

-- Запис за тегами вкладки (ресурс + номер списку)
local function tagged_entry(player)
  local box = container(player)
  if not box then return nil end
  local tags = box.tags
  local data = ctx.player_data(player)
  local list = data.lists[tags.list]
  for _, entry in ipairs(list and list.entries or {}) do
    if entry.type == tags.type and entry.name == tags.name and entry.surface == tags.surface then return entry, box end
  end
  return nil, box
end

local function state_caption(watch, list)
  if not watch then return {"resbal.watchtab-none"}, "utility/status_inactive" end
  if list.watch_paused then return {"resbal.watchtab-paused"}, "utility/status_inactive" end
  local snoozed = ctx.snooze_left(watch)
  if snoozed then return {"resbal.watchtab-snoozed", snoozed}, "utility/status_inactive" end
  if watch.violated then return {"resbal.watchtab-violated"}, "utility/status_not_working" end
  return {"resbal.watchtab-on"}, "utility/status_working"
end

function M.build_tab(inner, player)
  local data = ctx.player_data(player)
  local resource = ctx.focused(player)
  local entry, list_index = find_entry(data, resource)
  if not entry then
    -- сторож — лише для ресурсів зі списку
    local text = inner.add{type = "label", caption = {"resbal.watchtab-not-in-list"}, style = "resbal_cause_label"}
    text.style.minimal_width = 600
    local add = inner.add{type = "button", name = "resbal_watchtab_pin", caption = {"resbal.pin"}}
    add.style.top_margin = 8
    return
  end
  local list = data.lists[list_index]
  local watch = entry.watch or {}
  local window = watch.window or ctx.DEFAULT_WATCH_WINDOW
  local box = inner.add{type = "flow", name = "resbal_watch", direction = "vertical",
                        tags = {type = entry.type, name = entry.name, surface = entry.surface, list = list_index,
                                window = window}}
  box.style.vertical_spacing = 8
  box.style.minimal_width = 640

  -- стан і дії: «Відкласти» і червоне «Видалити сторожа» — тут, окремо від «Зберегти»
  local head = box.add{type = "flow", direction = "horizontal"}
  head.style.vertical_align = "center"
  head.style.horizontal_spacing = 8
  local caption, icon = state_caption(entry.watch, list)
  head.add{type = "label", caption = {"", "[img=" .. icon .. "] ", caption}, style = "bold_label"}
  if list_index ~= data.active then
    head.add{type = "label", caption = {"resbal.watchtab-list", ctx.lists.caption(list)}, style = "resbal_quiet_label"}
  end
  head.add{type = "empty-widget"}.style.horizontally_stretchable = true
  local snoozed = ctx.snooze_left(entry.watch)
  local snooze = head.add{type = "button", name = "resbal_watch_snooze",
                          caption = snoozed and {"resbal.watch-unsnooze", snoozed} or {"resbal.watch-snooze", ctx.SNOOZE_MINUTES},
                          tooltip = {"resbal.watch-snooze-tooltip", ctx.SNOOZE_MINUTES}}
  snooze.enabled = entry.watch ~= nil
  local remove = head.add{type = "button", name = "resbal_watch_remove", caption = {"resbal.watch-remove"},
                          style = "red_button"}
  remove.enabled = entry.watch ~= nil

  -- пороги: поле + «зараз …» (середнє за обране вікно) як орієнтир
  local card = box.add{type = "frame", name = "inner", direction = "vertical", style = "bordered_frame",
                       caption = {"resbal.watchtab-thresholds"}}
  card.style.horizontally_stretchable = true
  local fields = card.add{type = "table", name = "fields", column_count = 3}
  fields.style.horizontal_spacing = 12
  fields.style.vertical_spacing = 8
  local produced, consumed = ctx.current(player, entry, window)
  local function field(name, label, tooltip, value, negative, now)
    fields.add{type = "label", caption = label, tooltip = tooltip}
    local input = fields.add{type = "textfield", name = name, text = value and tostring(value) or "", tooltip = tooltip,
                             numeric = true, allow_decimal = true, allow_negative = negative}
    input.style.width = 110
    fields.add{type = "label", caption = now or "", style = "resbal_quiet_label"}
  end
  field("resbal_watch_prod", {"resbal.watch-min-produced"}, {"resbal.watch-min-produced-tooltip"}, watch.min_produced, false,
        {"resbal.watchtab-now", ctx.format_number(produced), window})
  field("resbal_watch_bal", {"resbal.watch-min-balance"}, {"resbal.watch-min-balance-tooltip"}, watch.min_balance, true,
        {"resbal.watchtab-now", ctx.format_balance(produced - consumed), window})
  field("resbal_watch_target", {"resbal.target"}, {"resbal.target-field-tooltip"}, entry.target, false, nil)

  local windows = card.add{type = "flow", name = "windows", direction = "horizontal"}
  windows.style.top_margin = 4
  windows.style.vertical_align = "center"
  windows.add{type = "label", caption = {"resbal.watch-window"}, tooltip = {"resbal.watch-window-tooltip"}}
  for _, minutes in ipairs(ctx.WATCH_WINDOWS) do
    local button = windows.add{type = "button", name = "resbal_watch_win_" .. minutes, style = "resbal_period_button",
                               caption = {"resbal.watch-minutes", minutes}, tooltip = {"resbal.watch-window-tooltip"}}
    button.toggled = minutes == window
  end
  local foot = card.add{type = "flow", direction = "horizontal"}
  foot.style.vertical_align = "center"
  foot.style.top_margin = 4
  local hint = foot.add{type = "label", caption = {"resbal.watch-hint"}, style = "resbal_quiet_label"}
  hint.style.single_line = false
  hint.style.maximal_width = 440
  foot.add{type = "empty-widget"}.style.horizontally_stretchable = true
  foot.add{type = "button", name = "resbal_watch_save", style = "confirm_button",
           caption = entry.watch and {"resbal.watch-save"} or {"resbal.watchtab-create"}}

  -- спрацювання цього ресурсу (з журналу сторожа)
  box.add{type = "label", caption = {"resbal.watchtab-log"}, style = "bold_label"}
  local records = ctx.watchlog.records_for(player, entry, LOG_LINES)
  if #records == 0 then
    box.add{type = "label", caption = {"resbal.watchlog-empty"}, style = "resbal_quiet_label"}
  else
    local tbl = box.add{type = "table", column_count = 5}
    tbl.style.horizontal_spacing = 16
    for _, record in ipairs(records) do
      tbl.add{type = "label", caption = ctx.ago_caption((game.tick - record.start) / 60), style = "resbal_quiet_label"}
      tbl.add{type = "label", caption = record.finish and ctx.duration_caption((record.finish - record.start) / 60)
                                         or {"resbal.watchlog-ongoing", ctx.duration_caption((game.tick - record.start) / 60)}}
      tbl.add{type = "label", caption = {"resbal.watchtab-min-produced", ctx.format_number(record.min_produced or 0)}}
      tbl.add{type = "label", caption = {"resbal.watchtab-min-balance", ctx.format_balance(record.min_balance or 0)}}
      tbl.add{type = "label", caption = record.finish and {"resbal.watchlog-how-" .. (record.how or "recover")} or "",
              style = "resbal_quiet_label"}
    end
  end
end

local function done(player)
  ctx.after_change(player)
  ctx.rebuild(player)
end

-- «Відкласти на 30 хв» / скасувати відкладення
local function toggle_snooze(player)
  local entry = tagged_entry(player)
  if entry and entry.watch then
    entry.watch.snooze_until = (not ctx.snooze_left(entry.watch)) and (game.tick + ctx.SNOOZE_MINUTES * 3600) or nil
  end
  done(player)
end

local function set_window(player, minutes)
  local box = container(player)
  if not box then return end
  local tags = box.tags
  tags.window = minutes
  box.tags = tags
  for _, button in pairs(box.inner.windows.children) do
    if button.type == "button" then button.toggled = button.name == "resbal_watch_win_" .. minutes end
  end
end

-- remove = true: прибрати сторожа; інакше зберегти введене (обидва поля порогів порожні — теж прибрати)
local function save(player, remove)
  local entry, box = tagged_entry(player)
  if not entry then return end
  local tags = box.tags
  local fields = box.inner.fields
  local produced = tonumber(fields.resbal_watch_prod.text)
  produced = produced and math.max(0, produced)
  local balance = tonumber(fields.resbal_watch_bal.text)
  local old = entry.watch
  local same = old and not remove and old.min_produced == produced and old.min_balance == balance
               and (old.window or ctx.DEFAULT_WATCH_WINDOW) == tags.window
  if old and old.violated and not same then -- поріг змінили чи видалили посеред порушення
    ctx.marks.add_auto(player, entry, "changed", {since = old.violated_since})
    ctx.watchlog.close(player, old.log_id, "changed")
  end
  if remove or (produced == nil and balance == nil) then
    entry.watch = nil
  elseif not same then -- пороги ті самі — сторож лишається як є (стан порушення, журнал, відкладення)
    entry.watch = {min_produced = produced, min_balance = balance, window = tags.window,
                   snooze_until = old and old.snooze_until}
  end
  -- ціль випуску — окремо від сторожа (кнопка «Видалити сторожа» її не чіпає)
  if not remove then
    local target = tonumber(fields.resbal_watch_target.text)
    entry.target = (target and target > 0) and target or nil
  end
  done(player)
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_watch_snooze" then
    toggle_snooze(player)
  elseif name == "resbal_watch_save" or name == "resbal_watch_remove" then
    save(player, name == "resbal_watch_remove")
  elseif name:find("^resbal_watch_win_") then
    set_window(player, tonumber(name:match("%d+$")))
  elseif name == "resbal_watchtab_pin" then
    ctx.lists.open_pin(player, ctx.focused(player))
  else
    return false
  end
  return true
end

-- Enter у полі — зберегти
function M.on_confirmed(player, element)
  local name = element.name
  if name ~= "resbal_watch_prod" and name ~= "resbal_watch_bal" and name ~= "resbal_watch_target" then return false end
  save(player)
  return true
end

return M
