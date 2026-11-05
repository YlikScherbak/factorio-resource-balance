-- Журнал сторожа: «що сталося, поки я займався іншою частиною фабрики».
-- Кожне спрацювання — запис: ресурс, планета, список, початок, кінець (або «триває»), тривалість,
-- мінімальний випуск і баланс за час порушення, умова, як закінчилось. Окремо для кожного гравця.
--   data.watch_log = {{id, type, name, surface, list = локалізована назва, start, finish?, how?,
--                      reasons, min_produced, min_balance}, ...} (від старих до нових)
--   data.watch_log_next = наступний id; entry.watch.log_id — відкритий запис цього ресурсу
local M = {}

local MAX_RECORDS = 100

-- Залежності з control.lua: player_data, format_number, format_balance, ago_caption(seconds),
-- duration_caption(seconds), where(record) — планета або «усі планети»
local ctx

function M.init(context)
  ctx = context
end

local function log_of(data)
  data.watch_log = data.watch_log or {}
  return data.watch_log
end

local function find(data, id)
  if not id then return nil end
  local log = log_of(data)
  for i = #log, 1, -1 do
    if log[i].id == id then return log[i] end
  end
  return nil
end

-- Лишає не більше MAX_RECORDS записів: видаляє найстаріші завершені (відкриті не чіпаємо)
local function prune(log)
  local i = 1
  while #log > MAX_RECORDS and i <= #log do
    if log[i].finish then table.remove(log, i) else i = i + 1 end
  end
end

-- Вміст вкладки «Журнал сторожа» вікна «Діагностика фабрики» (редизайн 1.7), якщо вона відкрита
local function container(player)
  return ctx.diag_inner(player, "log")
end

local fill -- оголошено нижче

local function refresh(player, data)
  local inner = container(player)
  if inner then fill(inner, data) end
end

-- Нове порушення; повертає id запису (зберігається в entry.watch.log_id)
function M.open(player, entry, list_caption, reasons, produced, balance)
  local data = ctx.player_data(player)
  local log = log_of(data)
  local id = data.watch_log_next or 1
  data.watch_log_next = id + 1
  log[#log + 1] = {id = id, type = entry.type, name = entry.name, surface = entry.surface, list = list_caption,
                   start = game.tick, reasons = reasons, min_produced = produced, min_balance = balance}
  prune(log)
  refresh(player, data)
  return id
end

-- Порушення триває: оновити мінімуми (без перемальовування діалогу — він показує їх при відкритті й подіях)
function M.update(player, id, produced, balance)
  local record = find(ctx.player_data(player), id)
  if not record or record.finish then return end
  if produced < record.min_produced then record.min_produced = produced end
  if balance < record.min_balance then record.min_balance = balance end
end

-- Кінець порушення: how = "recover" | "pause" | "snooze" | "changed"
function M.close(player, id, how)
  local data = ctx.player_data(player)
  local record = find(data, id)
  if not record or record.finish then return end
  record.finish, record.how = game.tick, how
  refresh(player, data)
end

