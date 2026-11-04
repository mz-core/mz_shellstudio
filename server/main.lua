local RESOURCE = GetCurrentResourceName()
local STORE_PATH = 'data/projects.json'
local store = { schemaVersion = 1, projects = {} }
local mutationAt = {}
local idSequence = 0
local exportSequence = 0

local function result(ok, payload, errorCode)
  return { ok = ok == true, data = payload, error = errorCode }
end

local function loadStore()
  local raw = LoadResourceFile(RESOURCE, STORE_PATH)
  if not raw or raw == '' then return end
  local ok, decoded = pcall(json.decode, raw)
  if ok and type(decoded) == 'table' and tonumber(decoded.schemaVersion) == 1 and type(decoded.projects) == 'table' then
    local verified = { schemaVersion = 1, projects = {} }
    for projectId, project in pairs(decoded.projects) do
      local valid, normalized = MZShellStudioProject.Normalize(project, { maxElements = Config.MaxElements })
      if not valid or normalized.id ~= projectId then
        print(('[%s] ERRO: projeto persistido invalido (%s); store bloqueado para escrita.'):format(RESOURCE, tostring(projectId)))
        store = decoded
        store.invalid = true
        return
      end
      verified.projects[projectId] = normalized
    end
    store = verified
  else
    print(('[%s] ERRO: %s invalido; nenhuma escrita sera feita ate o resource reiniciar com um JSON valido.'):format(RESOURCE, STORE_PATH))
    store.invalid = true
  end
end

local function saveStore()
  if store.invalid then return false, 'store_invalid' end
  local encoded = json.encode(store)
  if not encoded or not SaveResourceFile(RESOURCE, STORE_PATH, encoded, -1) then
    return false, 'store_write_failed'
  end
  return true
end

local function authorize(source)
  if source <= 0 or GetResourceState('mz_core') ~= 'started' then return false, nil, 'core_unavailable' end
  local permissionOk, allowed = pcall(function()
    return exports['mz_core']:HasGlobalPermission(source, Config.Permission)
  end)
  if not permissionOk or allowed ~= true then return false, nil, 'not_authorized' end
  local accountOk, accountId = pcall(function()
    return exports['mz_core']:GetAccountId(source)
  end)
  accountId = accountOk and tonumber(accountId) or nil
  if not accountId or accountId < 1 then return false, nil, 'identity_unavailable' end
  return true, math.floor(accountId)
end

local function audit(source, accountId, action, projectId, metadata)
  local payload = {
    actor = { source = source, accountId = accountId, name = GetPlayerName(source) },
    target = { type = 'shellstudio_project', id = projectId or 'none' },
    metadata = metadata or {}
  }
  local ok = pcall(function() exports['mz_core']:CreateDetailedLog('world', action, payload) end)
  if not ok then
    print(('[%s] audit action=%s account=%s project=%s'):format(RESOURCE, action, accountId, projectId or 'none'))
  end
end

local function allowMutation(source)
  local now = GetGameTimer()
  if mutationAt[source] and now - mutationAt[source] < Config.MutationCooldownMs then return false end
  mutationAt[source] = now
  return true
end

local function ownedProjects(accountId)
  local list = {}
  for _, project in pairs(store.projects) do
    if tonumber(project.ownerAccountId) == accountId then
      list[#list + 1] = {
        id = project.id, name = project.name, gridSize = project.gridSize,
        elementCount = #(project.elements or {}), updatedAt = project.updatedAt
      }
    end
  end
  table.sort(list, function(a, b)
    if a.updatedAt == b.updatedAt then return a.id < b.id end
    return (a.updatedAt or 0) > (b.updatedAt or 0)
  end)
  return list
end

local function ownedProject(accountId, projectId)
  if type(projectId) ~= 'string' then return nil end
  local project = store.projects[projectId]
  if not project or tonumber(project.ownerAccountId) ~= accountId then return nil end
  return project
end

local function nextId(accountId)
  idSequence = (idSequence + 1) % 10000
  return ('mzss_p_%d_%d_%04d'):format(accountId, os.time(), idSequence)
end

local function callback(handler, mutating)
  return function(source, ...)
    local allowed, accountId, errorCode = authorize(source)
    if not allowed then return result(false, nil, errorCode) end
    if mutating and not allowMutation(source) then return result(false, nil, 'rate_limited') end
    return handler(source, accountId, ...)
  end
end

lib.callback.register('mz_shellstudio:server:bootstrap', callback(function(_, accountId)
  return result(true, { projects = ownedProjects(accountId), limits = { maxElements = Config.MaxElements } })
end, false))

lib.callback.register('mz_shellstudio:server:load', callback(function(_, accountId, projectId)
  local project = ownedProject(accountId, projectId)
  if not project then return result(false, nil, 'project_not_found') end
  return result(true, project)
end, false))

