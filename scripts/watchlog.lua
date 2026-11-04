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

local function dialog(player)
  return player.gui.screen.resbal_watchlog
end

local fill -- оголошено нижче

local function refresh(player, data)
  local frame = dialog(player)
  if frame then fill(frame, data) end
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

local function close_dialog(player)
  local frame = dialog(player)
  if frame then frame.destroy() end
end

local COLUMNS = 7

function fill(frame, data)
  local tbl = frame.inner.scroll.resbal_watchlog_table
  tbl.clear()
  for _, caption in ipairs({"watchlog-col-start", "watchlog-col-resource", "watchlog-col-where", "watchlog-col-duration",
                            "watchlog-col-produced", "watchlog-col-balance", "watchlog-col-end"}) do
    tbl.add{type = "label", caption = {"resbal." .. caption}, style = "bold_label"}
  end
  local log = log_of(data)
  if #log == 0 then
    local empty = tbl.add{type = "label", caption = {"resbal.watchlog-empty"}}
    empty.style.font_color = {0.7, 0.7, 0.7}
    for _ = 2, COLUMNS do tbl.add{type = "empty-widget"} end
    return
  end
  for i = #log, 1, -1 do -- новіші зверху
    local record = log[i]
    local start = tbl.add{type = "label", caption = ctx.ago_caption((game.tick - record.start) / 60)}
    start.style.font_color = {0.7, 0.7, 0.7}
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

local function open_dialog(player)
  close_dialog(player)
  local frame = player.gui.screen.add{type = "frame", name = "resbal_watchlog", direction = "vertical"}
  frame.auto_center = true
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", style = "frame_title", caption = {"resbal.watchlog-title"}, ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_watchlog_clear", sprite = "utility/trash", style = "frame_action_button",
               tooltip = {"resbal.watchlog-clear"}}
  titlebar.add{type = "sprite-button", name = "resbal_watchlog_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical", style = "inside_shallow_frame_with_padding"}
  local hint = inner.add{type = "label", caption = {"resbal.watchlog-hint", MAX_RECORDS}}
  hint.style.single_line = false
  hint.style.maximal_width = 760
  hint.style.font_color = {0.7, 0.7, 0.7}
  local scroll = inner.add{type = "scroll-pane", name = "scroll"}
  scroll.style.maximal_height = 420
  scroll.style.top_margin = 8
  local tbl = scroll.add{type = "table", name = "resbal_watchlog_table", column_count = COLUMNS,
                         draw_horizontal_line_after_headers = true}
  tbl.style.horizontal_spacing = 14
  tbl.style.vertical_spacing = 4
  fill(frame, ctx.player_data(player))
end

function M.add_button(parent)
  local button = parent.add{type = "button", name = "resbal_watchlog_open", caption = {"resbal.watchlog"},
                            tooltip = {"resbal.watchlog-tooltip"}}
  button.style.left_margin = 4
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_watchlog_open" then
    if dialog(player) then close_dialog(player) else open_dialog(player) end
  elseif name == "resbal_watchlog_close" then
    close_dialog(player)
  elseif name == "resbal_watchlog_clear" then
    -- очищаємо завершені; відкриті порушення лишаються (на них посилається сторож)
    local data = ctx.player_data(player)
    local log = log_of(data)
    for i = #log, 1, -1 do
      if log[i].finish then table.remove(log, i) end
    end
    refresh(player, data)
  else
    return false
  end
  return true
end

return M