-- Записи одного ресурсу (для вкладки «Сторож»), новіші першими, не більше limit
function M.records_for(player, resource, limit)
  local result = {}
  local log = log_of(ctx.player_data(player))
  for i = #log, 1, -1 do
    local record = log[i]
    if record.type == resource.type and record.name == resource.name and record.surface == resource.surface then
      result[#result + 1] = record
      if #result >= limit then break end
    end
  end
  return result
end

-- Відкриті записи, на які вже не посилається жоден сторож (ресурс чи вкладку видалили), закриваються
-- як «прибрано». active — {[log_id] = true} з усіх списків гравця.
function M.close_orphans(player, active)
  local data = ctx.player_data(player)
  local closed = false
  for _, record in ipairs(log_of(data)) do
    if not record.finish and not active[record.id] then
      record.finish, record.how = game.tick, "removed"
      closed = true
    end
  end
  if closed then refresh(player, data) end
end

local COLUMNS = 7

-- Порожній стан (один вигляд у всьому моді): сірий напис по центру замість порожньої таблиці
local function empty_state(parent, name)
  local box = parent.add{type = "flow", name = name, direction = "vertical"}
  box.style.horizontal_align = "center"
  box.style.horizontally_stretchable = true
  box.style.top_padding, box.style.bottom_padding = 24, 24
  box.add{type = "label", name = "resbal_empty_text", caption = "", style = "resbal_quiet_label"}
  box.visible = false
  return box
end

function fill(inner, data)
  local tbl = inner.resbal_log_scroll.resbal_watchlog_table
  tbl.clear()
  for _, caption in ipairs({"watchlog-col-start", "watchlog-col-resource", "watchlog-col-where", "watchlog-col-duration",
                            "watchlog-col-produced", "watchlog-col-balance", "watchlog-col-end"}) do
    tbl.add{type = "label", caption = {"resbal." .. caption}, style = "resbal_quiet_label"}
  end
  local log = log_of(data)
  local ongoing = 0
  for _, record in ipairs(log) do
    if not record.finish then ongoing = ongoing + 1 end
  end
  inner.resbal_log_head.resbal_log_counts.caption = {"resbal.watchlog-counts", #log, ongoing}
  local empty = inner.resbal_log_empty
  tbl.visible = #log > 0
  empty.visible = #log == 0
  if #log == 0 then
    empty.resbal_empty_text.caption = {"resbal.watchlog-empty"}
    return
  end
  for i = #log, 1, -1 do -- новіші зверху
    local record = log[i]
    tbl.add{type = "label", caption = ctx.ago_caption((game.tick - record.start) / 60), style = "resbal_quiet_label"}
    local proto = (record.type == "fluid" and prototypes.fluid or prototypes.item)[record.name]
    local icon = "[" .. record.type .. "=" .. record.name .. "] "
    local resource = tbl.add{type = "button", style = "resbal_status_button",
                             caption = {"", icon, proto and proto.localised_name or record.name},
                             tooltip = {"resbal.watchlog-resource-tooltip", record.reasons or "", record.list or ""}}
    if proto then
      resource.tags = {resbal_chart = {type = record.type, name = record.name, surface = record.surface}}
    end
    resource.style.maximal_width = 260
    tbl.add{type = "label", caption = ctx.where(record)}
    local duration = tbl.add{type = "label",
                             caption = record.finish and ctx.duration_caption((record.finish - record.start) / 60)
                                       or {"resbal.watchlog-ongoing", ctx.duration_caption((game.tick - record.start) / 60)}}
    if not record.finish then duration.style.font_color = {1, 0.6, 0.2} end
    local produced = tbl.add{type = "label", caption = ctx.format_number(record.min_produced or 0)}
    produced.style.horizontal_align = "right"
    produced.style.minimal_width = 60
    local balance = tbl.add{type = "label", caption = ctx.format_balance(record.min_balance or 0)}
    balance.style.horizontal_align = "right"
    balance.style.minimal_width = 60
    local ending = tbl.add{type = "label", caption = record.finish and {"resbal.watchlog-how-" .. (record.how or "recover")} or ""}
    if record.how == "recover" then ending.style.font_color = {0.45, 0.9, 0.45} end
  end
end

-- Вкладка «Журнал сторожа»: лічильники, пояснення в підказці (i), «Очистити» — тут, подалі від ✕ вікна
function M.build_into(inner, player)
  local head = inner.add{type = "flow", name = "resbal_log_head", direction = "horizontal"}
  head.style.vertical_align = "center"
  head.style.horizontal_spacing = 8
  head.add{type = "label", name = "resbal_log_counts", caption = "", style = "resbal_quiet_label"}
  head.add{type = "empty-widget"}.style.horizontally_stretchable = true
  local tip = head.add{type = "sprite", sprite = "utility/tip_icon", tooltip = {"resbal.watchlog-hint", MAX_RECORDS}}
  tip.style.size = 16
  tip.style.stretch_image_to_widget_size = true
  head.add{type = "sprite-button", name = "resbal_watchlog_clear", sprite = "utility/trash", style = "tool_button_red",
           tooltip = {"resbal.watchlog-clear"}}
  empty_state(inner, "resbal_log_empty")
  local scroll = inner.add{type = "scroll-pane", name = "resbal_log_scroll"}
  scroll.style.maximal_height = 520
  scroll.style.minimal_width = 820
  scroll.style.top_margin = 6
  local tbl = scroll.add{type = "table", name = "resbal_watchlog_table", column_count = COLUMNS,
                         draw_horizontal_line_after_headers = true}
  tbl.style.horizontal_spacing = 14
  tbl.style.vertical_spacing = 4
  fill(inner, ctx.player_data(player))
end

function M.on_click(player, element)
  if element.name ~= "resbal_watchlog_clear" then return false end
  -- очищаємо завершені; відкриті порушення лишаються (на них посилається сторож)
  local data = ctx.player_data(player)
  local log = log_of(data)
  for i = #log, 1, -1 do
    if log[i].finish then table.remove(log, i) end
  end
  refresh(player, data)
  return true
end

return M
