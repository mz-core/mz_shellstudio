MZShellStudioProject = MZShellStudioProject or {}

local Project = MZShellStudioProject
local TYPES = { floor = true, wall = true, ceiling = true, door = true, window = true }
local MATERIALS = {
  checker = true,
  concrete = true,
  plaster = true,
  wood = true,
  tile = true,
  brick = true,
  metal = true
}
local PLAN_VERSION = 1
local MAX_PLAN_CELLS = 4096

local function finite(value, minimum, maximum)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
  if (minimum and value < minimum) or (maximum and value > maximum) then return nil end
  return value + 0.0
end

local function integer(value, minimum, maximum)
  local number = finite(value, minimum, maximum)
  if not number or number % 1 ~= 0 then return nil end
  return math.floor(number)
end

local function safeId(value, maximum)
  value = tostring(value or '')
  if value == '' or #value > (maximum or 48) or not value:match('^[a-z][a-z0-9_%-]*$') then return nil end
  return value
end

local function cleanName(value)
  value = tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' or #value > 64 then return nil end
  return value
end

local function exactKeys(value, allowed)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if allowed[key] ~= true then return false end end
  return true
end

local function vector(value, count, minimum, maximum)
  if type(value) ~= 'table' or #value ~= count then return nil end
  local out = {}
  for index = 1, count do
    out[index] = finite(value[index], minimum, maximum)
    if not out[index] then return nil end
  end
  return out
end

local function aligned(value, grid)
  return math.abs(value / grid - math.floor(value / grid + 0.5)) <= 0.001
end

local function normalizePlan(raw, grid)
  if raw == nil then return nil end
  if type(raw) ~= 'table' then return nil, 'plan_not_object' end
  if not exactKeys(raw, { version = true, cellSize = true, wallHeight = true, wallThickness = true, slabThickness = true, cells = true }) then
    return nil, 'unknown_plan_field'
  end
  if tonumber(raw.version) ~= PLAN_VERSION then return nil, 'unsupported_plan_version' end
  local cellSize = finite(raw.cellSize, 1.0, 4.0)
  local wallHeight = finite(raw.wallHeight, 2.0, 8.0)
  local wallThickness = finite(raw.wallThickness, 0.05, 0.5)
  local slabThickness = finite(raw.slabThickness, 0.05, 1.0)
  if not cellSize or not wallHeight or not wallThickness or not slabThickness then return nil, 'invalid_plan_header' end
  if not aligned(cellSize, grid) then return nil, 'plan_cell_size_not_aligned' end
  if type(raw.cells) ~= 'table' or #raw.cells > MAX_PLAN_CELLS then return nil, 'invalid_plan_cells' end

  local cells, seen = {}, {}
  local minGx, maxGx, minGy, maxGy
  for index, cell in ipairs(raw.cells) do
    if type(cell) ~= 'table' or not exactKeys(cell, {
      gx = true, gy = true, level = true, floor = true, ceiling = true,
      floorMaterial = true, ceilingMaterial = true, wallMaterial = true
    }) then
      return nil, ('plan_cell_%d:invalid'):format(index)
    end
    local gx = integer(cell.gx, -128, 128)
    local gy = integer(cell.gy, -128, 128)
    local level = integer(cell.level, 0, 0)
    if not gx or not gy or not level or type(cell.floor) ~= 'boolean' or type(cell.ceiling) ~= 'boolean' then
      return nil, ('plan_cell_%d:invalid'):format(index)
    end
    local floorMaterial = cell.floorMaterial == nil and 'checker' or tostring(cell.floorMaterial)
    local ceilingMaterial = cell.ceilingMaterial == nil and 'checker' or tostring(cell.ceilingMaterial)
    local wallMaterial = cell.wallMaterial == nil and 'checker' or tostring(cell.wallMaterial)
    if not MATERIALS[floorMaterial] or not MATERIALS[ceilingMaterial] or not MATERIALS[wallMaterial] then
      return nil, ('plan_cell_%d:invalid_material'):format(index)
    end
    if gx * cellSize < -40.0 or (gx + 1) * cellSize > 40.0
      or gy * cellSize < -40.0 or (gy + 1) * cellSize > 40.0 then
      return nil, ('plan_cell_%d:out_of_bounds'):format(index)
    end
    if cell.floor or cell.ceiling then
      local key = ('%d,%d,%d'):format(gx, gy, level)
      if seen[key] then return nil, 'duplicate_plan_cell' end
      seen[key] = true
      minGx = minGx and math.min(minGx, gx) or gx
      maxGx = maxGx and math.max(maxGx, gx) or gx
      minGy = minGy and math.min(minGy, gy) or gy
      maxGy = maxGy and math.max(maxGy, gy) or gy
      cells[#cells + 1] = {
        gx = gx, gy = gy, level = level, floor = cell.floor, ceiling = cell.ceiling,
        floorMaterial = floorMaterial, ceilingMaterial = ceilingMaterial, wallMaterial = wallMaterial
      }
    end
  end
  if maxGx and ((maxGx - minGx + 1) * cellSize > 40.0 or (maxGy - minGy + 1) * cellSize > 40.0) then
    return nil, 'plan_extent_too_large'
  end
  return {
    version = PLAN_VERSION,
    cellSize = cellSize,
    wallHeight = wallHeight,
    wallThickness = wallThickness,
    slabThickness = slabThickness,
    cells = cells
  }
