local mod_gui = require("mod-gui")
local lists = require("scripts.lists") -- кілька списків ресурсів (вкладки)
local marks = require("scripts.marks") -- позначки на великому графіку

-- Проміжки часу, як у вбудованому вікні виробництва
local PRECISIONS = {
  "five_seconds", "one_minute", "ten_minutes", "one_hour",
  "ten_hours", "fifty_hours", "two_hundred_fifty_hours", "one_thousand_hours",
}
local DEFAULT_PRECISION = 3 -- 10 хв
local RANGE_SECONDS = {5, 60, 600, 3600, 36000, 180000, 900000, 3600000} -- довжина кожного проміжку
-- Як часто оновлювати цифри й графіки (тіки): 5с → 5 с, 1хв → 30 с, далі → раз на хвилину
local REFRESH_TICKS = {300, 1800, 3600, 3600, 3600, 3600, 3600, 3600}

local CHART_POINTS = 60     -- точок на міні-графіку (по 2 px)
local CHART_HEIGHT = 28     -- px
local LINE_WIDTH = 1        -- товщина лінії, px

-- Великий графік: малюється рендером на прихованій поверхні й показується камерою у вікні
local BIG_SURFACE = "resbal-charts"
-- Запис «Усі планети»: сума по всіх поверхнях сили (планети, платформи), крім службової
local ALL_SURFACES = "*"
local MAX_TOOLTIP_LINES = 15                  -- рядків розбивки по поверхнях у підказці
local BIG_W = 680                             -- px, ширина поля графіка
local PAD_X, PAD_Y = 4, 8                     -- відступ ліній від країв поля
local MAX_PANELS = 4                          -- до 4 ресурсів на одному великому графіку
local CHIP_NAME_WIDTH = 160                   -- довша назва ресурсу в «чипі» над графіком обрізається
-- Висота панелі залежно від кількості панелей: поле ліній, відступ, смуга балансу (px)
local PANEL_SIZES = {
  {chart = 240, gap = 10, band = 70},
  {chart = 160, gap = 8, band = 50},
  {chart = 120, gap = 6, band = 40},
  {chart = 100, gap = 6, band = 34},
}
local PANEL_SPACING = 14                      -- проміжок між панелями
-- Підписи осей — звичайні елементи GUI довкола камери (текст рендера камера не показує)
local AXIS_Y_WIDTH, AXIS_LABEL_H = 64, 16
local AXIS_X_LABEL_W = 60
local HOVER_COLUMNS = 68                      -- колонок з підказкою «значення в точці» (по 10 px)
local BIG_SAMPLES = 299                       -- усі повні зразки обраного проміжку
local SMOOTHING = {1, 10, 30}                 -- ковзне середнє, зразків: немає / слабке / сильне
local DEFAULT_SMOOTHING = 0                   -- 0 = «Авто»: рівень залежить від проміжку
-- «Авто»: 5с → немає, 1хв → слабке, 10хв і далі → сильне
local SMOOTHING_AUTO = {1, 2, 3, 3, 3, 3, 3, 3}

-- Фактичний рівень згладжування (1..3) з урахуванням «Авто»
local function smoothing_level(state)
  local level = state.smoothing or DEFAULT_SMOOTHING
  if level == 0 then return SMOOTHING_AUTO[state.precision] or 2 end
  return level
end
local BIG_REFRESH = {60, 300, 1800, 3600, 3600, 3600, 3600, 3600}
local TILE = 32                               -- px у тайлі при зумі 1
local COLOR_PROD = {0.35, 0.9, 0.35}
local COLOR_CONS = {1, 0.4, 0.35}
local CHARTS_PER_TICK = 4   -- графіки перераховуються по черзі, щоб не було ривків
local CHART_IMMEDIATE = 40  -- скільки графіків рахувати одразу, коли рядок змінився
local EPSILON = 0.05
local COLOR_POSITIVE = {0.4, 1, 0.4}
local COLOR_NEGATIVE = {1, 0.4, 0.4}
local COLOR_NEUTRAL = {0.8, 0.8, 0.8}
local NAME_WIDTH = 200
local NAME_MAX_WIDTH = 280   -- довша назва обрізається; повна — у підказці
local MAX_PLANET_ICONS = 8   -- іконок поверхонь у колонці «Планети»; решта — «+N»
local PLANET_ICON = 24
local PLANETS_WIDTH = 16 + MAX_PLANET_ICONS * (PLANET_ICON + 2) + 32 -- «Σ» + іконки + «+N»
local NUMBER_WIDTH = 90
local COLUMNS = 8
local ROW_HEIGHT = CHART_HEIGHT + 4 -- висота «плитки» клітинки = рамка міні-графіка
local TILE_PADDING = 8

-- Напрям сортування за першим кліком: назва — за алфавітом, баланс — спершу нестача
local DEFAULT_ASC = {name = true, produced = false, consumed = false, balance = true}

-- Стан відображення по гравцях; не зберігається в сейві (після завантаження таблиця перебудується)
-- views[player_index] = {count, rows, keys, next_update, chart_cursor}
local views = {}

