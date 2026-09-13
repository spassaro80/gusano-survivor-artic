--!strict
--[[
	HarvestSystem.lua — Sistema de servidor AUTORITATIVO de talado y minería.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es "pegamento de motor": traduce las
	intenciones del cliente (RemoteEvents), consulta el estado de los nodos del
	Mundo, resuelve la física de troncos/fragmentos en `Workspace` y otorga los
	recursos resultantes. Toda decisión de resultado ocurre en el SERVIDOR.

	Responsabilidades (Requisitos 7.1, 7.2, 7.3, 7.4, 7.5, 7.8, 7.9):
	  - 7.1: Golpear un Arbol con el Hacha 5 veces desancla el Tronco y lo hace
	         caer al suelo por gravedad. El conteo de golpes se DELEGA en
	         `WorldSystem.registerHit`; al alcanzar el umbral (5) se marca el nodo
	         como talado y este sistema suelta un Tronco físico no anclado.
	  - 7.2: Mientras un Tronco está en el suelo y el Jugador está a <= 2 m, hay
	         una acción "Cortar Leña". La visibilidad de la acción se replica por
	         StateUpdate; la validación de distancia (2 m) es autoritativa aquí.
	  - 7.3: Ejecutar "Cortar Leña" sobre un Tronco rompe el Tronco y produce
	         EXACTAMENTE 3 de Madera (Constants.HARVEST.WOOD_PER_LOG).
	  - 7.4: Golpear una Roca con el Pico 5 veces la desmorona en 3 fragmentos
	         físicos en el suelo.
	  - 7.5: Minar un fragmento de Roca otorga 1 de Piedra por fragmento
	         (Constants.HARVEST.STONE_PER_FRAGMENT).
	  - 7.8: Usar la herramienta INCORRECTA (no Hacha sobre Arbol / no Pico sobre
	         Roca) NO incrementa el contador de golpes y deja el objeto intacto.
	  - 7.9: Si el Inventario está lleno cuando se debería otorgar Madera/Piedra,
	         el recurso se deja como objeto físico en el suelo y se envía la señal
	         "inventario lleno" por StateUpdate.

	Reutilización de estado de nodos (decisión de diseño):
	  El estado de árboles/rocas (golpes, talado) es propiedad de WorldSystem. Este
	  sistema lo REUTILIZA vía `require(script.Parent.WorldSystem)` y delega el
	  conteo de golpes en `WorldSystem.registerHit(id) -> (hits, felled)` y el
	  respawn en `WorldSystem.markFelled(id)` (que WorldSystem ya invoca al llegar
	  al umbral). HarvestSystem solo añade la validación de herramienta (7.8), la
	  física de Tronco/fragmentos (7.1, 7.4) y el otorgamiento de recursos (7.3,
	  7.5, 7.9). Para pruebas, `deps.world` permite inyectar un doble de WorldSystem.

	Dependencia inyectable de inventario (decisión de diseño):
	  El Inventario es propiedad de GameServer/PlayerState (aún no construido). Para
	  no acoplar HarvestSystem a un módulo inexistente, el otorgamiento de recursos
	  se inyecta con `deps.grantResource(player, kind, amount) -> ok:boolean`:
	    - ok = true  -> el recurso entró en el Inventario (se representa recogido).
	    - ok = false -> Inventario lleno: el recurso se deja como objeto físico en
	                    el suelo y se envía la señal "inventario lleno" (Req. 7.9).
	  La herramienta equipada se consulta con `deps.getEquippedTool(player) -> string?`
	  y la posición del Jugador con `deps.getPlayerPosition(player) -> Vector3?`.

	  SUPUESTOS de los valores por defecto (documentados):
	    - `grantResource` por defecto devuelve `true` (Inventario con espacio). Es
	      el camino normal hasta que GameServer inyecte el Inventario real. El caso
	      de Inventario lleno (7.9) se ejercita inyectando un `grantResource` que
	      devuelva `false`.
	    - `getEquippedTool`/`getPlayerPosition` por defecto leen el Character del
	      Jugador (Tool equipada y HumanoidRootPart), como el resto de sistemas.
	    - La distancia de "Cortar Leña" (Req. 7.2) usa `Constants.INTERACTION.CHOP_WOOD_M`
	      (2) y se compara en las MISMAS unidades que las posiciones inyectadas
	      (studs del Workspace). Es configurable con `deps.chopRadius`.

	Interpretación de 7.3/7.9 (documentada): "Cortar Leña" produce 3 de Madera y
	minar un fragmento produce 1 de Piedra. El sistema intenta otorgarlos al
	Inventario con `grantResource`; solo si el Inventario está lleno se materializan
	como objetos físicos en el suelo (Req. 7.9). Así se satisface la cantidad exacta
	(3 Madera / 1 Piedra) y la ruta de "inventario lleno".

	Requisitos cubiertos: 7.1, 7.2, 7.3, 7.4, 7.5, 7.8, 7.9
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Remotes)
local Constants = require(ReplicatedStorage.Shared.Constants)
-- Estado de nodos del Mundo (golpes/talado/respawn). Propiedad de WorldSystem.
local WorldSystem = require(script.Parent.WorldSystem)

--=============================================================================
-- Constantes de balance (fuente de verdad: Constants)
--=============================================================================

local HITS_TO_FELL: number = Constants.HARVEST.HITS_TO_FELL -- 5 (Req. 7.1, 7.4)
local WOOD_PER_LOG: number = Constants.HARVEST.WOOD_PER_LOG -- 3 (Req. 7.3)
local STONE_PER_FRAGMENT: number = Constants.HARVEST.STONE_PER_FRAGMENT -- 1 (Req. 7.5)
local CHOP_WOOD_M: number = Constants.INTERACTION.CHOP_WOOD_M -- 2 (Req. 7.2)

-- Al desmoronarse una Roca se generan este número de fragmentos físicos (Req. 7.4).
local FRAGMENTS_PER_ROCK: number = 3

-- Herramientas correctas por tipo de nodo (Req. 7.8).
local TOOL_FOR_KIND: { [string]: string } = {
	tree = "Hacha",
	stone = "Pico",
}

--=============================================================================
-- Tipos
--=============================================================================

export type ResourceKind = "Wood" | "Stone" | string

-- Subconjunto de la API de WorldSystem que HarvestSystem necesita. Se inyecta
-- (o usa WorldSystem por defecto) para bajo acoplamiento y testeo aislado.
export type WorldNodeLike = {
	id: string,
	kind: string,
	position: Vector3,
	hits: number,
	felled: boolean,
}

export type WorldAccess = {
	getNode: (id: string) -> WorldNodeLike?,
	getAllNodes: () -> { [string]: WorldNodeLike },
	registerHit: (id: string) -> (number, boolean),
}

-- Dependencias inyectables con valores por defecto razonables.
export type Deps = {
	-- Acceso al estado de nodos del Mundo. Por defecto: WorldSystem.
	world: WorldAccess?,
	-- Otorga `amount` de `kind` al Inventario del Jugador. Devuelve ok:boolean.
	-- ok=false => Inventario lleno (se deja el recurso en el suelo, Req. 7.9).
	grantResource: ((player: Player, kind: ResourceKind, amount: number) -> boolean)?,
	-- Herramienta equipada por el Jugador ("Hacha", "Pico", ...).
	getEquippedTool: ((player: Player) -> string?)?,
	-- Posición del Jugador (para validar distancia y depositar recursos).
	getPlayerPosition: ((player: Player) -> Vector3?)?,
	-- Radio (mismas unidades que las posiciones) para "Cortar Leña" (Req. 7.2).
	chopRadius: number?,
	-- Radio para considerar que un golpe/minado cae sobre un objeto por posición.
	targetRadius: number?,
}

-- Tronco físico soltado tras talar un Arbol (Req. 7.1). Vive hasta "Cortar Leña".
export type Trunk = {
	id: string,
	position: Vector3,
	instance: Instance?,
	nodeId: string?, -- nodo de origen (trazabilidad)
}

-- Fragmento físico de Roca tras desmoronarla (Req. 7.4). Vive hasta minarlo.
export type Fragment = {
	id: string,
	position: Vector3,
	instance: Instance?,
	nodeId: string?,
}

-- Resultados de las acciones (útiles para pruebas unitarias, Req. 7.8, 7.9).
export type HitResult = {
	ok: boolean,
	reason: string?, -- "badTarget" | "unknownNode" | "wrongTool" | "alreadyFelled"
	hits: number?,
	felled: boolean?,
	kind: string?,
}

export type ChopResult = {
	ok: boolean,
	reason: string?, -- "badTarget" | "unknownTrunk" | "tooFar" | "noPosition"
	woodReleased: number?,
	granted: boolean?, -- false => se dejó en el suelo (Req. 7.9)
}

export type MineResult = {
	ok: boolean,
	reason: string?, -- "badTarget" | "unknownFragment"
	stoneReleased: number?,
	granted: boolean?, -- false => se dejó en el suelo (Req. 7.9)
}

--=============================================================================
-- Estado del módulo
--=============================================================================

local HarvestSystem = {}

local deps: Deps = {}
local chopRadius: number = CHOP_WOOD_M
local targetRadius: number = 6

-- Troncos y fragmentos físicos rastreados por este sistema.
local trunks: { [string]: Trunk } = {}
local fragments: { [string]: Fragment } = {}
local nextTrunkId = 1
local nextFragmentId = 1

--=============================================================================
-- Dependencias por defecto (motor de Roblox)
--=============================================================================

local function defaultWorld(): WorldAccess
	return {
		getNode = function(id: string): WorldNodeLike?
			return (WorldSystem.getNode(id) :: any) :: WorldNodeLike?
		end,
		getAllNodes = function(): { [string]: WorldNodeLike }
			return (WorldSystem.getAllNodes() :: any) :: { [string]: WorldNodeLike }
		end,
		registerHit = function(id: string): (number, boolean)
			return WorldSystem.registerHit(id)
		end,
	}
end

-- Por defecto se asume Inventario con espacio (camino normal). GameServer debe
-- inyectar el `grantResource` real que consulte el Inventario del PlayerState.
local function defaultGrantResource(_player: Player, _kind: ResourceKind, _amount: number): boolean
	return true
end

local function defaultGetEquippedTool(player: Player): string?
	local character = player.Character
	if not character then
		return nil
	end
	local tool = character:FindFirstChildOfClass("Tool")
	return tool and tool.Name or nil
end

local function defaultGetPlayerPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

--=============================================================================
-- Construcción de objetos físicos (Tronco, fragmento, recurso suelto)
--=============================================================================

-- makePart — Part con propiedades comunes (anclaje configurable).
local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, anchored: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = anchored
	part.CanCollide = true
	part.Size = size
	part.Position = position
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- spawnTrunkInstance — Tronco NO anclado que cae por gravedad (Req. 7.1). Tumbado
-- horizontalmente para sugerir un tronco caído.
local function spawnTrunkInstance(id: string, position: Vector3): Instance
	local trunk = makePart("Tronco", Vector3.new(1.6, 1.6, 6), position + Vector3.new(0, 3, 0), Color3.fromRGB(96, 64, 32), false)
	trunk.Material = Enum.Material.Wood
	trunk.CFrame = CFrame.new(trunk.Position) * CFrame.Angles(0, 0, math.rad(90))
	trunk:SetAttribute("Trunk", true)
	trunk:SetAttribute("TrunkId", id)
	trunk.Parent = Workspace
	return trunk
end

-- spawnFragmentInstance — Fragmento físico de Roca en el suelo (Req. 7.4).
local function spawnFragmentInstance(id: string, position: Vector3): Instance
	local frag = makePart("Fragmento_Roca", Vector3.new(1.6, 1.6, 1.6), position, Color3.fromRGB(105, 105, 105), false)
	frag.Material = Enum.Material.Rock
	frag:SetAttribute("Fragment", true)
	frag:SetAttribute("FragmentId", id)
	frag.Parent = Workspace
	return frag
end

-- spawnResourceDrop — Materializa un recurso (Madera/Piedra) como objeto físico
-- en el suelo cuando el Inventario está lleno (Req. 7.9).
local function spawnResourceDrop(kind: ResourceKind, position: Vector3): Instance
	local color = kind == "Wood" and Color3.fromRGB(120, 82, 45) or Color3.fromRGB(130, 130, 130)
	local drop = makePart(tostring(kind), Vector3.new(1, 1, 1), position, color, false)
	drop.Material = kind == "Wood" and Enum.Material.Wood or Enum.Material.Rock
	drop:SetAttribute("Resource", kind)
	drop.Parent = Workspace
	return drop
end

--=============================================================================
-- Retroalimentación al cliente (StateUpdate, canal S->C)
--=============================================================================

-- sendHarvestState — Replica el estado de recolección al Jugador. `phase`:
--   "hit"           -> golpe registrado (incluye hits/felled)
--   "felled"        -> nodo talado/desmoronado
--   "chopAvailable" -> acción "Cortar Leña" disponible (Req. 7.2)
--   "chopped"       -> Tronco cortado (Madera producida)
--   "mined"         -> fragmento minado (Piedra producida)
--   "inventoryFull" -> Inventario lleno; recurso dejado en el suelo (Req. 7.9)
--   "rejected"      -> intento rechazado (con motivo, p. ej. herramienta incorrecta)
local function sendHarvestState(player: Player, phase: string, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		kind = "harvest",
		phase = phase,
	}
	if extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	Remotes.StateUpdate:FireClient(player, payload)
end

--=============================================================================
-- Utilidades de resolución de objetivo y distancia
--=============================================================================

local function getWorld(): WorldAccess
	return deps.world or defaultWorld()
end

-- planarDistance — Distancia en el plano X,Z (tolerante a diferencias de altura).
local function planarDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- findNearestNodeId — Nodo (árbol/roca) más cercano a `target` dentro de
-- `targetRadius` en el plano X,Z, o nil. Usado cuando el payload trae posición.
local function findNearestNodeId(target: Vector3): string?
	local world = getWorld()
	local bestId: string? = nil
	local bestDist = targetRadius
	for id, node in world.getAllNodes() do
		if not node.felled then
			local dist = planarDistance(target, node.position)
			if dist <= bestDist then
				bestDist = dist
				bestId = id
			end
		end
	end
	return bestId
end

-- findNearest — Ayudante genérico: id del objeto más cercano en `collection`.
local function findNearest(collection: { [string]: { position: Vector3 } }, target: Vector3): string?
	local bestId: string? = nil
	local bestDist = targetRadius
	for id, obj in collection do
		local dist = planarDistance(target, obj.position)
		if dist <= bestDist then
			bestDist = dist
			bestId = id
		end
	end
	return bestId
end

-- resolveNodeId — Extrae el id de nodo del payload: `nodeId` explícito, atributo
-- "id" de una Instance objetivo, o nodo más cercano a una posición.
local function resolveNodeId(payload: { [string]: any }): string?
	if type(payload.nodeId) == "string" then
		return payload.nodeId :: string
	end
	local target = payload.target
	if typeof(target) == "Instance" then
		local id = (target :: Instance):GetAttribute("id")
		if type(id) == "string" then
			return id :: string
		end
	elseif typeof(target) == "Vector3" then
		return findNearestNodeId(target :: Vector3)
	end
	return nil
end

-- resolveTrunkId — Id de Tronco desde `trunkId`, atributo "TrunkId" o posición.
local function resolveTrunkId(payload: { [string]: any }): string?
	if type(payload.trunkId) == "string" then
		return payload.trunkId :: string
	end
	local target = payload.target
	if typeof(target) == "Instance" then
		local id = (target :: Instance):GetAttribute("TrunkId")
		if type(id) == "string" then
			return id :: string
		end
	elseif typeof(target) == "Vector3" then
		return findNearest(trunks :: any, target :: Vector3)
	end
	return nil
end

-- resolveFragmentId — Id de fragmento desde `fragmentId`, atributo o posición.
local function resolveFragmentId(payload: { [string]: any }): string?
	if type(payload.fragmentId) == "string" then
		return payload.fragmentId :: string
	end
	local target = payload.target
	if typeof(target) == "Instance" then
		local id = (target :: Instance):GetAttribute("FragmentId")
		if type(id) == "string" then
			return id :: string
		end
	elseif typeof(target) == "Vector3" then
		return findNearest(fragments :: any, target :: Vector3)
	end
	return nil
end

--=============================================================================
-- Efectos de talado/desmoronamiento
--=============================================================================

-- releaseTrunk — Suelta un Tronco físico no anclado en la posición del Arbol
-- talado (Req. 7.1) y lo rastrea para la acción "Cortar Leña".
local function releaseTrunk(nodeId: string, position: Vector3): Trunk
	local id = "trunk_" .. tostring(nextTrunkId)
	nextTrunkId += 1
	local trunk: Trunk = {
		id = id,
		position = position,
		instance = spawnTrunkInstance(id, position),
		nodeId = nodeId,
	}
	trunks[id] = trunk
	return trunk
end

-- crumbleRock — Desmorona una Roca en FRAGMENTS_PER_ROCK fragmentos físicos
-- (Req. 7.4) alrededor de la posición del nodo, y los rastrea para minarlos.
local function crumbleRock(nodeId: string, position: Vector3): { Fragment }
	local created: { Fragment } = {}
	for i = 1, FRAGMENTS_PER_ROCK do
		local id = "frag_" .. tostring(nextFragmentId)
		nextFragmentId += 1
		-- Dispersa los fragmentos ligeramente para que no se solapen.
		local angle = (i / FRAGMENTS_PER_ROCK) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 2, 1, math.sin(angle) * 2)
		local fragment: Fragment = {
			id = id,
			position = position + offset,
			instance = spawnFragmentInstance(id, position + offset),
			nodeId = nodeId,
		}
		fragments[id] = fragment
		table.insert(created, fragment)
	end
	return created
