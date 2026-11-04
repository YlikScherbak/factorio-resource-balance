-- Вкладка «Виробники й споживачі» великого вікна: розбивка по рецептах, стан машин, показ на мапі,
-- підказка причини дефіциту. Окремий модуль — щоб не впиратися в ліміт 200 локальних змінних
-- верхнього рівня control.lua. Фабрика: отримує спільні функції/константи з control.lua (ctx)
-- і повертає функції, потрібні ззовні.
return function(ctx)
  local PRECISIONS, ALL_SURFACES, EPSILON, COLOR_NEGATIVE, prototype_of, use_number_format, format_number, format_balance, statistics, flow, surfaces_of, sources, flow_sum, big_state, big_frame, rich_icon, panel_caption =
    ctx.PRECISIONS, ctx.ALL_SURFACES, ctx.EPSILON, ctx.COLOR_NEGATIVE, ctx.prototype_of, ctx.use_number_format, ctx.format_number, ctx.format_balance, ctx.statistics, ctx.flow, ctx.surfaces_of, ctx.sources, ctx.flow_sum, ctx.big_state, ctx.big_frame, ctx.rich_icon, ctx.panel_caption
  local step_rescan, update_flow_tab, show_next_machine, build_flow_tab

  -- Гра не веде статистики по рецептах. Два способи:
  --  • «статистика продуктів» (типово, одразу за 1хв/10хв/1г/10г): витрата рецептом = виробництво його продукту
  --    (з гри) ÷ (вихід × (1 + продуктивність)) × вхід; якщо продукт роблять кілька рецептів — ділимо за потужністю машин;
  --  • «наживо»: лічильники завершених крафтів (products_finished) кожної машини раз на секунду, вікно 60 с.

  local CRAFTING_TYPES = {"assembling-machine", "furnace", "rocket-silo"}
  local FLOW_PRECISIONS = {2, 3, 4, 5}  -- індекси PRECISIONS: 1хв, 10хв, 1г, 10г
  local TRACK_WINDOW = 60      -- с, ковзне вікно «наживо»
  local TRACK_POLL = 60        -- тіків між опитуваннями «наживо»
  local STATS_REFRESH = 300    -- тіків між оновленнями в режимі статистики
  local TRACK_RESCAN = 1800    -- тіків між перепошуком машин
  local TRACK_REORDER = 10     -- опитувань «наживо» між пересортуваннями рядків
  local TOP_RECIPES = 15

  local SCAN_BATCH = 3000      -- машин за тік при перепошуку (щоб не було ривка)

  -- Стан машин — знімок під час перепошуку (раз на TRACK_RESCAN), між перепошуками не змінюється.
  -- Групи: працює / нема входу / вихід повний / енергія чи паливо / інше. Частини станів немає в 2.0 — пропускаємо.
  local STATUS_GROUPS = {"no_input", "full_output", "power", "other"} -- порядок показу (крім «працює»)
  local STATUS_SPRITES = {working = "utility/status_working", no_input = "utility/status_yellow",
                          full_output = "utility/status_blue", power = "utility/status_not_working",
                          other = "utility/status_inactive"}
  -- Колір кола-підсвітки машини на мапі — як у значка групи
  local STATUS_COLORS = {no_input = {1, 0.85, 0.1}, full_output = {0.3, 0.6, 1}, power = {1, 0.25, 0.2},
                         other = {0.75, 0.75, 0.75}}
  local STATUS_GROUP = {}
  do
    local names = {
      working = {"working", "normal"},
      no_input = {"item_ingredient_shortage", "fluid_ingredient_shortage", "no_ingredients", "no_input_fluid",
                  "low_input_fluid", "missing_required_fluid", "input_fluid_too_cold", "input_fluid_too_hot"},
      full_output = {"full_output", "not_enough_space_in_output", "full_burnt_result_output"},
      power = {"no_power", "low_power", "no_fuel", "not_plugged_in_electric_network",
               "recharging_after_power_outage", "low_temperature"},
    }
    for group, list in pairs(names) do
      for _, name in ipairs(list) do
        local value = defines.entity_status[name]
        if value then STATUS_GROUP[value] = group end
      end
    end
  end

  -- Пошук рецептів — вбудованим фільтром гри prototypes.get_recipe_filtered (has-ingredient/has-product):
  -- гра шукає у своєму C++ коді й повертає лише потрібні рецепти. Дані рецептів (meta) читаються ліниво
  -- і кешуються. Раніше мод перебирав усі рецепти гри (у Py — тисячі), і вкладка «зависала».
  -- Кеші — з прототипів, однакові для всіх гравців, тож без storage.
  local meta_cache = {}         -- [рецепт] = {energy, products = {{type,name,key,amount}}, ingredients = {[ключ]=к-сть}, main}
  local consumers_cache = {}    -- [ресурс] = {[рецепт] = к-сть за крафт}
  local producers_cache = {}    -- [ресурс] = {[рецепт] = вихід за крафт}
  local natural_cache = {}      -- [ресурс] = чи є не-рецептне джерело (видобуток, рідина з поверхні)
  local relevant_cache = {}     -- [ресурс] = {[рецепт] = {consume, produce}}

  -- Очікувана кількість продукту за крафт. Сумісно з 2.0 і 2.1:
  -- у 2.1 поле probability перейменоване на independent_probability і додано shared_probability {min, max}
  local function product_amount(product)
    local amount = product.amount or ((product.amount_min + product.amount_max) / 2)
    local probability = product.independent_probability or product.probability or 1
    local shared = product.shared_probability
    if shared and shared.min and shared.max then
      probability = probability * math.max(0, shared.max - shared.min)
    end
    return amount * probability + (product.extra_count_fraction or 0)
  end

  local function meta_of(recipe_name)
    local meta = meta_cache[recipe_name]
    if meta ~= nil then return meta or nil end
    local recipe = prototypes.recipe[recipe_name]
    if not recipe then
      meta_cache[recipe_name] = false
      return nil
    end
    local products, ingredients = {}, {}
    for _, product in pairs(recipe.products) do
      products[#products + 1] = {type = product.type, name = product.name,
                                 key = product.type .. "/" .. product.name, amount = product_amount(product)}
    end
    for _, ingredient in pairs(recipe.ingredients) do
      local key = ingredient.type .. "/" .. ingredient.name
      ingredients[key] = (ingredients[key] or 0) + ingredient.amount
    end
    local main = recipe.main_product
    meta = {energy = math.max(recipe.energy, 0.001), products = products, ingredients = ingredients,
            main = main and (main.type .. "/" .. main.name) or nil}
    meta_cache[recipe_name] = meta
    return meta
  end

  local function key_of(panel) return panel.type .. "/" .. panel.name end

  -- Рецепти з цим ресурсом серед інгредієнтів (side = "ingredient") або продуктів (side = "product")
  local function filtered_recipes(type, name, side)
    local filter = "has-" .. side .. "-" .. (type == "fluid" and "fluid" or "item")
    return prototypes.get_recipe_filtered{{filter = filter, elem_filters = {{filter = "name", name = name}}}}
  end

  -- {[рецепт] = к-сть ресурсу за крафт} для споживачів
  local function consumers_of(type, name)
    local key = type .. "/" .. name
    if consumers_cache[key] then return consumers_cache[key] end
    local result = {}
    for recipe_name in pairs(filtered_recipes(type, name, "ingredient")) do
      local meta = meta_of(recipe_name)
      local amount = meta and meta.ingredients[key]
      if amount and amount > 0 then result[recipe_name] = amount end
    end
    consumers_cache[key] = result
    return result
  end

  -- {[рецепт] = вихід за крафт} для виробників продукту (ключ «тип/назва»)
  local function producers_of(key)
    if producers_cache[key] then return producers_cache[key] end
    local type, name = key:match("^([^/]+)/(.+)$")
    local result = {}
    for recipe_name in pairs(filtered_recipes(type, name, "product")) do
      local meta = meta_of(recipe_name)
      local amount = 0
      for _, product in ipairs(meta and meta.products or {}) do
        if product.key == key then amount = amount + product.amount end
      end
      if amount > 0 then result[recipe_name] = amount end
    end
    producers_cache[key] = result
    return result
  end

  -- Рецепти, що виробляють або споживають ресурс: {[рецепт] = {consume, produce}}
  local function recipes_for(panel)
    local key = key_of(panel)
    if relevant_cache[key] then return relevant_cache[key] end
    local result = {}
    for recipe, amount in pairs(consumers_of(panel.type, panel.name)) do result[recipe] = {consume = amount, produce = 0} end
    for recipe, amount in pairs(producers_of(key)) do
      result[recipe] = result[recipe] or {consume = 0, produce = 0}
      result[recipe].produce = amount
    end
    relevant_cache[key] = result
    return result
  end

  local function has_natural_source(panel)
    local key = key_of(panel)
    if natural_cache[key] ~= nil then return natural_cache[key] end
    local natural = false
    for _, entity in pairs(prototypes.get_entity_filtered{{filter = "type", type = "resource"}}) do
      local mineable = entity.mineable_properties
      for _, product in pairs(mineable and mineable.products or {}) do
        if product.name == panel.name and product.type == panel.type then natural = true end
      end
    end
    if not natural and panel.type == "fluid" then
      for _, tile in pairs(prototypes.tile) do
        if tile.fluid and tile.fluid.name == panel.name then natural = true break end
      end
    end
    natural_cache[key] = natural
    return natural
  end

  -- Продукт рецепта, за статистикою якого оцінюємо його крафти (не сам ресурс): основний або найбільший
  local function estimation_product(recipe, panel)
    local meta = meta_of(recipe)
    if not meta then return nil end
    local target, best = key_of(panel), nil
    for _, product in ipairs(meta.products) do
      if product.key ~= target and product.amount > 0 then
        local main = product.key == meta.main
        if main or not best or (not best.main and product.amount > best.amount) then
          best = {type = product.type, name = product.name, key = product.key, amount = product.amount, main = main}
        end
      end
    end
    return best
  end

  -- Будівлі, обладнання, транспорт — те, що ставиться, а не йде потоком (кешується в meta)
  local function is_building_recipe(recipe)
    local meta = meta_of(recipe)
    if not meta then return false end
    if meta.building == nil then
      local product
      for _, p in ipairs(meta.products) do
        if p.key == meta.main then product = p end
      end
      product = product or meta.products[1]
      local item = product and product.type == "item" and prototypes.item[product.name]
      meta.building = item and (item.place_result ~= nil or item.place_as_equipment_result ~= nil) or false
    end
    return meta.building
  end

  local function machine_recipe(entity)
    local recipe = entity.get_recipe()
    if recipe then return recipe.name end
    if entity.type == "furnace" then -- піч без входу «забуває» рецепт — беремо попередній
      local previous = entity.previous_recipe
      if previous then
        local name = previous.name
        return type(name) == "string" and name or (name and name.name)
      end
    end
    return nil
  end

  local function new_tracker(panel)
    return {panel = panel, machines = {}, rings = {}, recipes = nil, polls = 0, order = nil, next_rescan = 0}
  end

  -- Перепошук: зведення по ВСІХ рецептах на поверхні (потужність, продуктивність, працюють)
  -- + машини потрібних рецептів для режиму «наживо». Розкладено порціями по тіках.
  -- Для «Усіх планет» — по черзі всі поверхні; зведення окреме для кожної (tracker.by_surface)
  -- і спільне (tracker.recipes) для показу кількості машин.
  local function start_rescan(tracker, player)
    tracker.next_rescan = game.tick + TRACK_RESCAN
    local chunks, total = {}, 0
    for _, surface in ipairs(surfaces_of(tracker.panel.surface)) do
      local entities = surface.find_entities_filtered{type = CRAFTING_TYPES, force = player.force}
      chunks[#chunks + 1] = {index = surface.index, entities = entities}
      total = total + #entities
    end
    if #chunks == 0 then
      tracker.recipes, tracker.by_surface = tracker.recipes or {}, tracker.by_surface or {}
      return
    end
    tracker.scan = {chunks = chunks, chunk = 1, position = 1, done = 0, total = total, by_surface = {}, statuses = {}, idle = {}}
  end

  local function new_aggregate()
    return {total = 0, working = 0, capacity = 0, working_capacity = 0, productivity = 0}
  end

  -- Обробляє наступну порцію; повертає true, коли прохід завершено
  function step_rescan(tracker)
    local scan = tracker.scan
    if not (scan and scan.chunks) then -- немає проходу або формат до 1.1 — почнеться новий
      tracker.scan = nil
      return true
    end
    local relevant = recipes_for(tracker.panel)
    scan.statuses = scan.statuses or {} -- прохід, розпочатий до 1.4
    scan.idle = scan.idle or {}
    local budget = SCAN_BATCH
    while budget > 0 and scan.chunk <= #scan.chunks do
      local chunk = scan.chunks[scan.chunk]
      local entities = chunk.entities
      local recipes = scan.by_surface[chunk.index] or {}
      scan.by_surface[chunk.index] = recipes
      local last = math.min(#entities, scan.position + budget - 1)
      for i = scan.position, last do
        local entity = entities[i]
        if entity.valid then
          local recipe = machine_recipe(entity)
          local info = recipe and meta_of(recipe)
          if info then
            local agg = recipes[recipe]
            if not agg then
              agg = new_aggregate()
              recipes[recipe] = agg
            end
            local crafts = entity.crafting_speed / info.energy -- крафтів/с на повній швидкості
            agg.total = agg.total + 1
            agg.capacity = agg.capacity + crafts
            agg.productivity = agg.productivity + (entity.productivity_bonus or 0)
            local group = STATUS_GROUP[entity.status] or "other"
            if group == "working" then
              agg.working = agg.working + 1
              agg.working_capacity = agg.working_capacity + crafts
            end
            if relevant[recipe] then
              local counts = scan.statuses[recipe]
              if not counts then
                counts = {}
                scan.statuses[recipe] = counts
              end
              counts[group] = (counts[group] or 0) + 1
              if group ~= "working" then -- для «показати на мапі»
                local groups = scan.idle[recipe]
                if not groups then
                  groups = {}
                  scan.idle[recipe] = groups
                end
                local list = groups[group]
                if not list then
                  list = {}
                  groups[group] = list
                end
                list[#list + 1] = entity
              end
            end
            local unit = entity.unit_number
            if unit and relevant[recipe] and not tracker.machines[unit] then
              tracker.machines[unit] = {entity = entity, recipe = recipe, count = entity.products_finished}
            end
          end
        end
      end
      local processed = last - scan.position + 1
      budget, scan.done = budget - processed, scan.done + processed
      if last >= #entities then
        scan.chunk, scan.position = scan.chunk + 1, 1
      else
        scan.position = last + 1
      end
    end
    if scan.chunk <= #scan.chunks then return false end

    -- спільне зведення по всіх поверхнях; продуктивність — середня по машинах
    local merged = {}
    for _, recipes in pairs(scan.by_surface) do
      for recipe, agg in pairs(recipes) do
        local sum = merged[recipe] or new_aggregate()
        merged[recipe] = sum
        for field, value in pairs(agg) do sum[field] = sum[field] + value end
      end
    end
    for _, recipes in pairs(scan.by_surface) do
      for _, agg in pairs(recipes) do agg.productivity = agg.total > 0 and agg.productivity / agg.total or 0 end
    end
    for _, agg in pairs(merged) do agg.productivity = agg.total > 0 and agg.productivity / agg.total or 0 end
    tracker.recipes, tracker.by_surface = merged, scan.by_surface
    tracker.statuses, tracker.status_tick, tracker.idle = scan.statuses, game.tick, scan.idle
    tracker.scan = nil
    return true
  end

  local function scan_progress(tracker)
    local scan = tracker.scan
    if not scan or scan.total == 0 then return 100 end
    return math.floor(scan.done / scan.total * 100)
  end
  local function poll_tracker(tracker)
    tracker.polls = tracker.polls + 1
    local slot = (tracker.polls - 1) % TRACK_WINDOW + 1
    for _, ring in pairs(tracker.rings) do ring.raw[slot], ring.base[slot] = 0, 0 end
    for unit, machine in pairs(tracker.machines) do
      local entity = machine.entity
      local recipe = entity.valid and machine_recipe(entity)
      if recipe ~= machine.recipe then
        tracker.machines[unit] = nil -- машину знесли або змінили рецепт; перепошук підхопить знову
      else
        local count = entity.products_finished
        local delta = count - machine.count
        machine.count = count
        if delta > 0 then
          local ring = tracker.rings[recipe]
          if not ring then
            ring = {raw = {}, base = {}}
            for s = 1, TRACK_WINDOW do ring.raw[s], ring.base[s] = 0, 0 end
            tracker.rings[recipe] = ring
          end
          ring.raw[slot] = ring.raw[slot] + delta
          -- лічильник рахує і бонусні крафти продуктивності; витрата інгредієнтів — лише за звичайні
          ring.base[slot] = ring.base[slot] + delta / (1 + (entity.productivity_bonus or 0))
        end
      end
    end
  end

  local function live_rates(tracker)
    local elapsed = math.min(tracker.polls, TRACK_WINDOW)
    local per_minute = elapsed > 0 and 60 / elapsed or 0
    local produced, consumed = {}, {}
    for recipe, info in pairs(recipes_for(tracker.panel)) do
      local ring = tracker.rings[recipe]
      if ring or (tracker.recipes and tracker.recipes[recipe]) then
        local raw, base = 0, 0
        if ring then
          for s = 1, TRACK_WINDOW do raw, base = raw + ring.raw[s], base + ring.base[s] end
        end
        if info.produce > 0 then produced[recipe] = raw * info.produce * per_minute end
        if info.consume > 0 then consumed[recipe] = base * info.consume * per_minute end
      end
    end
    return produced, consumed, {}
  end

  -- Статистика продуктів за проміжок на одній поверхні (aggs — зведення машин цієї поверхні);
  -- результат додається до produced/consumed/approx
  local function surface_rates(tracker, player, surface, aggs, precision, produced, consumed, approx)
    local panel = tracker.panel
    local item_stats = statistics(player.force, surface, "item")
    local fluid_stats = statistics(player.force, surface, "fluid")
    local function made(type, name) -- вироблено за хвилину (середнє за проміжок)
      return (flow(type == "fluid" and fluid_stats or item_stats, name, precision))
    end
    local total_produced = made(panel.type, panel.name)
    -- частка рецепта у виробництві продукту на цій планеті (за потужністю машин × вихід × продуктивність)
    local function share(recipe, key)
      local total, mine, count = 0, 0, 0
      for other, per_craft in pairs(producers_of(key)) do
        local agg = aggs[other]
        if agg and agg.capacity > 0 then
          local weight = agg.capacity * per_craft * (1 + agg.productivity)
          total, count = total + weight, count + 1
          if other == recipe then mine = weight end
        end
      end
      if total <= 0 then return 0, false end
      return mine / total, count > 1
    end

    local natural = has_natural_source(panel)
    for recipe, info in pairs(recipes_for(panel)) do
      local agg = aggs[recipe]
      if agg then
        if info.consume > 0 then
          local product = estimation_product(recipe, panel)
          if product then
            local s, shared = share(recipe, product.key)
            local crafts = made(product.type, product.name) * s / (product.amount * (1 + agg.productivity))
            consumed[recipe] = (consumed[recipe] or 0) + crafts * info.consume
            approx[recipe] = approx[recipe] or shared
          end
        end
        if info.produce > 0 then
          if natural then
            -- ресурс ще й добувається: гра не розділяє джерела — оцінка за машинами, що працюють
            produced[recipe] = (produced[recipe] or 0) + agg.working_capacity * 60 * info.produce * (1 + agg.productivity)
            approx[recipe] = true
          else
            local s, shared = share(recipe, key_of(panel))
            produced[recipe] = (produced[recipe] or 0) + total_produced * s
            approx[recipe] = approx[recipe] or shared
          end
        end
      end
    end
  end

  -- Статистика продуктів за проміжок (сума по поверхнях запису); повертає також, які рядки наближені
  local function stats_rates(tracker, player, precision_index)
    local produced, consumed, approx = {}, {}, {}
    local precision = defines.flow_precision_index[PRECISIONS[precision_index]]
    for index, aggs in pairs(tracker.by_surface or {}) do
      local surface = game.surfaces[index]
      if surface and surface.valid then
        surface_rates(tracker, player, surface, aggs, precision, produced, consumed, approx)
      end
    end
    return produced, consumed, approx
  end

  local function flow_section(parent, name, caption)
    local header = parent.add{type = "label", caption = caption, style = "bold_label"}
    header.style.top_margin = 8
    local tbl = parent.add{type = "table", name = name, column_count = 7, draw_horizontal_lines = true}
    tbl.style.horizontal_spacing = 12
    tbl.style.vertical_spacing = 4
    return tbl
  end

  -- Лічильники машин, що не працюють: кнопка на групу; клік — наступна така машина на мапі.
  -- key — рецепт або «*buildings:<секція>» (рядок будівель); cursors — які машини вже показано.
  local function status_buttons(parent, counts, key, cursors)
    for _, group in ipairs(STATUS_GROUPS) do
      local count = counts and counts[group]
      if count and count > 0 then
        local icon = "[img=" .. STATUS_SPRITES[group] .. "]"
        local shown = cursors and cursors[key .. "/" .. group]
        local tooltip = {"", {"resbal.status-button", icon, {"resbal.status-" .. group}, count}, "\n", {"resbal.status-click"}}
        if shown then tooltip[#tooltip + 1] = {"resbal.status-shown", math.min(shown, count), count} end
        parent.add{type = "button", style = "resbal_status_button", caption = icon .. count, tooltip = tooltip,
                   tags = {resbal_status = {key = key, group = group}}}
      end
    end
  end

  local function add_counts(sum, counts)
    for group, count in pairs(counts or {}) do sum[group] = (sum[group] or 0) + count end
  end

  local function flow_row(tbl, sprite, caption, machines, machines_tooltip, rate, rate_tooltip, share, muted,
                          statuses, status_key, cursors)
    if sprite then tbl.add{type = "sprite", sprite = sprite} else tbl.add{type = "empty-widget"} end
    local tooltip = {"", "[font=default-bold]", caption, "[/font]"}
    if rate_tooltip then tooltip[#tooltip + 1] = {"", "\n\n", rate_tooltip} end
    local name = tbl.add{type = "label", caption = caption, tooltip = tooltip}
    name.style.minimal_width = 260
    name.style.maximal_width = 260 -- довгі назви рецептів (Py) не розширюють вікно
    if muted then name.style.font_color = {0.7, 0.7, 0.7} end
    local count = tbl.add{type = "label", caption = machines or "", tooltip = machines_tooltip}
    count.style.minimal_width = 50
    count.style.horizontal_align = "right"
    local status = tbl.add{type = "flow", direction = "horizontal"}
    status.style.minimal_width = 150
    status.style.horizontal_spacing = 2
    if status_key then status_buttons(status, statuses, status_key, cursors) end
    local value = tbl.add{type = "label", caption = rate, tooltip = rate_tooltip}
    value.style.minimal_width = 80
    value.style.horizontal_align = "right"
    local percent = tbl.add{type = "label", caption = string.format("%.0f%%", share * 100)}
    percent.style.minimal_width = 40
    percent.style.horizontal_align = "right"
    local bar = tbl.add{type = "progressbar", value = math.max(0, math.min(1, share))}
    bar.style.width = 80
    return value
  end

  -- Рядки секції: компоненти окремо, будівлі/обладнання — одним рядком, «Інше» — останнім
  local function fill_flow_section(tbl, tracker, order, rates, approx, total, other_key, section, cursors)
    tbl.clear()
    local shown, rest, rest_count = 0, 0, 0
    local buildings, building_names = 0, {}
    local building_total, building_working = 0, 0
    local building_statuses = {}
    local statuses = tracker.statuses or {}
    local measured = 0
    for _, recipe in ipairs(order) do
      local rate = rates[recipe] or 0
      measured = measured + rate
      local proto = prototypes.recipe[recipe]
      local agg = tracker.recipes[recipe] or {total = 0, working = 0}
      if proto and is_building_recipe(recipe) then
        buildings = buildings + rate
        building_total, building_working = building_total + agg.total, building_working + agg.working
        add_counts(building_statuses, statuses[recipe])
        if #building_names < 12 then
          building_names[#building_names + 1] = {"", "\n", "[img=recipe/" .. recipe .. "] ", proto.localised_name}
        end
      elseif shown < TOP_RECIPES then
        local rate_text = (approx[recipe] and "≈" or "") .. format_number(rate)
        flow_row(tbl, "recipe/" .. recipe, proto and proto.localised_name or recipe,
                 agg.working .. "/" .. agg.total, {"resbal.machines-tooltip", agg.working, agg.total},
                 rate_text, approx[recipe] and {"resbal.rate-approx"} or nil,
                 total > EPSILON and rate / total or 0, nil, statuses[recipe], recipe, cursors)
        shown = shown + 1
      else
        rest, rest_count = rest + rate, rest_count + 1
      end
    end
    if rest_count > 0 then
      flow_row(tbl, nil, {"resbal.more-recipes", rest_count}, nil, nil, format_number(rest), nil,
               total > EPSILON and rest / total or 0, true)
    end
    if building_total > 0 then
      local tooltip = {"", {"resbal.buildings-tooltip"}}
      for _, line in ipairs(building_names) do tooltip[#tooltip + 1] = line end
      flow_row(tbl, nil, {"resbal.buildings", #building_names}, building_working .. "/" .. building_total,
               {"resbal.machines-tooltip", building_working, building_total}, format_number(buildings), tooltip,
               total > EPSILON and buildings / total or 0, true, building_statuses, "*buildings:" .. section, cursors)
    end
    if shown == 0 and building_total == 0 then
      tbl.add{type = "empty-widget"}
      local all = tracker.panel.surface == ALL_SURFACES
      tbl.add{type = "label", caption = {all and "resbal.no-recipes-all" or "resbal.no-recipes"}}
      for _ = 1, 5 do tbl.add{type = "empty-widget"} end
    end
    -- «Інше»: те, що гра порахувала, але не рецепти (або похибка оцінки)
    local other = total - measured
    local value = flow_row(tbl, nil, {other_key}, nil, nil, format_number(other), {"resbal.other-tooltip"},
                           total > EPSILON and math.max(0, other) / total or 0, true)
    if other < -math.max(1, total * 0.05) then value.style.font_color = COLOR_NEGATIVE end
  end

  -- Підказка причини на один рівень: ресурс у дефіциті → інгредієнти його головних виробників,
  -- що теж у дефіциті на цій планеті (той самий проміжок). Клік — відкрити такий інгредієнт.
  local CAUSE_RECIPES = 3 -- скільки головних рецептів-виробників дивитися
  local CAUSE_MAX = 5     -- скільки інгредієнтів показати

  local function fill_cause(flow, player, panel, precision_index, produced_rates, balance)
    flow.clear()
    flow.visible = false
    if balance >= -EPSILON then return end
    -- головні виробники: за виміряним/оціненим внеском; якщо все стоїть — ті, що є на планеті (внесок 0)
    local recipes = {}
    for recipe, rate in pairs(produced_rates) do recipes[#recipes + 1] = {name = recipe, rate = rate} end
    table.sort(recipes, function(a, b)
      if a.rate == b.rate then return a.name < b.name end
      return a.rate > b.rate
    end)
    local precision = defines.flow_precision_index[PRECISIONS[precision_index]]
    local seen, found = {}, {}
    for i = 1, math.min(CAUSE_RECIPES, #recipes) do
      local recipe = prototypes.recipe[recipes[i].name]
      for _, ingredient in pairs(recipe and recipe.ingredients or {}) do
        local key = ingredient.type .. "/" .. ingredient.name
        if not seen[key] and not (ingredient.type == panel.type and ingredient.name == panel.name)
           and prototype_of(ingredient.type, ingredient.name) then
          seen[key] = true
          local produced, consumed = flow_sum(sources(player.force, panel.surface, ingredient.type, ingredient.name),
                                              ingredient.name, precision)
          if produced - consumed < -EPSILON then
            found[#found + 1] = {type = ingredient.type, name = ingredient.name, balance = produced - consumed}
          end
        end
      end
    end
    if #found == 0 then return end
    table.sort(found, function(a, b) return a.balance < b.balance end)
    flow.visible = true
    flow.add{type = "label", caption = {"resbal.cause"}, tooltip = {"resbal.cause-tooltip", CAUSE_RECIPES}}
    for i = 1, math.min(CAUSE_MAX, #found) do
      local item = found[i]
      local button = flow.add{type = "button", style = "resbal_status_button",
                              caption = "[" .. item.type .. "=" .. item.name .. "] " .. format_balance(item.balance),
                              tooltip = {"resbal.cause-item", prototype_of(item.type, item.name).localised_name,
                                         format_balance(item.balance)},
                              tags = {resbal_chart = {type = item.type, name = item.name, surface = panel.surface}}}
      button.style.font_color = COLOR_NEGATIVE
      button.style.hovered_font_color = COLOR_NEGATIVE
    end
  end

  -- Підказка «перевір доставку»: ресурс у дефіциті, а помітна частка його виробників стоїть із повним
  -- виходом — отже, біда не у виробництві, а в тому, що продукт (чи побічний продукт) не забирають.
  -- Стани — зі знімка перепошуку (tracker.statuses), тож підказка не блимає між оновленнями.
  local DELIVERY_SHARE = 0.1 -- від якої частки виробників із повним виходом показувати

  local function fill_delivery(label, tracker, produced_rates, balance)
    if not label then return end -- вкладку побудовано до оновлення мода
    label.visible = false
    if balance >= -EPSILON then return end
    local statuses = tracker.statuses or {}
    local full, total = 0, 0
    for recipe in pairs(produced_rates) do
      for group, count in pairs(statuses[recipe] or {}) do
        total = total + count
        if group == "full_output" then full = full + count end
      end
    end
    if full == 0 or full < total * DELIVERY_SHARE then return end
    label.caption = {"resbal.delivery", "[img=utility/status_blue]", full, total}
    label.visible = true
  end

  -- «· стан машин — N с тому» (знімок останнього перепошуку)
  local function status_age(tracker)
    if not tracker.status_tick then return "" end
    return {"resbal.status-age", math.floor((game.tick - tracker.status_tick) / 60)}
  end

  function update_flow_tab(player)
    use_number_format(player)
    local state, frame = big_state(player), big_frame(player)
    if not (state and frame and state.tab == "flow" and state.tracker) then return end
    local content = frame.resbal_big_inner.resbal_flow
    if not content then return end
    local tracker = state.tracker
    local live = state.flow_mode == "live"
    if not tracker.scan and (game.tick >= tracker.next_rescan or not tracker.by_surface) then start_rescan(tracker, player) end
    if not tracker.recipes then
      -- перший прохід перепошуку ще триває (порціями по тіках) — показуємо прогрес
      content.resbal_flow_status.caption = {"resbal.flow-scanning", scan_progress(tracker)}
      state.flow_next = game.tick + 1
      return
    end
    if live then poll_tracker(tracker) end

    local panel = tracker.panel
    local precision_index = live and 2 or (state.flow_precision or 2)
    local total_produced, total_consumed = 0, 0
    if prototype_of(panel.type, panel.name) then
      total_produced, total_consumed = flow_sum(sources(player.force, panel.surface, panel.type, panel.name), panel.name,
                                                defines.flow_precision_index[PRECISIONS[precision_index]])
    end

    local produced_rates, consumed_rates, approx
    if live then
      produced_rates, consumed_rates, approx = live_rates(tracker)
    else
      produced_rates, consumed_rates, approx = stats_rates(tracker, player, precision_index)
    end

    local balance = total_produced - total_consumed
    fill_cause(content.resbal_flow_cause, player, panel, precision_index, produced_rates, balance)
    fill_delivery(content.resbal_flow_delivery, tracker, produced_rates, balance)
    content.resbal_flow_header.caption = {"resbal.flow-header", rich_icon(panel), format_number(total_produced),
                                          format_number(total_consumed),
                                          (balance > EPSILON and "+" or "") .. format_number(balance),
                                          {"resbal.p-" .. PRECISIONS[precision_index]}}
    if live then
      local elapsed = math.min(tracker.polls, TRACK_WINDOW)
      content.resbal_flow_status.caption = {"", elapsed < 5 and {"resbal.flow-collecting", elapsed}
                                                or {"resbal.flow-measured", elapsed}, status_age(tracker)}
    else
      content.resbal_flow_status.caption = {"", {"resbal.flow-estimated", {"resbal.p-" .. PRECISIONS[precision_index]}},
                                            status_age(tracker)}
    end

    -- порядок рядків: у режимі «наживо» оновлюємо рідше, щоб рядки не стрибали щосекунди
    local reorder = not live or not tracker.order or tracker.polls % TRACK_REORDER == 1
    tracker.order = tracker.order or {}
    for _, section in ipairs({{"produced", produced_rates, total_produced, "resbal_flow_producers", "resbal.other-producers"},
                              {"consumed", consumed_rates, total_consumed, "resbal_flow_consumers", "resbal.other-consumers"}}) do
      local key, rates, total, table_name, other_key = section[1], section[2], section[3], section[4], section[5]
      if reorder or not tracker.order[key] then
        local names = {}
        for recipe in pairs(rates) do names[#names + 1] = recipe end
        table.sort(names, function(a, b) if rates[a] == rates[b] then return a < b end return rates[a] > rates[b] end)
        tracker.order[key] = names
      end
      fill_flow_section(content[table_name], tracker, tracker.order[key], rates, approx, total, other_key, key,
                        state.cursors)
    end
    state.flow_next = game.tick + (live and TRACK_POLL or STATS_REFRESH)
  end

  -- Машини групи для кнопки: рецепт або всі будівельні рецепти секції («*buildings:produced|consumed»)
  local function idle_list(tracker, key, group)
    local idle = tracker.idle or {}
    local section = key:match("^%*buildings:(%a+)$")
    if not section then return (idle[key] or {})[group] or {} end
    local list, relevant = {}, recipes_for(tracker.panel)
    for recipe, groups in pairs(idle) do
      local info = relevant[recipe]
      if info and is_building_recipe(recipe)
         and ((section == "produced" and info.produce > 0) or (section == "consumed" and info.consume > 0)) then
        for _, entity in ipairs(groups[group] or {}) do list[#list + 1] = entity end
      end
    end
    return list
  end

  -- Віддалений огляд на машині + підсвітка кругом на 5 с; якщо огляд недоступний — алерт з позицією
  -- Вікно графіка може накрити центр екрана, де опиниться машина. Розміру вікна гра не повідомляє —
  -- оцінюємо ширину (кнопки є лише на вкладці виробників, її ширина майже стала), положення беремо справжнє.
  -- Машину ставимо на FOCUS_MARGIN від краю вікна з боку, де більше місця; якщо місця замало — лишаємо в центрі.
  -- Усе в одиницях GUI: location — у них, екран = роздільна здатність / display_scale; виміряно в грі,
  -- що й світ в огляді при зумі 1 — 32 одиниці GUI на клітинку.
  local BIG_WINDOW_W = 1080  -- одиниць GUI, ширина вікна на вкладці виробників (виміряно)
  local FOCUS_MARGIN = 200   -- одиниць GUI від краю вікна до центру машини
  local function screen_offset(player)
    local frame = big_frame(player)
    if not (frame and frame.valid) then return 0 end
    local screen_w = player.display_resolution.width / player.display_scale
    local left = frame.location.x
    local right = left + BIG_WINDOW_W
    local center = screen_w / 2
    if right < center or left > center then return 0 end -- центр і так вільний
    local margin = FOCUS_MARGIN
    local free_left, free_right = left, screen_w - right
    if math.max(free_left, free_right) < margin * 1.5 then return 0 end
    local target = free_right > free_left and right + margin or left - margin
    return target - center
  end

  local function focus_entity(player, entity, group, state)
    local ok = pcall(function() player.centered_on = entity end)
    if ok then
      local offset = screen_offset(player)
      if offset ~= 0 then
        -- машина має бути на offset px праворуч від центру → центр огляду зсуваємо в інший бік
        -- повторне перемикання огляду скидає зум — зберігаємо й повертаємо
        local zoom = player.zoom
        local tiles = offset / (32 * zoom)
        local position = entity.position
        pcall(function()
          player.set_controller{type = defines.controllers.remote, surface = entity.surface,
                                position = {position.x - tiles, position.y}}
          player.zoom = zoom
        end)
      end
      -- лише одне коло: попереднє прибираємо, щоб було видно, яку машину показано зараз
      local previous = state.highlight and rendering.get_object_by_id(state.highlight)
      if previous and previous.valid then previous.destroy() end
      local circle = rendering.draw_circle{color = STATUS_COLORS[group] or {1, 0.8, 0.1}, width = 4, filled = false,
                                           radius = math.max(entity.tile_width, entity.tile_height) / 2 + 0.5,
                                           target = entity, surface = entity.surface, players = {player.index},
                                           time_to_live = 300}
      state.highlight = circle.id
    else
      player.add_custom_alert(entity, {type = "entity", name = entity.name}, {"resbal.status-alert", entity.localised_name}, true)
    end
  end

  function show_next_machine(player, key, group)
    local state = big_state(player)
    local tracker = state and state.tracker
    if not tracker then return end
    local list = idle_list(tracker, key, group)
    state.cursors = state.cursors or {}
    local cursor_key = key .. "/" .. group
    local start = state.cursors[cursor_key] or 0
    for step = 1, #list do
      local index = (start + step - 1) % #list + 1
      local entity = list[index]
      if entity.valid then
        state.cursors[cursor_key] = index
        focus_entity(player, entity, group, state)
        state.flow_next = game.tick -- одразу оновити підказку «показано N з M»
        return
      end
    end
    player.create_local_flying_text{text = {"resbal.status-none"}, create_at_cursor = true}
  end

  function build_flow_tab(player, inner, state)
    -- вибір ресурсу, якщо на графіку кілька
    state.focus = math.max(1, math.min(state.focus or 1, #state.panels))
    if #state.panels > 1 then
      local focus = inner.add{type = "flow", direction = "horizontal"}
      focus.style.vertical_align = "center"
      focus.add{type = "label", caption = {"resbal.flow-focus"}}
      for i, panel in ipairs(state.panels) do
        local button = focus.add{type = "sprite-button", name = "resbal_bfocus_" .. i, style = "slot_button",
                                 sprite = panel.type .. "/" .. panel.name, tooltip = panel_caption(panel)}
        button.toggled = (i == state.focus)
      end
    end

    -- режим: статистика продуктів за проміжок або «наживо»
    local modes = inner.add{type = "flow", direction = "horizontal"}
    modes.style.top_margin = 6
    for _, precision_index in ipairs(FLOW_PRECISIONS) do
      local button = modes.add{type = "button", name = "resbal_fprec_" .. precision_index,
                               caption = {"resbal.p-" .. PRECISIONS[precision_index]}, tooltip = {"resbal.flow-stats-tooltip"}}
      button.style.minimal_width = 60
      button.toggled = state.flow_mode ~= "live" and (state.flow_precision or 2) == precision_index
    end
    local live = modes.add{type = "button", name = "resbal_flive", caption = {"resbal.flow-live"},
                           tooltip = {"resbal.flow-tooltip"}}
    live.toggled = state.flow_mode == "live"

    local panel = state.panels[state.focus]
    local current = state.tracker and state.tracker.panel
    if not (current and current.type == panel.type and current.name == panel.name and current.surface == panel.surface) then
      state.tracker = new_tracker(panel)
      state.cursors = {}
      start_rescan(state.tracker, player) -- зведення по машинах і базова точка лічильників (порціями)
    end

    local content = inner.add{type = "scroll-pane", name = "resbal_flow"}
    content.style.maximal_height = 600
    content.style.minimal_width = 760
    content.style.top_margin = 6
    content.add{type = "label", name = "resbal_flow_header", caption = "", style = "bold_label"}
    local status = content.add{type = "label", name = "resbal_flow_status", caption = ""}
    status.style.font_color = {0.7, 0.7, 0.7}
    local cause = content.add{type = "flow", name = "resbal_flow_cause", direction = "horizontal"}
    cause.style.vertical_align = "center"
    cause.style.horizontal_spacing = 4
    cause.style.top_margin = 4
    cause.visible = false
    local delivery = content.add{type = "label", name = "resbal_flow_delivery", caption = "",
                                 tooltip = {"resbal.delivery-tooltip"}}
    delivery.style.single_line = false
    delivery.style.maximal_width = 740
    delivery.style.font_color = {1, 0.85, 0.3}
    delivery.style.top_margin = 4
    delivery.visible = false
    flow_section(content, "resbal_flow_producers", {"resbal.producers"})
    flow_section(content, "resbal_flow_consumers", {"resbal.consumers"})
    update_flow_tab(player)
  end


  return {step_rescan = step_rescan, update_flow_tab = update_flow_tab, show_next_machine = show_next_machine, build_flow_tab = build_flow_tab}
end