-- Графік показує ширший проміжок, ніж цифри: наступний рівень (5с → 1хв, 1хв → 10хв, …).
-- Джерело зразків — найгрубша статистика, де на кожну точку графіка припадає ≥ 1 зразок
-- (кожен зразок гри — вже середнє за свій відрізок). n — скільки останніх зразків охоплює графік.
local CHART_SOURCE = {}
for i = 1, #PRECISIONS do
  local window = RANGE_SECONDS[math.min(i + 1, #PRECISIONS)]
  local source = 1
  for s = 1, #PRECISIONS do
    if RANGE_SECONDS[s] <= window * 300 / CHART_POINTS then source = s end
  end
  CHART_SOURCE[i] = {
    window = math.min(i + 1, #PRECISIONS),
    precision = PRECISIONS[source],
    -- найновіший зразок ще набирається, тому його пропускаємо (максимум 299 повних)
    samples = math.min(299, math.floor(window * 300 / RANGE_SECONDS[source] + 0.5)),
  }
end

-- ---------- нижній регістр для кирилиці (Lua 5.2 у Factorio не має utf8) ----------

local LOWER = {}
do
  local function utf8_char(code)
    return string.char(192 + math.floor(code / 64), 128 + code % 64)
  end
  for code = 0x410, 0x42F do LOWER[utf8_char(code)] = utf8_char(code + 0x20) end -- А-Я
  for code = 0x400, 0x40F do LOWER[utf8_char(code)] = utf8_char(code + 0x50) end -- Ѐ-Џ (Ё, Є, І, Ї…)
  LOWER[utf8_char(0x490)] = utf8_char(0x491)                                        -- Ґ
end

local function lower(text)
  return (text:lower():gsub("[\208\210][\128-\191]", LOWER))
end

-- ---------- дані гравця ----------

local function player_data(player)
  storage.players = storage.players or {}
  local data = storage.players[player.index]
  if not data then
    data = {entries = {}, precision = DEFAULT_PRECISION, negative_only = false}
    storage.players[player.index] = data
  end
  data.search = data.search or ""
  lists.normalize(data) -- data.entries = відкритий список
  return data
end

local function prototype_of(type, name)
  if type == "fluid" then return prototypes.fluid[name] end
  return prototypes.item[name]
end

-- ---------- переклади назв (для пошуку й сортування) ----------

local function request_translations(player)
  if not (player and player.connected) then return end
  storage.translations = storage.translations or {}
  storage.pending = storage.pending or {}
  storage.translations[player.index] = {}
  local keys, strings = {}, {}
  for _, group in ipairs({{"item", prototypes.item}, {"fluid", prototypes.fluid}}) do
    for name, proto in pairs(group[2]) do
      if not proto.hidden then
        keys[#keys + 1] = group[1] .. "/" .. name
        strings[#strings + 1] = proto.localised_name
      end
    end
  end
  local ids = player.request_translations(strings)
  if ids then
    for i, id in ipairs(ids) do storage.pending[id] = keys[i] end
  end
end

local function translations_of(player)
  return storage.translations and storage.translations[player.index]
end

local function search_text(translations, row)
  return translations and translations[row.type .. "/" .. row.name] or row.name
end

-- ---------- форматування ----------

-- Формат чисел гравця (налаштування «Формат чисел»): auto — k від 10 000, short — k від 1000,
-- full — повністю з пробілом між тисячами. Ставиться на початку кожного оновлення для гравця.
local number_format = "auto"
local function use_number_format(player)
  number_format = player.mod_settings["resbal-number-format"].value
end

-- mode — примусовий формат (для вузьких підписів осей), інакше — формат гравця
local function format_number(value, mode)
  mode = mode or number_format
  local abs = math.abs(value)
  if mode == "full" then
    if abs < 100 then return string.format("%.1f", value) end
    local digits = string.format("%.0f", abs)
    local grouped = digits:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (value < 0 and "-" or "") .. (grouped:gsub("^ ", ""))
  end
  if abs >= 1e9 then return string.format("%.1fG", value / 1e9) end
  if abs >= 1e6 then return string.format("%.1fM", value / 1e6) end
  if abs >= (mode == "short" and 1e3 or 1e4) then return string.format("%.1fk", value / 1e3) end
  if abs >= 100 then return string.format("%.0f", value) end
  return string.format("%.1f", value)
end

local function planet_sprite(surface)
  if surface and surface.valid and surface.planet then
    local name = surface.planet.prototype.name
    for _, prefix in ipairs({"space-location/", "planet/"}) do
      if helpers.is_valid_sprite_path(prefix .. name) then return prefix .. name end
    end
  end
  return "utility/questionmark"
end

local function platform_sprite()
  for _, path in ipairs({"entity/space-platform-hub", "item/space-platform-starter-pack"}) do
    if helpers.is_valid_sprite_path(path) then return path end
  end
  return "utility/questionmark"
end

local function surface_caption(surface, surface_name)
  if not (surface and surface.valid) then return {"resbal.missing-surface", surface_name} end
  if surface.planet then return surface.planet.prototype.localised_name end
  return surface.localised_name or surface.name
end

local function format_balance(value)
  return (value > EPSILON and "+" or "") .. format_number(value)
end

-- Іконки для колонки «Планети» рядка Σ: {sprite}; платформи — однією іконкою
local function active_surfaces(parts)
  local list, platforms = {}, nil
  for _, part in ipairs(parts or {}) do
    if part.surface.valid and (part.produced > EPSILON or part.consumed > EPSILON) then
      if part.surface.platform then
        platforms = platforms or {sprite = platform_sprite(), produced = 0, consumed = 0}
        platforms.produced = platforms.produced + part.produced
        platforms.consumed = platforms.consumed + part.consumed
      else
        list[#list + 1] = {sprite = planet_sprite(part.surface), produced = part.produced, consumed = part.consumed}
      end
    end
  end
  if platforms then list[#list + 1] = platforms end
  table.sort(list, function(a, b)
    local pa, pb = a.produced > EPSILON, b.produced > EPSILON
    if pa ~= pb then return pa end
    if pa then return a.produced > b.produced end
    return a.consumed > b.consumed
  end)
  return list
end

-- Підказка рядка «Усі планети»: внесок кожної поверхні; платформи — одним рядком
local function all_surfaces_tooltip(parts)
  local tooltip = {"", {"resbal.all-surfaces-tooltip"}}
  local platforms = {count = 0, produced = 0, consumed = 0}
  local lines, hidden = 0, 0
  local function line(caption, produced, consumed)
    if lines >= MAX_TOOLTIP_LINES then hidden = hidden + 1 return end
    lines = lines + 1
    tooltip[#tooltip + 1] = {"resbal.point-line", caption, format_number(produced), format_number(consumed),
                             format_balance(produced - consumed)}
  end
  for _, part in ipairs(parts or {}) do
    if part.surface.valid and part.surface.platform then
      platforms.count = platforms.count + 1
      platforms.produced = platforms.produced + part.produced
      platforms.consumed = platforms.consumed + part.consumed
    elseif part.surface.valid then
      line(surface_caption(part.surface), part.produced, part.consumed)
    end
  end
  if platforms.count > 0 then
    line({"resbal.platforms", platforms.count}, platforms.produced, platforms.consumed)
  end
  if hidden > 0 then tooltip[#tooltip + 1] = {"resbal.more-surfaces", hidden} end
  return tooltip
end

-- ---------- статистика ----------

local function statistics(force, surface, type)
  if type == "fluid" then return force.get_fluid_production_statistics(surface) end
  return force.get_item_production_statistics(surface)
end

-- Кеш об'єктів статистики на один прохід оновлення
local function stats_getter(force)
  local cache = {}
  return function(surface, type)
    local key = surface.index .. type
    if not cache[key] then cache[key] = statistics(force, surface, type) end
    return cache[key]
  end
end

-- На довгих проміжках гра може віддати NaN/нескінченність — такі значення вважаємо нулем
local function sane(value)
  if value ~= value or value == math.huge or value < 0 then return 0 end
  return value
end

local function flow(stats, name, precision, sample_index)
  -- input = вироблено, output = спожито; значення за хвилину
  return sane(stats.get_flow_count{name = name, category = "input", precision_index = precision, sample_index = sample_index}),
         sane(stats.get_flow_count{name = name, category = "output", precision_index = precision, sample_index = sample_index})
end

-- Поверхні запису: одна за назвою або, для «Усіх планет», усі, крім службової
local function surfaces_of(surface_name)
  local list = {}
  if surface_name ~= ALL_SURFACES then
    list[1] = game.surfaces[surface_name]
    return list
  end
  for _, surface in pairs(game.surfaces) do
    if surface.name ~= BIG_SURFACE then list[#list + 1] = surface end
  end
  return list
end

-- Джерела статистики запису: {surface, stats} для його поверхні або, для «Усіх планет», для кожної
-- поверхні, де ресурс колись вироблявся чи споживався (решту пропускаємо — менше викликів)
local function sources(force, surface_name, type, name, get_stats)
  get_stats = get_stats or function(surface, t) return statistics(force, surface, t) end
  local list = {}
  for _, surface in ipairs(surfaces_of(surface_name)) do
    local stats = get_stats(surface, type)
    if surface_name ~= ALL_SURFACES or stats.get_input_count(name) > 0 or stats.get_output_count(name) > 0 then
      list[#list + 1] = {surface = surface, stats = stats}
    end
  end
  return list
end

-- Сума потоку по всіх джерелах
local function flow_sum(list, name, precision, sample_index)
  local produced, consumed = 0, 0
  for _, source in ipairs(list) do
    local p, c = flow(source.stats, name, precision, sample_index)
    produced, consumed = produced + p, consumed + c
  end
  return produced, consumed
end

local function current_precision(data)
  return defines.flow_precision_index[PRECISIONS[data.precision]]
end

-- Рядки для показу: {type, name, surface_name, produced, consumed, entry_index?}
-- Запас предмета в логістичних мережах поверхні (або всіх поверхонь для «Усіх планет»).
-- Рідини в логістику не потрапляють — для них nil. Стрічки й скрині поза мережею не враховуються.
local function logistic_stock(networks, type, name, surface_name)
  if type ~= "item" then return nil end
  local total = 0
  for surface, list in pairs(networks) do
    if surface_name == ALL_SURFACES or surface == surface_name then
      for _, network in ipairs(list) do
        if network.valid then total = total + network.get_item_count(name) end
      end
    end
  end
  return total
end

local function collect_rows(player, data)
  local precision = current_precision(data)
  local get_stats = stats_getter(player.force)
  local rows = {}

  if data.negative_only then
    -- усе з від'ємним балансом на поточній планеті
    local surface = player.surface
    for _, type in ipairs({"item", "fluid"}) do
      local stats = get_stats(surface, type)
      for name in pairs(stats.output_counts) do -- кандидати: лише те, що колись споживалось
        if prototype_of(type, name) then
          local produced, consumed = flow(stats, name, precision)
          if produced - consumed < -EPSILON then
            rows[#rows + 1] = {type = type, name = name, surface_name = surface.name,
                               produced = produced, consumed = consumed}
          end
        end
      end
    end
  else
    for i, entry in ipairs(data.entries) do
      local row = {type = entry.type, name = entry.name, surface_name = entry.surface,
                   produced = 0, consumed = 0, entry_index = i}
      if prototype_of(entry.type, entry.name) then
        local list = sources(player.force, entry.surface, entry.type, entry.name, get_stats)
        if entry.surface == ALL_SURFACES then
          -- розбивка по поверхнях для підказки
          row.parts = {}
          for _, source in ipairs(list) do
            local p, c = flow(source.stats, entry.name, precision)
            row.parts[#row.parts + 1] = {surface = source.surface, produced = p, consumed = c}
            row.produced, row.consumed = row.produced + p, row.consumed + c
          end
        else
          row.produced, row.consumed = flow_sum(list, entry.name, precision)
        end
      end
      rows[#rows + 1] = row
    end
  end
  local networks = player.force.logistic_networks -- один раз на прохід
  for _, row in ipairs(rows) do row.stock = logistic_stock(networks, row.type, row.name, row.surface_name) end
  return rows
end

local function effective_sort(data)
  if data.sort_key then return data.sort_key, data.sort_asc end
  if data.negative_only then return "balance", true end
  return nil
end

-- пошук + сортування
local function prepare_rows(player, data)
  local rows = collect_rows(player, data)
  local translations = translations_of(player)

  if data.search ~= "" then
    local query = lower(data.search)
    local filtered = {}
    for _, row in ipairs(rows) do
      if search_text(translations, row):find(query, 1, true) or row.name:find(query, 1, true) then
        filtered[#filtered + 1] = row
      end
    end
    rows = filtered
  end

  local key, asc = effective_sort(data)
  if key then
    local function value(row)
      if key == "name" then return search_text(translations, row) end
      if key == "produced" then return row.produced end
      if key == "consumed" then return row.consumed end
      return row.produced - row.consumed
    end
    table.sort(rows, function(a, b)
      local va, vb = value(a), value(b)
      if va == vb then return a.name .. a.surface_name < b.name .. b.surface_name end
      if asc then return va < vb end
      return va > vb
    end)
  end
  return rows
end

-- ---------- міні-графік ----------

-- Малює лінію з відрізків: кожен відрізок тягнеться від попередньої точки до поточної
local function draw_line(segments, values, max)
  local usable = CHART_HEIGHT - LINE_WIDTH
  local previous
  for point, segment in ipairs(segments) do
    local y = max > EPSILON and math.floor(values[point] / max * usable + 0.5) or 0
    local from = previous or y
    local low, high = math.min(from, y), math.max(from, y)
    segment.style.height = high - low + LINE_WIDTH
    segment.style.top_margin = CHART_HEIGHT - LINE_WIDTH - high
    previous = y
  end
end

local function update_chart(player, chart, row, data)
  use_number_format(player)
  local layers = chart.layers
  local produced, consumed, max = {}, {}, 0
  local source = CHART_SOURCE[data.precision]
  local list = prototype_of(row.type, row.name) and sources(player.force, row.surface_name, row.type, row.name) or {}

  if #list > 0 then
    local precision = defines.flow_precision_index[source.precision]
    local n = source.samples
    for point = 1, CHART_POINTS do
      -- точка (зліва найстаріша) — середнє всіх зразків свого відрізка;
      -- sample_index 1 — найновіший (неповний), тому зсув на 1
      local first = math.floor((point - 1) * n / CHART_POINTS) + 1
      local last = math.floor(point * n / CHART_POINTS)
      local p, c = 0, 0
      for age = first, last do
        local a, b = flow_sum(list, row.name, precision, n - age + 2)
        p, c = p + a, c + b
      end
      local count = math.max(1, last - first + 1)
      produced[point], consumed[point] = p / count, c / count
      max = math.max(max, produced[point], consumed[point])
    end
  else
    for point = 1, CHART_POINTS do produced[point], consumed[point] = 0, 0 end
  end

  draw_line(layers.cons.children, consumed, max)
  draw_line(layers.prod.children, produced, max)
  chart.tooltip = {"resbal.trend-tooltip", {"resbal.p-" .. PRECISIONS[source.window]}, format_number(max),
                   format_number(produced[CHART_POINTS]), format_number(consumed[CHART_POINTS])}
end

-- ---------- GUI ----------

-- Кнопка вибору ресурсу з постійним «+» поверх (порожній квадрат незрозумілий);
-- «+» накладено від'ємним відступом і не перехоплює кліки
local function add_button(parent, name, size, tooltip)
  local holder = parent.add{type = "flow", direction = "horizontal"}
  holder.style.horizontal_spacing = 0
  holder.style.size = size -- «+» з від'ємним відступом не має впливати на ширину
  local button = holder.add{type = "choose-elem-button", name = name, elem_type = "signal", tooltip = tooltip}
  button.style.size = size
  local inner = math.floor(size / 2)
  local plus = holder.add{type = "sprite", sprite = "utility/add_white", ignored_by_interaction = true}
  plus.style.size = inner
  plus.style.stretch_image_to_widget_size = true
  plus.style.left_margin = -math.floor((size + inner) / 2)
  plus.style.top_margin = math.floor((size - inner) / 2)
  return button
end

local function main_frame(player)
  return player.gui.screen.resbal_main
end

-- ---------- Esc ----------
-- Esc (і E) закриває лише вікно, записане в player.opened. Велике вікно графіка — завжди;
-- панель — лише якщо гравець увімкнув це в налаштуваннях (інакше вона висить на екрані під час гри,
-- а «відкрите» вікно гра закриває, коли відкривається будь-яке інше — інвентар, машина…).
local quiet = {} -- [player_index] = true, поки мод сам перемикає чи знищує вікна (не реагувати на on_gui_closed)

local function is_own_opened(player)
  if player.opened_gui_type ~= defines.gui_type.custom then return false end
  local opened = player.opened
  return opened and opened.valid and opened.get_mod() == script.mod_name
end

-- Робить «відкритим» велике вікно, якщо воно є, інакше панель (за налаштуванням), інакше нічого.
-- Чужі вікна (інвентар тощо) не чіпаємо, якщо ставити нічого.
local function update_opened(player)
  if not player.connected then return end
  local target = player.gui.screen.resbal_big
  if not target and player.mod_settings["resbal-close-on-esc"].value then target = main_frame(player) end
  if target then
    if player.opened == target then return end
  elseif not is_own_opened(player) then
    return
  end
  quiet[player.index] = true
  player.opened = target
  quiet[player.index] = nil
end

-- Знищує власне вікно, не сприймаючи це як закриття гравцем
local function destroy_quietly(player, element)
  if not (element and element.valid) then return end
  quiet[player.index] = true
  element.destroy()
  quiet[player.index] = nil
end

local function ensure_top_button(player)
  local button_flow = mod_gui.get_button_flow(player)
  if not button_flow.resbal_top then
    button_flow.add{type = "sprite-button", name = "resbal_top", sprite = "resbal-icon",
                    style = mod_gui.button_style, tooltip = {"resbal.title"}}
  end
end

-- «Плитка» клітинки: темна рамка, як слоти інвентаря; між плитками — проміжок таблиці.
-- Вміст — у flow «content» (рамка сама не задає відступів між дітьми)
local function tile(tbl, name, stretch)
  local frame = tbl.add{type = "frame", name = name, style = "deep_frame_in_shallow_frame"}
  frame.style.height = ROW_HEIGHT
  frame.style.left_padding, frame.style.right_padding = TILE_PADDING, TILE_PADDING
  frame.style.horizontally_stretchable = stretch == true
  local content = frame.add{type = "flow", name = "content", direction = "horizontal"}
  content.style.vertical_align = "center"
  content.style.height = ROW_HEIGHT
  content.style.horizontally_stretchable = stretch == true
  return content
end

local function number_label(tbl, name)
  local label = tile(tbl, name).add{type = "label", name = "amount", caption = "-"}
  label.style.minimal_width = NUMBER_WIDTH
  label.style.horizontal_align = "right"
  return label
end

local function set_balance(label, produced, consumed)
  local balance = produced - consumed
  label.caption = format_balance(balance)
  label.style.font_color = balance > EPSILON and COLOR_POSITIVE
                        or balance < -EPSILON and COLOR_NEGATIVE
                        or COLOR_NEUTRAL
end

-- ---------- «Сторож»: пороги для ресурсу зі списку ----------
-- entry.watch = {min_produced = число|nil, min_balance = число|nil, window = хвилин}
local WATCH_WINDOWS = {1, 5, 10, 30}   -- хв: за який час береться середнє (і скільки має тривати порушення)
local DEFAULT_WATCH_WINDOW = 5
local SNOOZE_MINUTES = 30

local function snooze_left(watch) -- хвилин до кінця «відкласти», або nil
  if watch and watch.snooze_until and game.tick < watch.snooze_until then
    return math.ceil((watch.snooze_until - game.tick) / 3600)
  end
end

local function watch_conditions(watch)
  local parts = {""}
  local function add(part)
    if #parts > 1 then parts[#parts + 1] = ", " end
    parts[#parts + 1] = part
  end
  if watch.min_produced then add({"resbal.watch-cond-prod", format_number(watch.min_produced)}) end
  if watch.min_balance then add({"resbal.watch-cond-bal", format_balance(watch.min_balance)}) end
  add({"resbal.watch-cond-window", watch.window or DEFAULT_WATCH_WINDOW})
  return parts
end

local function watch_tooltip(watch)
  if not watch then return {"resbal.watch-add"} end
  local tooltip = {"", {"resbal.watch-tooltip", watch_conditions(watch)}}
  if watch.produced then
    tooltip[#tooltip + 1] = {"resbal.watch-now", watch.window or DEFAULT_WATCH_WINDOW, format_number(watch.produced),
                             format_balance(watch.produced - watch.consumed)}
  end
  if watch.violated then tooltip[#tooltip + 1] = {"resbal.watch-violated"} end
  local left = snooze_left(watch)
  if left then tooltip[#tooltip + 1] = {"resbal.watch-snoozed", left} end
  return tooltip
end

-- «Запас»: на скільки вистачить запасу логістичних мереж за поточного дефіциту
local STOCK_RED, STOCK_YELLOW = 10, 60 -- хв: менше — червоним / жовтим
local function stock_time(minutes)
  if minutes < 1 then return {"", "<", {"resbal.t-m", "1"}} end
  if minutes < 60 then return {"resbal.t-m", string.format("%d", math.floor(minutes))} end
  local hours = math.floor(minutes / 6 + 0.5) / 10 -- до десятих
  return {"resbal.t-h", hours == math.floor(hours) and string.format("%d", hours) or string.format("%.1f", hours)}
end

local function set_stock(label, row, data)
  if row.stock == nil then -- рідина
    label.caption, label.tooltip, label.style.font_color = "—", {"resbal.stock-fluid"}, COLOR_NEUTRAL
    return
  end
  local deficit = row.consumed - row.produced
  local where = {"resbal.p-" .. PRECISIONS[data.precision]}
  if deficit <= EPSILON then
    label.caption, label.style.font_color = "—", COLOR_NEUTRAL
    label.tooltip = {"resbal.stock-ok", format_number(row.stock), where}
    return
  end
  if row.stock <= 0 then -- дефіцит, а в мережах нічого немає
    label.caption, label.style.font_color = "0", COLOR_NEGATIVE
    label.tooltip = {"resbal.stock-empty", format_number(deficit), where}
    return
  end
  local minutes = row.stock / deficit
  local lasts = minutes < 1 and stock_time(minutes) or {"", "≈", stock_time(minutes)} -- «<1хв» або «≈N хв»
  label.caption = lasts
  label.style.font_color = minutes < STOCK_RED and COLOR_NEGATIVE
                        or minutes < STOCK_YELLOW and {1, 0.85, 0.3} or COLOR_NEUTRAL
  label.tooltip = {"resbal.stock-tooltip", format_number(row.stock), format_number(deficit), lasts, where}
end

local function header(tbl, key, caption, data, width, align, tooltip)
  local sort_key, asc = effective_sort(data)
  local text = (key and sort_key == key) and {"", caption, asc and " ▲" or " ▼"} or caption
  local label = tbl.add{type = "label", name = key and ("resbal_sort_" .. key) or nil, caption = text,
                        style = "bold_label", tooltip = tooltip or (key and {"resbal.sort-tooltip"}) or nil}
  if width then label.style.minimal_width = width end
  if align == "right" then
    label.style.right_padding = TILE_PADDING
  else
    label.style.left_padding = TILE_PADDING
  end
  if key == "name" then label.style.horizontally_stretchable = true end
  if align then label.style.horizontal_align = align end
end

-- Будує заголовки й порожні «слоти» рядків; вміст заповнює fill_slot
local function build_table(tbl, count, data)
  tbl.clear()
  header(tbl, "name", {"resbal.resource"}, data, NAME_WIDTH)
  header(tbl, nil, {"resbal.planets"}, data, PLANETS_WIDTH, nil, {"resbal.planets-tooltip"})
  header(tbl, nil, {"resbal.trend"}, data, nil, nil,
         {"resbal.trend-header-tooltip", {"resbal.p-" .. PRECISIONS[CHART_SOURCE[data.precision].window]}})
  header(tbl, "produced", {"resbal.produced"}, data, NUMBER_WIDTH, "right")
  header(tbl, "consumed", {"resbal.consumed"}, data, NUMBER_WIDTH, "right")
  header(tbl, "balance", {"resbal.balance"}, data, NUMBER_WIDTH, "right")
  header(tbl, nil, {"resbal.stock"}, data, NUMBER_WIDTH, "right", {"resbal.stock-header-tooltip"})
  tbl.add{type = "empty-widget"}

  for i = 1, count do
    -- ресурс: іконка й назва в одній клітинці (без вертикальної лінії між ними)
    local resource = tile(tbl, "resbal_res_" .. i, true)
    resource.add{type = "sprite", name = "res_icon"}
    local name = resource.add{type = "label", name = "res_name"}
    name.style.minimal_width = NAME_WIDTH
    name.style.maximal_width = NAME_MAX_WIDTH

    -- планети: одна іконка або «Σ» + іконки поверхонь, де ресурс рухається, і «+N»
    local planets = tile(tbl, "resbal_planets_" .. i)
    planets.style.horizontal_spacing = 2
    planets.style.minimal_width = PLANETS_WIDTH
    local sigma = planets.add{type = "label", name = "sigma", caption = "Σ", style = "bold_label"}
    sigma.style.font = "default-large-bold"
    sigma.style.right_margin = 4
    for k = 1, MAX_PLANET_ICONS do
      local icon = planets.add{type = "sprite", name = "p" .. k}
      icon.style.size = PLANET_ICON
      icon.style.stretch_image_to_widget_size = true
    end
    local more = planets.add{type = "label", name = "more", style = "bold_label"}
    more.style.left_margin = 4

    -- графік: два шари (споживання під виробництвом), накладені від'ємним відступом;
    -- вміст ігнорує кліки, щоб клік отримувала рамка (відкриває великий графік)
    local chart = tbl.add{type = "frame", name = "resbal_chart_" .. i, style = "deep_frame_in_shallow_frame"}
    chart.style.padding = 2
    local layers = chart.add{type = "flow", name = "layers", direction = "vertical", ignored_by_interaction = true}
    layers.style.vertical_spacing = 0
    for _, layer in ipairs({"cons", "prod"}) do
      local line = layers.add{type = "flow", name = layer, direction = "horizontal"}
      line.style.horizontal_spacing = 0
      line.style.height = CHART_HEIGHT
      if layer == "prod" then line.style.top_margin = -CHART_HEIGHT end
      for _ = 1, CHART_POINTS do
        local segment = line.add{type = "empty-widget", style = "resbal_line_" .. layer}
        segment.style.height = LINE_WIDTH
        segment.style.top_margin = CHART_HEIGHT - LINE_WIDTH
      end
    end

    number_label(tbl, "resbal_prod_" .. i)
    number_label(tbl, "resbal_cons_" .. i)
    number_label(tbl, "resbal_bal_" .. i)
    number_label(tbl, "resbal_stock_" .. i)

    -- дії: у «Моєму списку» — сторож і прибрати, у «Лише від'ємних» — додати до списку
    local actions = tbl.add{type = "flow", name = "resbal_actions_" .. i, direction = "horizontal"}
    actions.style.horizontal_spacing = 4
    actions.style.vertical_align = "center"
    if data.negative_only then
      actions.add{type = "button", name = "resbal_act_" .. i, caption = "+", style = "tool_button", tooltip = {"resbal.pin"}}
    else
      actions.add{type = "sprite-button", name = "watch", sprite = "utility/notification", style = "tool_button"}
      actions.add{type = "sprite-button", name = "resbal_act_" .. i, sprite = "utility/close",
                  style = "tool_button_red", tooltip = {"resbal.remove"}}
    end
  end

  if count == 0 then
    local caption = data.search ~= "" and {"resbal.nothing-found"}
                 or data.negative_only and {"resbal.no-negative"} or {"resbal.empty"}
    tbl.add{type = "label", caption = caption}
  end
end

-- Повертає залишок «бюджету» на негайний розрахунок графіків
local function fill_slot(player, tbl, i, row, data, view, budget)
  -- планети: для Σ — де ресурс рухається (спершу виробники), для рядка планети — вона сама
  local planets = tbl["resbal_planets_" .. i].content
  local all = row.surface_name == ALL_SURFACES
  local icons, caption
  if all then
    caption = all_surfaces_tooltip(row.parts)
    icons = active_surfaces(row.parts)
  else
    local surface = game.surfaces[row.surface_name]
    caption = surface_caption(surface, row.surface_name)
    icons = {{sprite = planet_sprite(surface)}}
  end
  planets.tooltip = caption
  planets.sigma.visible = all
  planets.sigma.tooltip = caption
  for k = 1, MAX_PLANET_ICONS do
    local slot = planets["p" .. k]
    slot.visible = icons[k] ~= nil
    if icons[k] then
      slot.sprite = icons[k].sprite
      slot.tooltip = caption
    end
  end
  local hidden = #icons - MAX_PLANET_ICONS
  planets.more.visible = hidden > 0
  planets.more.caption = hidden > 0 and ("+" .. hidden) or ""
  planets.more.tooltip = caption
  -- та сама підказка на назві й іконці ресурсу (від назви до графіка — усюди розбивка)
  local proto = prototype_of(row.type, row.name)
  local title = proto and proto.localised_name or row.name
  -- повна назва першим рядком: довга назва в таблиці обрізається
  local open_tooltip = {"", "[font=default-bold]", title, "[/font]\n", caption, "\n\n",
                        {"resbal.open-chart"}}
  local resource = tbl["resbal_res_" .. i].content
  local icon = resource.res_icon
  icon.sprite = proto and (row.type .. "/" .. row.name) or "utility/questionmark"
  icon.tooltip = open_tooltip
  resource.res_name.caption = title
  resource.res_name.tooltip = open_tooltip

  tbl["resbal_prod_" .. i].content.amount.caption = format_number(row.produced)
  tbl["resbal_cons_" .. i].content.amount.caption = format_number(row.consumed)
  set_balance(tbl["resbal_bal_" .. i].content.amount, row.produced, row.consumed)
  set_stock(tbl["resbal_stock_" .. i].content.amount, row, data)

  -- клік по іконці, назві чи міні-графіку відкриває великий графік
  local open_tags = {resbal_chart = {type = row.type, name = row.name, surface = row.surface_name}}
  icon.tags = open_tags
  resource.res_name.tags = open_tags
  tbl["resbal_chart_" .. i].tags = open_tags

  local actions = tbl["resbal_actions_" .. i]
  local action = actions["resbal_act_" .. i]
  if data.negative_only then
    action.tags = {resbal_action = "pin", type = row.type, name = row.name, surface = row.surface_name}
  else
    action.tags = {resbal_action = "del", entry = row.entry_index}
    local entry = data.entries[row.entry_index]
    local bell = actions.watch
    bell.tags = {resbal_watch = row.entry_index}
    local watch = entry and entry.watch
    bell.style = (watch and watch.violated) and "tool_button_red" or "tool_button"
    bell.toggled = watch ~= nil and not watch.violated
    bell.tooltip = watch_tooltip(watch)
  end

  local key = row.type .. ":" .. row.name .. "@" .. row.surface_name
  if view.keys[i] ~= key then
    view.keys[i] = key
    if budget > 0 then
      update_chart(player, tbl["resbal_chart_" .. i], row, data)
      budget = budget - 1
    end
  end
  return budget
end

-- Інтервал оновлення панелі: з налаштувань гравця або «Авто» — за обраним проміжком
local function refresh_ticks(player, data)
  local seconds = tonumber(player.mod_settings["resbal-refresh"].value)
  if seconds then return seconds * 60 end
  return REFRESH_TICKS[data.precision]
end

-- Оновлює цифри й ставить усі графіки в чергу на перерахунок
local function update(player)
  local frame = main_frame(player)
  if not frame then return end
  use_number_format(player)
  local data = player_data(player)
  local tbl = frame.resbal_inner.resbal_scroll.resbal_table
  local rows = prepare_rows(player, data)

  local view = views[player.index]
  if not view or view.count ~= #rows then
    view = {count = #rows, keys = {}}
    views[player.index] = view
    build_table(tbl, #rows, data)
  end
  view.rows = rows
  view.next_update = game.tick + refresh_ticks(player, data)
  view.chart_cursor = 1

  local budget = CHART_IMMEDIATE
  for i, row in ipairs(rows) do
    budget = fill_slot(player, tbl, i, row, data, view, budget)
  end
end

local function build(player)
  destroy_quietly(player, main_frame(player))
  views[player.index] = nil
  local data = player_data(player)
  if not translations_of(player) then request_translations(player) end

  local frame = player.gui.screen.add{type = "frame", name = "resbal_main", direction = "vertical"}
  if data.location then
    frame.location = data.location
  else
    frame.auto_center = true
  end

  -- заголовок, за який вікно можна перетягувати
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = {"resbal.title"}, style = "frame_title", ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "resbal_inner", direction = "vertical",
                          style = "inside_shallow_frame_with_padding"}

  -- перемикач проміжку часу
  local precisions = inner.add{type = "flow", direction = "horizontal"}
  for i, key in ipairs(PRECISIONS) do
    local button = precisions.add{type = "button", name = "resbal_prec_" .. i, caption = {"resbal.p-" .. key}}
    button.style.minimal_width = 48
    button.style.horizontally_stretchable = true
    button.toggled = (i == data.precision)
  end

  if not data.negative_only then lists.add_tabs(inner, data) end

  -- режим + пошук
  local controls = inner.add{type = "flow", direction = "horizontal"}
  controls.style.top_margin = 8
  controls.style.vertical_align = "center"
  local list_button = controls.add{type = "button", name = "resbal_mode_list", caption = {"resbal.mode-list"}}
  list_button.toggled = not data.negative_only
  local negative_button = controls.add{type = "button", name = "resbal_mode_negative", caption = {"resbal.mode-negative"},
                                       tooltip = {"resbal.mode-negative-tooltip"}}
  negative_button.toggled = data.negative_only
  local pause = controls.add{type = "button", name = "resbal_watch_pause", tooltip = {"resbal.watch-pause-tooltip"},
                             caption = data.lists[data.active].watch_paused and {"resbal.watch-state-paused"}
                                       or {"resbal.watch-state-on"},
                             style = data.lists[data.active].watch_paused and "red_button" or "button"}
  pause.style.left_margin = 16
  controls.add{type = "empty-widget"}.style.horizontally_stretchable = true
  controls.add{type = "sprite", sprite = "utility/search", tooltip = {"resbal.search-tooltip"}}
  local search = controls.add{type = "textfield", name = "resbal_search", text = data.search,
                              tooltip = {"resbal.search-tooltip"}}
  search.style.width = 240

  -- без горизонтальної прокрутки таблиця може розтягнутися на всю ширину вікна
  local scroll = inner.add{type = "scroll-pane", name = "resbal_scroll", horizontal_scroll_policy = "never"}
  scroll.style.maximal_height = 640
  scroll.style.minimal_width = 960
  scroll.style.top_margin = 8
  scroll.style.horizontally_stretchable = true
  local tbl = scroll.add{type = "table", name = "resbal_table", column_count = COLUMNS,
                         draw_horizontal_line_after_headers = true}
  tbl.style.horizontally_stretchable = true
  tbl.style.horizontal_spacing = 4
  tbl.style.column_alignments[COLUMNS] = "center" -- кнопка ✕ / + — по центру висоти плитки
  tbl.style.vertical_spacing = 4

  if not data.negative_only then
    local add = inner.add{type = "flow", direction = "horizontal"}
    add.style.top_margin = 8
    add.style.vertical_align = "center"
    add.style.horizontal_spacing = 12
    add_button(add, "resbal_add", 40, {"resbal.add-tooltip"})
    add.add{type = "label", caption = {"resbal.add"}, style = "bold_label", tooltip = {"resbal.add-tooltip"}}
    -- куди прив'язати новий ресурс: до поточної планети чи до суми по всіх
    local scope = add.add{type = "label", caption = {"resbal.scope"}}
    scope.style.left_margin = 16
    local here = add.add{type = "button", name = "resbal_scope_here", caption = {"resbal.scope-here"},
                         tooltip = {"resbal.scope-here-tooltip"}}
    here.toggled = not data.add_all
    local all = add.add{type = "button", name = "resbal_scope_all", caption = {"resbal.scope-all"},
                        tooltip = {"resbal.scope-all-tooltip"}}
    all.toggled = data.add_all == true
  end

  update(player)
  update_opened(player)
end

local function set_open(player, open)
  if open then
    build(player)
  else
    destroy_quietly(player, main_frame(player))
    views[player.index] = nil
  end
  player.set_shortcut_toggled("resbal-toggle", open)
end

local function toggle(player)
  set_open(player, main_frame(player) == nil)
end

local function add_entry(player, type, name, surface_name)
  local entries = player_data(player).entries
  for _, e in ipairs(entries) do
    if e.type == type and e.name == name and e.surface == surface_name then return end
  end
  entries[#entries + 1] = {type = type, name = name, surface = surface_name}
end

-- ---------- вікно «Сторожа» ----------

local check_watch_now -- check_watch(player); оголошено нижче, після допоміжних функцій графіка

local function watch_frame(player)
  return player.gui.screen.resbal_watch
end

local function find_entry(data, ref)
  local list = ref.list and data.lists[ref.list]
  for _, entry in ipairs(list and list.entries or data.entries) do
    if entry.type == ref.type and entry.name == ref.name and entry.surface == ref.surface then return entry end
  end
end

local function open_watch(player, entry_index)
  local data = player_data(player)
  local entry = data.entries[entry_index]
  if not entry then return end
  local old = watch_frame(player)
  if old then old.destroy() end
  local watch = entry.watch or {}

  local frame = player.gui.screen.add{type = "frame", name = "resbal_watch", direction = "vertical",
                                      tags = {type = entry.type, name = entry.name, surface = entry.surface,
                                              list = data.active, window = watch.window or DEFAULT_WATCH_WINDOW}}
  frame.auto_center = true

  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  local proto = prototype_of(entry.type, entry.name)
  local where = entry.surface == ALL_SURFACES and {"resbal.all-surfaces"}
                or surface_caption(game.surfaces[entry.surface], entry.surface)
  titlebar.add{type = "label", style = "frame_title", ignored_by_interaction = true,
               caption = {"", {"resbal.watch-title"}, ": ", proto and ("[" .. entry.type .. "=" .. entry.name .. "] ") or "",
                          proto and proto.localised_name or entry.name, " (", where, ")"}}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.right_margin = 4
  drag.style.minimal_width = 24
  titlebar.add{type = "sprite-button", name = "resbal_watch_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "inner", direction = "vertical",
                          style = "inside_shallow_frame_with_padding"}
  local fields = inner.add{type = "table", name = "fields", column_count = 2}
  fields.style.horizontal_spacing = 12
  fields.style.vertical_spacing = 8
  local function field(name, caption, tooltip, value, negative)
    fields.add{type = "label", caption = caption, tooltip = tooltip}
    local box = fields.add{type = "textfield", name = name, text = value and tostring(value) or "", tooltip = tooltip,
                           numeric = true, allow_decimal = true, allow_negative = negative}
    box.style.width = 100
  end
  field("resbal_watch_prod", {"resbal.watch-min-produced"}, {"resbal.watch-min-produced-tooltip"}, watch.min_produced, false)
  field("resbal_watch_bal", {"resbal.watch-min-balance"}, {"resbal.watch-min-balance-tooltip"}, watch.min_balance, true)

  local windows = inner.add{type = "flow", name = "windows", direction = "horizontal"}
  windows.style.top_margin = 8
  windows.style.vertical_align = "center"
  windows.add{type = "label", caption = {"resbal.watch-window"}, tooltip = {"resbal.watch-window-tooltip"}}
  for _, minutes in ipairs(WATCH_WINDOWS) do
    local button = windows.add{type = "button", name = "resbal_watch_win_" .. minutes,
                               caption = {"resbal.watch-minutes", minutes}, tooltip = {"resbal.watch-window-tooltip"}}
    button.style.minimal_width = 56
    button.toggled = minutes == frame.tags.window
  end

  local hint = inner.add{type = "label", caption = {"resbal.watch-hint"}}
  hint.style.top_margin = 8
  hint.style.single_line = false
  hint.style.maximal_width = 420
  hint.style.font_color = {0.7, 0.7, 0.7}

  local buttons = frame.add{type = "flow", direction = "horizontal", style = "dialog_buttons_horizontal_flow"}
  local remove = buttons.add{type = "button", name = "resbal_watch_remove", caption = {"resbal.watch-remove"},
                             style = "red_button"}
  remove.enabled = entry.watch ~= nil
  local snoozed = snooze_left(entry.watch)
  local snooze = buttons.add{type = "button", name = "resbal_watch_snooze",
                             caption = snoozed and {"resbal.watch-unsnooze", snoozed} or {"resbal.watch-snooze", SNOOZE_MINUTES},
                             tooltip = {"resbal.watch-snooze-tooltip", SNOOZE_MINUTES}}
  snooze.enabled = entry.watch ~= nil
  local filler = buttons.add{type = "empty-widget", style = "draggable_space", ignored_by_interaction = true}
  filler.style.horizontally_stretchable = true
  filler.style.height = 32
  buttons.add{type = "button", name = "resbal_watch_save", caption = {"resbal.watch-save"}, style = "confirm_button"}
end

-- «Відкласти на 30 хв» / скасувати відкладення
local function toggle_snooze(player)
  local frame = watch_frame(player)
  if not frame then return end
  local entry = find_entry(player_data(player), frame.tags)
  if entry and entry.watch then
    entry.watch.snooze_until = (not snooze_left(entry.watch)) and (game.tick + SNOOZE_MINUTES * 3600) or nil
  end
  frame.destroy()
  if main_frame(player) then update(player) end
  if check_watch_now then check_watch_now(player) end
end

local function set_watch_window(player, minutes)
  local frame = watch_frame(player)
  if not frame then return end
  local tags = frame.tags
  tags.window = minutes
  frame.tags = tags
  for _, button in pairs(frame.inner.windows.children) do
    if button.type == "button" then button.toggled = button.name == "resbal_watch_win_" .. minutes end
  end
end

-- remove = true: прибрати сторожа; інакше зберегти введене (обидва поля порожні — теж прибрати)
local function save_watch(player, remove)
  local frame = watch_frame(player)
  if not frame then return end
  local tags = frame.tags
  local entry = find_entry(player_data(player), tags)
  if entry then
    local produced = tonumber(frame.inner.fields.resbal_watch_prod.text)
    local balance = tonumber(frame.inner.fields.resbal_watch_bal.text)
    if remove or (produced == nil and balance == nil) then
      entry.watch = nil
    else
      local snooze_until = entry.watch and entry.watch.snooze_until
      entry.watch = {min_produced = produced and math.max(0, produced), min_balance = balance, window = tags.window,
                     snooze_until = snooze_until}
    end
  end
  frame.destroy()
  if main_frame(player) then update(player) end
  if check_watch_now then check_watch_now(player) end
end

-- ---------- великий графік ----------

local function big_state(player)
  return storage.big and storage.big[player.index]
end

local function big_frame(player)
  return player.gui.screen.resbal_big
end

-- Прихована поверхня лише для малювання графіків (майже вся «за межами карти» — чорний фон)
-- Службову поверхню не показуємо у списку поверхонь віддаленого огляду
local function hide_chart_surface(surface, force)
  local forces = force and {force} or game.forces
  for _, f in pairs(forces) do
    pcall(f.set_surface_hidden, surface, true)
  end
end

local function chart_surface()
  local surface = game.surfaces[BIG_SURFACE]
  if not surface then
    local settings = game.surfaces["nauvis"].map_gen_settings
    settings.width, settings.height = 1, 1
    surface = game.create_surface(BIG_SURFACE, settings)
    surface.always_day = true
    hide_chart_surface(surface)
  elseif not storage.chart_hidden then
    hide_chart_surface(surface) -- сейви, створені до 1.4 (прапорець у storage — однаково для всіх гравців)
  end
  storage.chart_hidden = true
  return surface
end

-- У кожного гравця своя ділянка поверхні; ліву верхню точку графіка ставимо тут
local function big_origin(player)
  return {x = player.index * 64, y = 0}
end

-- Зум камери, за якого 1 px графіка = 1 одиниця GUI (див. коментар у build_big)
local function camera_zoom(player)
  local density = player.display_density_scale
  if not density or density <= 0 then density = 1 end
  return player.display_scale / density
end

local function destroy_objects(state)
  for _, object in pairs(state.objects or {}) do
    if object.valid then object.destroy() end
  end
  state.objects = {}
end

-- «Кругла» верхня межа шкали: 1, 2, 2.5, 5 × 10^n
local function nice_max(value)
  if value <= 0 then return 1 end
  local magnitude = 10 ^ math.floor(math.log(value, 10))
  for _, m in ipairs({1, 2, 2.5, 5, 10}) do
    if m * magnitude >= value then return m * magnitude end
  end
  return 10 * magnitude
end

local function short_number(value)
  -- округлення до десятих, щоб похибка (2.0000001) не давала «2.0» поруч із «8»
  local rounded = math.floor(value * 10 + 0.5) / 10
  if rounded == math.floor(rounded) then return string.format("%d", rounded) end
  return string.format("%.1f", rounded)
end

-- Ковзне середнє з центрованим вікном (на краях — по наявних зразках)
local function smooth(values, window)
  if window <= 1 then return values end
  local result, half, n = {}, math.floor(window / 2), #values
  for k = 1, n do
    local from, to = math.max(1, k - half), math.min(n, k + half)
    local sum = 0
    for j = from, to do sum = sum + values[j] end
    result[k] = sum / (to - from + 1)
  end
  return result
end

local function time_axis(range)
  if range > 3600 then return "h", 3600 end
  if range > 60 then return "m", 60 end
  return "s", 1
end

-- Розкладка панелей по вертикалі в «пікселях» графіка (= одиниці GUI)
local function panel_layout(count)
  local size = PANEL_SIZES[math.max(1, math.min(count, MAX_PANELS))]
  local panels, y = {}, 0
  for i = 1, count do
    local chart_bottom = y + size.chart
    local band_top = chart_bottom + size.gap
    panels[i] = {
      top = y,
      chart_bottom = chart_bottom,
      band_top = band_top,
      band_mid = band_top + size.band / 2,
      band_half = size.band / 2 - 4,
      bottom = band_top + size.band,
    }
    y = panels[i].bottom + (i < count and PANEL_SPACING or 0)
  end
  return panels, math.max(y, 1)
end

-- Іконка ресурсу як rich text (для підписів і підказок)
local function rich_icon(panel)
  return "[img=" .. panel.type .. "/" .. panel.name .. "]"
end

local function panel_caption(panel)
  local proto = prototype_of(panel.type, panel.name)
  return proto and proto.localised_name or panel.name
end

-- Дані панелі: згладжені ряди + середні за проміжок
local function panel_data(player, panel, precision_index, window)
  local produced, consumed = {}, {}
  local list = prototype_of(panel.type, panel.name) and sources(player.force, panel.surface, panel.type, panel.name) or {}
  if #list > 0 then
    local precision = defines.flow_precision_index[PRECISIONS[precision_index]]
    for k = 1, BIG_SAMPLES do
      produced[k], consumed[k] = flow_sum(list, panel.name, precision, BIG_SAMPLES - k + 2)
    end
  else
    for k = 1, BIG_SAMPLES do produced[k], consumed[k] = 0, 0 end
  end
  return smooth(produced, window), smooth(consumed, window)
end

-- ---------- «Що змінилося?» ----------
-- Два однакові вікна поспіль завдовжки з обраний проміжок: попереднє й останнє. Зразки беремо з
-- наступного (грубшого) рівня, де вміщаються обидва вікна; найновіший неповний зразок пропускаємо.
-- Для найдовшого проміжку грубшого рівня немає — порівнюємо дві половини самого проміжку.
local CHANGE_THRESHOLD = 0.05 -- зміна, менша за 5 % більшого зі значень, — шум
local CHANGE_FLOOR = 0.1      -- /хв; менші зміни — шум навіть для дрібних потоків
local COLOR_MUTED = {0.6, 0.6, 0.6}

local function change_source(precision_index)
  local coarser = precision_index + 1
  if coarser <= #PRECISIONS then
    return PRECISIONS[coarser], math.floor(RANGE_SECONDS[precision_index] * 300 / RANGE_SECONDS[coarser] + 0.5), false
  end
  return PRECISIONS[precision_index], math.floor(BIG_SAMPLES / 2), true
end

local function window_caption(precision_index, half)
  if not half then return {"resbal.p-" .. PRECISIONS[precision_index]} end
  local seconds = RANGE_SECONDS[precision_index] / 2
  local unit, divisor = time_axis(seconds)
  return {"resbal.t-" .. unit, short_number(seconds / divisor)}
end

-- Середнє за count зразків, починаючи з first (1 — найновіший, ще неповний)
local function window_average(list, name, precision, first, count)
  local produced, consumed = 0, 0
  for k = first, first + count - 1 do
    local p, c = flow_sum(list, name, precision, k)
    produced, consumed = produced + p, consumed + c
  end
  return produced / count, consumed / count
end

-- {before = {produced, consumed}, after = {produced, consumed}}
local function panel_change(player, panel, precision_index)
  local source, count = change_source(precision_index)
  local result = {before = {produced = 0, consumed = 0}, after = {produced = 0, consumed = 0}}
  if not prototype_of(panel.type, panel.name) then return result end
  local list = sources(player.force, panel.surface, panel.type, panel.name)
  if #list == 0 then return result end
  local precision = defines.flow_precision_index[source]
  result.after.produced, result.after.consumed = window_average(list, panel.name, precision, 2, count)
  result.before.produced, result.before.consumed = window_average(list, panel.name, precision, 2 + count, count)
  return result
end

local function significant(delta, scale)
  return math.abs(delta) > math.max(CHANGE_FLOOR, CHANGE_THRESHOLD * scale)
end

-- Зміни й чи вони суттєві. Баланс зрушив, якщо змінилася лише одна сторона, або обидві —
-- у різні боки, або в один бік, але різниця помітна. «Разом» — обидві в один бік, баланс майже той самий.
local function analyze_change(change)
  local b, a = change.before, change.after
  local r = {produced = a.produced - b.produced, consumed = a.consumed - b.consumed}
  r.balance = r.produced - r.consumed
  r.produced_moved = significant(r.produced, math.max(a.produced, b.produced))
  r.consumed_moved = significant(r.consumed, math.max(a.consumed, b.consumed))
  if r.produced_moved and r.consumed_moved and (r.produced > 0) == (r.consumed > 0) then
    r.balance_moved = significant(r.balance, math.max(a.produced, b.produced, a.consumed, b.consumed))
  else
    r.balance_moved = r.produced_moved or r.consumed_moved
  end
  return r
end

-- Висновок одним рядком: що саме зрушило баланс
local function change_verdict(change, r)
  local b, a = change.before, change.after
  local was_active = b.produced > EPSILON or b.consumed > EPSILON
  local is_active = a.produced > EPSILON or a.consumed > EPSILON
  if was_active and not is_active then return {"resbal.change-stopped"}, COLOR_NEGATIVE end
  if is_active and not was_active then return {"resbal.change-started"}, nil end
  if not (r.produced_moved or r.consumed_moved) then return {"resbal.change-none"}, COLOR_MUTED end
  if not r.balance_moved then
    return {"resbal.change-together", format_balance(r.produced), format_balance(r.consumed)}, nil
  end

  -- причини в напрямку зміни балансу, від більшої
  local worse = r.balance < 0
  local causes = {}
  if r.produced_moved and (r.produced < 0) == worse then
    causes[#causes + 1] = {size = math.abs(r.produced),
                           text = {r.produced > 0 and "resbal.change-prod-up" or "resbal.change-prod-down", format_balance(r.produced)}}
  end
  if r.consumed_moved and (r.consumed > 0) == worse then
    causes[#causes + 1] = {size = math.abs(r.consumed),
                           text = {r.consumed > 0 and "resbal.change-cons-up" or "resbal.change-cons-down", format_balance(r.consumed)}}
  end
  table.sort(causes, function(x, y) return x.size > y.size end)
  local text = {""}
  for i, cause in ipairs(causes) do
    if i > 1 then text[#text + 1] = ", " end
    text[#text + 1] = cause.text
  end
  return {worse and "resbal.change-worse" or "resbal.change-better", format_number(math.abs(r.balance)), text},
         worse and COLOR_NEGATIVE or COLOR_POSITIVE
end

local function change_cell(tbl, before, after, balance)
  local fmt = balance and format_balance or format_number
  local label = tbl.add{type = "label", caption = fmt(before) .. " → " .. fmt(after)}
  label.style.minimal_width = 130
  label.style.horizontal_align = "right"
end

-- good_up: зростання — добре (виробництво, баланс) чи погано (споживання)
local function delta_cell(tbl, delta, moved, good_up)
  local label = tbl.add{type = "label", caption = format_balance(delta), style = moved and "bold_label" or "label"}
  label.style.minimal_width = 60
  label.style.horizontal_align = "right"
  if not moved then
    label.style.font_color = COLOR_MUTED
  else
    label.style.font_color = ((delta > 0) == good_up) and COLOR_POSITIVE or COLOR_NEGATIVE
  end
end

-- Таблиця під графіком: рядок на ресурс, під таблицею — висновки
local function fill_change(player, state, summary)
  summary.clear()
  local _, _, half = change_source(state.precision)
  local window = window_caption(state.precision, half)
  summary.add{type = "label", caption = {"resbal.change-title", window}, style = "bold_label",
              tooltip = {"resbal.change-title-tooltip"}}
  local tbl = summary.add{type = "table", column_count = 7, draw_horizontal_line_after_headers = true}
  tbl.style.horizontal_spacing = 12
  tbl.style.vertical_spacing = 2
  tbl.add{type = "empty-widget"}
  for _, key in ipairs({"produced", "consumed", "balance"}) do
    local head = tbl.add{type = "label", caption = {"resbal." .. key}, style = "bold_label"}
    head.style.minimal_width = 130
    head.style.horizontal_align = "right"
    local delta = tbl.add{type = "label", caption = {"resbal.change-delta"}, style = "bold_label"}
    delta.style.minimal_width = 60
    delta.style.horizontal_align = "right"
  end

  local verdicts = {}
  for _, panel in ipairs(state.panels) do
    local change = panel_change(player, panel, state.precision)
    local b, a = change.before, change.after
    local proto = prototype_of(panel.type, panel.name)
    tbl.add{type = "sprite", sprite = proto and (panel.type .. "/" .. panel.name) or "utility/questionmark",
            tooltip = panel_caption(panel)}
    local r = analyze_change(change)
    change_cell(tbl, b.produced, a.produced)
    delta_cell(tbl, r.produced, r.produced_moved, true)
    change_cell(tbl, b.consumed, a.consumed)
    delta_cell(tbl, r.consumed, r.consumed_moved, false)
    change_cell(tbl, b.produced - b.consumed, a.produced - a.consumed, true)
    delta_cell(tbl, r.balance, r.balance_moved, true)
    local text, color = change_verdict(change, r)
    verdicts[#verdicts + 1] = {text = #state.panels > 1 and {"", rich_icon(panel), " ", text} or text, color = color}
  end
  for _, verdict in ipairs(verdicts) do
    local label = summary.add{type = "label", caption = verdict.text}
    if verdict.color then label.style.font_color = verdict.color end
  end
end

local function draw_big(player)
  use_number_format(player)
  local state, frame = big_state(player), big_frame(player)
  if not (state and frame and state.panels and #state.panels > 0) then return end
  if state.tab == "flow" then return end
  destroy_objects(state)

  local surface = chart_surface()
  local origin = big_origin(player)
  local players = {player.index}
  local objects = state.objects
  local function at(px, py) return {origin.x + px / TILE, origin.y + py / TILE} end
  local function line(color, width, x1, y1, x2, y2)
    objects[#objects + 1] = rendering.draw_line{color = color, width = width, from = at(x1, y1), to = at(x2, y2),
                                                surface = surface, players = players}
  end
  local function rect(color, x1, y1, x2, y2)
    objects[#objects + 1] = rendering.draw_rectangle{color = color, filled = true, left_top = at(x1, y1),
                                                     right_bottom = at(x2, y2), surface = surface, players = players}
  end

  local layout, total_h = panel_layout(#state.panels)
  -- суцільний фон під усім полем камери: у проміжках між панелями інакше видно порожнечу поверхні
  -- (у 2.1 — з розмитими темними плямами); колір — як у рамки вікна
  rect({0.19, 0.19, 0.19}, -TILE, -TILE, BIG_W + TILE, total_h + TILE)
  local window = SMOOTHING[smoothing_level(state)]
  local plot_w = BIG_W - 2 * PAD_X
  local function x_of(k) return PAD_X + (k - 1) / (BIG_SAMPLES - 1) * plot_w end
  local bar_width = plot_w / (BIG_SAMPLES - 1) + 0.5 -- трохи внахлест, щоб вийшла суцільна заливка

  local inner = frame.resbal_big_inner
  local axis_labels = inner.resbal_big_plot.resbal_big_y.children
  local series = {}

  for i, panel in ipairs(state.panels) do
    local geometry = layout[i]
    local produced, consumed = panel_data(player, panel, state.precision, window)
    local balance = {}
    local max, balance_max = 0, 0
    for k = 1, BIG_SAMPLES do
      max = math.max(max, produced[k], consumed[k])
      balance[k] = produced[k] - consumed[k]
      balance_max = math.max(balance_max, math.abs(balance[k]))
    end
    series[i] = {produced = produced, consumed = consumed}

    -- поле графіка
    local chart_top, chart_bottom = geometry.top + PAD_Y, geometry.chart_bottom - PAD_Y
    local plot_h = chart_bottom - chart_top
    local top = nice_max(max)
    local function y_of(v)
      return math.max(chart_top, math.min(chart_bottom, chart_bottom - v / top * plot_h)) -- не виходимо за поле
    end
    rect({0.07, 0.07, 0.07}, 0, geometry.top, BIG_W, geometry.chart_bottom)
    for g = 0, 4 do
      local y = y_of(top * g / 4)
      line(g == 0 and {0.45, 0.45, 0.45} or {0.2, 0.2, 0.2}, 1, PAD_X, y, BIG_W - PAD_X, y)
    end
    for g = 0, 5 do
      local x = PAD_X + plot_w * g / 5
      line({0.2, 0.2, 0.2}, 1, x, chart_top, x, chart_bottom)
    end
    for _, s in ipairs({{consumed, COLOR_CONS}, {produced, COLOR_PROD}}) do
      local values = s[1]
      for k = 2, BIG_SAMPLES do
        line(s[2], 1.5, x_of(k - 1), y_of(values[k - 1]), x_of(k), y_of(values[k]))
      end
    end

    -- смуга балансу: вироблено − спожито від нуля (вгору надлишок, вниз нестача)
    local balance_top = nice_max(balance_max)
    rect({0.1, 0.1, 0.1}, 0, geometry.band_top, BIG_W, geometry.bottom)
    for g = 0, 5 do
      local x = PAD_X + plot_w * g / 5
      line({0.2, 0.2, 0.2}, 1, x, geometry.band_top, x, geometry.bottom)
    end
    local mid, half = geometry.band_mid, geometry.band_half
    line({0.2, 0.2, 0.2}, 1, PAD_X, mid - half, BIG_W - PAD_X, mid - half)
    line({0.2, 0.2, 0.2}, 1, PAD_X, mid + half, BIG_W - PAD_X, mid + half)
    for k = 1, BIG_SAMPLES do
      local value = balance[k]
      if math.abs(value) > EPSILON then
        local height = math.max(1, math.min(1, math.abs(value) / balance_top) * half)
        local x = x_of(k)
        if value > 0 then
          line(COLOR_PROD, bar_width, x, mid, x, mid - height)
        else
          line(COLOR_CONS, bar_width, x, mid, x, mid + height)
        end
      end
    end
    line({0.45, 0.45, 0.45}, 1, PAD_X, mid, BIG_W - PAD_X, mid)

    -- підписи осі значень: 5 для графіка (перший з іконкою ресурсу), 3 для смуги
    local base = (i - 1) * 8
    for g = 4, 0, -1 do
      local label = axis_labels[base + 5 - g]
      local value = format_number(top * g / 4, "auto")
      label.caption = (g == 4 and #state.panels > 1) and (rich_icon(panel) .. " " .. value) or value
    end
    axis_labels[base + 6].caption = "+" .. format_number(balance_top, "auto")
    axis_labels[base + 7].caption = "0"
    axis_labels[base + 8].caption = "−" .. format_number(balance_top, "auto")
  end
  fill_change(player, state, inner.resbal_big_summary)

  -- вісь часу
  local range = RANGE_SECONDS[state.precision]
  local unit, divisor = time_axis(range)
  for index, label in ipairs(inner.resbal_big_x.children) do
    label.caption = {"resbal.t-" .. unit, short_number(range * (1 - (index - 1) / 5) / divisor)}
  end

  -- позначки гравця: блакитні пунктирні лінії на всю висоту; текст — у підказці колонки
  local sample_seconds = range / 300
  local shown_marks = {}
  for _, mark in ipairs(marks.visible(player_data(player), range)) do
    local k = BIG_SAMPLES + 1 - mark.ago / sample_seconds -- той самий відлік, що й у підписах «тому»
    if k >= 1 then
      local x = x_of(math.min(k, BIG_SAMPLES))
      objects[#objects + 1] = rendering.draw_line{color = {0.4, 0.75, 1}, width = 2, from = at(x, 0), to = at(x, total_h),
                                                  dash_length = 6 / TILE, gap_length = 4 / TILE,
                                                  surface = surface, players = players}
      mark.k = k
      shown_marks[#shown_marks + 1] = mark
    end
  end

  -- підказки «значення в точці»: колонка на всю висоту — момент на всіх панелях одразу
  for c, column in ipairs(inner.resbal_big_plot.resbal_big_stack.resbal_big_cols.children) do
    local first = math.floor((c - 1) * BIG_SAMPLES / HOVER_COLUMNS) + 1
    local last = math.max(first, math.floor(c * BIG_SAMPLES / HOVER_COLUMNS))
    local count = last - first + 1
    local ago = (BIG_SAMPLES - (first + last) / 2 + 1) * sample_seconds -- +1 — пропущений неповний зразок
    local ago_unit, ago_divisor = time_axis(ago)
    local tooltip = {"", {"resbal.point-ago", {"resbal.t-" .. ago_unit, short_number(ago / ago_divisor)}}}
    for i, panel in ipairs(state.panels) do
      local p, q = 0, 0
      for k = first, last do p, q = p + series[i].produced[k], q + series[i].consumed[k] end
      p, q = p / count, q / count
      local point_balance = p - q
      tooltip[#tooltip + 1] = {"resbal.point-line", rich_icon(panel), format_number(p), format_number(q),
                               (point_balance > EPSILON and "+" or "") .. format_number(point_balance)}
    end
    local in_column = 0
    for _, mark in ipairs(shown_marks) do
      if mark.k >= first - 0.5 and mark.k <= last + 0.5 and in_column < 3 then
        in_column = in_column + 1
        local ago_unit, ago_divisor = time_axis(mark.ago)
        tooltip[#tooltip + 1] = {"resbal.mark-line", mark.text ~= "" and mark.text or "—",
                                 {"resbal.t-" .. ago_unit, short_number(mark.ago / ago_divisor)}}
      end
    end
    column.tooltip = tooltip
  end

  state.next_update = game.tick + BIG_REFRESH[state.precision]
end

-- ---------- виробники й споживачі (модуль scripts/flow.lua) ----------
local flow_tab = require("scripts.flow")({
  PRECISIONS = PRECISIONS,
  ALL_SURFACES = ALL_SURFACES,
  EPSILON = EPSILON,
  COLOR_NEGATIVE = COLOR_NEGATIVE,
  prototype_of = prototype_of,
  use_number_format = use_number_format,
  format_number = format_number,
  format_balance = format_balance,
  statistics = statistics,
  flow = flow,
  surfaces_of = surfaces_of,
  sources = sources,
  flow_sum = flow_sum,
  big_state = big_state,
  big_frame = big_frame,
  rich_icon = rich_icon,
  panel_caption = panel_caption,
})
local step_rescan, update_flow_tab, show_next_machine, build_flow_tab =
  flow_tab.step_rescan, flow_tab.update_flow_tab, flow_tab.show_next_machine, flow_tab.build_flow_tab

local function axis_label(parent)
  local label = parent.add{type = "label", caption = ""}
  label.style.font = "default-small"
  label.style.font_color = {0.7, 0.7, 0.7}
  label.style.height = AXIS_LABEL_H
  return label
end

local function build_big(player)
  if not storage.chart_hidden and game.surfaces[BIG_SURFACE] then -- сейви до 1.4: сховати службову поверхню
    hide_chart_surface(game.surfaces[BIG_SURFACE])
    storage.chart_hidden = true
  end
  local state = big_state(player)
  destroy_quietly(player, big_frame(player))
  if not (state and state.panels and #state.panels > 0) then
    update_opened(player)
    return
  end

  local frame = player.gui.screen.add{type = "frame", name = "resbal_big", direction = "vertical"}
  if state.location then
    frame.location = state.location
  else
    frame.auto_center = true
  end

  -- заголовок
  local single = #state.panels == 1 and state.panels[1]
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.style.vertical_align = "center"
  titlebar.add{type = "label", caption = single and panel_caption(single) or {"resbal.big-title-multi"},
               style = "frame_title", ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.right_margin = 4
  titlebar.add{type = "sprite-button", name = "resbal_big_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  local inner = frame.add{type = "frame", name = "resbal_big_inner", direction = "vertical",
                          style = "inside_shallow_frame_with_padding"}

  -- вкладки: графік / виробники й споживачі
  local tabs = inner.add{type = "flow", direction = "horizontal"}
  tabs.style.bottom_margin = 6
  for _, tab in ipairs({"chart", "flow"}) do
    local button = tabs.add{type = "button", name = "resbal_btab_" .. tab, caption = {"resbal.tab-" .. tab}}
    button.toggled = (state.tab or "chart") == tab
  end
  if state.tab == "flow" then
    destroy_objects(state) -- лінії графіка не потрібні, поки відкрита ця вкладка
    build_flow_tab(player, inner, state)
    return
  end
  state.tracker = nil -- вимірювання лише поки відкрита вкладка розкладу

  local precisions = inner.add{type = "flow", direction = "horizontal"}
  for i, key in ipairs(PRECISIONS) do
    local button = precisions.add{type = "button", name = "resbal_bprec_" .. i, caption = {"resbal.p-" .. key}}
    button.style.minimal_width = 48
    button.style.horizontally_stretchable = true
    button.toggled = (i == state.precision)
  end

  local smoothing = inner.add{type = "flow", direction = "horizontal"}
  smoothing.style.top_margin = 6
  smoothing.style.vertical_align = "center"
  smoothing.add{type = "label", caption = {"resbal.smooth"}, tooltip = {"resbal.smooth-tooltip"}}
  local chosen = state.smoothing or DEFAULT_SMOOTHING
  for i = 0, #SMOOTHING do -- 0 = «Авто»
    local button = smoothing.add{type = "button", name = "resbal_bsmooth_" .. i, caption = {"resbal.smooth-" .. i}}
    button.toggled = (i == chosen)
    if i == 0 then
      button.tooltip = {"resbal.smooth-auto-tooltip", {"resbal.smooth-" .. SMOOTHING_AUTO[state.precision]}}
    end
  end

  -- «чипи» ресурсів на графіку: іконка, назва, планета, прибрати; «+» — додати ресурс
  local chips = inner.add{type = "flow", name = "resbal_big_chips", direction = "horizontal"}
  chips.style.top_margin = 6
  chips.style.vertical_align = "center"
  chips.style.horizontal_spacing = 12
  for i, panel in ipairs(state.panels) do
    local chip = chips.add{type = "flow", direction = "horizontal"}
    chip.style.vertical_align = "center"
    chip.style.horizontal_spacing = 4
    local proto = prototype_of(panel.type, panel.name)
    chip.add{type = "sprite", sprite = proto and (panel.type .. "/" .. panel.name) or "utility/questionmark"}
    local chip_name = chip.add{type = "label", caption = panel_caption(panel), tooltip = panel_caption(panel)}
    chip_name.style.maximal_width = CHIP_NAME_WIDTH
    if panel.surface == ALL_SURFACES then
      local sigma = chip.add{type = "label", caption = "Σ", style = "bold_label", tooltip = {"resbal.all-surfaces"}}
      sigma.style.font = "default-large-bold"
    else
      local surface = game.surfaces[panel.surface]
      local planet = chip.add{type = "sprite", sprite = planet_sprite(surface),
                              tooltip = surface_caption(surface, panel.surface)}
      planet.style.size = 20
      planet.style.stretch_image_to_widget_size = true
    end
    if #state.panels > 1 then
      local remove = chip.add{type = "sprite-button", name = "resbal_bdel_" .. i, sprite = "utility/close",
                              style = "tool_button_red", tooltip = {"resbal.remove-panel"}}
      remove.style.size = 20
    end
  end
  if #state.panels < MAX_PANELS then
    local add_flow = chips.add{type = "flow", direction = "horizontal"}
    add_flow.style.vertical_align = "center"
    add_flow.style.horizontal_spacing = 8
    add_button(add_flow, "resbal_badd", 28, {"resbal.add-panel"})
    add_flow.add{type = "label", caption = {"resbal.add-panel-caption"}, tooltip = {"resbal.add-panel"}}
  end
  marks.add_button(chips)

  -- вісь значень зліва + камера + прозорі колонки; позиції підписів збігаються з сіткою
  local layout, total_h = panel_layout(#state.panels)
  local plot = inner.add{type = "flow", name = "resbal_big_plot", direction = "horizontal"}
  plot.style.top_margin = 8
  plot.style.horizontal_spacing = 0
  local y_axis = plot.add{type = "flow", name = "resbal_big_y", direction = "vertical"}
  y_axis.style.width = AXIS_Y_WIDTH
  y_axis.style.vertical_spacing = 0
  local previous_bottom = 0
  for _, geometry in ipairs(layout) do
    local chart_top, chart_bottom = geometry.top + PAD_Y, geometry.chart_bottom - PAD_Y
    local centers = {}
    for g = 4, 0, -1 do centers[#centers + 1] = chart_bottom - (chart_bottom - chart_top) * g / 4 end
    for _, offset in ipairs({-geometry.band_half, 0, geometry.band_half}) do
      centers[#centers + 1] = geometry.band_mid + offset
    end
    for index, center in ipairs(centers) do
      local top = math.floor(center - AXIS_LABEL_H / 2 + 0.5)
      local label = axis_label(y_axis)
      label.style.width = AXIS_Y_WIDTH - 6
      label.style.horizontal_align = "right"
      label.style.top_margin = top - previous_bottom
      if index > 5 then label.tooltip = {"resbal.band-tooltip"} end
      previous_bottom = top + AXIS_LABEL_H
    end
  end

  local stack = plot.add{type = "flow", name = "resbal_big_stack", direction = "vertical"}
  stack.style.vertical_spacing = 0
  local origin = big_origin(player)
  local camera = stack.add{type = "camera", name = "resbal_big_camera",
                           position = {origin.x + BIG_W / 2 / TILE, origin.y + total_h / 2 / TILE},
                           surface_index = chart_surface().index,
                           -- GUI масштабується на display_scale, а камера — на display_density_scale (DPI екрана),
                           -- тож щоб 1 px графіка = 1 одиниця GUI: зум = display_scale / display_density_scale
                           zoom = camera_zoom(player)}
  camera.style.width = BIG_W
  camera.style.height = total_h

  local columns = stack.add{type = "flow", name = "resbal_big_cols", direction = "horizontal"}
  columns.style.top_margin = -total_h
  columns.style.horizontal_spacing = 0
  for _ = 1, HOVER_COLUMNS do
    local column = columns.add{type = "button", style = "resbal_column_button"}
    column.style.width = BIG_W / HOVER_COLUMNS
    column.style.height = total_h
  end

  -- вісь часу знизу; координати відносно лівого краю камери
  local x_axis = inner.add{type = "flow", name = "resbal_big_x", direction = "horizontal"}
  x_axis.style.horizontal_spacing = 0
  local plot_w = BIG_W - 2 * PAD_X
  local previous_right = -AXIS_Y_WIDTH
  for g = 0, 5 do
    local left = math.floor(PAD_X + plot_w * g / 5 - AXIS_X_LABEL_W / 2 + 0.5)
    local label = axis_label(x_axis)
    label.style.width = AXIS_X_LABEL_W
    label.style.horizontal_align = "center"
    label.style.left_margin = left - previous_right
    previous_right = left + AXIS_X_LABEL_W
  end

  local summary = inner.add{type = "flow", name = "resbal_big_summary", direction = "vertical"}
  summary.style.top_margin = 6
  summary.style.vertical_spacing = 2

  draw_big(player)
  update_opened(player)
end

local function same_panel(a, b)
  return a.type == b.type and a.name == b.name and a.surface == b.surface
end

-- add = false: графік лише цього ресурсу; add = true: додати панеллю до відкритого графіка
local function open_big(player, type, name, surface_name, add)
  storage.big = storage.big or {}
  local state = storage.big[player.index] or {objects = {}}
  state.precision = state.precision or player_data(player).precision
  state.smoothing = state.smoothing or DEFAULT_SMOOTHING
  local panel = {type = type, name = name, surface = surface_name}
  if add and state.panels and #state.panels > 0 and big_frame(player) then
    for _, existing in ipairs(state.panels) do
      if same_panel(existing, panel) then return end
    end
    if #state.panels >= MAX_PANELS then
      player.create_local_flying_text{text = {"resbal.max-panels", MAX_PANELS}, create_at_cursor = true}
      return
    end
    state.panels[#state.panels + 1] = panel
  else
    state.panels = {panel}
  end
  storage.big[player.index] = state
  build_big(player)
end

local function close_big(player)
  destroy_quietly(player, big_frame(player))
  local state = big_state(player)
  if state then
    destroy_objects(state)
    state.panels = nil -- точність, згладжування і позицію вікна пам'ятаємо
  end
  update_opened(player) -- Esc знову закриватиме панель, якщо так налаштовано
end

-- ---------- події ----------

-- ---------- «Сторож»: перевірка порогів ----------
local WATCH_CHECK = 600 -- тіків між перевірками (10 с)

-- Середнє за останні window хвилин: точний проміжок гри — одразу, інакше — зразки ширшого проміжку
-- (найновіший неповний пропускаємо)
local function watch_average(player, entry, window, get_stats)
  local seconds = window * 60
  local index = #PRECISIONS
  for i = 1, #PRECISIONS do
    if RANGE_SECONDS[i] >= seconds then
      index = i
      break
    end
  end
  local list = sources(player.force, entry.surface, entry.type, entry.name, get_stats)
  if #list == 0 then return 0, 0 end
  local precision = defines.flow_precision_index[PRECISIONS[index]]
  if RANGE_SECONDS[index] == seconds then return flow_sum(list, entry.name, precision) end
  local count = math.max(1, math.floor(seconds * 300 / RANGE_SECONDS[index] + 0.5))
  return window_average(list, entry.name, precision, 2, count)
end

local function entry_where(entry)
  if entry.surface == ALL_SURFACES then return {"resbal.scope-all"} end
  return surface_caption(game.surfaces[entry.surface], entry.surface)
end

-- Кнопка мода вгорі: лічильник порушень і червоний стиль, у підказці — що саме порушено
-- violated = {{entry, list}}; many_lists — дописувати назву списку
local function update_top_watch(player, violated, paused, many_lists)
  local button = mod_gui.get_button_flow(player).resbal_top
  if not button then return end
  if #violated == 0 then
    button.style = mod_gui.button_style
    button.number = nil
    button.tooltip = paused and {"", {"resbal.title"}, "\n", {"resbal.watch-paused"}} or {"resbal.title"}
    return
  end
  button.style = "red_slot_button"
  button.number = #violated
  local tooltip = {"", {"resbal.title"}, "\n", {"resbal.watch-top", #violated}}
  for i, item in ipairs(violated) do
    if i > MAX_TOOLTIP_LINES then
      tooltip[#tooltip + 1] = {"resbal.more-surfaces", #violated - MAX_TOOLTIP_LINES}
      break
    end
    local entry = item.entry
    tooltip[#tooltip + 1] = {"", "\n[" .. entry.type .. "=" .. entry.name .. "] ",
                             prototype_of(entry.type, entry.name).localised_name, " (", entry_where(entry), ")",
                             many_lists and {"", " — ", lists.caption(item.list)} or ""}
  end
  button.tooltip = tooltip
end

local function check_watch(player)
  local data = player_data(player)
  local get_stats = stats_getter(player.force)
  local violated, fresh, changed = {}, {}, false
  local all_paused = true
  for _, list in ipairs(data.lists) do
    if not list.watch_paused then all_paused = false end
  end
  for entry, list in lists.each_entry(data) do
    local watch = entry.watch
    if watch and list.watch_paused then
      -- список на паузі: не перевіряємо й гасимо індикатори; після паузи порушення сповістять знову
      if watch.violated then changed = true end
      watch.violated = nil
    elseif watch and prototype_of(entry.type, entry.name) then
      local window = watch.window or DEFAULT_WATCH_WINDOW
      local produced, consumed = watch_average(player, entry, window, get_stats)
      local balance = produced - consumed
      local low_produced = watch.min_produced ~= nil and produced < watch.min_produced - EPSILON
      local low_balance = watch.min_balance ~= nil and balance < watch.min_balance - EPSILON
      if watch.snooze_until and not snooze_left(watch) then watch.snooze_until = nil end -- відкладення скінчилось
      local now = (low_produced or low_balance) and not snooze_left(watch)
      watch.produced, watch.consumed = produced, consumed
      if now ~= (watch.violated == true) then changed = true end
      if now and not watch.violated then
        -- нове порушення: сповіщаємо один раз, наступне — лише після відновлення
        local reasons = {""}
        if low_produced then
          reasons[#reasons + 1] = {"resbal.watch-alert-prod", format_number(produced), format_number(watch.min_produced)}
        end
        if low_balance then
          if #reasons > 1 then reasons[#reasons + 1] = ", " end
          reasons[#reasons + 1] = {"resbal.watch-alert-bal", format_balance(balance), format_balance(watch.min_balance)}
        end
        fresh[#fresh + 1] = {entry = entry, reasons = reasons, window = window}
      end
      watch.violated = now
      if now then violated[#violated + 1] = {entry = entry, list = list} end
    end
  end

  update_top_watch(player, violated, all_paused, #data.lists > 1)
  if #fresh > 0 then
    if player.mod_settings["resbal-watch-chat"].value then
      for _, alert in ipairs(fresh) do
        local entry = alert.entry
        -- тег [item=…] чат сам показує іконкою з назвою — окремо назву не додаємо
        player.print({"resbal.watch-alert", "[" .. entry.type .. "=" .. entry.name .. "]",
                      entry_where(entry), alert.reasons, alert.window},
                     {color = {1, 0.65, 0.4}, sound = defines.print_sound.never})
      end
    end
    if player.mod_settings["resbal-watch-sound"].value then player.play_sound{path = "utility/new_objective"} end
  end
  if changed and main_frame(player) then
    if #data.lists > 1 and not data.negative_only then build(player) else update(player) end
  end
end

check_watch_now = function(player)
  use_number_format(player)
  check_watch(player)
end

lists.init{build = build, player_data = player_data, after_change = check_watch_now}
marks.init{
  player_data = player_data,
  redraw = function(player) -- перемалювати відкритий графік (вкладка «Графік»)
    local state = big_state(player)
    if state and state.tab ~= "flow" and big_frame(player) then draw_big(player) end
  end,
  ago_caption = function(seconds)
    local unit, divisor = time_axis(seconds)
    return {"resbal.point-ago", {"resbal.t-" .. unit, short_number(seconds / divisor)}}
  end,
}

script.on_nth_tick(WATCH_CHECK, function()
  for _, player in pairs(game.connected_players) do
    use_number_format(player)
    check_watch(player)
  end
end)

local function init_player(player)
  player_data(player)
  ensure_top_button(player)
end

script.on_init(function()
  storage.players = {}
  for _, player in pairs(game.players) do
    init_player(player)
    request_translations(player)
  end
end)

-- Міграція з версій ≤ 0.4.3, де імена мали префікс rb (збігався з модом Recipe Book).
-- Прибирає лише елементи, створені цим модом. Повертає, чи були відкриті старі вікна.
local function remove_legacy_gui(player)
  local function destroy_own(element)
    if element and element.valid and element.get_mod() == script.mod_name then
      element.destroy()
      return true
    end
    return false
  end
  local had_main = destroy_own(player.gui.screen["rb_main"])
  local had_big = destroy_own(player.gui.screen["rb_big"])
  destroy_own(mod_gui.get_button_flow(player)["rb_top"])
  return had_main, had_big
end

script.on_configuration_changed(function()
  storage.players = storage.players or {}
  storage.pending = {}
  if game.surfaces["rb-charts"] then game.delete_surface("rb-charts") end
  if game.surfaces[BIG_SURFACE] then hide_chart_surface(game.surfaces[BIG_SURFACE]) end -- до 1.4 не ховали
  for _, player in pairs(game.players) do
    local had_main, had_big = remove_legacy_gui(player)
    init_player(player)
    local data = player_data(player)
    if data.precision < 1 or data.precision > #PRECISIONS then data.precision = DEFAULT_PRECISION end
    request_translations(player) -- набір предметів міг змінитися
    if had_main or main_frame(player) then set_open(player, true) end
    local state = big_state(player)
    if state and state.type then
      -- міграція з версій ≤ 0.6.1: один ресурс → список панелей
      state.panels = {{type = state.type, name = state.name, surface = state.surface}}
      state.type, state.name, state.surface = nil, nil, nil
    end
    if state then state.tracker = nil end -- формат зведення по машинах міг змінитися
    if state and state.panels and #state.panels > 0 and (had_big or big_frame(player)) then build_big(player) end
  end
end)

script.on_event(defines.events.on_force_created, function(event)
  if game.surfaces[BIG_SURFACE] then hide_chart_surface(game.surfaces[BIG_SURFACE], event.force) end
end)

script.on_event(defines.events.on_player_created, function(event)
  init_player(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  if not translations_of(player) then request_translations(player) end
end)

script.on_event(defines.events.on_player_locale_changed, function(event)
  request_translations(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_string_translated, function(event)
  local key = storage.pending and storage.pending[event.id]
  if not key then return end
  storage.pending[event.id] = nil
  local translations = translations_of(game.get_player(event.player_index))
  if translations and event.translated then translations[key] = lower(event.result) end
end)

script.on_event(defines.events.on_player_removed, function(event)
  if storage.players then storage.players[event.player_index] = nil end
  if storage.translations then storage.translations[event.player_index] = nil end
  if storage.big and storage.big[event.player_index] then
    destroy_objects(storage.big[event.player_index])
    storage.big[event.player_index] = nil
  end
  views[event.player_index] = nil
end)

script.on_event({defines.events.on_player_display_scale_changed,
                 defines.events.on_player_display_density_scale_changed}, function(event)
  local player = game.get_player(event.player_index)
  if big_frame(player) then build_big(player) end
end)

script.on_event("resbal-toggle", function(event)
  toggle(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "resbal-toggle" then toggle(game.get_player(event.player_index)) end
end)

script.on_event(defines.events.on_gui_click, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  local name = element.name
  local data = player_data(player)

  if lists.on_click(player, element) then return end
  if marks.on_click(player, element) then return end

  local watch_entry = element.tags and element.tags.resbal_watch
  if watch_entry then
    open_watch(player, watch_entry)
    return
  end
  if name == "resbal_watch_close" then
    if watch_frame(player) then watch_frame(player).destroy() end
    return
  elseif name == "resbal_watch_snooze" then
    toggle_snooze(player)
    return
  elseif name == "resbal_watch_pause" then
    local list = data.lists[data.active]
    list.watch_paused = not list.watch_paused or nil
    if check_watch_now then check_watch_now(player) end
    build(player)
    return
  elseif name == "resbal_watch_save" or name == "resbal_watch_remove" then
    save_watch(player, name == "resbal_watch_remove")
    return
  elseif name:find("^resbal_watch_win_") then
    set_watch_window(player, tonumber(name:match("%d+$")))
    return
  end

  local status = element.tags and element.tags.resbal_status
  if status then
    show_next_machine(player, status.key, status.group)
    return
  end

  local open = element.tags and element.tags.resbal_chart
  if open then
    -- Ctrl+клік або правий клік — додати панеллю до відкритого графіка
    local add = event.control or event.button == defines.mouse_button_type.right
    open_big(player, open.type, open.name, open.surface, add)
    return
  end

  if name == "resbal_big_close" then
    close_big(player)
  elseif name == "resbal_btab_chart" or name == "resbal_btab_flow" then
    big_state(player).tab = (name == "resbal_btab_flow") and "flow" or "chart"
    build_big(player)
  elseif name:find("^resbal_fprec_") then
    local state = big_state(player)
    state.flow_mode, state.flow_precision = "stats", tonumber(name:match("%d+$"))
    build_big(player)
  elseif name == "resbal_flive" then
    local state = big_state(player)
    state.flow_mode, state.tracker = "live", nil -- нове вимірювання з чистого старту
    build_big(player)
  elseif name:find("^resbal_bfocus_") then
    big_state(player).focus = tonumber(name:match("%d+$"))
    build_big(player)
  elseif name:find("^resbal_bdel_") then
    local state = big_state(player)
    table.remove(state.panels, tonumber(name:match("%d+$")))
    if #state.panels == 0 then close_big(player) else build_big(player) end
  elseif name:find("^resbal_bprec_") then
    big_state(player).precision = tonumber(name:match("%d+$"))
    build_big(player)
  elseif name:find("^resbal_bsmooth_") then
    big_state(player).smoothing = tonumber(name:match("%d+$"))
    build_big(player)
  elseif name == "resbal_top" then
    toggle(player)
  elseif name == "resbal_close" then
    set_open(player, false)
  elseif name:find("^resbal_prec_") then
    data.precision = tonumber(name:match("%d+$"))
    build(player)
  elseif name == "resbal_mode_list" or name == "resbal_mode_negative" then
    data.negative_only = (name == "resbal_mode_negative")
    data.sort_key = nil
    build(player)
  elseif name == "resbal_scope_here" or name == "resbal_scope_all" then
    data.add_all = (name == "resbal_scope_all")
    build(player)
  elseif name:find("^resbal_sort_") then
    local key = name:sub(#"resbal_sort_" + 1)
    if data.sort_key ~= key then
      data.sort_key, data.sort_asc = key, DEFAULT_ASC[key]
    elseif data.sort_asc == DEFAULT_ASC[key] then
      data.sort_asc = not data.sort_asc       -- другий клік — зворотний напрям
    else
      data.sort_key = nil                     -- третій клік — без сортування
    end
    build(player)
  elseif name:find("^resbal_act_") then
    local tags = element.tags
    if tags.resbal_action == "del" then
      table.remove(data.entries, tags.entry)
      build(player)
    elseif tags.resbal_action == "pin" then
      add_entry(player, tags.type, tags.name, tags.surface)
      player.create_local_flying_text{text = {"resbal.pinned"}, create_at_cursor = true}
    end
  end
end)

-- Esc / E / відкриття іншого вікна гри
script.on_event(defines.events.on_gui_confirmed, function(event)
  local element = event.element
  if element and element.valid and lists.on_confirmed(game.get_player(event.player_index), element) then return end
  if element and element.valid and marks.on_confirmed(game.get_player(event.player_index), element) then return end
  if element and element.valid and (element.name == "resbal_watch_prod" or element.name == "resbal_watch_bal") then
    save_watch(game.get_player(event.player_index))
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if quiet[event.player_index] then return end
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  if element == big_frame(player) then
    close_big(player)
  elseif element == main_frame(player) then
    set_open(player, false)
  end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  local player = event.player_index and game.get_player(event.player_index)
  if not player then return end
  if event.setting == "resbal-close-on-esc" then
    update_opened(player)
  elseif event.setting == "resbal-refresh" and main_frame(player) then
    update(player)
  elseif event.setting == "resbal-number-format" then
    if main_frame(player) then build(player) end -- міні-графіки теж (підказки)
    if big_frame(player) then build_big(player) end
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  local element = event.element
  if not (element and element.valid and element.name == "resbal_search") then return end
  local player = game.get_player(event.player_index)
  player_data(player).search = event.text
  update(player)
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  local element = event.element
  if not (element and element.valid and (element.name == "resbal_add" or element.name == "resbal_badd")) then return end
  local value = element.elem_value
  if not value then return end
  local player = game.get_player(event.player_index)
  local type = value.type or "item"

  if type ~= "item" and type ~= "fluid" then
    player.print({"resbal.only-items-fluids"})
    element.elem_value = nil
    return
  end
  -- ресурс прив'язується до планети, на якій гравець зараз (або до «Усіх планет» у списку)
  local surface_name = player_data(player).add_all and ALL_SURFACES or player.surface.name
  if element.name == "resbal_badd" then
    open_big(player, type, value.name, surface_name, true) -- додати панеллю до великого графіка
  else
    add_entry(player, type, value.name, surface_name)
    build(player)
  end
end)

script.on_event(defines.events.on_gui_location_changed, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  if element.name == "resbal_main" then
    player_data(player).location = element.location
  elseif element.name == "resbal_big" and big_state(player) then
    big_state(player).location = element.location
  end
end)

script.on_event(defines.events.on_player_changed_surface, function(event)
  local player = game.get_player(event.player_index)
  if player and main_frame(player) then update(player) end
end)

-- Оновлення за розкладом обраного проміжку; графіки після кожного оновлення
-- перераховуються по черзі (кілька за тік), щоб не було ривків
script.on_event(defines.events.on_tick, function(event)
  for _, player in pairs(game.connected_players) do
    local frame = main_frame(player)
    if frame then
      local view = views[player.index]
      if not view or event.tick >= view.next_update then
        update(player)
        view = views[player.index]
      end
      local rows = view.rows
      if view.chart_cursor <= #rows then
        local tbl = frame.resbal_inner.resbal_scroll.resbal_table
        local data = player_data(player)
        for _ = 1, CHARTS_PER_TICK do
          local i = view.chart_cursor
          if i > #rows then break end
          local chart = tbl["resbal_chart_" .. i]
          if chart then update_chart(player, chart, rows[i], data) end
          view.chart_cursor = i + 1
        end
      end
    end

    -- великий графік: власний розклад оновлення
    local state = big_state(player)
    if state and state.panels and #state.panels > 0 and big_frame(player) then
      if state.tab == "flow" then
        local tracker = state.tracker
        if tracker and tracker.scan then
          -- перепошук машин порціями по тіках; по завершенні — одразу оновити таблиці
          if step_rescan(tracker) or not tracker.recipes then update_flow_tab(player) end
        elseif event.tick >= (state.flow_next or 0) then
          update_flow_tab(player)
        end
      elseif event.tick >= (state.next_update or 0) then
        draw_big(player)
      end
    end
  end
end)
