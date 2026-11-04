-- Запас рідин у резервуарах планети — для колонки «Запас» (у логістичні мережі рідини не потрапляють).
--   • Реєстр резервуарів (storage-tank): один пошук на початку, далі події побудови; знесені випадають при обході.
--   • Підрахунок: для кожного резервуара — його сегмент рідини (резервуар + з'єднані труби), кожен сегмент
--     один раз (get_fluid_segment_id); сума по рідинах. Кеш на CACHE_TICKS для кожної поверхні.
--   • Перший підрахунок поверхні — одразу (щоб не показувати «0»); далі застарілий кеш оновлюється у фоні
--     порціями по CHUNK резервуарів за тік (M.step) — без ривка на великих базах.
--   Кеш, черга й реєстр — у storage (не в змінних модуля): обхід змінює реєстр, і це має відбуватися однаково
--   в усіх гравців мультиплеєра.
local M = {}

M.TYPE = "storage-tank"
local CACHE_TICKS = 600 -- 10 с
local CHUNK = 100       -- резервуарів за тік у фоновому перерахунку

local function state()
  storage.fluidstock = storage.fluidstock or {list = {}, known = {}, cache = {}}
  return storage.fluidstock
end

local function add(entity)
  if not (entity and entity.valid and entity.unit_number and entity.type == M.TYPE) then return end
  local s = state()
  if s.known[entity.unit_number] then return end
  s.known[entity.unit_number] = true
  s.list[#s.list + 1] = {entity = entity, unit = entity.unit_number, surface = entity.surface.index}
end

function M.rebuild()
  local s = state()
  s.list, s.known, s.cache, s.pending, s.pass, s.built = {}, {}, {}, {}, nil, true
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{type = M.TYPE}) do add(entity) end
  end
end

function M.on_built(event)
  add(event.entity or event.destination)
end

-- Обробити запис list[i] для проходу по поверхні surface_index.
-- Повертає true, якщо запис лишився на місці (можна йти далі); false — знесений і замінений останнім.
local function visit(s, i, surface_index, totals, seen)
  local list = s.list
  local record = list[i]
  local entity = record.entity
  if not entity.valid then
    s.known[record.unit] = nil
    list[i] = list[#list]
    list[#list] = nil
    return false
  end
  if record.surface == surface_index then
    for box = 1, entity.fluids_count do
      local fluid
      if entity.has_fluid_segment(box) then
        local id = entity.get_fluid_segment_id(box)
        if not seen[id] then
          seen[id] = true
          fluid = entity.get_fluid_segment_fluid(box)
        end
      else
        fluid = entity.get_fluid(box)
      end
      if fluid then totals[fluid.name] = (totals[fluid.name] or 0) + fluid.amount end
    end
  end
  return true
end

-- Повний перерахунок однієї поверхні одразу: {[рідина] = кількість}
function M.recompute(surface_index)
  local s = state()
  if not s.built then M.rebuild() end
  local totals, seen = {}, {}
  local i = 1
  while i <= #s.list do
    if visit(s, i, surface_index, totals, seen) then i = i + 1 end
  end
  s.cache[surface_index] = {tick = game.tick, totals = totals}
  return totals
end

-- Скільки рідини name у резервуарах поверхні. Перший раз — рахує одразу; застарілий кеш — повертає його
-- і ставить поверхню в чергу фонового перерахунку.
function M.amount(surface_index, name)
  local s = state()
  local cached = s.cache[surface_index]
  if not cached then return M.recompute(surface_index)[name] or 0 end
  if game.tick - cached.tick >= CACHE_TICKS and not (s.pass and s.pass.surface == surface_index) then
    s.pending = s.pending or {}
    s.pending[surface_index] = true
  end
  return cached.totals[name] or 0
end

-- Щотіку: порція фонового перерахунку (якщо є що рахувати)
function M.step()
  local s = storage.fluidstock
  if not s then return end
  local pass = s.pass
  if not pass then
    local surface_index = s.pending and next(s.pending)
    if not surface_index then return end
    s.pending[surface_index] = nil
    pass = {surface = surface_index, i = 1, totals = {}, seen = {}}
    s.pass = pass
  end
  local done = 0
  while done < CHUNK and pass.i <= #s.list do
    if visit(s, pass.i, pass.surface, pass.totals, pass.seen) then pass.i = pass.i + 1 end
    done = done + 1
  end
  if pass.i > #s.list then
    s.cache[pass.surface] = {tick = game.tick, totals = pass.totals}
    s.pass = nil
  end
end

function M.count()
  return #state().list
end

return M