end

local function gridVector(value, count, grid)
  local out = vector(value, count, -40.0, 40.0)
  if not out then return nil end
  for index = 1, count do if not aligned(out[index], grid) then return nil end end
  return out
end

local function normalizeElement(raw, grid)
  if type(raw) ~= 'table' then return nil, 'element_not_object' end
  local kind = tostring(raw.type or '')
  local id = safeId(raw.id)
  if not id or not TYPES[kind] then return nil, 'invalid_element_identity' end
  if raw.generated ~= nil and type(raw.generated) ~= 'boolean' then return nil, 'invalid_generated_flag' end
  local generated = raw.generated == true

  if kind == 'floor' or kind == 'ceiling' then
    if not exactKeys(raw, { id = true, type = true, position = true, size = true, rotation = true, thickness = true, material = true, generated = true }) then
      return nil, 'unknown_slab_field'
    end
    local position = gridVector(raw.position, 3, grid)
    local size = gridVector(raw.size, 2, grid)
    local rotation = finite(raw.rotation, 0, 270)
    local thickness = finite(raw.thickness, 0.05, 1.0)
    local material = tostring(raw.material or 'checker')
    if not position or not size or size[1] < grid or size[2] < grid or not rotation or rotation % 90 ~= 0 or not thickness or not MATERIALS[material] then
      return nil, 'invalid_slab'
    end
    return { id = id, type = kind, position = position, size = size, rotation = rotation, thickness = thickness, material = material, generated = generated or nil }
  end

  if kind == 'wall' then
    if not exactKeys(raw, { id = true, type = true, start = true, ['end'] = true, height = true, thickness = true, material = true, generated = true }) then
      return nil, 'unknown_wall_field'
    end
    local start = gridVector(raw.start, 3, grid)
    local finish = gridVector(raw['end'], 3, grid)
    local height = finite(raw.height, 2.0, 8.0)
    local thickness = finite(raw.thickness, 0.05, 0.5)
    local material = tostring(raw.material or 'checker')
    if not start or not finish or not height or not thickness or not MATERIALS[material] or math.abs(start[3] - finish[3]) > 0.001 then
      return nil, 'invalid_wall'
    end
    local dx, dy = finish[1] - start[1], finish[2] - start[2]
    if (math.abs(dx) > 0.001 and math.abs(dy) > 0.001) or math.max(math.abs(dx), math.abs(dy)) < grid then
      return nil, 'wall_must_be_orthogonal'
    end
    return { id = id, type = kind, start = start, ['end'] = finish, height = height, thickness = thickness, material = material, generated = generated or nil }
  end

  if not exactKeys(raw, { id = true, type = true, wallId = true, offset = true, width = true, height = true, sill = true, generated = true }) then
    return nil, 'unknown_opening_field'
  end
  local wallId = safeId(raw.wallId)
  local offset = finite(raw.offset, 0.0, 40.0)
  local width = finite(raw.width, 0.5, 4.0)
  local height = finite(raw.height, kind == 'door' and 1.5 or 0.4, 4.0)
  local sill = finite(raw.sill, 0.0, 6.0)
  if not wallId or not offset or not width or not height or not sill or kind == 'door' and math.abs(sill) > 0.001 then
    return nil, 'invalid_opening'
  end
  if kind == 'window' and sill < 0.2 then return nil, 'invalid_window_sill' end
  return { id = id, type = kind, wallId = wallId, offset = offset, width = width, height = height, sill = sill, generated = generated or nil }
