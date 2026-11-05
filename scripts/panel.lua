-- Головна панель «Баланс ресурсів»: рядки таблиці (статистика, сортування, запас), міні-графіки,
-- побудова й оновлення панелі, керування Esc (player.opened). Окремий модуль — щоб не впиратися
-- в ліміт 200 локальних змінних верхнього рівня control.lua і щоб редизайн панелі жив окремо.
-- Фабрика: отримує спільні функції/константи з control.lua (ctx) і повертає функції, потрібні ззовні.
return function(ctx)
  local diag = ctx.diag -- вікно «Діагностика фабрики»: кнопка на панелі
  local active_qualities = ctx.active_qualities -- якості, що реально траплялися (кеш у storage)
  local ALL_SURFACES, CHART_HEIGHT, CHART_IMMEDIATE, CHART_POINTS, CHART_SOURCE, COLOR_NEGATIVE, COLOR_NEUTRAL, COLOR_POSITIVE =
    ctx.ALL_SURFACES, ctx.CHART_HEIGHT, ctx.CHART_IMMEDIATE, ctx.CHART_POINTS, ctx.CHART_SOURCE, ctx.COLOR_NEGATIVE, ctx.COLOR_NEUTRAL, ctx.COLOR_POSITIVE
  local COLUMNS, EPSILON, LINE_WIDTH, MAX_PLANET_ICONS, NAME_MAX_WIDTH, NAME_WIDTH, NUMBER_WIDTH, PLANETS_WIDTH =
    ctx.COLUMNS, ctx.EPSILON, ctx.LINE_WIDTH, ctx.MAX_PLANET_ICONS, ctx.NAME_MAX_WIDTH, ctx.NAME_WIDTH, ctx.NUMBER_WIDTH, ctx.PLANETS_WIDTH
  local PLANET_ICON, PRECISIONS, REFRESH_TICKS, ROW_HEIGHT, TILE_PADDING, active_surfaces, all_surfaces_tooltip, by_quality =
    ctx.PLANET_ICON, ctx.PRECISIONS, ctx.REFRESH_TICKS, ctx.ROW_HEIGHT, ctx.TILE_PADDING, ctx.active_surfaces, ctx.all_surfaces_tooltip, ctx.by_quality
  local flow, flow_sum, fluidstock, format_balance, format_number, idle, lists, lower =
    ctx.flow, ctx.flow_sum, ctx.fluidstock, ctx.format_balance, ctx.format_number, ctx.idle, ctx.lists, ctx.lower
  local mod_gui, planet_sprite, player_data, prototype_of, qualities, request_translations, search_text, sources =
    ctx.mod_gui, ctx.planet_sprite, ctx.player_data, ctx.prototype_of, ctx.qualities, ctx.request_translations, ctx.search_text, ctx.sources
  local stats_getter, surface_caption, surfaces_of, translations_of, use_number_format, views, watchlog =
    ctx.stats_getter, ctx.surface_caption, ctx.surfaces_of, ctx.translations_of, ctx.use_number_format, ctx.views, ctx.watchlog

  local NEGATIVE_MAX = 50 -- рядків у «Тільки мінус»

  local function current_precision(data)
    return defines.flow_precision_index[PRECISIONS[data.precision]]
  end

  -- Рядки для показу: {type, name, surface_name, produced, consumed, entry_index?}
  -- Запас предмета в логістичних мережах поверхні (або всіх поверхонь для «Усіх планет»).
  -- Рідини в логістику не потрапляють — для них nil. Стрічки й скрині поза мережею не враховуються.
  local function logistic_stock(networks, type, name, surface_name, get_stats)
    if type == "fluid" then -- рідини — у резервуарах (з трубами їхніх сегментів), scripts/fluidstock.lua
      local total = 0
      for _, surface in ipairs(surfaces_of(surface_name)) do
        if surface and surface.valid then total = total + fluidstock.amount(surface.index, name) end
      end
      return total
    end
    if type ~= "item" then return nil end
    local total = 0
    for surface, list in pairs(networks) do
      if surface_name == ALL_SURFACES or surface == surface_name then
        -- лише якості, що реально траплялися на цій поверхні (а не всі 5 на кожну мережу)
        local lua_surface = game.surfaces[surface]
        local wanted = lua_surface and active_qualities(get_stats(lua_surface, "item"), lua_surface.index, name) or qualities()
        for _, network in ipairs(list) do
          if network.valid then
            for _, quality in ipairs(wanted) do total = total + network.get_item_count({name = name, quality = quality}) end
          end
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
            local produced, consumed = flow(stats, name, precision, nil, type, surface.index)
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
              local p, c = flow(source.stats, entry.name, precision, nil, source.type, source.surface.index)
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
    for _, row in ipairs(rows) do row.stock = logistic_stock(networks, row.type, row.name, row.surface_name, get_stats) end
    return rows
  end

  -- Лічильник вкладки «Дефіцит», коли відкрито список: скільки ресурсів у мінусі на поточній планеті.
  -- Повний перебір кандидатів дорогий — не частіше за DEFICIT_RECOUNT (або коли змінився проміжок / планета).
  -- Зберігається в data (storage), щоб усі гравці мультиплеєра рахували однаково.
  local DEFICIT_RECOUNT = 3600 -- 1 хв
  local function count_deficits(player, data)
    local key = data.precision .. "@" .. player.surface.index
    if data.deficit_key == key and data.deficit_tick and game.tick - data.deficit_tick < DEFICIT_RECOUNT then return end
    local precision = current_precision(data)
    local get_stats = stats_getter(player.force)
    local surface = player.surface
    local count = 0
    for _, type in ipairs({"item", "fluid"}) do
      local stats = get_stats(surface, type)
      for name in pairs(stats.output_counts) do
        if prototype_of(type, name) then
          local produced, consumed = flow(stats, name, precision, nil, type, surface.index)
          if produced - consumed < -EPSILON then count = count + 1 end
        end
      end
    end
    data.deficit_count, data.deficit_key, data.deficit_tick = count, key, game.tick
  end

  local function effective_sort(data)
    if data.sort_key then return data.sort_key, data.sort_asc end
    if data.negative_only then return "balance", true end
    return nil
  end

  -- пошук + сортування (rows — зібрані collect_rows; при зміні лише тексту пошуку беруться вже зібрані)
  local function prepare_rows(player, data, rows)
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

    -- «Тільки мінус»: лише NEGATIVE_MAX найбільших дефіцитів (після пошуку — шукається серед усіх);
    -- кожен рядок — це ще й міні-графік зі 120 відрізків, сотня рядків помітно навантажує інтерфейс
    local total = #rows
    if data.negative_only and total > NEGATIVE_MAX then
      table.sort(rows, function(a, b)
        local da, db = a.produced - a.consumed, b.produced - b.consumed
        if da == db then return a.name .. a.surface_name < b.name .. b.surface_name end
        return da < db
      end)
      local top = {}
      for i = 1, NEGATIVE_MAX do top[i] = rows[i] end
      rows = top
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
    return rows, total
  end

  -- ---------- міні-графік ----------

  -- Малює лінію з відрізків: кожен відрізок тягнеться від попередньої точки до поточної
  -- cache — останні висота/відступ кожного відрізка: міняємо стиль лише там, де лінія змінилась
  -- (зміна стилю — найдорожче в інтерфейсі: 120 відрізків на рядок, у «Тільки мінус» — десятки рядків)
  local function draw_line(segments, values, max, cache)
    local usable = CHART_HEIGHT - LINE_WIDTH
    local previous
    for point, segment in ipairs(segments) do
      local y = max > EPSILON and math.floor(values[point] / max * usable + 0.5) or 0
      local from = previous or y
      local low, high = math.min(from, y), math.max(from, y)
      local height, margin = high - low + LINE_WIDTH, CHART_HEIGHT - LINE_WIDTH - high
      local key = height * 1000 + margin
      if cache[point] ~= key then
        cache[point] = key
        segment.style.height = height
        segment.style.top_margin = margin
      end
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
      -- кожен зразок питаємо в гри один раз (зразків може бути менше, ніж точок — тоді зразок на кілька точок);
      -- sample_index 1 — найновіший (неповний), тому зсув на 1; age 1 — найстаріший
      local sample_p, sample_c = {}, {}
      for age = 1, n do sample_p[age], sample_c[age] = flow_sum(list, row.name, precision, n - age + 2) end
      for point = 1, CHART_POINTS do
        -- точка (зліва найстаріша) — середнє зразків свого відрізка
        local first = math.min(n, math.floor((point - 1) * n / CHART_POINTS) + 1)
        local last = math.max(first, math.floor(point * n / CHART_POINTS))
        local p, c = 0, 0
        for age = first, last do p, c = p + sample_p[age], c + sample_c[age] end
        local count = last - first + 1
        produced[point], consumed[point] = p / count, c / count
        max = math.max(max, produced[point], consumed[point])
      end
    else
      for point = 1, CHART_POINTS do produced[point], consumed[point] = 0, 0 end
    end

    -- кеш відрізків — у views гравця (скидається разом із таблицею при перебудові)
    local view = views[player.index]
    local cache
    if view then
      view.chart_cache = view.chart_cache or {}
      cache = view.chart_cache[chart.name]
      if not cache then
        cache = {cons = {}, prod = {}}
        view.chart_cache[chart.name] = cache
      end
    else
      cache = {cons = {}, prod = {}}
    end
    draw_line(layers.cons.children, consumed, max, cache.cons)
    draw_line(layers.prod.children, produced, max, cache.prod)
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
  -- Діалоги мода (сторож, позначки, журнал, списки): поки відкритий — саме він закривається на Esc
  local DIALOGS = {"resbal_pin_dialog", "resbal_watch", "resbal_marks", "resbal_watchlog", "resbal_list_dialog", "resbal_chain_dialog",
                   "resbal_rootcause", "resbal_idle", "resbal_diag"}
  local DIALOG_NAMES = {}
  for _, name in ipairs(DIALOGS) do DIALOG_NAMES[name] = true end

  local function top_dialog(player)
    for _, name in ipairs(DIALOGS) do
      local dialog = player.gui.screen[name]
      if dialog then return dialog end
    end
    return nil
  end

  local function update_opened(player)
    if not player.connected then return end
    local target = top_dialog(player) or player.gui.screen.resbal_big
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

  -- Клітинка таблиці: пласка (редизайн 1.7 — рядок читається як рядок, а не як плитки; між рядками —
  -- горизонтальні лінії таблиці). Вміст — у flow «content».
  local function tile(tbl, name, stretch)
    local frame = tbl.add{type = "flow", name = name, direction = "horizontal"}
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
  local STOCK_RED = 10 -- хв: менше — червоним
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
    local kind = row.type == "fluid" and "-fluid" or "" -- рідини: «у резервуарах» замість «у логістичних мережах»
    if deficit <= EPSILON then
      label.caption, label.style.font_color = "—", COLOR_NEUTRAL
      label.tooltip = {"resbal.stock-ok" .. kind, format_number(row.stock), where}
      return
    end
    if row.stock <= 0 then -- дефіцит, а в мережах (резервуарах) нічого немає
      label.caption, label.style.font_color = "0", COLOR_NEGATIVE
      label.tooltip = {"resbal.stock-empty" .. kind, format_number(deficit), where}
      return
    end
    local minutes = row.stock / deficit
    local lasts = minutes < 1 and stock_time(minutes) or {"", "≈", stock_time(minutes)} -- «<1хв» або «≈N хв»
    label.caption = lasts
    -- лише червоний (< 10 хв); «менше години» — у підказці, без жовтого (жовтий — значок «немає входу»)
    label.style.font_color = minutes < STOCK_RED and COLOR_NEGATIVE or COLOR_NEUTRAL
    label.tooltip = {"resbal.stock-tooltip" .. kind, format_number(row.stock), format_number(deficit), lasts, where}
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
    -- короткі заголовки (переклад не розтягує колонки); повна назва — у підказці
    header(tbl, "produced", {"resbal.col-produced"}, data, NUMBER_WIDTH, "right",
           {"", {"resbal.produced"}, "\n", {"resbal.sort-tooltip"}})
    header(tbl, "consumed", {"resbal.col-consumed"}, data, NUMBER_WIDTH, "right",
           {"", {"resbal.consumed"}, "\n", {"resbal.sort-tooltip"}})
    header(tbl, "balance", {"resbal.col-balance"}, data, NUMBER_WIDTH, "right",
           {"", {"resbal.balance"}, "\n", {"resbal.sort-tooltip"}})
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
        -- «додати до списку» — темна пласка кнопка-значок, як дії в «Моєму списку»
        actions.add{type = "sprite-button", name = "resbal_act_" .. i, sprite = "utility/add_white", style = "resbal_row_icon",
                    tooltip = {"resbal.pin"}}
      else
        actions.add{type = "sprite-button", name = "watch", sprite = "utility/warning_white", style = "resbal_row_icon"}
        actions.add{type = "sprite-button", name = "resbal_act_" .. i, sprite = "utility/close",
                    style = "resbal_row_remove", tooltip = {"resbal.remove"}}
      end
    end

    if count == 0 then
      local caption = data.search ~= "" and {"resbal.nothing-found"}
                   or data.negative_only and {"resbal.no-negative"} or {"resbal.empty"}
      local empty = tbl.add{type = "label", caption = caption, style = "resbal_quiet_label"}
      empty.style.left_padding = TILE_PADDING
      for _ = 2, COLUMNS do tbl.add{type = "empty-widget"} end
    end

    -- останній рядок «Мого списку» — слот «+», як у ванільних запитах логістики (замість нижнього рядка панелі)
    if not data.negative_only then
      local slot = tbl.add{type = "flow", direction = "horizontal"}
      slot.style.vertical_align = "center"
      slot.style.horizontal_spacing = 8
      slot.style.left_padding = TILE_PADDING - 4
      slot.style.top_padding, slot.style.bottom_padding = 2, 2
      add_button(slot, "resbal_add", 32, {"resbal.add-tooltip"})
      slot.add{type = "label", caption = {"resbal.add"}, style = "resbal_quiet_label", tooltip = {"resbal.add-tooltip"}}
      -- куди прив'язати новий ресурс: компактна кнопка-перемикач «Σ» поруч із додаванням
      -- (увімкнена — сума по всіх планетах і платформах, вимкнена — планета, де гравець зараз)
      local scope = slot.add{type = "button", name = "resbal_scope_toggle", caption = "Σ",
                             style = "resbal_period_button", tooltip = {"resbal.scope-toggle-tooltip"}}
      scope.toggled = data.add_all == true
      scope.style.font = "default-bold"
      scope.style.left_margin = 8
      for _ = 2, COLUMNS do tbl.add{type = "empty-widget"} end
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
    if row.type == "item" and #qualities() > 1 then -- є якості (Space Age): числа — сума всіх
      open_tooltip[#open_tooltip + 1] = {"resbal.all-qualities"}
    end
    local resource = tbl["resbal_res_" .. i].content
    local icon = resource.res_icon
    icon.sprite = proto and (row.type .. "/" .. row.name) or "utility/questionmark"
    icon.tooltip = open_tooltip
    resource.res_name.caption = title
    resource.res_name.tooltip = open_tooltip

    -- «Вироблено»: якщо задано ціль випуску — жовтий нижче 95% цілі, у підказці відсоток
    local produced_label = tbl["resbal_prod_" .. i].content.amount
    produced_label.caption = format_number(row.produced)
    local target = row.entry_index and data.entries[row.entry_index] and data.entries[row.entry_index].target
    if target then
      local share = row.produced / target
      produced_label.style.font_color = share < 0.95 and {1, 0.85, 0.3} or {1, 1, 1}
      produced_label.tooltip = {"resbal.target-tooltip", format_number(target), string.format("%.0f", share * 100)}
    else
      produced_label.style.font_color = {1, 1, 1}
      produced_label.tooltip = nil
    end
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
      -- три стани: немає сторожа (білий контурний трикутник) / є (жовтий) / спрацював (червона кнопка);
      -- список на паузі — як «немає», пояснення в підказці
      local list = data.lists and data.lists[data.active]
      local active = watch and not (list and list.watch_paused)
      bell.style = (watch and watch.violated) and "tool_button_red" or "resbal_row_icon"
      bell.sprite = active and "utility/notification" or "utility/warning_white"
      bell.toggled = false
      bell.tooltip = (watch and not active) and {"", watch_tooltip(watch), "\n", {"resbal.list-tooltip-paused"}}
                     or watch_tooltip(watch)
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

  -- Оновлює цифри й ставить усі графіки в чергу на перерахунок.
  -- reuse = true — змінився лише текст пошуку: фільтруємо вже зібрані рядки, статистику не питаємо
  local function update(player, reuse)
    local frame = main_frame(player)
    if not frame then return end
    use_number_format(player)
    local data = player_data(player)
    local tbl = frame.resbal_inner.resbal_scroll.resbal_table
    local view = views[player.index]
    local collected = reuse and view and view.collected or collect_rows(player, data)
    local rows, total = prepare_rows(player, data, collected)
    -- лічильник вкладки «Дефіцит»: у самій вкладці — точний (без пошуку), у списку — рідкий перерахунок
    if data.negative_only then
      if (data.search or "") == "" then
        data.deficit_count, data.deficit_key, data.deficit_tick = total, data.precision .. "@" .. player.surface.index, game.tick
      end
    else
      count_deficits(player, data)
    end
    local tabs = frame.resbal_inner.resbal_lists and frame.resbal_inner.resbal_lists.resbal_lists_scroll.resbal_tabs
    if tabs and tabs.resbal_list_deficit then
      tabs.resbal_list_deficit.caption = {"", "[img=utility/warning_icon] ", {"resbal.deficit-tab"},
                                          data.deficit_count and (" (" .. data.deficit_count .. ")") or ""}
    end
    -- «Тільки мінус» обрізано до NEGATIVE_MAX — напис під таблицею
    local note = frame.resbal_inner.resbal_neg_note
    if note then
      note.visible = data.negative_only == true and total > #rows
      note.caption = {"resbal.negative-shown", #rows, total}
    end

    if not view or view.count ~= #rows then
      view = {count = #rows, keys = {}}
      views[player.index] = view
      build_table(tbl, #rows, data)
    end
    view.collected = collected
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
    -- дії заголовка (ванільний патерн): пошук, довідка з клавішами, закрити
    local searching = data.search_open or (data.search or "") ~= ""
    local search_button = titlebar.add{type = "sprite-button", name = "resbal_search_toggle", sprite = "utility/search",
                                       style = "frame_action_button", tooltip = {"resbal.search-tooltip"}}
    search_button.toggled = searching
    titlebar.add{type = "sprite-button", name = "resbal_help", sprite = "utility/questionmark",
                 style = "frame_action_button", tooltip = {"resbal.help-tooltip"}}
    titlebar.add{type = "sprite-button", name = "resbal_close", sprite = "utility/close",
                 style = "frame_action_button", tooltip = {"resbal.close"}}

    local inner = frame.add{type = "frame", name = "resbal_inner", direction = "vertical",
                            style = "inside_shallow_frame_with_padding"}

    -- вкладки списків
    lists.add_tabs(inner, data) -- «Дефіцит» + списки

    -- рядок керування: планета / Σ, проміжок (вузькі кнопки), режим, сторож, журнал, простої
    local controls = inner.add{type = "flow", direction = "horizontal"}
    controls.style.top_margin = 8
    controls.style.vertical_align = "center"
    controls.style.horizontal_spacing = 4
    for i, key in ipairs(PRECISIONS) do
      local button = controls.add{type = "button", name = "resbal_prec_" .. i, caption = {"resbal.p-" .. key},
                                  style = "resbal_period_button"}
      button.toggled = (i == data.precision)
    end
    controls.add{type = "empty-widget"}.style.horizontally_stretchable = true
    -- сторож списку: значок-перемикач (ширина не залежить від стану й мови), стан — у підказці
    local paused = data.lists[data.active].watch_paused
    local pause = controls.add{type = "sprite-button", name = "resbal_watch_pause", style = "tool_button",
                               sprite = paused and "utility/pause" or "utility/notification",
                               tooltip = {"", paused and {"resbal.watch-state-paused"} or {"resbal.watch-state-on"},
                                          "\n", {"resbal.watch-pause-tooltip"}}}
    pause.toggled = not paused
    pause.style.left_margin = 12
    diag.add_button(controls) -- «Простої» і «Журнал» — вкладки одного вікна

    -- поле пошуку: лише коли відкрите лупою (або вже є текст)
    if searching then
      local row = inner.add{type = "flow", direction = "horizontal"}
      row.style.top_margin = 6
      row.style.vertical_align = "center"
      local search = row.add{type = "textfield", name = "resbal_search", text = data.search or "",
                             tooltip = {"resbal.search-tooltip"}}
      search.style.width = 300
      if data.focus_search then
        search.focus()
        data.focus_search = nil
      end
    end

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
    tbl.style.column_alignments[COLUMNS] = "center" -- кнопки дій — по центру висоти рядка
    tbl.style.vertical_spacing = 2
    tbl.draw_horizontal_lines = true -- пласкі клітинки: рядки розділяють тонкі лінії
    local note = inner.add{type = "label", name = "resbal_neg_note", caption = "", style = "resbal_quiet_label"}
    note.style.top_margin = 4
    note.visible = false

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

  return {
    DEFAULT_WATCH_WINDOW = DEFAULT_WATCH_WINDOW,
    DIALOG_NAMES = DIALOG_NAMES,
    SNOOZE_MINUTES = SNOOZE_MINUTES,
    WATCH_WINDOWS = WATCH_WINDOWS,
    add_button = add_button,
    add_entry = add_entry,
    build = build,
    destroy_quietly = destroy_quietly,
    ensure_top_button = ensure_top_button,
    main_frame = main_frame,
    quiet = quiet,
    set_open = set_open,
    snooze_left = snooze_left,
    toggle = toggle,
    top_dialog = top_dialog,
    update = update,
    update_chart = update_chart,
    update_opened = update_opened,
  }
end
