local mod_gui = require("mod-gui")
local lists = require("scripts.lists") -- кілька списків ресурсів (вкладки)
local marks = require("scripts.marks") -- позначки на великому графіку
local watchlog = require("scripts.watchlog") -- журнал спрацювань сторожа
local chain = require("scripts.chain") -- «створити список з інгредієнтів»
local rootcause = require("scripts.rootcause") -- «знайти першопричини»
local machines = require("scripts.machines") -- фоновий облік станів машин (історія простою)
local idle = require("scripts.idle") -- вікно «Простої фабрики»
local watchtab = require("scripts.watchtab") -- вкладка «Сторож» вікна ресурсу
local diag = require("scripts.diag") -- вікно «Діагностика фабрики» (Простої + Журнал)
local fluidstock = require("scripts.fluidstock") -- запас рідин у резервуарах (колонка «Запас»)

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
local CHART_IMMEDIATE = 10  -- скільки графіків рахувати одразу, коли рядок змінився
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

-- Стан відображення панелі по гравцях: views[player_index] = {count, rows, keys, collected, next_update,
-- chart_cursor, chart_cache}. Живе в storage.views (а не в змінній модуля): від нього залежить, коли
-- оновлюється панель, а оновлення пише в storage (кеш якостей, запас рідин, лічильник дефіциту). Якби стан
-- був локальним, гравець, що щойно під'єднався, оновлював би чужі панелі в інші тіки — розсинхрон.
-- views — «вікно» в storage.views (лише читання/запис за ключем; pairs по ньому не працює).
local views = setmetatable({}, {
  __index = function(_, index)
    return storage.views and storage.views[index]
  end,
  __newindex = function(_, index, value)
    storage.views = storage.views or {}
    storage.views[index] = value
  end,
})

