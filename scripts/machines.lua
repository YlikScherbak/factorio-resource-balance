-- Фоновий облік станів машин з рецептами: «на що пішов час» за останні 30 хвилин.
--   • Реєстр: один пошук усіх машин (init / зміна модів), далі — події побудови. Знесені прибираються ліниво
--     (невалідні випадають під час опитування).
--   • Опитування: щотіку порція машин по колу, кожна приблизно раз на інтервал (налаштування карти
--     resbal-history-interval). Без ривків: навантаження розподілене рівномірно.
--   • Накопичення: частка часу в кожному стані — вага спостереження = тіки з попереднього опитування цієї машини.
--     Хвилинні кошики: storage.machines.history[force][surface][recipe][хвилина] = {група = тіки}.
local M = {}

M.CRAFTING_TYPES = {"assembling-machine", "furnace", "rocket-silo"}
M.WINDOW_MINUTES = 30 -- скільки хвилин історії тримаємо

local MINUTE = 3600 -- тіків

-- Групи станів (як у вкладці «Виробники й споживачі»): working / no_input / full_output / power / other
M.STATUS_GROUP = {}
do
  local names = {
    -- ракетна шахта: підготовка й запуск — теж робота
    working = {"working", "normal", "preparing_rocket_for_launch", "launching_rocket"},
    no_input = {"item_ingredient_shortage", "fluid_ingredient_shortage", "no_ingredients", "no_input_fluid",
                "low_input_fluid", "missing_required_fluid", "input_fluid_too_cold", "input_fluid_too_hot"},
    -- waiting_for_space_in_destination — машини, що кладуть продукт одразу на конвеєр чи в сусідню сутність
    -- (vector_to_place_result: ливарні Py тощо); waiting_for_space_in_platform_hub — ракетна шахта
    full_output = {"full_output", "not_enough_space_in_output", "full_burnt_result_output",
                   "waiting_for_space_in_destination", "waiting_for_space_in_platform_hub"},
    power = {"no_power", "low_power", "no_fuel", "not_plugged_in_electric_network",
             "recharging_after_power_outage", "low_temperature", "frozen"},
  }
  for group, list in pairs(names) do
    for _, name in ipairs(list) do
      local value = defines.entity_status[name]
      if value then M.STATUS_GROUP[value] = group end
    end
  end
end

local function state()
  storage.machines = storage.machines or {list = {}, known = {}, cursor = 1, history = {}}
  return storage.machines
end

-- Інтервал опитування кожної машини, тіки; nil — облік вимкнено
local function interval_ticks()
  local value = settings.global["resbal-history-interval"].value
  local seconds = tonumber(value)
  return seconds and seconds * 60 or nil
end

function M.enabled()
  return interval_ticks() ~= nil
end

local function add(entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  local s = state()
  if s.known[entity.unit_number] then return end
  s.known[entity.unit_number] = true
  -- сила й поверхня машини не змінюються — запам'ятовуємо (на кожне опитування менше звернень до гри)
  s.list[#s.list + 1] = {entity = entity, unit = entity.unit_number, force = entity.force.index,
                         surface = entity.surface.index}
end

-- Повний перепошук (init / зміна модів): реєстр з нуля, історію лишаємо
function M.rebuild()
  local s = state()
  s.list, s.known, s.cursor, s.built = {}, {}, 1, true
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{type = M.CRAFTING_TYPES}) do add(entity) end
  end
end

local CRAFTING = {}
for _, type in ipairs(M.CRAFTING_TYPES) do CRAFTING[type] = true end

function M.on_built(event)
  local entity = event.entity or event.destination
  -- події побудови спільні з реєстром резервуарів — беремо лише машини з рецептами
  if entity and entity.valid and CRAFTING[entity.type] then add(entity) end
end