end

local function wallLength(wall)
  return math.max(math.abs(wall['end'][1] - wall.start[1]), math.abs(wall['end'][2] - wall.start[2]))
end

function Project.Normalize(raw, options)
  options = type(options) == 'table' and options or {}
  if type(raw) ~= 'table' then return false, 'project_not_object' end
  if not exactKeys(raw, {
    schemaVersion = true, id = true, name = true, gridSize = true, elements = true,
    ownerAccountId = true, createdAt = true, updatedAt = true, plan = true
  }) then return false, 'unknown_project_field' end
  if tonumber(raw.schemaVersion) ~= 1 then return false, 'unsupported_schema' end
  local id = safeId(raw.id, 40)
  local name = cleanName(raw.name)
  local grid = finite(raw.gridSize, 0.25, 2.0)
  if not id or not name or not grid or not aligned(grid, 0.25) then return false, 'invalid_project_header' end
  if type(raw.elements) ~= 'table' or #raw.elements > (tonumber(options.maxElements) or 256) then return false, 'invalid_element_count' end

  local normalized = { schemaVersion = 1, id = id, name = name, gridSize = grid, elements = {} }
  if raw.plan ~= nil then
    local plan, planError = normalizePlan(raw.plan, grid)
    if not plan then return false, planError end
    normalized.plan = plan
  end
  local byId, walls, openingByWall = {}, {}, {}
  for index, element in ipairs(raw.elements) do
    local item, err = normalizeElement(element, grid)
    if not item then return false, ('element_%d:%s'):format(index, err) end
    if byId[item.id] then return false, 'duplicate_element_id' end
    byId[item.id] = item
    if item.type == 'wall' then walls[item.id] = item end
    normalized.elements[#normalized.elements + 1] = item
  end
  for _, item in ipairs(normalized.elements) do
    if item.type == 'door' or item.type == 'window' then
      local wall = walls[item.wallId]
      if not wall then return false, 'opening_wall_not_found' end
      -- shortcut: Wave 2 aceita uma abertura retangular por parede; multiplas aberturas
      -- exigem particionamento de intervalos comum ao editor, validador e exportador.
      if openingByWall[item.wallId] then return false, 'one_opening_per_wall_in_wave2' end
      local length = wallLength(wall)
      if item.offset - item.width / 2 <= 0.05 or item.offset + item.width / 2 >= length - 0.05 then return false, 'opening_outside_wall' end
      if item.sill + item.height >= wall.height - 0.05 then return false, 'opening_exceeds_wall_height' end
      openingByWall[item.wallId] = item
    end
  end

  if raw.ownerAccountId ~= nil then
    normalized.ownerAccountId = math.floor(finite(raw.ownerAccountId, 1, 2147483647) or 0)
    if normalized.ownerAccountId == 0 then return false, 'invalid_owner' end
  end
  if raw.createdAt ~= nil then normalized.createdAt = math.floor(finite(raw.createdAt, 0, 4102444800) or 0) end
  if raw.updatedAt ~= nil then normalized.updatedAt = math.floor(finite(raw.updatedAt, 0, 4102444800) or 0) end
  return true, normalized
end

local PLAN_SIDE_ORDER = { 'north', 'south', 'east', 'west' }
local PLAN_SIDES = {
  north = { dx = 0, dy = 1, axis = 'h' },
  south = { dx = 0, dy = -1, axis = 'h' },
  east = { dx = 1, dy = 0, axis = 'v' },
  west = { dx = -1, dy = 0, axis = 'v' }
}

local function planKey(gx, gy, level)
  return ('%d,%d,%d'):format(gx, gy, level)
end

local function gridUnit(value, grid)
  return math.floor(value / grid + 0.5)
end

local function planCellMap(plan)
  local map = {}
  for _, cell in ipairs(plan.cells or {}) do
    map[planKey(cell.gx, cell.gy, cell.level)] = cell
  end
  return map
end

local function hasFloor(map, gx, gy)
  local cell = map[planKey(gx, gy, 0)]
  return cell ~= nil and cell.floor == true
end

local function compileSlabs(project, out)
  local plan = project.plan
  local map = planCellMap(plan)
  local grid = project.gridSize
  local cellSize = plan.cellSize

  local function merge(field, materialField)
    local cells = {}
    for _, cell in ipairs(plan.cells) do
      if cell[field] then cells[#cells + 1] = cell end
    end
    table.sort(cells, function(a, b)
      if a.gy == b.gy then return a.gx < b.gx end
      return a.gy < b.gy
    end)
    local used = {}
    for _, cell in ipairs(cells) do
      if not used[planKey(cell.gx, cell.gy, 0)] then
        local material = cell[materialField] or 'checker'
        local width = 0
        while true do
          local nextCell = map[planKey(cell.gx + width, cell.gy, 0)]
          if not nextCell or not nextCell[field] or used[planKey(cell.gx + width, cell.gy, 0)]
            or (nextCell[materialField] or 'checker') ~= material then break end
          width = width + 1
        end
        local height = 1
        while true do
          local complete = true
          for dx = 0, width - 1 do
            local nextCell = map[planKey(cell.gx + dx, cell.gy + height, 0)]
            if not nextCell or not nextCell[field] or used[planKey(cell.gx + dx, cell.gy + height, 0)]
              or (nextCell[materialField] or 'checker') ~= material then
              complete = false
              break
            end
          end
          if not complete then break end
          height = height + 1
        end
        for dy = 0, height - 1 do
          for dx = 0, width - 1 do used[planKey(cell.gx + dx, cell.gy + dy, 0)] = true end
        end
        local x, y = cell.gx * cellSize, cell.gy * cellSize
        local z = field == 'floor' and 0.0 or plan.wallHeight
        local prefix = field == 'floor' and 'gf' or 'gc'
        out[#out + 1] = {
          id = ('%s_%d_%d_%d_%d'):format(prefix, gridUnit(x, grid), gridUnit(y, grid), width, height),
          type = field,
          position = { x, y, z },
          size = { width * cellSize, height * cellSize },
          rotation = 0,
          thickness = plan.slabThickness,
          material = material,
          generated = true
        }
      end
    end
  end

  merge('floor', 'floorMaterial')
  merge('ceiling', 'ceilingMaterial')
end

local function compileWalls(project, requests, manualWalls, out, remapped, dropped)
  local plan = project.plan
  local map = planCellMap(plan)
  local grid = project.gridSize
  local cellSize = plan.cellSize
  local edges = {}

  local function manualWallCovers(edge)
    for _, wall in ipairs(manualWalls or {}) do
      if wall.type == 'wall' then
        local dx = wall['end'][1] - wall.start[1]
        local dy = wall['end'][2] - wall.start[2]
        local axis = math.abs(dx) >= math.abs(dy) and 'h' or 'v'
        if axis == edge.axis then
          local fixed = axis == 'h' and wall.start[2] or wall.start[1]
          local from = axis == 'h' and math.min(wall.start[1], wall['end'][1]) or math.min(wall.start[2], wall['end'][2])
          local to = axis == 'h' and math.max(wall.start[1], wall['end'][1]) or math.max(wall.start[2], wall['end'][2])
          if math.abs(fixed - edge.fixed) <= 0.05 and from <= edge.from + 0.05 and to >= edge.to - 0.05 then
            return true
          end
        end
      end
    end
    return false
  end

  for _, cell in ipairs(plan.cells) do
    if cell.floor then
      for _, side in ipairs(PLAN_SIDE_ORDER) do
        local spec = PLAN_SIDES[side]
        if not hasFloor(map, cell.gx + spec.dx, cell.gy + spec.dy) then
          local edge = { axis = spec.axis, material = cell.wallMaterial or 'checker' }
          if spec.axis == 'h' then
            edge.fixed = (spec.dy > 0) and (cell.gy + 1) * cellSize or cell.gy * cellSize
            edge.from = cell.gx * cellSize
            edge.to = (cell.gx + 1) * cellSize
          else
            edge.fixed = (spec.dx > 0) and (cell.gx + 1) * cellSize or cell.gx * cellSize
            edge.from = cell.gy * cellSize
            edge.to = (cell.gy + 1) * cellSize
          end
          if not manualWallCovers(edge) then edges[#edges + 1] = edge end
        end
      end
    end
  end

  local groups, groupKeys = {}, {}
  for _, edge in ipairs(edges) do
    local key = ('%s|%.4f'):format(edge.axis, edge.fixed)
    if not groups[key] then
      groups[key] = {}
      groupKeys[#groupKeys + 1] = key
    end
    groups[key][#groups[key] + 1] = edge
  end
  table.sort(groupKeys)

  local runs = {}
  for _, key in ipairs(groupKeys) do
    local group = groups[key]
    table.sort(group, function(a, b) return a.from < b.from end)
    local run
    local function flush()
      if run then
        runs[#runs + 1] = run
        run = nil
      end
    end
    for _, edge in ipairs(group) do
      if run and math.abs(edge.from - run.to) <= 0.001 and edge.material == run.material then
        run.to = edge.to
      else
        flush()
        run = { axis = edge.axis, fixed = edge.fixed, from = edge.from, to = edge.to, material = edge.material }
      end
    end
    flush()
  end

  local function pointOnRun(run, point)
    if run.axis == 'h' then
      return math.abs(point[2] - run.fixed) <= 0.3 and point[1] >= run.from - 0.01 and point[1] <= run.to + 0.01
    end
    return math.abs(point[1] - run.fixed) <= 0.3 and point[2] >= run.from - 0.01 and point[2] <= run.to + 0.01
  end

  local requestRuns = {}
  for _, request in ipairs(requests or {}) do
    local matched
    for index, run in ipairs(runs) do
      if pointOnRun(run, request.point) then matched = index break end
    end
    if matched then
      requestRuns[matched] = requestRuns[matched] or {}
      requestRuns[matched][#requestRuns[matched] + 1] = request
    else
      dropped[#dropped + 1] = request.id
    end
  end

  local function emitSolid(run, from, to)
    if to - from < grid - 0.001 then return end
    local wallId = ('gwr_%s_%d_%d_%d'):format(run.axis, gridUnit(run.fixed, grid), gridUnit(from, grid), gridUnit(to, grid))
    local start, finish
    if run.axis == 'h' then
      start = { from, run.fixed, 0.0 }
      finish = { to, run.fixed, 0.0 }
    else
      start = { run.fixed, from, 0.0 }
      finish = { run.fixed, to, 0.0 }
    end
    out[#out + 1] = {
      id = wallId,
      type = 'wall',
      start = start,
      ['end'] = finish,
      height = plan.wallHeight,
      thickness = plan.wallThickness,
      material = run.material or 'checker',
      generated = true
    }
  end

  local function emitOpening(run, request, from, to, wallId)
    local length = to - from
    local coordinate = run.axis == 'h' and request.point[1] or request.point[2]
    local offset = coordinate - from
    local half = request.width / 2
    if offset - half <= 0.05 or offset + half >= length - 0.05
      or request.sill + request.height >= plan.wallHeight - 0.05 then
      dropped[#dropped + 1] = request.id
      return false
    end
    local start, finish
    if run.axis == 'h' then
      start = { from, run.fixed, 0.0 }
      finish = { to, run.fixed, 0.0 }
    else
      start = { run.fixed, from, 0.0 }
      finish = { run.fixed, to, 0.0 }
    end
    out[#out + 1] = {
      id = wallId,
      type = 'wall',
      start = start,
      ['end'] = finish,
      height = plan.wallHeight,
      thickness = plan.wallThickness,
      material = run.material or 'checker',
      generated = true
    }
    remapped[#remapped + 1] = {
      id = request.id,
      type = request.type,
      wallId = wallId,
      offset = offset,
      width = request.width,
      height = request.height,
      sill = request.sill
    }
    return true
  end

  for runIndex, run in ipairs(runs) do
    local list = requestRuns[runIndex]
    if not list or #list == 0 then
      emitSolid(run, run.from, run.to)
    else
      table.sort(list, function(a, b)
        local av = run.axis == 'h' and a.point[1] or a.point[2]
        local bv = run.axis == 'h' and b.point[1] or b.point[2]
        return av < bv
      end)
      local cursor = run.from
      for requestIndex, request in ipairs(list) do
        local coordinate = run.axis == 'h' and request.point[1] or request.point[2]
        local rawLeft = coordinate - request.width / 2 - 0.3
        local rawRight = coordinate + request.width / 2 + 0.3
        local left = math.floor(rawLeft / grid + 0.0001) * grid
        local right = math.ceil(rawRight / grid - 0.0001) * grid
        if left < cursor + grid - 0.001 or right > run.to - grid + 0.001 then
          dropped[#dropped + 1] = request.id
        else
          local wallId = ('gwo_%d_%d'):format(runIndex, requestIndex)
          if emitOpening(run, request, left, right, wallId) then
            emitSolid(run, cursor, left)
            cursor = right
          end
        end
      end
      emitSolid(run, cursor, run.to)
    end
  end
end

function Project.PlanDefaults(wallHeight, wallThickness, slabThickness, cellSize)
  return {
    version = PLAN_VERSION,
    cellSize = cellSize or 2.0,
    wallHeight = wallHeight or 3.0,
    wallThickness = wallThickness or 0.12,
    slabThickness = slabThickness or 0.2,
    cells = {}
  }
end

function Project.IsMaterial(value)
  return MATERIALS[tostring(value or '')] == true
end
function Project.PaintCells(plan, minX, minY, maxX, maxY, mode)
  if type(plan) ~= 'table' or type(plan.cells) ~= 'table' then return nil, 'invalid_plan' end
  if mode ~= 'floor' and mode ~= 'ceiling' and mode ~= 'erase' then return nil, 'invalid_paint_mode' end
  local x1, x2 = math.min(minX, maxX), math.max(minX, maxX)
  local y1, y2 = math.min(minY, maxY), math.max(minY, maxY)
  minX, maxX, minY, maxY = x1, x2, y1, y2
  if maxX - minX > 128 or maxY - minY > 128 then return nil, 'paint_area_too_large' end

  local map = {}
  for _, cell in ipairs(plan.cells) do
    map[planKey(cell.gx, cell.gy, cell.level)] = {
      gx = cell.gx, gy = cell.gy, level = cell.level,
      floor = cell.floor, ceiling = cell.ceiling,
      floorMaterial = cell.floorMaterial or 'checker',
      ceilingMaterial = cell.ceilingMaterial or 'checker',
      wallMaterial = cell.wallMaterial or 'checker'
    }
  end

  for gx = minX, maxX do
    for gy = minY, maxY do
      local key = planKey(gx, gy, 0)
      if mode == 'erase' then
        map[key] = nil
      else
        local cell = map[key] or {
          gx = gx, gy = gy, level = 0, floor = false, ceiling = false,
          floorMaterial = 'checker', ceilingMaterial = 'checker', wallMaterial = 'checker'
        }
        cell.floor = true
        if mode == 'ceiling' then cell.ceiling = true end
        map[key] = cell
      end
    end
  end

  local cells = {}
  for _, cell in pairs(map) do
    if cell.floor or cell.ceiling then cells[#cells + 1] = cell end
  end
  table.sort(cells, function(a, b)
    if a.gy == b.gy then return a.gx < b.gx end
    return a.gy < b.gy
  end)
  return cells
end

function Project.CompilePlan(project, openingRequests, manualWalls)
  local plan = project and project.plan
  if not plan then return {}, {}, {} end
  local out, remapped, dropped = {}, {}, {}
  compileSlabs(project, out)
  compileWalls(project, openingRequests or {}, manualWalls or {}, out, remapped, dropped)
  return out, remapped, dropped
end

function Project.Reconcile(project, options)
  if type(project) ~= 'table' or project.plan == nil then return true, project, {} end
  local generatedWalls = {}
  for _, element in ipairs(project.elements or {}) do
    if element.generated == true and element.type == 'wall' then generatedWalls[element.id] = element end
  end

  local manual, requests, dropped = {}, {}, {}
  for _, element in ipairs(project.elements or {}) do
    if element.generated == true then
      -- generated structures are always rebuilt from the plan
    elseif (element.type == 'door' or element.type == 'window') and generatedWalls[element.wallId] then
      local wall = generatedWalls[element.wallId]
      local dx, dy = wall['end'][1] - wall.start[1], wall['end'][2] - wall.start[2]
      local length = math.max(math.abs(dx), math.abs(dy))
      if length > 0 then
        local ux, uy = dx / length, dy / length
        requests[#requests + 1] = {
          id = element.id,
          type = element.type,
          point = { wall.start[1] + ux * element.offset, wall.start[2] + uy * element.offset },
          width = element.width,
          height = element.height,
          sill = element.sill
        }
      else
        dropped[#dropped + 1] = element.id
      end
    else
      manual[#manual + 1] = element
    end
  end

  local manualWalls = {}
  for _, element in ipairs(manual) do
    if element.type == 'wall' then manualWalls[#manualWalls + 1] = element end
  end

  local generated, remapped, compileDropped = Project.CompilePlan(project, requests, manualWalls)
  for _, id in ipairs(compileDropped) do dropped[#dropped + 1] = id end
  local elements = {}
  for _, element in ipairs(manual) do elements[#elements + 1] = element end
  for _, element in ipairs(generated) do elements[#elements + 1] = element end
  for _, element in ipairs(remapped) do elements[#elements + 1] = element end

  local candidate = {}
  for key, value in pairs(project) do candidate[key] = value end
  candidate.elements = elements
  local valid, normalized = Project.Normalize(candidate, options or { maxElements = 256 })
  return valid, normalized, dropped
end

function Project.PlanCellCount(project)
  return project and project.plan and #project.plan.cells or 0
end

local function wallBox(wall, fromDistance, toDistance, z0, z1)
  local sx, sy, sz = wall.start[1], wall.start[2], wall.start[3]
  local dx, dy = wall['end'][1] - sx, wall['end'][2] - sy
  local length = math.max(math.abs(dx), math.abs(dy))
  local ux, uy = dx / length, dy / length
  local ax, ay = sx + ux * fromDistance, sy + uy * fromDistance
  local bx, by = sx + ux * toDistance, sy + uy * toDistance
  local half = wall.thickness / 2
  return {
    min = { math.min(ax, bx) - (math.abs(uy) * half), math.min(ay, by) - (math.abs(ux) * half), sz + z0 },
    max = { math.max(ax, bx) + (math.abs(uy) * half), math.max(ay, by) + (math.abs(ux) * half), sz + z1 }
  }
end

function Project.Boxes(project)
  local openings = {}
  for _, element in ipairs(project.elements or {}) do
    if element.type == 'door' or element.type == 'window' then openings[element.wallId] = element end
  end
  local boxes = {}
  for _, element in ipairs(project.elements or {}) do
    if element.type == 'floor' or element.type == 'ceiling' then
      local sizeX, sizeY = element.size[1], element.size[2]
      if element.rotation % 180 ~= 0 then sizeX, sizeY = sizeY, sizeX end
      boxes[#boxes + 1] = {
        elementId = element.id,
        type = element.type,
        min = { element.position[1], element.position[2], element.position[3] - (element.type == 'floor' and element.thickness or 0) },
        max = { element.position[1] + sizeX, element.position[2] + sizeY, element.position[3] + (element.type == 'ceiling' and element.thickness or 0) }
      }
    elseif element.type == 'wall' then
      local opening = openings[element.id]
      local length = wallLength(element)
      local parts = {}
      if not opening then
        parts[1] = wallBox(element, 0, length, 0, element.height)
      else
        local left, right = opening.offset - opening.width / 2, opening.offset + opening.width / 2
        parts[#parts + 1] = wallBox(element, 0, left, 0, element.height)
        parts[#parts + 1] = wallBox(element, right, length, 0, element.height)
        if opening.sill > 0 then parts[#parts + 1] = wallBox(element, left, right, 0, opening.sill) end
        parts[#parts + 1] = wallBox(element, left, right, opening.sill + opening.height, element.height)
      end
      for _, part in ipairs(parts) do
        part.elementId = element.id
        part.type = element.type
        boxes[#boxes + 1] = part
      end
    end
  end
  return boxes
end

function Project.OpeningBounds(project, opening)
  if not opening then return nil end
  local wall
  for _, element in ipairs(project.elements or {}) do if element.id == opening.wallId and element.type == 'wall' then wall = element break end end
  if not wall then return nil end
  return wallBox(wall, opening.offset - opening.width / 2, opening.offset + opening.width / 2, opening.sill, opening.sill + opening.height)
end

function Project.SelectionBoxes(project)
  local boxes = Project.Boxes(project)
  for _, element in ipairs(project and project.elements or {}) do
    if element.type == 'door' or element.type == 'window' then
      local bounds = Project.OpeningBounds(project, element)
      if bounds then
        bounds.elementId = element.id
        bounds.type = element.type
        boxes[#boxes + 1] = bounds
      end
    end
  end
  return boxes
end

function Project.Find(project, id)
  for index, element in ipairs(project and project.elements or {}) do if element.id == id then return element, index end end
  return nil
end
