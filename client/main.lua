local state = {
  open = false, project = nil, projects = {}, selectedId = nil, tool = 'select',
  draftStart = nil, history = {}, future = {}, dirty = false,
  origin = nil, cameraTarget = nil, cursor = nil, camera = nil, gridDrag = nil,
  material = 'checker',
  yaw = 45.0, pitch = -35.0, distance = Config.Editor.cameraDistance
}

local colors = {
  floor = { 60, 146, 198, 90 }, ceiling = { 115, 117, 128, 70 },
  wall = { 225, 166, 45, 115 }, selected = { 255, 207, 87, 180 }, opening = { 44, 208, 154, 120 }
}

local function clone(value)
  if value == nil then return nil end
  return json.decode(json.encode(value))
end

local function notify(message, kind)
  lib.notify({ title = 'MZ Shell Studio', description = message, type = kind or 'inform' })
end

local function post(action, payload)
  SendNUIMessage({ action = action, payload = payload })
end

local function awaitServer(name, timeoutMs, ...)
  local args = { ... }
  local done, response, failed = false, nil, false
  CreateThread(function()
    local ok, result = pcall(function()
      return lib.callback.await(name, false, table.unpack(args))
    end)
    if ok then response = result else failed = true end
    done = true
  end)
  local deadline = GetGameTimer() + (timeoutMs or 5000)
  while not done and GetGameTimer() < deadline do Wait(25) end
  return done, response, failed
end

local function snapshot()
  if not state.project then return end
  state.history[#state.history + 1] = {
    elements = clone(state.project.elements),
    plan = clone(state.project.plan)
  }
  if #state.history > 64 then table.remove(state.history, 1) end
  state.future = {}
end

local function restoreSnapshot(snapshotValue)
  state.project.elements = clone(snapshotValue.elements or {})
  state.project.plan = clone(snapshotValue.plan)
end

local function currentSnapshot()
  return {
    elements = clone(state.project.elements),
    plan = clone(state.project.plan)
  }
end

local function validateProject()
  if not state.project then return false, 'no_project' end
  local valid, normalized = MZShellStudioProject.Normalize(state.project, { maxElements = Config.MaxElements })
  if not valid then return false, normalized end
  state.project = normalized
  return true
end

local function rejectGenerated(element, callback)
  if element and element.generated then
    notify('Elemento gerado pela planta. Use as ferramentas de grade.', 'error')
    if callback then callback({ ok = false, error = 'generated_readonly' }) end
    return true
  end
  return false
end

local function changed()
  state.dirty = true
  post('project', {
    project = state.project,
    selectedId = state.selectedId,
    clearSelection = state.selectedId == nil,
    dirty = true
  })
end

local function currentElement()
  return MZShellStudioProject.Find(state.project, state.selectedId)
end

local function nextElementId(kind)
  local used, index = {}, 0
  for _, element in ipairs(state.project.elements) do used[element.id] = true end
  repeat index = index + 1 until not used[('%s_%03d'):format(kind, index)]
  return ('%s_%03d'):format(kind, index)
end

local function snap(value)
  local grid = state.project and state.project.gridSize or Config.Editor.gridSize
  return math.floor(value / grid + 0.5) * grid
end

local function world(localPoint)
  return vector3(state.origin.x + localPoint[1], state.origin.y + localPoint[2], state.origin.z + localPoint[3])
end

local function localPoint(point)
  return { snap(point.x - state.origin.x), snap(point.y - state.origin.y), snap(point.z - state.origin.z) }
end

local function cameraPosition()
  local yaw, pitch = math.rad(state.yaw), math.rad(state.pitch)
  local horizontal = math.cos(pitch) * state.distance
  return vector3(
    state.cameraTarget.x + math.sin(yaw) * horizontal,
    state.cameraTarget.y - math.cos(yaw) * horizontal,
    state.cameraTarget.z - math.sin(pitch) * state.distance
  )
end

local function updateCamera()
  if not state.camera or not DoesCamExist(state.camera) then return end
  local position = cameraPosition()
  SetCamCoord(state.camera, position.x, position.y, position.z)
  PointCamAtCoord(state.camera, state.cameraTarget.x, state.cameraTarget.y, state.cameraTarget.z)
end