-- Фільтр подій побудови: лише машини з рецептами
M.BUILT_FILTER = {}
for _, type in ipairs(M.CRAFTING_TYPES) do M.BUILT_FILTER[#M.BUILT_FILTER + 1] = {filter = "type", type = type} end

local function machine_recipe(entity)
  local recipe = entity.get_recipe()
  if recipe then return recipe.name end
  if entity.type == "furnace" then
    local previous = entity.previous_recipe
    if previous then
      local name = previous.name
      return type(name) == "string" and name or (name and name.name)
    end
  end
  return nil
end

-- Одне спостереження машини record (з вагою — тіки від попереднього)
local function observe(s, record, tick, interval)
  -- перше спостереження машини лише запам'ятовує момент: вага — це реальний час між двома спостереженнями
  -- (інакше на початку обліку кожна машина приносила б цілий інтервал і «машин» виходило в рази більше)
  if not record.last then
    record.last = tick
    return
  end
  local entity = record.entity
  local recipe = machine_recipe(entity)
  local weight = math.min(tick - record.last, interval * 2) -- після паузи не роздуваємо
  record.last = tick
  if not recipe or weight <= 0 then return end
  local group = M.STATUS_GROUP[entity.status] or "other"
  if not record.force then record.force, record.surface = entity.force.index, entity.surface.index end
  local by_force = s.history[record.force]
  if not by_force then
    by_force = {}
    s.history[record.force] = by_force
  end
  local by_surface = by_force[record.surface]
  if not by_surface then
    by_surface = {}
    by_force[record.surface] = by_surface
  end
  local buckets = by_surface[recipe]
  if not buckets then
    buckets = {}
    by_surface[recipe] = buckets
  end
  local minute = math.floor(tick / MINUTE)
  local bucket = buckets[minute]
  if not bucket then
    bucket = {}
    buckets[minute] = bucket
    buckets[minute - M.WINDOW_MINUTES - 1] = nil -- найстаріший кошик цього рецепта
  end
  bucket[group] = (bucket[group] or 0) + weight
end

-- Порція опитування на цей тік; повертає, скільки машин опитано
function M.step(tick, limit)
  local interval = interval_ticks()
  if not interval then return 0 end
  local s = state()
  -- сейв, де мод оновився без on_configuration_changed (та сама версія) — реєстр ще не збудовано
  if not s.built then M.rebuild() end
  s.started = s.started or tick -- початок обліку: середня кількість машин рахується від нього
  local list = s.list
  local count = #list
  if count == 0 then return 0 end
  local budget = limit or math.ceil(count / interval)
  local done = 0
  while done < budget and #list > 0 do
    if s.cursor > #list then s.cursor = 1 end
    local record = list[s.cursor]
    if record.entity.valid then
      observe(s, record, tick, interval)
      s.cursor = s.cursor + 1
    else
      -- знесена: прибираємо (останню ставимо на її місце, курсор не рухаємо)
      s.known[record.unit] = nil
      list[s.cursor] = list[#list]
      list[#list] = nil
    end
    done = done + 1
  end
  return done
end

-- Раз на кілька хвилин: прибрати кошики старші за вікно (рецепти, яких більше немає)
function M.cleanup(tick)
  local oldest = math.floor(tick / MINUTE) - M.WINDOW_MINUTES
  for _, by_force in pairs(state().history) do
    for _, by_surface in pairs(by_force) do
      for recipe, buckets in pairs(by_surface) do
        local any = false
        for minute in pairs(buckets) do
          if minute < oldest then buckets[minute] = nil else any = true end
        end
        if not any then by_surface[recipe] = nil end
      end
    end
  end
end

-- Частки часу за останні minutes хвилин: {group = частка 0..1}, загальна кількість тіків, давність (хв)
-- для рецептів recipes ({[рецепт] = true}) на поверхнях surfaces (масив індексів) сили force_index.
function M.shares(force_index, surfaces, recipes, minutes, tick)
  local by_force = state().history[force_index]
  local totals, sum = {}, 0
  local from = math.floor(tick / MINUTE) - minutes + 1
  local first
  for _, surface_index in ipairs(surfaces) do
    local by_surface = by_force and by_force[surface_index]
    for recipe in pairs(recipes) do
      for minute, bucket in pairs(by_surface and by_surface[recipe] or {}) do
        if minute >= from then
          if not first or minute < first then first = minute end
          for group, ticks in pairs(bucket) do
            totals[group] = (totals[group] or 0) + ticks
            sum = sum + ticks
          end
        end
      end
    end
  end
  if sum == 0 then return nil, 0, 0 end
  for group, ticks in pairs(totals) do totals[group] = ticks / sum end
  local covered = first and (math.floor(tick / MINUTE) - first + 1) or 0
  return totals, sum, covered
end

-- Підсумок по всіх рецептах поверхонь за останні minutes хвилин (для вікна «Простої фабрики»):
-- {{recipe, shares = {група = частка}, machines = середня кількість машин}}, тривалість вікна в тіках.
-- Середня кількість машин = накопичений час спостережень ÷ тривалість вікна (з початку обліку, якщо пізніше).
function M.summary(force_index, surfaces, minutes, tick)
  local s = state()
  local by_force = s.history[force_index]
  local from = math.floor(tick / MINUTE) - minutes + 1
  local span = tick - math.max(from * MINUTE, s.started or 0)
  local per_recipe = {}
  for _, surface_index in ipairs(surfaces) do
    for recipe, buckets in pairs(by_force and by_force[surface_index] or {}) do
      for minute, bucket in pairs(buckets) do
        if minute >= from then
          local acc = per_recipe[recipe]
          if not acc then
            acc = {groups = {}, ticks = 0}
            per_recipe[recipe] = acc
          end
          for group, ticks in pairs(bucket) do
            acc.groups[group] = (acc.groups[group] or 0) + ticks
            acc.ticks = acc.ticks + ticks
          end
        end
      end
    end
  end
  local list = {}
  for recipe, acc in pairs(per_recipe) do
    if acc.ticks > 0 then
      local shares = {}
      for group, ticks in pairs(acc.groups) do shares[group] = ticks / acc.ticks end
      list[#list + 1] = {recipe = recipe, shares = shares, machines = span > 0 and acc.ticks / span or 0}
    end
  end
  return list, span
end

function M.count()
  return #state().list
end

-- Машини з рецептами на поверхні сили — з реєстру (замість find_entities_filtered: на 20 тис. машин пошук
-- за один тік давав помітний ривок при відкритті «Виробників і споживачів»). Лише дійсні.
function M.entities_on(surface_index, force_index)
  local s = state()
  if not s.built then M.rebuild() end
  local result = {}
  for _, record in ipairs(s.list) do
    local entity = record.entity
    if entity.valid then
      if not record.force then record.force, record.surface = entity.force.index, entity.surface.index end
      if record.surface == surface_index and record.force == force_index then result[#result + 1] = entity end
    end
  end
  return result
end

return M
