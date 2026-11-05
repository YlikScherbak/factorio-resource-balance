-- Вкладка «Простої» (вікно «Діагностика фабрики»): рецепти поточної планети, що найбільше стоять (за фоновою історією станів машин).
-- Сортування — за втраченим машино-часом (частка простою × машин). Окремо — чи шкодить простій: баланс
-- головного продукту (червоний — продукту бракує; звичайний — вистачає, машина просто чекає попиту).
local M = {}

-- Залежності з control.lua: machines (модуль), format_balance, player_data, diag_inner(player, tab),
-- balance(player, type, name, surface_name, precision_name) → баланс/хв або nil
local ctx

function M.init(context)
  ctx = context
end

local WINDOWS = {5, 10, 30}                -- хв
local PRECISION = {[5] = "ten_minutes", [10] = "ten_minutes", [30] = "one_hour"} -- для балансу продукту
local TOP = 50
local WORKING_HIDE = 0.95                  -- рецепти, що працювали від 95% часу, не показуємо
local REASONS = {"no_input", "full_output", "power", "other"}
local SPRITES = {no_input = "utility/status_yellow", full_output = "utility/status_blue",
                 power = "utility/status_not_working", other = "utility/status_inactive"}
local COLUMNS = 6

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

-- Вміст вкладки «Простої» вікна «Діагностика фабрики» (редизайн 1.7), якщо вона відкрита
local function container(player)
  return ctx.diag_inner(player, "idle")
end

-- Головний продукт рецепта: тип, назва або nil
local function main_product(recipe_name)
  local recipe = prototypes.recipe[recipe_name]
  if not recipe then return nil end
  local product = recipe.main_product or recipe.products[1]
  if product and (product.type == "item" or product.type == "fluid") then return product.type, product.name end
  return nil
end

local function percent(share)
  return string.format("%.0f%%", (share or 0) * 100)
end