end

--=============================================================================
-- Núcleo: golpear un nodo (Req. 7.1, 7.4, 7.8)
--=============================================================================

--[[
	tryHit — Procesa un golpe sobre un Arbol/Roca. Valida que la herramienta
	equipada sea la correcta (Hacha para árbol, Pico para roca): con la herramienta
	INCORRECTA NO se incrementa el contador de golpes y el objeto queda intacto
	(Req. 7.8). Con la herramienta correcta, DELEGA el conteo en
	`WorldSystem.registerHit`; al alcanzar los 5 golpes, WorldSystem marca el nodo
	como talado/destruido y este sistema suelta el Tronco (7.1) o desmorona la Roca
	en 3 fragmentos (7.4).
]]
function HarvestSystem.tryHit(player: Player, payload: { [string]: any }): HitResult
	local nodeId = resolveNodeId(payload)
	if nodeId == nil then
		return { ok = false, reason = "badTarget" }
	end

	local world = getWorld()
	local node = world.getNode(nodeId)
	if node == nil then
		return { ok = false, reason = "unknownNode" }
	end
	if node.felled then
		return { ok = false, reason = "alreadyFelled", kind = node.kind }
	end

	-- Validación de herramienta correcta (Req. 7.8): con la incorrecta NO se
	-- incrementa el contador ni se muta el objeto.
	local getTool = deps.getEquippedTool or defaultGetEquippedTool
	local equipped = getTool(player)
	local requiredTool = TOOL_FOR_KIND[node.kind]
	if equipped ~= requiredTool then
		return { ok = false, reason = "wrongTool", kind = node.kind }
	end

	-- Delegación del conteo de golpes a WorldSystem (fuente de verdad del estado).
	local hits, felled = world.registerHit(nodeId)

	if felled then
		if node.kind == "tree" then
			releaseTrunk(nodeId, node.position) -- Req. 7.1
		else
			crumbleRock(nodeId, node.position) -- Req. 7.4
		end
	end

	return { ok = true, hits = hits, felled = felled, kind = node.kind }
