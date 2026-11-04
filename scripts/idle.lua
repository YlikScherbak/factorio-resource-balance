-- Вікно «Простої фабрики»: рецепти поточної планети, що найбільше стоять (за фоновою історією станів машин).
-- Сортування — за втраченим машино-часом (частка простою × машин). Окремо — чи шкодить простій: баланс
-- головного продукту (червоний — продукту бракує; сірий — вистачає, машина просто чекає попиту).
local M = {}

-- Залежності з control.lua: machines (модуль), format_balance, surface_caption(surface, name),
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
local COLUMNS = 5

local function frame_of(player)
  return player.gui.screen.resbal_idle
end

local function close(player)
  local frame = frame_of(player)
  if frame then frame.destroy() end
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

local function fill(player, frame)
  local window = frame.tags.window or 10
  for _, minutes in ipairs(WINDOWS) do
    local button = frame.inner.windows["resbal_idle_win_" .. minutes]
    if button then button.toggled = minutes == window end
  end
  local tbl = frame.inner.scroll.resbal_idle_table
  tbl.clear()
  for _, caption in ipairs({"idle-col-recipe", "idle-col-machines", "idle-col-working", "idle-col-reason",
                            "idle-col-product"}) do
    tbl.add{type = "label", caption = {"resbal." .. caption}, style = "bold_label"}
  end

  local function message(caption)
    local label = tbl.add{type = "label", caption = caption}
    label.style.font_color = {0.7, 0.7, 0.7}
    for _ = 2, COLUMNS do tbl.add{type = "empty-widget"} end
  end
  if not ctx.machines.enabled() then return message({"resbal.history-off"}) end

  local surface = player.surface
  local list, span = ctx.machines.summary(player.force.index, {surface.index}, window, game.tick)
  frame.inner.info.caption = {"resbal.idle-info", string.format("%.1f", math.max(span, 0) / 3600), window}
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

  for i = 1, math.min(TOP, #rows) do
    local row = rows[i]
    local recipe = prototypes.recipe[row.recipe]
    local product_type, product_name = main_product(row.recipe)
    local name = tbl.add{type = "button", style = "resbal_status_button",
                         caption = {"", "[img=recipe/" .. row.recipe .. "] ", recipe and recipe.localised_name or row.recipe},
                         tooltip = product_type and {"resbal.idle-recipe-tooltip"} or nil}
    name.style.maximal_width = 340
    if product_type then
      name.tags = {resbal_chart = {type = product_type, name = product_name, surface = surface.name}}
    end
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
    -- чи шкодить: баланс головного продукту на планеті
    local balance = product_type and ctx.balance(player, product_type, product_name, surface.name, PRECISION[window])
    local product = tbl.add{type = "label",
                            caption = balance and {"", "[" .. product_type .. "=" .. product_name .. "] ",
                                                   ctx.format_balance(balance)} or "—",
                            tooltip = balance and (balance < 0 and {"resbal.idle-product-short"}
                                                   or {"resbal.idle-product-ok"}) or nil}
    product.style.font_color = (balance and balance < 0) and {1, 0.45, 0.4} or {0.7, 0.7, 0.7}
  end
end

local function open(player)
  close(player)
  local frame = player.gui.screen.add{type = "frame", name = "resbal_idle", direction = "vertical", tags = {window = 10}}
  frame.auto_center = true
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", style = "frame_title", ignored_by_interaction = true,
               caption = {"resbal.idle-title", ctx.surface_caption(player.surface, player.surface.name)}}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.minimal_width = 24
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_idle_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical", style = "inside_shallow_frame_with_padding"}
  local windows = inner.add{type = "flow", name = "windows", direction = "horizontal"}
  windows.style.vertical_align = "center"
  windows.add{type = "label", caption = {"resbal.idle-window"}}
  for _, minutes in ipairs(WINDOWS) do
    windows.add{type = "button", name = "resbal_idle_win_" .. minutes, caption = {"resbal.idle-minutes", minutes}}
  end
  local info = inner.add{type = "label", name = "info", caption = ""}
  info.style.single_line = false
  info.style.maximal_width = 820
  info.style.font_color = {0.7, 0.7, 0.7}
  info.style.top_margin = 4
  local scroll = inner.add{type = "scroll-pane", name = "scroll"}
  scroll.style.maximal_height = 520
  scroll.style.top_margin = 6
  local tbl = scroll.add{type = "table", name = "resbal_idle_table", column_count = COLUMNS,
                         draw_horizontal_line_after_headers = true}
  tbl.style.horizontal_spacing = 16
  tbl.style.vertical_spacing = 2
  fill(player, frame)
end

function M.add_button(parent)
  local button = parent.add{type = "button", name = "resbal_idle_open", caption = {"resbal.idle"},
                            tooltip = {"resbal.idle-tooltip"}}
  button.style.left_margin = 4
end

function M.on_click(player, element)
  local name = element.name
  if name == "resbal_idle_open" then
    if frame_of(player) then close(player) else open(player) end
  elseif name == "resbal_idle_close" then
    close(player)
  elseif name:find("^resbal_idle_win_") then
    local frame = frame_of(player)
    if frame then
      local tags = frame.tags
      tags.window = tonumber(name:match("%d+$"))
      frame.tags = tags
      fill(player, frame)
    end
  else
    return false
  end
  return true
end

-- Раз на 10 с: оновити відкриті вікна
function M.refresh()
  for _, player in pairs(game.connected_players) do
    local frame = frame_of(player)
    if frame then fill(player, frame) end
  end
end

return M