local function rayFromScreen(x, y, width, height)
  local cam = cameraPosition()
  local target = state.cameraTarget
  local forward = target - cam
  forward = forward / #forward
  local right = vector3(forward.y, -forward.x, 0.0)
  right = right / math.max(#right, 0.001)
  local up = vector3(
    right.y * forward.z - right.z * forward.y,
    right.z * forward.x - right.x * forward.z,
    right.x * forward.y - right.y * forward.x
  )
  local aspect = width / math.max(height, 1)
  local scale = math.tan(math.rad(GetCamFov(state.camera)) * 0.5)
  local nx, ny = (x / width) * 2.0 - 1.0, 1.0 - (y / height) * 2.0
  local direction = forward + right * (nx * scale * aspect) + up * (ny * scale)
  return cam, direction / #direction
end

local function planePoint(x, y, width, height, z)
  local origin, direction = rayFromScreen(x, y, width, height)
  if math.abs(direction.z) < 0.0001 then return nil end
  local distance = ((state.origin.z + (z or 0.0)) - origin.z) / direction.z
  if distance < 0.0 or distance > 100.0 then return nil end
  return origin + direction * distance
end

local function rayBox(origin, direction, box)
  local minimum, maximum = world(box.min), world(box.max)
  local tmin, tmax = 0.0, 1000.0
  for axis = 1, 3 do
    local o = axis == 1 and origin.x or (axis == 2 and origin.y or origin.z)
    local d = axis == 1 and direction.x or (axis == 2 and direction.y or direction.z)
    local lo = axis == 1 and minimum.x or (axis == 2 and minimum.y or minimum.z)
    local hi = axis == 1 and maximum.x or (axis == 2 and maximum.y or maximum.z)
    if math.abs(d) < 0.00001 then
      if o < lo or o > hi then return nil end
    else
      local a, b = (lo - o) / d, (hi - o) / d
      if a > b then a, b = b, a end
      tmin, tmax = math.max(tmin, a), math.min(tmax, b)
      if tmin > tmax then return nil end
    end
  end
  return tmin
end

local function selectAt(x, y, width, height)
  local origin, direction = rayFromScreen(x, y, width, height)
  local bestId, bestDistance
  for _, box in ipairs(MZShellStudioProject.SelectionBoxes(state.project)) do
    local distance = rayBox(origin, direction, box)
    if distance and (not bestDistance or distance < bestDistance) then bestId, bestDistance = box.elementId, distance end
  end
  state.selectedId = bestId
  post('selection', { selectedId = bestId, project = state.project })
  return bestId
end

local planCellSize, ensurePlan

local function hitStructureAt(x, y, width, height)
  local origin, direction = rayFromScreen(x, y, width, height)
  local bestBox, bestDistance
  for _, box in ipairs(MZShellStudioProject.Boxes(state.project)) do
    local distance = rayBox(origin, direction, box)
    if distance and (not bestDistance or distance < bestDistance) then
      bestBox, bestDistance = box, distance
    end
  end
  if not bestBox then return nil end
  return bestBox, origin + direction * bestDistance
end

local function cellCoordinates(point)
  local size = planCellSize()
  return math.floor((point.x - state.origin.x) / size), math.floor((point.y - state.origin.y) / size)
end

local function planCellAt(gx, gy)
  local plan = state.project and state.project.plan
  if not plan then return nil end
  for _, cell in ipairs(plan.cells) do
    if cell.gx == gx and cell.gy == gy and cell.level == 0 then return cell end
  end
  return nil
end

local function cellsForGeneratedSlab(element)
  local size = planCellSize()
  local width, depth = element.size[1], element.size[2]
  if element.rotation % 180 ~= 0 then width, depth = depth, width end
  local x0, y0 = element.position[1], element.position[2]
  local gx0 = math.floor(x0 / size + 0.001)
  local gy0 = math.floor(y0 / size + 0.001)
  local gx1 = math.floor((x0 + width - 0.001) / size)
  local gy1 = math.floor((y0 + depth - 0.001) / size)
  local cells = {}
  for gx = gx0, gx1 do
    for gy = gy0, gy1 do
      local cell = planCellAt(gx, gy)
      if cell and cell.floor then cells[#cells + 1] = cell end
    end
  end
  return cells
end

local function cellsForGeneratedWall(wall)
  local size = planCellSize()
  local dx, dy = wall['end'][1] - wall.start[1], wall['end'][2] - wall.start[2]
  local cells, seen = {}, {}
  local function add(cell)
    if cell and cell.floor then
      local key = ('%d,%d'):format(cell.gx, cell.gy)
      if not seen[key] then seen[key] = true cells[#cells + 1] = cell end
    end
  end
  if math.abs(dx) >= math.abs(dy) then
    local x0, x1 = math.min(wall.start[1], wall['end'][1]), math.max(wall.start[1], wall['end'][1])
    local fixed = wall.start[2]
    local gx0 = math.floor(x0 / size + 0.001)
    local gx1 = math.floor((x1 - 0.001) / size)
    local gy = math.floor(fixed / size)
    for gx = gx0, gx1 do
      local below = planCellAt(gx, gy - 1)
      if below and below.floor then add(below) else add(planCellAt(gx, gy)) end
    end
  else
    local y0, y1 = math.min(wall.start[2], wall['end'][2]), math.max(wall.start[2], wall['end'][2])
    local fixed = wall.start[1]
    local gy0 = math.floor(y0 / size + 0.001)
    local gy1 = math.floor((y1 - 0.001) / size)
    local gx = math.floor(fixed / size)
    for gy = gy0, gy1 do
      local west = planCellAt(gx - 1, gy)
      if west and west.floor then add(west) else add(planCellAt(gx, gy)) end
    end
  end
  return cells
end

local function applyMaterialAt(x, y, width, height)
  if not state.project then return false, 'no_project' end
  local box, point = hitStructureAt(x, y, width, height)
  if not box or not point then
    notify('Clique em um piso, parede ou teto para aplicar o material.', 'error')
    return false, 'no_surface'
  end
  local element, index = MZShellStudioProject.Find(state.project, box.elementId)
  if not element or not index then return false, 'no_element' end
  if element.type ~= 'floor' and element.type ~= 'ceiling' and element.type ~= 'wall' then
    notify('Materiais se aplicam a piso, parede ou teto.', 'error')
    return false, 'invalid_surface'
  end

  local before = currentSnapshot()
  snapshot()
  if element.generated then
    local cells, surface
    if element.type == 'floor' or element.type == 'ceiling' then
      cells = cellsForGeneratedSlab(element)
      surface = element.type == 'floor' and 'floorMaterial' or 'ceilingMaterial'
    else
      cells = cellsForGeneratedWall(element)
      surface = 'wallMaterial'
    end
    if #cells == 0 then
      local gx, gy = cellCoordinates(point)
      local fallback = planCellAt(gx, gy)
      if fallback then cells = { fallback } end
    end
    if #cells == 0 then
      restoreSnapshot(before)
      table.remove(state.history)
      notify('Nao foi possivel localizar a celula de origem desta superficie.', 'error')
      return false, 'no_cell'
    end
    for _, cell in ipairs(cells) do cell[surface] = state.material end
    local candidate = {}
    for key, value in pairs(state.project) do candidate[key] = value end
    local valid, normalized, dropped = MZShellStudioProject.Reconcile(candidate, { maxElements = Config.MaxElements })
    if not valid then
      restoreSnapshot(before)
      table.remove(state.history)
      notify('Material invalido: ' .. tostring(normalized), 'error')
      return false, normalized
    end
    state.project = normalized
    if dropped and #dropped > 0 then
      notify(('%d abertura(s) removida(s) ao recompilar.'):format(#dropped), 'error')
    end
    state.selectedId = nil
    changed()
    notify(('Material aplicado em %d celula(s): %s'):format(#cells, state.material), 'success')
    return true
  end

  element.material = state.material
  local valid, errorCode = validateProject()
  if not valid then
    restoreSnapshot(before)
    table.remove(state.history)
    notify('Material invalido: ' .. tostring(errorCode), 'error')
    return false, errorCode
  end
  state.selectedId = element.id
  changed()
  notify('Material aplicado: ' .. state.material, 'success')
  return true
end

local function deleteSelected()
  local element, index = currentElement()
  if not index or not element then return false, 'no_selection' end
  if element.generated then return false, 'generated_readonly' end
  snapshot()
  local before = currentSnapshot()
  local removedId = element.id
  local removedType = element.type
  table.remove(state.project.elements, index)

  for i = #state.project.elements, 1, -1 do
    local candidate = state.project.elements[i]
    if candidate.wallId == removedId then table.remove(state.project.elements, i) end
  end
  if removedType == 'floor' then
    for i = #state.project.elements, 1, -1 do
      local candidate = state.project.elements[i]
      if candidate.type == 'ceiling'
        and candidate.position[1] == element.position[1] and candidate.position[2] == element.position[2]
        and candidate.size[1] == element.size[1] and candidate.size[2] == element.size[2] then
        table.remove(state.project.elements, i)
      end
    end
  end

  state.selectedId = nil
  local valid, errorCode = validateProject()
  if not valid then
    restoreSnapshot(before)
    table.remove(state.history)
    notify('Nao foi possivel excluir: ' .. tostring(errorCode), 'error')
    return false, errorCode
  end
  changed()
  return true
end

local function wallAtPoint(point)
  local best, bestDistance, bestOffset
  for _, wall in ipairs(state.project.elements) do
    if wall.type == 'wall' then
      local ax, ay, bx, by = wall.start[1], wall.start[2], wall['end'][1], wall['end'][2]
      local length = math.max(math.abs(bx - ax), math.abs(by - ay))
      local ux, uy = (bx - ax) / length, (by - ay) / length
      local offset = math.max(0, math.min(length, (point[1] - ax) * ux + (point[2] - ay) * uy))
      local px, py = ax + ux * offset, ay + uy * offset
      local distance = math.sqrt((point[1] - px)^2 + (point[2] - py)^2)
      if distance <= state.project.gridSize * 1.25 and (not bestDistance or distance < bestDistance) then
        best, bestDistance, bestOffset = wall, distance, offset
      end
    end
  end
  return best, bestOffset
end

planCellSize = function()
  return (state.project and state.project.plan and state.project.plan.cellSize) or Config.Editor.cellSize
end

ensurePlan = function()
  if not state.project then return nil end
  if not state.project.plan then
    state.project.plan = MZShellStudioProject.PlanDefaults(
      Config.Editor.wallHeight,
      Config.Editor.wallThickness,
      Config.Editor.slabThickness,
      Config.Editor.cellSize
    )
  end
  return state.project.plan
end

local function cellAtScreen(x, y, width, height)
  local hit = planePoint(x, y, width, height, 0.0)
  if not hit then return nil end
  local size = planCellSize()
  return {
    gx = math.floor((hit.x - state.origin.x) / size),
    gy = math.floor((hit.y - state.origin.y) / size),
    level = 0
  }
end

local function gridRectangle(a, b)
  return math.min(a.gx, b.gx), math.min(a.gy, b.gy), math.max(a.gx, b.gx), math.max(a.gy, b.gy)
end

local function applyGridDrag()
  local drag = state.gridDrag
  if not drag or not drag.startCell or not drag.currentCell then return false, 'no_drag' end
  if state.tool ~= 'gridFloor' and state.tool ~= 'gridCeiling' and state.tool ~= 'gridErase' then
    return false, 'invalid_tool'
  end
  local plan = ensurePlan()
  if not plan then return false, 'no_project' end
  local before = currentSnapshot()
  snapshot()

  local minX, minY, maxX, maxY = gridRectangle(drag.startCell, drag.currentCell)
  local mode = state.tool == 'gridErase' and 'erase' or (state.tool == 'gridCeiling' and 'ceiling' or 'floor')
  local cells, paintError = MZShellStudioProject.PaintCells(plan, minX, minY, maxX, maxY, mode)
  if not cells then
    restoreSnapshot(before)
    table.remove(state.history)
    state.gridDrag = nil
    notify('Nao foi possivel alterar a planta: ' .. tostring(paintError), 'error')
    return false, paintError
  end
  plan.cells = cells

  local candidate = {}
  for key, value in pairs(state.project) do candidate[key] = value end
  candidate.plan = plan
  local valid, normalized, dropped = MZShellStudioProject.Reconcile(candidate, { maxElements = Config.MaxElements })
  if not valid then
    restoreSnapshot(before)
    table.remove(state.history)
    state.gridDrag = nil
    notify('Planta invalida: ' .. tostring(normalized), 'error')
    return false, normalized
  end

  state.project = normalized
  state.selectedId = nil
  state.gridDrag = nil
  if dropped and #dropped > 0 then
    notify(('%d abertura(s) removida(s) porque a parede deixou de existir.'):format(#dropped), 'error')
  end
  changed()
  return true, { dropped = dropped or {} }
end

local function addAt(x, y, width, height)
  if state.tool == 'materials' then applyMaterialAt(x, y, width, height) return end
  if state.tool == 'gridFloor' or state.tool == 'gridCeiling' or state.tool == 'gridErase' then return end
  local hit = planePoint(x, y, width, height, 0.0)
  if not hit then return end
  local point = localPoint(hit)
  if state.tool == 'select' then selectAt(x, y, width, height) return end
  if state.tool == 'delete' then
    if selectAt(x, y, width, height) then
      local ok, errorCode = deleteSelected()
      if not ok then notify('Nao foi possivel apagar: ' .. tostring(errorCode), 'error') end
    end
    return
  end

  if state.tool == 'door' or state.tool == 'window' then
    local wall, offset = wallAtPoint(point)
    if not wall then notify('Clique proximo de uma parede para criar a abertura.', 'error') return end
    for _, element in ipairs(state.project.elements) do
      if (element.type == 'door' or element.type == 'window') and element.wallId == wall.id then
        notify('Wave 2 aceita uma abertura por parede.', 'error') return
      end
    end
    local openingWidth = state.tool == 'door' and Config.Editor.doorWidth or Config.Editor.windowWidth
    local length = math.max(math.abs(wall['end'][1] - wall.start[1]), math.abs(wall['end'][2] - wall.start[2]))
    offset = math.max(openingWidth / 2 + 0.1, math.min(length - openingWidth / 2 - 0.1, snap(offset)))
    snapshot()
    state.project.elements[#state.project.elements + 1] = {
      id = nextElementId(state.tool), type = state.tool, wallId = wall.id, offset = offset,
      width = openingWidth,
      height = state.tool == 'door' and Config.Editor.doorHeight or Config.Editor.windowHeight,
      sill = state.tool == 'door' and 0.0 or Config.Editor.windowSill
    }
    state.selectedId = state.project.elements[#state.project.elements].id
    changed()
    return
  end

  if not state.draftStart then
    state.draftStart = point
    post('draft', { active = true })
    return
  end
  local start = state.draftStart
  state.draftStart = nil
  if start[1] == point[1] and start[2] == point[2] then notify('Use dois pontos diferentes.', 'error') return end
  snapshot()
  local element
  if state.tool == 'wall' then
    local dx, dy = math.abs(point[1] - start[1]), math.abs(point[2] - start[2])
    if dx >= dy then point[2] = start[2] else point[1] = start[1] end
    element = { id = nextElementId('wall'), type = 'wall', start = start, ['end'] = point,
      height = Config.Editor.wallHeight, thickness = Config.Editor.wallThickness, material = 'checker' }
  else
    local minimumX, minimumY = math.min(start[1], point[1]), math.min(start[2], point[2])
    local z = state.tool == 'ceiling' and Config.Editor.wallHeight or 0.0
    element = { id = nextElementId(state.tool), type = state.tool, position = { minimumX, minimumY, z },
      size = { math.abs(point[1] - start[1]), math.abs(point[2] - start[2]) }, rotation = 0,
      thickness = Config.Editor.slabThickness, material = 'checker' }
  end
  state.project.elements[#state.project.elements + 1] = element
  state.selectedId = element.id
  changed()
end

local function closeEditor()
  if not state.open then return end
  state.open = false
  state.draftStart, state.cursor, state.gridDrag = nil, nil, nil
  SetNuiFocus(false, false)
  post('visibility', { visible = false })
  if state.camera and DoesCamExist(state.camera) then
    RenderScriptCams(false, true, 250, true, true)
    DestroyCam(state.camera, false)
  end
  state.camera = nil
  local ped = PlayerPedId()
  if DoesEntityExist(ped) and state.pedWasFrozen ~= true then FreezeEntityPosition(ped, false) end
  state.pedWasFrozen = nil
end

local function openEditor()
  if state.open then return end
  local response = lib.callback.await('mz_shellstudio:server:bootstrap', false)
  if not response or not response.ok then notify('Acesso negado ou mz_core indisponivel.', 'error') return end
  state.projects = response.data.projects or {}
  state.origin = GetEntityCoords(PlayerPedId()) + GetEntityForwardVector(PlayerPedId()) * Config.Editor.originDistance
  state.origin = vector3(snap(state.origin.x), snap(state.origin.y), snap(state.origin.z - 1.0))
  state.cameraTarget = vector3(state.origin.x, state.origin.y, state.origin.z + 1.5)
  state.camera = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
  if not state.camera or not DoesCamExist(state.camera) then notify('Nao foi possivel criar a camera.', 'error') return end
  SetCamFov(state.camera, 48.0)
  updateCamera()
  SetCamActive(state.camera, true)
  RenderScriptCams(true, true, 300, true, true)
  local ped = PlayerPedId()
  local frozenOk, wasFrozen = pcall(IsEntityPositionFrozen, ped)
  state.pedWasFrozen = frozenOk and wasFrozen == true
  FreezeEntityPosition(ped, true)
  state.open = true
  SetNuiFocus(true, true)
  post('bootstrap', { visible = true, projects = state.projects, config = Config.Editor, material = state.material })
end

RegisterCommand(Config.Command, function() if state.open then closeEditor() else openEditor() end end, false)

RegisterNUICallback('close', function(_, cb)
  closeEditor()
  cb({ ok = true })
end)
RegisterNUICallback('create', function(data, cb)
  local response = lib.callback.await('mz_shellstudio:server:create', false, data and data.name)
  if response and response.ok then
    state.project, state.projects = response.data.project, response.data.projects
    state.history, state.future, state.selectedId, state.dirty = {}, {}, nil, false
    post('project', { project = state.project, projects = state.projects, clearSelection = true, dirty = false })
  end
  cb(response or { ok = false, error = 'no_response' })
end)
RegisterNUICallback('load', function(data, cb)
  if state.dirty then cb({ ok = false, error = 'unsaved_changes' }) return end
  local response = lib.callback.await('mz_shellstudio:server:load', false, data and data.id)
  if response and response.ok then
    state.project, state.history, state.future, state.selectedId = response.data, {}, {}, nil
    post('project', { project = state.project, clearSelection = true, dirty = false })
  end
  cb(response or { ok = false, error = 'no_response' })
end)
RegisterNUICallback('save', function(_, cb)
  if not state.project then cb({ ok = false, error = 'no_project' }) return end
  local response = lib.callback.await('mz_shellstudio:server:save', false, state.project)
  if response and response.ok then
    state.project, state.projects, state.dirty = response.data.project, response.data.projects, false
    if state.selectedId and not MZShellStudioProject.Find(state.project, state.selectedId) then state.selectedId = nil end
    post('project', { project = state.project, projects = state.projects, selectedId = state.selectedId, clearSelection = state.selectedId == nil, dirty = false })
    notify('Projeto salvo.', 'success')
  end
  cb(response or { ok = false, error = 'no_response' })
end)
RegisterNUICallback('prepareExport', function(data, cb)
  if not state.project then cb({ ok = false, error = 'no_project' }) return end
  local projectId = type(data) == 'table' and data.projectId or nil
  if projectId ~= state.project.id then cb({ ok = false, error = 'project_mismatch' }) return end
  local completed, response, failed = awaitServer('mz_shellstudio:server:prepareExport', 5000, projectId)
  if not completed then cb({ ok = false, error = 'timeout' }) return end
  if failed then cb({ ok = false, error = 'server_error' }) return end
  if type(response) ~= 'table' then cb({ ok = false, error = 'no_response' }) return end
  cb(response)
end)
RegisterNUICallback('rename', function(data, cb)
  if not state.project then cb({ ok = false, error = 'no_project' }) return end
  local response = lib.callback.await('mz_shellstudio:server:rename', false, state.project.id, data and data.name)
  if response and response.ok then
    state.project, state.projects = response.data.project, response.data.projects
    post('project', response.data)
  end
  cb(response or { ok = false, error = 'no_response' })
end)
RegisterNUICallback('deleteProject', function(_, cb)
  if not state.project then cb({ ok = false, error = 'no_project' }) return end
  local response = lib.callback.await('mz_shellstudio:server:delete', false, state.project.id)
  if response and response.ok then
    state.project, state.projects, state.selectedId, state.dirty = nil, response.data.projects, nil, false
    post('project', { project = nil, projects = state.projects, clearSelection = true, dirty = false })
  end
  cb(response or { ok = false, error = 'no_response' })
end)
RegisterNUICallback('tool', function(data, cb)
  local allowed = { select=true, floor=true, wall=true, ceiling=true, door=true, window=true, delete=true,
    gridFloor=true, gridCeiling=true, gridErase=true, materials=true }
  if allowed[data and data.tool] then
    state.tool, state.draftStart, state.gridDrag = data.tool, nil, nil
  end
  cb({ ok = true })
end)
RegisterNUICallback('setMaterial', function(data, cb)
  local material = data and data.material
  if MZShellStudioProject.IsMaterial(material) then
    state.material = tostring(material)
    cb({ ok = true, material = state.material })
  else
    cb({ ok = false, error = 'invalid_material' })
  end
end)
RegisterNUICallback('worldClick', function(data, cb)
  if state.project and type(data) == 'table' then addAt(tonumber(data.x) or 0, tonumber(data.y) or 0, tonumber(data.width) or 1, tonumber(data.height) or 1) end
  cb({ ok = true })
end)
RegisterNUICallback('worldMove', function(data, cb)
  if state.project and type(data) == 'table' then
    local hit = planePoint(tonumber(data.x) or 0, tonumber(data.y) or 0,
      tonumber(data.width) or 1, tonumber(data.height) or 1, 0.0)
    state.cursor = hit and localPoint(hit) or nil
  end
  cb({ ok = true })
end)
RegisterNUICallback('gridBegin', function(data, cb)
  if not state.project or type(data) ~= 'table' then cb({ ok = false, error = 'no_project' }) return end
  local cell = cellAtScreen(tonumber(data.x) or 0, tonumber(data.y) or 0,
    tonumber(data.width) or 1, tonumber(data.height) or 1)
  if not cell then cb({ ok = false, error = 'no_cell' }) return end
  ensurePlan()
  state.gridDrag = { startCell = cell, currentCell = cell }
  cb({ ok = true })
end)
RegisterNUICallback('gridMove', function(data, cb)
  if not state.project or not state.gridDrag or type(data) ~= 'table' then cb({ ok = false }) return end
  local cell = cellAtScreen(tonumber(data.x) or 0, tonumber(data.y) or 0,
    tonumber(data.width) or 1, tonumber(data.height) or 1)
  if cell then state.gridDrag.currentCell = cell end
  cb({ ok = true })
end)
RegisterNUICallback('gridCommit', function(data, cb)
  if not state.project then cb({ ok = false, error = 'no_project' }) return end
  if type(data) == 'table' and data.startX and data.startY then
    local width, height = tonumber(data.width) or 1, tonumber(data.height) or 1
    local startCell = cellAtScreen(tonumber(data.startX) or 0, tonumber(data.startY) or 0, width, height)
    local currentCell = cellAtScreen(tonumber(data.x) or 0, tonumber(data.y) or 0, width, height)
    if startCell and currentCell then
      state.gridDrag = { startCell = startCell, currentCell = currentCell }
    end
  end
  if not state.gridDrag then cb({ ok = false, error = 'no_drag' }) return end
  local ok, payload = applyGridDrag()
  if ok then cb({ ok = true, dropped = payload.dropped })
  else cb({ ok = false, error = payload }) end
end)
RegisterNUICallback('gridCancel', function(_, cb)
  state.gridDrag = nil
  cb({ ok = true })
end)
RegisterNUICallback('camera', function(data, cb)
  if type(data) == 'table' then
    local dx, dy = math.max(-50, math.min(50, tonumber(data.dx) or 0)), math.max(-50, math.min(50, tonumber(data.dy) or 0))
    if data.pan == true then
      local yaw = math.rad(state.yaw)
      local right = vector3(math.cos(yaw), math.sin(yaw), 0.0)
      local forward = vector3(-math.sin(yaw), math.cos(yaw), 0.0)
      state.cameraTarget = state.cameraTarget + right * (-dx * 0.018) + forward * (dy * 0.018)
    else
      state.yaw = state.yaw - dx * 0.25
      state.pitch = math.max(-75.0, math.min(-10.0, state.pitch + dy * 0.2))
    end
    state.distance = math.max(Config.Editor.cameraMinDistance, math.min(Config.Editor.cameraMaxDistance, state.distance + (tonumber(data.zoom) or 0) * 0.015))
    updateCamera()
  end
  cb({ ok = true })
end)
RegisterNUICallback('cancel', function(_, cb)
  if state.gridDrag then
    state.gridDrag = nil
  elseif state.draftStart then
    state.draftStart = nil
    post('draft', { active = false })
  else
    closeEditor()
  end
  cb({ ok = true })
end)
RegisterNUICallback('updateElement', function(data, cb)
  local element, index = currentElement()
  if not element or type(data) ~= 'table' or type(data.patch) ~= 'table' then cb({ ok=false, error='no_selection' }) return end
  if rejectGenerated(element, cb) then return end
  local before = currentSnapshot()
  snapshot()
  local allowed
  if element.type == 'wall' then
    allowed = { height = true, thickness = true, material = true }
  elseif element.type == 'door' or element.type == 'window' then
    allowed = { offset = true, width = true, height = true, sill = true }
  else
    allowed = { thickness = true, material = true }
  end
  for key, value in pairs(data.patch) do
    if allowed[key] then
      if key == 'material' then element.material = tostring(value)
      else element[key] = tonumber(value) or element[key] end
    end
  end
  local valid, errorCode = validateProject()
  if not valid then
    restoreSnapshot(before)
    table.remove(state.history)
    notify('Valor fora dos limites do projeto.', 'error')
    cb({ ok=false, error=errorCode })
    return
  end
  changed()
  cb({ ok=true })
end)
RegisterNUICallback('nudge', function(data, cb)
  local element = currentElement()
  if not element then cb({ ok=false, error='no_selection' }) return end
  if rejectGenerated(element, cb) then return end
  local dx, dy = snap(tonumber(data and data.dx) or 0), snap(tonumber(data and data.dy) or 0)
  if dx == 0 and dy == 0 then cb({ ok=true }) return end
  local before = currentSnapshot()
  snapshot()
  if element.type == 'wall' then
    element.start[1], element.start[2] = element.start[1] + dx, element.start[2] + dy
    element['end'][1], element['end'][2] = element['end'][1] + dx, element['end'][2] + dy
  elseif element.position then
    element.position[1], element.position[2] = element.position[1] + dx, element.position[2] + dy
  else
    table.remove(state.history)
    cb({ ok=false, error='not_movable' })
    return
  end
  local valid, errorCode = validateProject()
  if not valid then
    restoreSnapshot(before)
    table.remove(state.history)
    notify('Movimento invalido: ' .. tostring(errorCode), 'error')
    cb({ ok=false, error=errorCode })
    return
  end
  changed()
  cb({ok=true})
end)
RegisterNUICallback('rotate', function(_, cb)
  local element = currentElement()
  if not element then cb({ok=false, error='no_selection'}) return end
  if rejectGenerated(element, cb) then return end
  if not element.rotation and element.type ~= 'wall' then cb({ok=false, error='not_rotatable'}) return end
  local before = currentSnapshot()
  snapshot()
  if element.type == 'wall' then
    local dx, dy = element['end'][1] - element.start[1], element['end'][2] - element.start[2]
    element['end'][1], element['end'][2] = element.start[1] - dy, element.start[2] + dx
  elseif element.rotation then
    local width, depth = element.size[1], element.size[2]
    local centerX = element.position[1] + width / 2
    local centerY = element.position[2] + depth / 2
    element.size[1], element.size[2] = depth, width
    element.position[1] = centerX - element.size[1] / 2
    element.position[2] = centerY - element.size[2] / 2
    element.rotation = (element.rotation + 90) % 360
  end
  local valid, errorCode = validateProject()
  if not valid then
    restoreSnapshot(before)
    table.remove(state.history)
    notify('Rotacao invalida: ' .. tostring(errorCode), 'error')
    cb({ok=false, error=errorCode})
    return
  end
  changed()
  cb({ok=true})
end)
RegisterNUICallback('deleteElement', function(_, cb)
  local ok, errorCode = deleteSelected()
  cb({ ok = ok, error = errorCode })
end)
RegisterNUICallback('undo', function(_, cb)
  local previous = table.remove(state.history)
  if previous then
    state.future[#state.future+1] = currentSnapshot()
    restoreSnapshot(previous)
    state.selectedId = nil
    changed()
  end
  cb({ok=previous~=nil})
end)
RegisterNUICallback('redo', function(_, cb)
  local nextValue = table.remove(state.future)
  if nextValue then
    state.history[#state.history+1] = currentSnapshot()
    restoreSnapshot(nextValue)
    state.selectedId = nil
    changed()
  end
  cb({ok=nextValue~=nil})
end)

CreateThread(function()
  while true do
    if not state.open or not state.project then Wait(300) else
      Wait(0)
      for i = -math.floor(Config.Editor.gridExtent / state.project.gridSize), math.floor(Config.Editor.gridExtent / state.project.gridSize) do
        local offset = i * state.project.gridSize
        local alpha = i == 0 and 125 or 35
        DrawLine(state.origin.x - Config.Editor.gridExtent, state.origin.y + offset, state.origin.z,
          state.origin.x + Config.Editor.gridExtent, state.origin.y + offset, state.origin.z, 132, 143, 156, alpha)
        DrawLine(state.origin.x + offset, state.origin.y - Config.Editor.gridExtent, state.origin.z,
          state.origin.x + offset, state.origin.y + Config.Editor.gridExtent, state.origin.z, 132, 143, 156, alpha)
      end
      local cellSize = planCellSize()
      if cellSize > 0 and (state.project.plan or state.tool:find('^grid')) then
        local count = math.floor(Config.Editor.gridExtent / cellSize)
        for i = -count, count do
          local offset = i * cellSize
          DrawLine(state.origin.x - Config.Editor.gridExtent, state.origin.y + offset, state.origin.z + 0.01,
            state.origin.x + Config.Editor.gridExtent, state.origin.y + offset, state.origin.z + 0.01, 230, 168, 45, 115)
          DrawLine(state.origin.x + offset, state.origin.y - Config.Editor.gridExtent, state.origin.z + 0.01,
            state.origin.x + offset, state.origin.y + Config.Editor.gridExtent, state.origin.z + 0.01, 230, 168, 45, 115)
        end
      end
      if state.gridDrag and state.gridDrag.startCell and state.gridDrag.currentCell then
        local minX, minY, maxX, maxY = gridRectangle(state.gridDrag.startCell, state.gridDrag.currentCell)
        local size = planCellSize()
        local color = state.tool == 'gridErase' and { 232, 82, 76, 90 } or { 230, 168, 45, 105 }
        for gx = minX, maxX do
          for gy = minY, maxY do
            local x, y = state.origin.x + gx * size, state.origin.y + gy * size
            DrawBox(x + 0.02, y + 0.02, state.origin.z + 0.02, x + size - 0.02, y + size - 0.02, state.origin.z + 0.08,
              color[1], color[2], color[3], color[4])
          end
        end
      end
      for _, box in ipairs(MZShellStudioProject.Boxes(state.project)) do
        local min, max = world(box.min), world(box.max)
        local color = box.elementId == state.selectedId and colors.selected or colors[box.type]
        DrawBox(min.x, min.y, min.z, max.x, max.y, max.z, color[1], color[2], color[3], color[4])
      end
      for _, element in ipairs(state.project.elements) do
        if element.type == 'door' or element.type == 'window' then
          local box = MZShellStudioProject.OpeningBounds(state.project, element)
          if box then
            local min, max = world(box.min), world(box.max)
            DrawBox(min.x, min.y, min.z, max.x, max.y, max.z,
              colors.opening[1], colors.opening[2], colors.opening[3], colors.opening[4])
          end
        end
      end
      if state.cursor and state.tool ~= 'select' and state.tool ~= 'delete' then
        local preview, valid
        if state.tool == 'floor' or state.tool == 'ceiling' then
          if state.draftStart then
            local start, point = state.draftStart, state.cursor
            local z = state.tool == 'ceiling' and Config.Editor.wallHeight or 0.0
            local thickness = Config.Editor.slabThickness
            preview = {
              min = { math.min(start[1], point[1]), math.min(start[2], point[2]), z - (state.tool == 'floor' and thickness or 0) },
              max = { math.max(start[1], point[1]), math.max(start[2], point[2]), z + (state.tool == 'ceiling' and thickness or 0) }
            }
            valid = preview.min[1] < preview.max[1] and preview.min[2] < preview.max[2]
          end
        elseif state.tool == 'wall' and state.draftStart then
          local point = { state.cursor[1], state.cursor[2], state.cursor[3] }
          local dx, dy = math.abs(point[1] - state.draftStart[1]), math.abs(point[2] - state.draftStart[2])
          if dx >= dy then point[2] = state.draftStart[2] else point[1] = state.draftStart[1] end
          if point[1] ~= state.draftStart[1] or point[2] ~= state.draftStart[2] then
            local wall = { type='wall', start=state.draftStart, ['end']=point, height=Config.Editor.wallHeight, thickness=Config.Editor.wallThickness }
            preview = MZShellStudioProject.Boxes({ elements = { wall } })[1]
            valid = preview ~= nil
          end
        elseif state.tool == 'door' or state.tool == 'window' then
          local wall, offset = wallAtPoint(state.cursor)
          if wall then
            local occupied = false
            for _, element in ipairs(state.project.elements) do
              if (element.type == 'door' or element.type == 'window') and element.wallId == wall.id then occupied = true break end
            end
            local openingWidth = state.tool == 'door' and Config.Editor.doorWidth or Config.Editor.windowWidth
            local length = math.max(math.abs(wall['end'][1] - wall.start[1]), math.abs(wall['end'][2] - wall.start[2]))
            local candidate = { type=state.tool, wallId=wall.id, offset=snap(offset), width=openingWidth,
              height=state.tool == 'door' and Config.Editor.doorHeight or Config.Editor.windowHeight,
              sill=state.tool == 'door' and 0.0 or Config.Editor.windowSill }
            preview = MZShellStudioProject.OpeningBounds(state.project, candidate)
            valid = not occupied and candidate.offset - openingWidth / 2 > 0.05 and candidate.offset + openingWidth / 2 < length - 0.05
          end
        end
        if preview then
          local min, max = world(preview.min), world(preview.max)
          local color = valid and colors.opening or { 232, 82, 76, 145 }
          DrawBox(min.x, min.y, min.z, max.x, max.y, max.z, color[1], color[2], color[3], color[4])
        end
      end
    end
  end
end)

AddEventHandler('onResourceStop', function(resource)
  if resource == GetCurrentResourceName() then closeEditor() end
end)