end

--=============================================================================
-- Núcleo: "Cortar Leña" sobre un Tronco (Req. 7.2, 7.3, 7.9)
--=============================================================================

--[[
	tryChop — Ejecuta "Cortar Leña" sobre un Tronco en el suelo. Valida que el
	Jugador esté a <= CHOP_WOOD_M (2 m) del Tronco (Req. 7.2), rompe el Tronco y
	produce EXACTAMENTE 3 de Madera (Req. 7.3). Intenta otorgarlas al Inventario;
	si está lleno, las deja como objeto físico en el suelo y señala "inventario
	lleno" (Req. 7.9).
]]
function HarvestSystem.tryChop(player: Player, payload: { [string]: any }): ChopResult
	local trunkId = resolveTrunkId(payload)
	if trunkId == nil then
		return { ok = false, reason = "badTarget" }
	end
	local trunk = trunks[trunkId]
	if trunk == nil then
		return { ok = false, reason = "unknownTrunk" }
	end

	-- Validación de distancia autoritativa (Req. 7.2).
	local getPos = deps.getPlayerPosition or defaultGetPlayerPosition
	local playerPos = getPos(player)
	if playerPos == nil then
		return { ok = false, reason = "noPosition" }
	end
	if planarDistance(playerPos, trunk.position) > chopRadius then
		return { ok = false, reason = "tooFar" }
	end

	-- Rompe el Tronco: retira su Instance y deja de rastrearlo.
	if trunk.instance then
		(trunk.instance :: Instance):Destroy()
	end
	trunks[trunkId] = nil

	-- Produce 3 de Madera (Req. 7.3) e intenta otorgarlas al Inventario.
	local grant = deps.grantResource or defaultGrantResource
	local granted = grant(player, "Wood", WOOD_PER_LOG)
	if not granted then
		-- Inventario lleno: deja la Madera en el suelo y señala (Req. 7.9).
		spawnResourceDrop("Wood", trunk.position)
		sendHarvestState(player, "inventoryFull", { resource = "Wood", amount = WOOD_PER_LOG })
	end

	sendHarvestState(player, "chopped", { woodReleased = WOOD_PER_LOG, granted = granted })
	return { ok = true, woodReleased = WOOD_PER_LOG, granted = granted }