-- Графік показує ширший проміжок, ніж цифри: наступний рівень (5с → 1хв, 1хв → 10хв, …).
-- Джерело зразків — найгрубша статистика, де на графік припадає ≥ 30 зразків (кожен зразок гри — вже
-- середнє за свій відрізок; один зразок може тягнутися на 2 точки). Раніше бралося ≥ 60 (до 299 зразків
-- на графік) — у «Тільки мінус» на сотню рядків це десятки тисяч звернень до гри за оновлення.
-- n — скільки останніх зразків охоплює графік.
local CHART_MIN_SAMPLES = 30
local CHART_SOURCE = {}
for i = 1, #PRECISIONS do
  local window = RANGE_SECONDS[math.min(i + 1, #PRECISIONS)]
  local source = 1
  for s = 1, #PRECISIONS do
    if RANGE_SECONDS[s] <= window * 300 / CHART_MIN_SAMPLES then source = s end
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

-- Якості предметів. get_flow_count / get_input_count / get_item_count з простим ім'ям рахують лише
-- normal (перевірено в 2.1: 20 normal + 20 uncommon → 20), тож для предметів сумуємо по всіх якостях.
-- Без Space Age якість одна — викликів стільки ж, як і раніше. Список будується ліниво (prototypes
-- незмінні під час гри, порядок pairs однаковий у всіх гравців).
local quality_list
local function qualities()
  if not quality_list then
    quality_list = {}
    for name in pairs(prototypes.quality) do
      if name ~= "quality-unknown" then quality_list[#quality_list + 1] = name end
    end
    if #quality_list == 0 then quality_list[1] = "normal" end
  end
  return quality_list
end

-- Сума count_of({name, quality}) по всіх якостях предмета; для рідин — один виклик з іменем
local function by_quality(type, name, count_of)
  if type == "fluid" then return count_of(name) end
  local total = 0
  for _, quality in ipairs(qualities()) do total = total + count_of({name = name, quality = quality}) end
  return total
end

-- Якості, що реально траплялися для предмета на поверхні (лічильник за весь час > 0) — щоб не питати гру
-- про всі 5 якостей щоразу (міні-графік — до 299 зразків). Кеш у storage (однаковий у всіх гравців
-- мультиплеєра), перевірка нових якостей — раз на QUALITY_RECHECK.
local QUALITY_RECHECK = 18000 -- 5 хв
local function active_qualities(stats, surface_index, name)
  local all = qualities()
  if #all == 1 or not surface_index then return all end
  storage.quality_cache = storage.quality_cache or {}
  local key = surface_index .. "/" .. name
  local cached = storage.quality_cache[key]
  if cached and game.tick - cached.tick < QUALITY_RECHECK then return cached.list end
  local list = {}
  for _, quality in ipairs(all) do
    local id = {name = name, quality = quality}
    if quality == "normal" or stats.get_input_count(id) > 0 or stats.get_output_count(id) > 0 then
      list[#list + 1] = quality
    end
  end
  storage.quality_cache[key] = {tick = game.tick, list = list}
  return list
end

-- input = вироблено, output = спожито; значення за хвилину; type — "item" (за замовчуванням) або "fluid";
-- surface_index — для кешу якостей (без нього — усі якості)
local function flow(stats, name, precision, sample_index, type, surface_index)
  if type == "fluid" then
    return sane(stats.get_flow_count{name = name, category = "input", precision_index = precision,
                                     sample_index = sample_index}),
           sane(stats.get_flow_count{name = name, category = "output", precision_index = precision,
                                     sample_index = sample_index})
  end
  local produced, consumed = 0, 0
  for _, quality in ipairs(active_qualities(stats, surface_index, name)) do
    local id = {name = name, quality = quality}
    produced = produced + sane(stats.get_flow_count{name = id, category = "input", precision_index = precision,
                                                    sample_index = sample_index})
    consumed = consumed + sane(stats.get_flow_count{name = id, category = "output", precision_index = precision,
                                                    sample_index = sample_index})
  end
  return produced, consumed
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
    if surface_name ~= ALL_SURFACES or by_quality(type, name, function(id) return stats.get_input_count(id) end) > 0
       or by_quality(type, name, function(id) return stats.get_output_count(id) end) > 0 then
      list[#list + 1] = {surface = surface, stats = stats, type = type}
    end
  end
  return list
end

-- Сума потоку по всіх джерелах
local function flow_sum(list, name, precision, sample_index)
  local produced, consumed = 0, 0
  for _, source in ipairs(list) do
    local p, c = flow(source.stats, name, precision, sample_index, source.type, source.surface.index)
    produced, consumed = produced + p, consumed + c
  end
  return produced, consumed
end

-- ---------- головна панель (модуль scripts/panel.lua) ----------
local panel = require("scripts.panel")({
  diag = diag,
  active_qualities = active_qualities,
  ALL_SURFACES = ALL_SURFACES,
  CHART_HEIGHT = CHART_HEIGHT,
  CHART_IMMEDIATE = CHART_IMMEDIATE,
  CHART_POINTS = CHART_POINTS,
  CHART_SOURCE = CHART_SOURCE,
  COLOR_NEGATIVE = COLOR_NEGATIVE,
  COLOR_NEUTRAL = COLOR_NEUTRAL,
  COLOR_POSITIVE = COLOR_POSITIVE,
  COLUMNS = COLUMNS,
  EPSILON = EPSILON,
  LINE_WIDTH = LINE_WIDTH,
  MAX_PLANET_ICONS = MAX_PLANET_ICONS,
  NAME_MAX_WIDTH = NAME_MAX_WIDTH,
  NAME_WIDTH = NAME_WIDTH,
  NUMBER_WIDTH = NUMBER_WIDTH,
  PLANETS_WIDTH = PLANETS_WIDTH,
  PLANET_ICON = PLANET_ICON,
  PRECISIONS = PRECISIONS,
  REFRESH_TICKS = REFRESH_TICKS,
  ROW_HEIGHT = ROW_HEIGHT,
  TILE_PADDING = TILE_PADDING,
  active_surfaces = active_surfaces,
  all_surfaces_tooltip = all_surfaces_tooltip,
  by_quality = by_quality,
  flow = flow,
  flow_sum = flow_sum,
  fluidstock = fluidstock,
  format_balance = format_balance,
  format_number = format_number,
  idle = idle,
  lists = lists,
  lower = lower,
  mod_gui = mod_gui,
  planet_sprite = planet_sprite,
  player_data = player_data,
  prototype_of = prototype_of,
  qualities = qualities,
  request_translations = request_translations,
  search_text = search_text,
  sources = sources,
  stats_getter = stats_getter,
  surface_caption = surface_caption,
  surfaces_of = surfaces_of,
  translations_of = translations_of,
  use_number_format = use_number_format,
  views = views,
  watchlog = watchlog,
})
local DEFAULT_WATCH_WINDOW, DIALOG_NAMES, SNOOZE_MINUTES, WATCH_WINDOWS, add_button, add_entry =
  panel.DEFAULT_WATCH_WINDOW, panel.DIALOG_NAMES, panel.SNOOZE_MINUTES, panel.WATCH_WINDOWS, panel.add_button, panel.add_entry
local build, destroy_quietly, ensure_top_button, main_frame, quiet, set_open =
  panel.build, panel.destroy_quietly, panel.ensure_top_button, panel.main_frame, panel.quiet, panel.set_open
local snooze_left, toggle, top_dialog, update, update_chart, update_opened =
  panel.snooze_left, panel.toggle, panel.top_dialog, panel.update, panel.update_chart, panel.update_opened

-- ---------- вікно «Сторожа» ----------

local check_watch_now -- check_watch(player); оголошено нижче, після допоміжних функцій графіка

-- ---------- великий графік ----------

local BIG_TABS = {"chart", "flow", "roots", "watch"} -- вкладки вікна ресурсу

local function big_state(player)
  return storage.big and storage.big[player.index]
end

local function big_frame(player)
  return player.gui.screen.resbal_big
end

-- Вміст відкритої вкладки великого вікна (редизайн 1.7: справжній tabbed-pane — вміст усередині нього)
local function big_inner(frame)
  local tabs = frame and frame.resbal_big_tabs
  return tabs and tabs.resbal_big_inner
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
  -- другий результат — значок стану (колір несе значок, текст звичайний)
  if was_active and not is_active then return {"resbal.change-stopped"}, "utility/status_not_working" end
  if is_active and not was_active then return {"resbal.change-started"}, "utility/status_working" end
  if not (r.produced_moved or r.consumed_moved) then return {"resbal.change-none"}, "utility/status_inactive" end
  if not r.balance_moved then
    return {"resbal.change-together", format_balance(r.produced), format_balance(r.consumed)}, "utility/status_inactive"
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
         worse and "utility/status_not_working" or "utility/status_working"
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
    local text, icon = change_verdict(change, r)
    text = {"", "[img=" .. icon .. "] ", text}
    verdicts[#verdicts + 1] = {text = #state.panels > 1 and {"", rich_icon(panel), " ", text} or text}
  end
  for _, verdict in ipairs(verdicts) do
    summary.add{type = "label", caption = verdict.text}
  end
end

local function draw_big(player)
  use_number_format(player)
  local state, frame = big_state(player), big_frame(player)
  if not (state and frame and state.panels and #state.panels > 0) then return end
  if (state.tab or "chart") ~= "chart" then return end
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

  local inner = big_inner(frame)
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

  -- позначки гравця: пунктирні лінії на всю висоту (ручні — блакитні, сторожа — за видом); текст — у підказці
  local sample_seconds = range / 300
  local shown_marks = {}
  for _, mark in ipairs(marks.visible(player_data(player), range, state.panels)) do
    local k = BIG_SAMPLES + 1 - mark.ago / sample_seconds -- той самий відлік, що й у підписах «тому»
    if k >= 1 then
      local x = x_of(math.min(k, BIG_SAMPLES))
      objects[#objects + 1] = rendering.draw_line{color = marks.color(mark.auto), width = 2, from = at(x, 0), to = at(x, total_h),
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
        tooltip[#tooltip + 1] = {"resbal.mark-line", marks.colored(mark.auto, mark.text ~= "" and mark.text or "—"),
                                 {"resbal.t-" .. ago_unit, short_number(mark.ago / ago_divisor)}}
      end
    end
    column.tooltip = tooltip
  end

  state.next_update = game.tick + BIG_REFRESH[state.precision]
end

-- ---------- виробники й споживачі (модуль scripts/flow.lua) ----------
local flow_tab = require("scripts.flow")({
  -- ціль випуску ресурсу панелі: з будь-якого списку гравця (спершу відкритий), або nil
  target_of = function(player, panel)
    local data = player_data(player)
    local found
    for entry, list in lists.each_entry(data) do
      if entry.target and entry.type == panel.type and entry.name == panel.name and entry.surface == panel.surface then
        if list == data.lists[data.active] then return entry.target end
        found = found or entry.target
      end
    end
    return found
  end,
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
rootcause.init{
  find = flow_tab.root_causes,
  format_balance = format_balance,
  big_inner = function(player) return big_inner(big_frame(player)) end,
  ensure_tracker = function(player) return flow_tab.ensure_tracker(player, big_state(player)) end,
}
idle.init{
  player_data = player_data,
  diag_inner = function(player, key) return diag.inner(player, key) end,
  machines = machines,
  format_balance = format_balance,
  surface_caption = surface_caption,
  balance = function(player, type, name, surface_name, precision_name)
    if not prototype_of(type, name) then return nil end
    local produced, consumed = flow_sum(sources(player.force, surface_name, type, name), name,
                                        defines.flow_precision_index[precision_name])
    return produced - consumed
  end,
}
chain.init{player_data = player_data, lists = lists, candidates = flow_tab.chain_candidates, open_panel = function(player) set_open(player, true) end}

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

  -- заголовок: назва першого ресурсу (при порівнянні — «Аміак +2»), кошик (прибрати зі списку), закрити
  local first = state.panels[1]
  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.style.vertical_align = "center"
  titlebar.add{type = "label", style = "frame_title", ignored_by_interaction = true,
               caption = #state.panels == 1 and panel_caption(first)
                         or {"resbal.big-title-plus", panel_caption(first), #state.panels - 1}}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.height = 24
  drag.style.horizontally_stretchable = true
  drag.style.right_margin = 4
  local in_list = false
  for _, entry in ipairs(player_data(player).entries) do
    if #state.panels == 1 and entry.type == first.type and entry.name == first.name and entry.surface == first.surface then
      in_list = true
    end
  end
  if in_list then
    titlebar.add{type = "sprite-button", name = "resbal_big_remove", sprite = "utility/trash",
                 style = "frame_action_button", tooltip = {"resbal.big-remove"}}
  end
  titlebar.add{type = "sprite-button", name = "resbal_big_close", sprite = "utility/close",
               style = "frame_action_button", tooltip = {"resbal.close"}}

  -- справжні вкладки (tabbed-pane): вміст будується лише для відкритої, решта — порожні заглушки
  local current = state.tab or "chart"
  local tabbed = frame.add{type = "tabbed-pane", name = "resbal_big_tabs"}
  local inner, selected = nil, 1
  for index, key in ipairs(BIG_TABS) do
    local tab = tabbed.add{type = "tab", name = "resbal_btab_" .. key, caption = {"resbal.tab-" .. key}}
    local content
    if key == current then
      content = tabbed.add{type = "frame", name = "resbal_big_inner", direction = "vertical",
                           style = "inside_shallow_frame_with_padding"}
      inner = content
      selected = index
    else
      content = tabbed.add{type = "empty-widget", name = "resbal_btab_empty_" .. key}
    end
    tabbed.add_tab(tab, content)
  end
  -- відкриту вкладку вибираємо ПІСЛЯ додавання всіх (раніше номер вкладки, якої ще нема, гра ігнорувала)
  tabbed.selected_tab_index = selected
  if current ~= "chart" then
    destroy_objects(state) -- лінії графіка не потрібні, поки відкрита інша вкладка
    if current ~= "flow" and current ~= "roots" then state.tracker = nil end -- скан потрібен і першопричинам
  end
  if current == "flow" then
    build_flow_tab(player, inner, state)
    update_opened(player)
    return
  elseif current == "roots" then
    rootcause.build_tab(inner, player)
    update_opened(player)
    return
  elseif current == "watch" then
    watchtab.build_tab(inner, player)
    update_opened(player)
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
  marks.add_button(chips, player)
  marks.add_panel(inner, player) -- розгортувана панель позначок (замість окремого діалогу)

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
  local active_log = {} -- id відкритих записів журналу, на які ще посилаються сторожі
  local all_paused = true
  for _, list in ipairs(data.lists) do
    if not list.watch_paused then all_paused = false end
  end
  for entry, list in lists.each_entry(data) do
    local watch = entry.watch
    if watch and list.watch_paused then
      -- список на паузі: не перевіряємо й гасимо індикатори; після паузи порушення сповістять знову
      if watch.violated then
        changed = true
        marks.add_auto(player, entry, "pause", {since = watch.violated_since})
        watchlog.close(player, watch.log_id, "pause")
      end
      watch.violated, watch.violated_since, watch.log_id = nil, nil, nil
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
        watch.violated_since = game.tick
        marks.add_auto(player, entry, "alert", {reasons = reasons})
        watch.log_id = watchlog.open(player, entry, lists.caption(list), reasons, produced, balance)
      elseif now then
        watchlog.update(player, watch.log_id, produced, balance) -- порушення триває: мінімуми
      elseif watch.violated then
        -- кінець порушення: справжнє відновлення або лише відкладення (поріг досі порушено)
        local how = (low_produced or low_balance) and "snooze" or "recover"
        marks.add_auto(player, entry, how, {since = watch.violated_since})
        watchlog.close(player, watch.log_id, how)
        watch.violated_since, watch.log_id = nil, nil
      end
      watch.violated = now
      if now then violated[#violated + 1] = {entry = entry, list = list} end
    end
    if watch and watch.log_id then active_log[watch.log_id] = true end
  end
  watchlog.close_orphans(player, active_log)

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
  big_inner = function(player) return big_inner(big_frame(player)) end,
  panels = function(player) -- ресурси на відкритому графіку (для фільтра автопозначок)
    local state = big_state(player)
    return state and state.panels
  end,
  redraw = function(player) -- перемалювати відкритий графік (вкладка «Графік»)
    local state = big_state(player)
    if state and state.tab ~= "flow" and big_frame(player) then draw_big(player) end
  end,
  ago_caption = function(seconds)
    local unit, divisor = time_axis(seconds)
    return {"resbal.point-ago", {"resbal.t-" .. unit, short_number(seconds / divisor)}}
  end,
  duration_caption = function(seconds) -- «14хв» для автопозначок сторожа
    local unit, divisor = time_axis(seconds)
    return {"resbal.t-" .. unit, short_number(seconds / divisor)}
  end,
}
diag.init{player_data = player_data, surface_caption = surface_caption, idle = idle, watchlog = watchlog}
watchlog.init{
  player_data = player_data,
  diag_inner = function(player, key) return diag.inner(player, key) end,
  format_number = format_number,
  format_balance = format_balance,
  where = entry_where,
  ago_caption = function(seconds)
    local unit, divisor = time_axis(seconds)
    return {"resbal.point-ago", {"resbal.t-" .. unit, short_number(seconds / divisor)}}
  end,
  duration_caption = function(seconds)
    local unit, divisor = time_axis(seconds)
    return {"resbal.t-" .. unit, short_number(seconds / divisor)}
  end,
}

watchtab.init{
  player_data = player_data,
  prototype_of = prototype_of,
  ALL_SURFACES = ALL_SURFACES,
  DEFAULT_WATCH_WINDOW = DEFAULT_WATCH_WINDOW,
  WATCH_WINDOWS = WATCH_WINDOWS,
  SNOOZE_MINUTES = SNOOZE_MINUTES,
  snooze_left = snooze_left,
  format_number = format_number,
  format_balance = format_balance,
  marks = marks,
  watchlog = watchlog,
  lists = lists,
  big_inner = function(player) return big_inner(big_frame(player)) end,
  focused = function(player) -- ресурс у фокусі вікна (при порівнянні — обраний у «Виробниках»)
    local state = big_state(player)
    return state.panels[math.max(1, math.min(state.focus or 1, #state.panels))]
  end,
  current = function(player, entry, window) return watch_average(player, entry, window, stats_getter(player.force)) end,
  after_change = function(player)
    if main_frame(player) then update(player) end
    check_watch_now(player)
  end,
  rebuild = function(player) build_big(player) end,
  ago_caption = function(seconds)
    local unit, divisor = time_axis(seconds)
    return {"resbal.point-ago", {"resbal.t-" .. unit, short_number(seconds / divisor)}}
  end,
  duration_caption = function(seconds)
    local unit, divisor = time_axis(seconds)
    return {"resbal.t-" .. unit, short_number(seconds / divisor)}
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
  machines.rebuild()
  fluidstock.rebuild()
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
  machines.rebuild() -- набір машин міг змінитися (нові моди, міграції)
  fluidstock.rebuild()
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

-- Реєстр машин для фонового обліку станів: усі способи побудови (фільтр — лише машини з рецептами).
-- Знесені не відстежуємо — вони випадають з реєстру під час опитування.
for _, id in ipairs({defines.events.on_built_entity, defines.events.on_robot_built_entity,
                     defines.events.on_space_platform_built_entity, defines.events.script_raised_built,
                     defines.events.script_raised_revive, defines.events.on_entity_cloned}) do
  local filter = {{filter = "type", type = fluidstock.TYPE}} -- резервуари (запас рідин) + машини з рецептами
  for _, item in ipairs(machines.BUILT_FILTER) do filter[#filter + 1] = item end
  script.on_event(id, function(event)
    machines.on_built(event)
    fluidstock.on_built(event)
  end, filter)
end

-- Тимчасова команда заміру: скільки коштує опитування (для рішення про вкладку простою всієї фабрики)
commands.add_command("resbal-perf", {"resbal.perf-help"}, function(command)
  local player = command.player_index and game.get_player(command.player_index)
  local profiler = helpers.create_profiler()
  local done = machines.step(game.tick, 1000)
  profiler.stop()
  local interval = tonumber(settings.global["resbal-history-interval"].value)
  local per_tick = interval and math.ceil(machines.count() / (interval * 60)) or 0
  local message = {"resbal.perf-result", machines.count(), done, profiler, per_tick}
  if player then player.print(message) else game.print(message) end
  -- резервуари: один перерахунок поверхні гравця (так раз на 10 с, поки відкрита панель)
  local surface = player and player.surface or game.surfaces[1]
  local tanks = helpers.create_profiler()
  fluidstock.recompute(surface.index)
  tanks.stop()
  local tanks_message = {"resbal.perf-tanks", fluidstock.count(), tanks}
  if player then player.print(tanks_message) else game.print(tanks_message) end
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

-- Клавіша «додати під курсором»: що саме додати за прототипом під курсором (тип, назва) або nil
local HOVER_CRAFTERS = {["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true}

local function recipe_product(recipe)
  if not recipe then return nil end
  local product = recipe.main_product or (#recipe.products == 1 and recipe.products[1]) or recipe.products[1]
  if product and (product.type == "item" or product.type == "fluid") then return product.type, product.name end
  return nil
end

local function hovered_resource(player, selected)
  local base, name = selected.base_type, selected.name
  if base == "item" or base == "fluid" then return base, name end
  if base == "recipe" then return recipe_product(prototypes.recipe[name]) end
  if base ~= "entity" then return nil end
  local entity = player.selected
  if entity and entity.valid and entity.name == name then
    local ore = entity.type == "resource" and entity -- родовище: те, що з нього видобувається
    if entity.type == "mining-drill" then ore = entity.mining_target end -- бур (і качалка): його поточне родовище
    if ore and ore.valid then
      local products = ore.prototype.mineable_properties.products
      if products and products[1] then return products[1].type, products[1].name end
    elseif entity.type == "offshore-pump" then -- насос на воді: рідина під ним
      local fluid = entity.get_fluid_source_fluid()
      if fluid then return "fluid", fluid end
    elseif HOVER_CRAFTERS[entity.type] then -- машина: продукт її рецепта (піч без входу — попередній)
      -- get_recipe() повертає LuaRecipe (рецепт сили, без main_product) — беремо прототип за назвою
      local current = entity.get_recipe()
      local recipe = current and prototypes.recipe[current.name]
      if not recipe and entity.type == "furnace" and entity.previous_recipe then
        local previous = entity.previous_recipe.name
        recipe = prototypes.recipe[type(previous) == "string" and previous or (previous and previous.name)]
      end
      local product_type, product_name = recipe_product(recipe)
      if product_type then return product_type, product_name end
    end
  end
  -- інша будівля (скриня, конвеєр, порожня машина) — нічого: саму будівлю додають, навівши на її предмет
  return nil
end

script.on_event("resbal-add-hovered", function(event)
  local player = game.get_player(event.player_index)
  local selected = event.selected_prototype
  local type, name = nil, nil
  if selected then type, name = hovered_resource(player, selected) end
  if not (type and prototype_of(type, name)) then
    player.create_local_flying_text{text = {"resbal.hover-nothing"}, create_at_cursor = true}
    return
  end
  local data = player_data(player)
  local surface_name = data.add_all and ALL_SURFACES or player.surface.name
  local icon = "[" .. type .. "=" .. name .. "]"
  for _, entry in ipairs(data.entries) do
    if entry.type == type and entry.name == name and entry.surface == surface_name then
      player.create_local_flying_text{text = {"resbal.hover-exists", icon}, create_at_cursor = true}
      return
    end
  end
  add_entry(player, type, name, surface_name)
  player.create_local_flying_text{text = {"resbal.hover-added", icon, lists.caption(data.lists[data.active])},
                                  create_at_cursor = true}
  if main_frame(player) then build(player) end
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "resbal-toggle" then toggle(game.get_player(event.player_index)) end
end)

local function handle_click(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  local name = element.name
  local data = player_data(player)

  if lists.on_click(player, element) then return end
  if marks.on_click(player, element) then return end
  if watchlog.on_click(player, element) then return end
  if chain.on_click(player, element) then return end
  if rootcause.on_click(player, element) then return end
  if idle.on_click(player, element) then return end
  if diag.on_click(player, element) then return end

  if watchtab.on_click(player, element) then return end
  local watch_entry = element.tags and element.tags.resbal_watch
  if watch_entry then
    local entry = data.entries[watch_entry]
    if entry then
      open_big(player, entry.type, entry.name, entry.surface)
      big_state(player).tab = "watch"
      build_big(player)
    end
    return
  end
  if name == "resbal_watch_pause" then
    local list = data.lists[data.active]
    list.watch_paused = not list.watch_paused or nil
    if check_watch_now then check_watch_now(player) end
    build(player)
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
  elseif name == "resbal_root_open" then
    -- «Шукати глибше» у картці діагнозу — вкладка «Першопричини» того ж вікна
    big_state(player).tab = "roots"
    build_big(player)
  elseif name == "resbal_big_remove" then
    -- кошик у заголовку вікна ресурсу: прибрати його з відкритого списку (як ✕ у таблиці)
    local panel = big_state(player).panels[1]
    for index, entry in ipairs(data.entries) do
      if entry.type == panel.type and entry.name == panel.name and entry.surface == panel.surface then
        table.remove(data.entries, index)
        break
      end
    end
    if main_frame(player) then build(player) end
    if check_watch_now then check_watch_now(player) end
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
  elseif name == "resbal_scope_toggle" then
    data.add_all = not data.add_all
    element.toggled = data.add_all
  elseif name == "resbal_search_toggle" then
    -- лупа в заголовку: показати поле пошуку (з фокусом) або сховати й очистити
    data.search_open = not (data.search_open or (data.search or "") ~= "")
    if data.search_open then data.focus_search = true else data.search = "" end
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
      if check_watch_now then check_watch_now(player) end -- закрити запис журналу, якщо ресурс був у порушенні
    elseif tags.resbal_action == "pin" then
      -- «Дефіцит» → вікно вибору списку (видно, де ресурс уже є)
      lists.open_pin(player, {type = tags.type, name = tags.name, surface = tags.surface})
    end
  end
end

-- Після кліку чи Enter діалог міг відкритися або закритися — тоді оновлюємо, що закривається на Esc.
-- Лише за зміни діалогу: інакше клік у чужому вікні (інвентар) перемикав би player.opened.
local function with_dialog_check(handler)
  return function(event)
    local player = game.get_player(event.player_index)
    local before = player and top_dialog(player)
    handler(event)
    if player and player.valid and top_dialog(player) ~= before then update_opened(player) end
  end
end

script.on_event(defines.events.on_gui_click, with_dialog_check(handle_click))

local function handle_confirmed(event)
  local element = event.element
  if element and element.valid and lists.on_confirmed(game.get_player(event.player_index), element) then return end
  if element and element.valid and marks.on_confirmed(game.get_player(event.player_index), element) then return end
  if element and element.valid and chain.on_confirmed(game.get_player(event.player_index), element) then return end
  if element and element.valid then watchtab.on_confirmed(game.get_player(event.player_index), element) end
end

script.on_event(defines.events.on_gui_confirmed, with_dialog_check(handle_confirmed))

-- Esc / E / відкриття іншого вікна гри

script.on_event(defines.events.on_gui_closed, function(event)
  if quiet[event.player_index] then return end
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  if DIALOG_NAMES[element.name] then
    -- Esc у діалозі: закрити лише його, «відкритим» знову стає графік або панель
    destroy_quietly(player, element)
    update_opened(player)
  elseif element == big_frame(player) then
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


-- Вкладки вікна ресурсу: вміст будується лише для відкритої — перебудувати з новою
script.on_event(defines.events.on_gui_selected_tab_changed, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  if diag.on_tab_changed(player, element) then -- вкладки «Діагностики фабрики»: вікно перебудовано —
    update_opened(player)                        -- знову зробити його «відкритим», щоб Esc закривав саме його
    return
  end
  if element.name ~= "resbal_big_tabs" then return end
  local state = big_state(player)
  local key = BIG_TABS[element.selected_tab_index]
  if not (state and key) or (state.tab or "chart") == key then return end
  state.tab = key
  build_big(player)
end)

-- Перемикач «Ця планета / Усі Σ» на панелі: куди прив'язувати новий ресурс
script.on_event(defines.events.on_gui_switch_state_changed, function(event)
  local element = event.element
  if not (element and element.valid and element.name == "resbal_scope_switch") then return end
  local player = game.get_player(event.player_index)
  player_data(player).add_all = element.switch_state == "right"
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  local element = event.element
  if not (element and element.valid and element.name == "resbal_search") then return end
  local player = game.get_player(event.player_index)
  player_data(player).search = event.text
  update(player, true) -- лише фільтр уже зібраних рядків, без нового збору статистики
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
  machines.step(event.tick) -- фоновий облік станів машин (порція на тік)
  fluidstock.step() -- фоновий перерахунок запасу рідин (порція на тік, лише коли кеш застарів)
  if event.tick % 18000 == 0 then machines.cleanup(event.tick) end -- раз на 5 хв: старі кошики
  if event.tick % 600 == 0 then idle.refresh() end -- відкриті вікна «Простої фабрики» — раз на 10 с
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
      elseif state.tab == "roots" then
        -- «Першопричини»: дочекатися сканування машин (порціями) і побудувати дерево
        local tracker = state.tracker
        if tracker and tracker.scan and step_rescan(tracker) then rootcause.fill(player) end
      elseif event.tick >= (state.next_update or 0) then
        draw_big(player)
      end
    end
  end
end)