lib.callback.register('mz_shellstudio:server:create', callback(function(source, accountId, name)
  local list = ownedProjects(accountId)
  if #list >= Config.MaxProjectsPerAccount then return result(false, nil, 'project_limit') end
  local project = {
    schemaVersion = 1,
    id = nextId(accountId),
    name = tostring(name or 'Novo shell'),
    gridSize = Config.Editor.gridSize,
    elements = {},
    ownerAccountId = accountId,
    createdAt = os.time(),
    updatedAt = os.time()
  }
  local valid, normalized = MZShellStudioProject.Normalize(project, { maxElements = Config.MaxElements })
  if not valid then return result(false, nil, normalized) end
  store.projects[normalized.id] = normalized
  local saved, saveError = saveStore()
  if not saved then store.projects[normalized.id] = nil return result(false, nil, saveError) end
  audit(source, accountId, 'shellstudio_project_created', normalized.id, { name = normalized.name })
  return result(true, { project = normalized, projects = ownedProjects(accountId) })
end, true))

lib.callback.register('mz_shellstudio:server:save', callback(function(source, accountId, payload)
  if type(payload) ~= 'table' or not ownedProject(accountId, payload.id) then return result(false, nil, 'project_not_found') end
  payload.ownerAccountId = accountId
  payload.createdAt = store.projects[payload.id].createdAt
  payload.updatedAt = os.time()
  local dropped = {}
  if payload.plan ~= nil then
    local reconciled, value, removed = MZShellStudioProject.Reconcile(payload, { maxElements = Config.MaxElements })
    if not reconciled then return result(false, nil, value) end
    payload, dropped = value, removed or {}
  end
  local valid, normalized = MZShellStudioProject.Normalize(payload, { maxElements = Config.MaxElements })
  if not valid then return result(false, nil, normalized) end
  local previous = store.projects[normalized.id]
  store.projects[normalized.id] = normalized
  local saved, saveError = saveStore()
  if not saved then store.projects[normalized.id] = previous return result(false, nil, saveError) end
  audit(source, accountId, 'shellstudio_project_saved', normalized.id, {
    elements = #normalized.elements,
    cells = MZShellStudioProject.PlanCellCount(normalized),
    droppedOpenings = #dropped
  })
  return result(true, { project = normalized, projects = ownedProjects(accountId) })
end, true))

lib.callback.register('mz_shellstudio:server:prepareExport', callback(function(source, accountId, projectId)
  local project = ownedProject(accountId, projectId)
  if not project then return result(false, nil, 'project_not_found') end
  local valid, normalized = MZShellStudioProject.Normalize(project, { maxElements = Config.MaxElements })
  if not valid then return result(false, nil, normalized) end
  if normalized.plan ~= nil then
    local reconciled, value = MZShellStudioProject.Reconcile(normalized, { maxElements = Config.MaxElements })
    if not reconciled then return result(false, nil, value) end
    normalized = value
  end
  exportSequence = (exportSequence + 1) % 10000
  local file = ('data/exports/%s_%d_%04d.json'):format(normalized.id, os.time(), exportSequence)
  local encoded = json.encode(normalized)
  if not encoded then return result(false, nil, 'export_encode_failed') end
  local saved, written = pcall(SaveResourceFile, RESOURCE, file, encoded, -1)
  if not saved or not written then return result(false, nil, 'export_write_failed') end
  audit(source, accountId, 'shellstudio_project_export_prepared', normalized.id, { file = file })
  local command = ('powershell -NoProfile -ExecutionPolicy Bypass -File tools/mz_shellstudio_exporter/export-project.ps1 -ProjectFile "%s"'):format(file)
  return result(true, { file = file, command = command, projectId = normalized.id })
end, true))

lib.callback.register('mz_shellstudio:server:rename', callback(function(source, accountId, projectId, name)
  local current = ownedProject(accountId, projectId)
  if not current then return result(false, nil, 'project_not_found') end
  local candidate = {}
  for key, value in pairs(current) do candidate[key] = value end
  candidate.name = name
  candidate.updatedAt = os.time()
  local valid, normalized = MZShellStudioProject.Normalize(candidate, { maxElements = Config.MaxElements })
  if not valid then return result(false, nil, normalized) end
  store.projects[projectId] = normalized
  local saved, saveError = saveStore()
  if not saved then store.projects[projectId] = current return result(false, nil, saveError) end
  audit(source, accountId, 'shellstudio_project_renamed', projectId, { name = normalized.name })
  return result(true, { project = normalized, projects = ownedProjects(accountId) })
end, true))

lib.callback.register('mz_shellstudio:server:delete', callback(function(source, accountId, projectId)
  local current = ownedProject(accountId, projectId)
  if not current then return result(false, nil, 'project_not_found') end
  store.projects[projectId] = nil
  local saved, saveError = saveStore()
  if not saved then store.projects[projectId] = current return result(false, nil, saveError) end
  audit(source, accountId, 'shellstudio_project_deleted', projectId, { name = current.name })
  return result(true, { projects = ownedProjects(accountId) })
end, true))

AddEventHandler('playerDropped', function() mutationAt[source] = nil end)

loadStore()