local function fill(player, inner)
  local data = ctx.player_data(player)
  local window = data.idle_window or 10
  local head = inner.resbal_idle_head
  for _, minutes in ipairs(WINDOWS) do
    head["resbal_idle_win_" .. minutes].toggled = minutes == window
  end
  local tbl = inner.resbal_idle_scroll.resbal_idle_table
  tbl.clear()
  for _, caption in ipairs({"idle-col-recipe", "idle-col-lost", "idle-col-machines", "idle-col-working", "idle-col-reason",
                            "idle-col-product"}) do
    tbl.add{type = "label", caption = {"resbal." .. caption}, style = "resbal_quiet_label"}
  end

  local empty = inner.resbal_idle_empty
  tbl.visible, empty.visible = true, false
  local function message(caption)
    tbl.visible, empty.visible = false, true
    empty.resbal_empty_text.caption = caption
  end
  if not ctx.machines.enabled() then
    head.resbal_idle_history.caption = ""
    return message({"resbal.history-off"})
  end

  local surface = player.surface
  local list, span = ctx.machines.summary(player.force.index, {surface.index}, window, game.tick)
  head.resbal_idle_history.caption = {"resbal.idle-history", string.format("%.1f", math.max(span, 0) / 3600), window}
  local rows = {}
  for _, row in ipairs(list) do
    local working = row.shares.working or 0
    if working < WORKING_HIDE then
      row.lost = (1 - working) * row.machines
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b)
    if a.lost == b.lost then return a.recipe < b.recipe end
    return a.lost > b.lost
  end)
  if #list == 0 then return message({"resbal.history-collecting"}) end
  if #rows == 0 then return message({"resbal.idle-none"}) end

  local most = rows[1].lost
  for i = 1, math.min(TOP, #rows) do
    local row = rows[i]
    local recipe = prototypes.recipe[row.recipe]
    local product_type, product_name = main_product(row.recipe)
    local name = tbl.add{type = "button", style = "resbal_status_button",
                         caption = {"", "[img=recipe/" .. row.recipe .. "] ", recipe and recipe.localised_name or row.recipe},
                         tooltip = product_type and {"resbal.idle-recipe-tooltip"} or nil}
    name.style.maximal_width = 320
    if product_type then
      name.tags = {resbal_chart = {type = product_type, name = product_name, surface = surface.name}}
    end
    -- «Простій»: втрачений машино-час відносно першого рядка — порядок видно без читання чисел
    local lost = tbl.add{type = "progressbar", value = most > 0 and row.lost / most or 0,
                         tooltip = {"resbal.idle-lost-tooltip", string.format("%.1f", row.lost)}}
    lost.style.width = 90
    lost.style.color = {1, 0.6, 0.2}
    local machines = tbl.add{type = "label", caption = string.format("%.1f", row.machines)}
    machines.style.horizontal_align = "right"
    machines.style.minimal_width = 50
    local working = tbl.add{type = "label", caption = percent(row.shares.working)}
    working.style.horizontal_align = "right"
    working.style.minimal_width = 60
    -- головна причина простою
    local reason, reason_share = nil, 0
    for _, group in ipairs(REASONS) do
      if (row.shares[group] or 0) > reason_share then reason, reason_share = group, row.shares[group] end
    end
    tbl.add{type = "label", caption = reason and {"", "[img=" .. SPRITES[reason] .. "] ",
                                                  {"resbal.history-" .. reason, string.format("%.0f", reason_share * 100)}}
                                      or ""}
    -- чи шкодить: баланс головного продукту (червоний — бракує; інакше звичайний колір)
    local balance = product_type and ctx.balance(player, product_type, product_name, surface.name, PRECISION[window])
    local product = tbl.add{type = "label",
                            caption = balance and {"", "[" .. product_type .. "=" .. product_name .. "] ",
                                                   ctx.format_balance(balance)} or "—",
                            tooltip = balance and (balance < 0 and {"resbal.idle-product-short"}
                                                   or {"resbal.idle-product-ok"}) or nil}
    if balance and balance < 0 then product.style.font_color = {1, 0.45, 0.4} end
  end
end

-- Вкладка «Простої»: вибір вікна, скільки історії зібрано, пояснення — у підказці (i)
function M.build_into(inner, player)
  local head = inner.add{type = "flow", name = "resbal_idle_head", direction = "horizontal"}
  head.style.vertical_align = "center"
  head.style.horizontal_spacing = 4
  head.add{type = "label", caption = {"resbal.idle-window"}}
  for _, minutes in ipairs(WINDOWS) do
    head.add{type = "button", name = "resbal_idle_win_" .. minutes, caption = {"resbal.idle-minutes", minutes},
             style = "resbal_period_button"}
  end
  local history = head.add{type = "label", name = "resbal_idle_history", caption = "", style = "resbal_quiet_label"}
  history.style.left_margin = 12
  head.add{type = "empty-widget"}.style.horizontally_stretchable = true
  local tip = head.add{type = "sprite", sprite = "utility/tip_icon", tooltip = {"resbal.idle-info"}}
  tip.style.size = 16
  tip.style.stretch_image_to_widget_size = true
  empty_state(inner, "resbal_idle_empty")
  local scroll = inner.add{type = "scroll-pane", name = "resbal_idle_scroll"}
  scroll.style.maximal_height = 520
  scroll.style.minimal_width = 860
  scroll.style.top_margin = 6
  local tbl = scroll.add{type = "table", name = "resbal_idle_table", column_count = COLUMNS,
                         draw_horizontal_line_after_headers = true}
  tbl.style.horizontal_spacing = 16
  tbl.style.vertical_spacing = 2
  fill(player, inner)
end

function M.on_click(player, element)
  local name = element.name
  if not name:find("^resbal_idle_win_") then return false end
  ctx.player_data(player).idle_window = tonumber(name:match("%d+$"))
  local inner = container(player)
  if inner then fill(player, inner) end
  return true
end

-- Раз на 10 с: оновити відкриті вкладки «Простої»
function M.refresh()
  for _, player in pairs(game.connected_players) do
    local inner = container(player)
    if inner then fill(player, inner) end
  end
end

return M