end

--=============================================================================
-- Núcleo: minar un fragmento de Roca (Req. 7.5, 7.9)
--=============================================================================

--[[
	tryMine — Mina un fragmento de Roca en el suelo, otorgando 1 de Piedra por
	fragmento (Req. 7.5). Si el Inventario está lleno, deja la Piedra como objeto
	físico en el suelo y señala "inventario lleno" (Req. 7.9).
]]
function HarvestSystem.tryMine(player: Player, payload: { [string]: any }): MineResult
	local fragmentId = resolveFragmentId(payload)
	if fragmentId == nil then
		return { ok = false, reason = "badTarget" }
	end
	local fragment = fragments[fragmentId]
	if fragment == nil then
		return { ok = false, reason = "unknownFragment" }
	end

	-- Retira el fragmento físico del mundo y deja de rastrearlo.
	if fragment.instance then
		(fragment.instance :: Instance):Destroy()
	end
	fragments[fragmentId] = nil

	-- Otorga 1 de Piedra (Req. 7.5).
	local grant = deps.grantResource or defaultGrantResource
	local granted = grant(player, "Stone", STONE_PER_FRAGMENT)
	if not granted then
		-- Inventario lleno: deja la Piedra en el suelo y señala (Req. 7.9).
		spawnResourceDrop("Stone", fragment.position)
		sendHarvestState(player, "inventoryFull", { resource = "Stone", amount = STONE_PER_FRAGMENT })
	end

	sendHarvestState(player, "mined", { stoneReleased = STONE_PER_FRAGMENT, granted = granted })
	return { ok = true, stoneReleased = STONE_PER_FRAGMENT, granted = granted }
