import { useEffect, useMemo, useRef, useState } from "react"
import {
  Box, DoorOpen, Grid2X2, House, MousePointer2, Redo2, RotateCw, Save,
  Square, Trash2, Undo2, PanelsTopLeft, X, AppWindow, ChevronLeft, ChevronRight,
  Paintbrush, Package, Copy,
} from "lucide-react"
import { Button } from "./components/ui/button"
import { Input } from "./components/ui/input"
import { isPreview, postNui } from "./lib/nui"

type Tool = "select" | "floor" | "wall" | "ceiling" | "door" | "window" | "delete" | "gridFloor" | "gridCeiling" | "gridErase" | "materials"
type Element = Record<string, unknown> & { id: string; type: Tool; generated?: boolean }
type Project = { id: string; name: string; gridSize: number; elements: Element[]; plan?: { cellSize: number; cells: unknown[] } }
type ProjectSummary = { id: string; name: string; elementCount: number }
type NuiResult = { ok: boolean; error?: string; data?: { file?: string; command?: string; projectId?: string } }
type MaterialId = "checker" | "concrete" | "plaster" | "wood" | "tile" | "brick" | "metal"

const materialCatalog: Array<{ id: MaterialId; label: string; swatch: string }> = [
  { id: "checker", label: "Checker", swatch: "repeating-conic-gradient(#d9bf59 0 25%, #3a3d3f 0 50%) 0 0 / 12px 12px" },
  { id: "concrete", label: "Concreto", swatch: "linear-gradient(135deg, #8e9293, #b7b9b7 55%, #7b7e7e)" },
  { id: "plaster", label: "Reboco", swatch: "linear-gradient(135deg, #f1ede4, #d8d2c6)" },
  { id: "wood", label: "Madeira", swatch: "repeating-linear-gradient(0deg, #7b4a28 0 6px, #98613a 6px 12px)" },
  { id: "tile", label: "Cerâmica", swatch: "repeating-linear-gradient(90deg, #c9ced0 0 2px, #e3e5e4 2px 18px), repeating-linear-gradient(0deg, #c9ced0 0 2px, #e3e5e4 2px 18px)" },
  { id: "brick", label: "Tijolo", swatch: "repeating-linear-gradient(0deg, #8b3d2c 0 8px, #a34a34 8px 16px)" },
  { id: "metal", label: "Metal", swatch: "linear-gradient(100deg, #7d8489, #c2c7c9 45%, #7a8085)" },
]

const nuiErrorMessages: Record<string, string> = {
  rate_limited: "Aguarde um instante",
  generated_readonly: "Elemento gerado pela planta",
  timeout: "Tempo esgotado ao preparar a exportação",
  server_error: "Erro no servidor ao preparar a exportação",
  no_response: "Sem resposta do jogo",
  export_write_failed: "Falha ao gravar o snapshot de exportação",
  export_encode_failed: "Falha ao serializar o projeto",
  project_not_found: "Projeto não encontrado",
  project_mismatch: "Projeto diferente do aberto no editor",
  no_project: "Nenhum projeto aberto",
  no_drag: "Nenhuma área selecionada",
  no_cell: "Célula inválida",
  no_surface: "Clique em uma superfície válida",
  invalid_surface: "Materiais se aplicam a piso, parede ou teto",
  invalid_material: "Material inválido",
}

const tools: Array<{ id: Tool; label: string; icon: typeof Box }> = [
  { id: "select", label: "Selecionar", icon: MousePointer2 },
  { id: "gridFloor", label: "Piso grade", icon: Grid2X2 },
  { id: "gridCeiling", label: "Teto grade", icon: Square },
  { id: "gridErase", label: "Apagar célula", icon: Trash2 },
  { id: "materials", label: "Materiais", icon: Paintbrush },
  { id: "floor", label: "Piso livre", icon: Grid2X2 },
  { id: "wall", label: "Parede", icon: PanelsTopLeft },
  { id: "ceiling", label: "Teto livre", icon: Square },
  { id: "door", label: "Porta", icon: DoorOpen },
  { id: "window", label: "Janela", icon: AppWindow },
  { id: "delete", label: "Apagar", icon: Trash2 },
]