end

--=============================================================================
-- Consultas públicas (inspección / pruebas)
--=============================================================================

function HarvestSystem.getTrunks(): { [string]: Trunk }
	local copy: { [string]: Trunk } = {}
	for id, t in trunks do
		copy[id] = t
	end
	return copy
end

function HarvestSystem.getTrunk(id: string): Trunk?
	return trunks[id]
end

function HarvestSystem.getFragments(): { [string]: Fragment }
	local copy: { [string]: Fragment } = {}
	for id, f in fragments do
		copy[id] = f
	end
	return copy
end

function HarvestSystem.getFragment(id: string): Fragment?
	return fragments[id]
end

function HarvestSystem.getTrunkCount(): number
	local n = 0
	for _ in trunks do
		n += 1
	end
	return n
end

function HarvestSystem.getFragmentCount(): number
	local n = 0
	for _ in fragments do
		n += 1
	end
	return n
end

--=============================================================================
-- Enrutado del RemoteEvent HarvestAction (C->S)
--=============================================================================

--[[
	onHarvestAction — Handler de `Remotes.HarvestAction`. Admite un payload de
	tabla con `kind`:
	  { kind = "hit",  nodeId?/target }      -> golpear Arbol/Roca (7.1, 7.4, 7.8)
	  { kind = "chop", trunkId?/target }     -> "Cortar Leña" sobre Tronco (7.2, 7.3)
	  { kind = "mine", fragmentId?/target }  -> minar fragmento de Roca (7.5)
	Todo intento fallido se replica como "rejected" con su motivo por StateUpdate.
]]
local function onHarvestAction(player: Player, payload: any)
	if type(payload) ~= "table" then
		return
	end
	local p = payload :: { [string]: any }
	local action = p.kind

	if action == "hit" then
		local result = HarvestSystem.tryHit(player, p)
		if result.ok then
			local phase = result.felled and "felled" or "hit"
			sendHarvestState(player, phase, { hits = result.hits, felled = result.felled, kind = result.kind })
		else
			sendHarvestState(player, "rejected", { reason = result.reason, action = "hit" })
		end
	elseif action == "chop" then
		local result = HarvestSystem.tryChop(player, p)
		if not result.ok then
			sendHarvestState(player, "rejected", { reason = result.reason, action = "chop" })
		end
	elseif action == "mine" then
		local result = HarvestSystem.tryMine(player, p)
		if not result.ok then
			sendHarvestState(player, "rejected", { reason = result.reason, action = "mine" })
		end
	end
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

local harvestConnection: RBXScriptConnection? = nil

--[[
	init — Inicializa el sistema con sus dependencias y conecta el handler a
	`Remotes.HarvestAction`. IDEMPOTENTE: reconectar reemplaza las dependencias sin
	duplicar la conexión (se conserva una única conexión almacenada).
]]
function HarvestSystem.init(injected: Deps?)
	deps = injected or {}
	chopRadius = deps.chopRadius or CHOP_WOOD_M
	targetRadius = deps.targetRadius or 6

	if not harvestConnection then
		harvestConnection = Remotes.HarvestAction.OnServerEvent:Connect(function(player: Player, ...)
			local payload = (...)
			onHarvestAction(player, payload)
		end)
	end

	return HarvestSystem
end

--[[
	shutdown — Desconecta el handler y limpia el estado rastreado. Útil para
	pruebas o reinicios controlados. No destruye Instances físicas ya creadas.
]]
function HarvestSystem.shutdown()
	if harvestConnection then
		harvestConnection:Disconnect()
		harvestConnection = nil
	end
	trunks = {}
	fragments = {}
	nextTrunkId = 1
	nextFragmentId = 1
end

return HarvestSystem