const isGridTool = (tool: Tool) => tool === "gridFloor" || tool === "gridCeiling" || tool === "gridErase"

const previewProject: Project = {
  id: "mzss_p_preview", name: "Estudio 4x4", gridSize: 0.5,
  elements: [
    { id: "floor_001", type: "floor", position: [-2, -2, 0], size: [4, 4], rotation: 0, thickness: .2 },
    { id: "wall_001", type: "wall", start: [-2, -2, 0], end: [2, -2, 0], height: 3, thickness: .12 },
    { id: "door_001", type: "door", wallId: "wall_001", offset: 2, width: 1, height: 2.1, sill: 0 },
  ],
}

export function App() {
  const [visible, setVisible] = useState(isPreview)
  const [projects, setProjects] = useState<ProjectSummary[]>(isPreview ? [{ id: previewProject.id, name: previewProject.name, elementCount: 3 }] : [])
  const [project, setProject] = useState<Project | null>(isPreview ? previewProject : null)
  const [selectedId, setSelectedId] = useState<string | null>(isPreview ? "wall_001" : null)
  const [tool, setTool] = useState<Tool>("select")
  const [dirty, setDirty] = useState(false)
  const [draft, setDraft] = useState(false)
  const [status, setStatus] = useState("Pronto")
  const [projectName, setProjectName] = useState("Novo shell")
  const [materialId, setMaterialId] = useState<MaterialId>("checker")
  const [exportInfo, setExportInfo] = useState<{ file?: string; command?: string; projectId?: string } | null>(null)
  const [copied, setCopied] = useState(false)
  const drag = useRef<{ x: number; y: number } | null>(null)
  const gridDrag = useRef<{ startX: number; startY: number; x: number; y: number } | null>(null)
  const suppressClick = useRef(false)
  const lastWorldMove = useRef(0)
  const lastGridMove = useRef(0)
  const selected = useMemo(() => project?.elements.find((element) => element.id === selectedId) ?? null, [project, selectedId])

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const message = event.data as { action?: string; payload?: Record<string, unknown> }
      const payload = message.payload ?? {}
      if (message.action === "visibility") setVisible(Boolean(payload.visible))
      if (message.action === "bootstrap") {
        setVisible(Boolean(payload.visible)); setProjects((payload.projects as ProjectSummary[]) ?? [])
        if (typeof payload.material === "string") setMaterialId(payload.material as MaterialId)
      }
      if (message.action === "project") {
        setProject((payload.project as Project | null) ?? null)
        if (payload.projects) setProjects(payload.projects as ProjectSummary[])
        if (typeof payload.dirty === "boolean") setDirty(payload.dirty)
        if (payload.clearSelection === true) setSelectedId(null)
        else if (typeof payload.selectedId === "string") setSelectedId(payload.selectedId)
      }
      if (message.action === "selection") {
        setSelectedId((payload.selectedId as string | null) ?? null)
        if (payload.project) setProject(payload.project as Project)
      }
      if (message.action === "draft") setDraft(Boolean(payload.active))
    }
    window.addEventListener("message", onMessage)
    return () => window.removeEventListener("message", onMessage)
  }, [])

  useEffect(() => {
    if (project) setProjectName(project.name)
  }, [project?.id])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") void postNui("cancel")
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") { event.preventDefault(); void run("save") }
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") { event.preventDefault(); void run(event.shiftKey ? "redo" : "undo") }
      if (event.key === "Delete" && selectedId && !selected?.generated) void run("deleteElement")
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [selectedId, selected])

  async function run(callback: string, payload: unknown = {}) {
    try {
      const response = await postNui<NuiResult>(callback, payload)
      if (!response.ok) {
        const message = nuiErrorMessages[response.error ?? ""] ?? response.error ?? "Operacao recusada"
        setStatus(message)
      } else setStatus(callback === "save" ? "Salvo" : callback === "prepareExport" ? "Snapshot preparado" : "Pronto")
      return response
    } catch {
      setStatus("Sem resposta do jogo")
      return { ok: false, error: "no_response" } as NuiResult
    }
  }

  function chooseTool(next: Tool) {
    setTool(next); setDraft(false); void run("tool", { tool: next })
  }

  function chooseMaterial(id: MaterialId) {
    setMaterialId(id)
    setCopied(false)
    void run("setMaterial", { material: id })
    if (selected && !selected.generated && (selected.type === "floor" || selected.type === "ceiling" || selected.type === "wall")) {
      void run("updateElement", { patch: { material: id } })
    }
  }

  async function prepareExport() {
    const response = await run("prepareExport", { projectId: project?.id })
    if (response.ok && response.data) setExportInfo(response.data)
  }

  async function copyCommand() {
    if (!exportInfo?.command) return
    try {
      await navigator.clipboard.writeText(exportInfo.command)
      setCopied(true)
    } catch { setCopied(false) }
  }

  function worldClick(event: React.MouseEvent<HTMLElement>) {
    if (suppressClick.current) { suppressClick.current = false; return }
    if (drag.current || isGridTool(tool)) return
    void run("worldClick", { x: event.clientX, y: event.clientY, width: window.innerWidth, height: window.innerHeight })
  }

  function gridBegin(event: React.MouseEvent<HTMLElement>) {
    if (event.button !== 0 || !isGridTool(tool)) return
    event.preventDefault()
    gridDrag.current = { startX: event.clientX, startY: event.clientY, x: event.clientX, y: event.clientY }
    suppressClick.current = true
    void run("gridBegin", { x: event.clientX, y: event.clientY, width: window.innerWidth, height: window.innerHeight })
  }

  function gridCommit(event: React.MouseEvent<HTMLElement>) {
    const current = gridDrag.current
    if (!current || !isGridTool(tool)) return
    gridDrag.current = null
    suppressClick.current = true
    void run("gridCommit", {
      startX: current.startX,
      startY: current.startY,
      x: event.clientX,
      y: event.clientY,
      width: window.innerWidth,
      height: window.innerHeight,
    })
  }

  if (!visible) return null

  return <main className="studio" data-testid="shellstudio-root">
    <header className="topbar panel">
      <div className="brand"><span className="brand-mark"><House /></span><div><strong>MZ SHELL STUDIO</strong><small>LEGACY · WAVE 2</small></div></div>
      <div className="project-switcher">
        <select aria-label="Projeto" value={project?.id ?? ""} onChange={(event) => void run("load", { id: event.target.value })}>
          <option value="">Selecione um projeto</option>
          {projects.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.elementCount}</option>)}
        </select>
        <Input aria-label="Nome do novo projeto" value={projectName} maxLength={64} onChange={(event) => setProjectName(event.target.value)} />
        <Button variant="outline" size="sm" onClick={() => void run("create", { name: projectName })}>Novo</Button>
      </div>
      <div className="actions">
        <span className={dirty ? "save-state dirty" : "save-state"}>{dirty ? "Alteracoes locais" : status}</span>
        <Button variant="ghost" size="icon" aria-label="Desfazer" onClick={() => void run("undo")}><Undo2 /></Button>
        <Button variant="ghost" size="icon" aria-label="Refazer" onClick={() => void run("redo")}><Redo2 /></Button>
        <Button size="sm" disabled={!project} onClick={() => void run("save")}><Save /> Salvar</Button>
        <Button variant="outline" size="sm" disabled={!project} onClick={() => void prepareExport()}><Package /> Preparar exportação</Button>
        <Button variant="ghost" size="icon" aria-label="Sair" onClick={() => void run("close")}><X /></Button>
      </div>
    </header>

    <aside className="toolrail panel" aria-label="Ferramentas">
      <div className="panel-label">CONSTRUIR</div>
      {tools.map(({ id, label, icon: Icon }) => <button key={id} className={tool === id ? "tool active" : "tool"} onClick={() => chooseTool(id)}>
        <Icon /><span>{label}</span>
      </button>)}
      <div className="rail-spacer" />
      <div className="grid-note"><Grid2X2 /><span>SNAP<br /><strong>{project?.gridSize ?? .5} m</strong><br />CÉLULA {project?.plan?.cellSize ?? 2} m</span></div>
    </aside>

    <section className="viewport" data-testid="viewport"
      onClick={worldClick}
      onContextMenu={(event) => event.preventDefault()}
      onMouseDown={(event) => {
        if (event.button === 2) drag.current = { x: event.clientX, y: event.clientY }
        else if (event.button === 0) gridBegin(event)
      }}
      onMouseMove={(event) => {
        if (drag.current) {
          const dx = event.clientX - drag.current.x, dy = event.clientY - drag.current.y
          drag.current = { x: event.clientX, y: event.clientY }
          void run("camera", { dx, dy, pan: event.shiftKey })
          return
        }
        if (gridDrag.current && isGridTool(tool)) {
          const now = performance.now()
          if (now - lastGridMove.current < 40) return
          lastGridMove.current = now
          gridDrag.current.x = event.clientX
          gridDrag.current.y = event.clientY
          void run("gridMove", { x: event.clientX, y: event.clientY, width: window.innerWidth, height: window.innerHeight })
          return
        }
        const now = performance.now()
        if (now - lastWorldMove.current < 32) return
        lastWorldMove.current = now
        void run("worldMove", { x: event.clientX, y: event.clientY, width: window.innerWidth, height: window.innerHeight })
      }}
      onMouseUp={(event) => {
        if (gridDrag.current) {
          if (event.button === 0) gridCommit(event)
          else { gridDrag.current = null; suppressClick.current = false; void run("gridCancel") }
          return
        }
        window.setTimeout(() => { drag.current = null }, 0)
      }}
      onMouseLeave={() => {
        if (gridDrag.current) { gridDrag.current = null; void run("gridCancel") }
        suppressClick.current = false
        drag.current = null
      }}
      onWheel={(event) => { void run("camera", { zoom: event.deltaY }) }}>
      {!project && <div className="empty-state"><Box /><strong>Nenhum projeto aberto</strong><span>Crie ou selecione um projeto para começar.</span></div>}
      {draft && <div className="draft-hint">Defina o segundo ponto</div>}
      <div className="viewport-help"><span>CLIQUE</span> construir/selecionar <span>GRADE</span> arraste piso/teto <span>BOTÃO DIREITO</span> orbitar <span>SHIFT + ARRASTAR</span> mover <span>SCROLL</span> zoom</div>
    </section>

    <aside className="inspector panel">
      <div className="inspector-head"><div><span className="panel-label">INSPETOR</span><h2>{selected ? String(selected.id) : "Sem selecao"}</h2></div><Box /></div>
      {(tool === "materials" || selected) && <div className="material-palette">
        <div className="section-title">MATERIAIS · ATIVO: {materialCatalog.find((item) => item.id === materialId)?.label ?? materialId}</div>
        <div className="material-grid">
          {materialCatalog.map((item) => <button key={item.id} className={item.id === materialId ? "material-swatch active" : "material-swatch"}
            onClick={() => chooseMaterial(item.id)} title={item.label} aria-label={`Material ${item.label}`}>
            <span style={{ background: item.swatch }} />
            <small>{item.label}</small>
          </button>)}
        </div>
        {tool === "materials" && <p className="material-hint">Clique em um piso, parede ou teto para aplicar. Em estruturas da planta, a superfície de origem é atualizada e recompilada.</p>}
        {selected?.generated && <p className="material-hint">Este elemento é gerado pela planta. Use a ferramenta Materiais na superfície para alterar a superfície de origem.</p>}
      </div>}
      {selected ? <>
        <dl className="summary">
          <div><dt>TIPO</dt><dd>{selected.type}</dd></div><div><dt>GRID</dt><dd>{project?.gridSize} m</dd></div>
          <div><dt>POSICAO</dt><dd>{"position" in selected ? (selected.position as number[]).slice(0, 2).join(", ") : (selected.type === "wall" ? (selected.start as number[]).slice(0, 2).join(", ") : `parede · ${selected.offset ?? "—"}`)}</dd></div>
          <div><dt>ROTACAO</dt><dd>{selected.rotation !== undefined ? `${selected.rotation}°` : (selected.type === "wall" ? "ortogonal" : "herdada")}</dd></div>
          <div><dt>MATERIAL</dt><dd>{String(selected.material ?? "checker")}</dd></div>
          <div><dt>ORIGEM</dt><dd>{selected.generated ? "planta" : "manual"}</dd></div>
        </dl>
        {selected.generated ? <div className="generated-note">
          <strong>Elemento gerado pela planta.</strong>
          <span>Use as ferramentas de piso/teto/apagar célula para alterar. O inspetor não move nem apaga estruturas automáticas.</span>
        </div> : <>
          <div className="section-title">TRANSFORMAR</div>
          {selected.type !== "door" && selected.type !== "window" && <div className="nudge-grid">
            <Button variant="outline" size="icon" onClick={() => void run("nudge", { dx: 0, dy: project?.gridSize })}><ChevronLeft className="up" /></Button>
            <Button variant="outline" size="icon" onClick={() => void run("nudge", { dx: -project!.gridSize, dy: 0 })}><ChevronLeft /></Button>
            <Button variant="outline" size="icon" onClick={() => void run("nudge", { dx: project!.gridSize, dy: 0 })}><ChevronRight /></Button>
            <Button variant="outline" size="icon" onClick={() => void run("nudge", { dx: 0, dy: -project!.gridSize })}><ChevronRight className="down" /></Button>
          </div>}
          {selected.type !== "door" && selected.type !== "window" && <Button variant="outline" onClick={() => void run("rotate")}><RotateCw /> Girar 90°</Button>}
          {["height", "thickness", "offset", "width", "sill"].filter((key) => key in selected).map((key) => <label className="field" key={key}>
            <span>{key.toUpperCase()}</span><Input type="number" step="0.05" value={Number(selected[key])} onChange={(event) => {
              const value = Number(event.target.value); setProject((current) => current ? { ...current, elements: current.elements.map((item) => item.id === selected.id ? { ...item, [key]: value } : item) } : current)
              void run("updateElement", { patch: { [key]: value } })
            }} />
          </label>)}
          <div className="inspector-bottom"><Button variant="destructive" onClick={() => void run("deleteElement")}><Trash2 /> Excluir elemento</Button></div>
        </>}
      </> : <div className="selection-empty"><MousePointer2 /><p>Clique na geometria para editar propriedades.</p></div>}
      {project && <div className="project-danger"><span>{project.elements.length} elementos · {project.plan?.cells.length ?? 0} células</span><Button variant="ghost" size="sm" onClick={() => void run("rename", { name: projectName })}>Renomear</Button><Button variant="destructive" size="sm" onClick={() => void run("deleteProject")}>Excluir projeto</Button></div>}
    </aside>

    {exportInfo && <div className="export-modal" role="dialog" aria-modal="true" aria-label="Exportacao preparada">
      <div className="export-card panel">
        <div className="export-head"><div><span className="panel-label">EXPORTACAO</span><h2>Snapshot preparado</h2></div><Button variant="ghost" size="icon" aria-label="Fechar" onClick={() => setExportInfo(null)}><X /></Button></div>
        <p>O servidor gravou o projeto validado. Nenhum compilador foi executado no FXServer.</p>
        <label className="field"><span>SNAPSHOT</span><code>{exportInfo.file ?? "—"}</code></label>
        <label className="field"><span>COMANDO LOCAL</span><code>{exportInfo.command ?? "—"}</code></label>
        <div className="export-actions">
          <Button variant="outline" onClick={() => void copyCommand()}><Copy /> {copied ? "Copiado" : "Copiar comando"}</Button>
          <Button onClick={() => setExportInfo(null)}>Fechar</Button>
        </div>
        <p className="material-hint">Copie o snapshot para a máquina de build, execute o comando e instale a pasta gerada em um FXServer staging. Não altere o server.cfg de produção.</p>
      </div>
    </div>}
  </main>
}
