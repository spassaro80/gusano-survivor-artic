--!strict
--[[
	WorldSystem.lua — Sistema de servidor autoritativo del Mundo.

	Feature: juego-supervivencia-artico

	Ubicación: ServerScriptService/Systems (src/server/Systems). Este módulo es
	"pegamento de motor": orquesta la generación PURA del Mundo (WorldGenModel)
	y construye la representación física en `Workspace` (Instances). Toda la
	lógica de distribución y validación vive en WorldGenModel; aquí solo se
	generan/validan datos, se instancian objetos y se mantiene el estado
	autoritativo del Mundo en el servidor.

	Responsabilidades (Requisitos 5.1–5.6, 7.6, 7.7):
	  - generateAndBuild: genera un Mundo con WorldGenModel.generate(seed) y lo
	    valida con WorldGenModel.validate(world). Si falla, reintenta con semillas
	    distintas hasta un máximo de 3 intentos. Si sigue sin validar, devuelve
	    fallo para que GameServer impida iniciar la partida (Req. 5.6).
	  - buildWorld: construye en `Workspace` el terreno nevado (baseplate 500x500),
	    la banda perimetral infranqueable de montañas/colinas, los lagos helados y
	    los objetos de piedra y árbol en las colocaciones generadas. Los objetos se
	    etiquetan con atributos (kind="tree"/"stone", id, hits) para que
	    HarvestSystem los localice (Req. 5.1–5.5).
	  - Respawn de recursos: markFelled(id) marca un árbol/roca como talado/destruido
	    y programa su reaparición en la posición original tras
	    Constants.HARVEST.RESPAWN_S (60 s) (Req. 7.6, 7.7).

	Fidelidad visual: básica (Parts). Este sistema se ejecuta en Studio tras
	sincronizar con Rojo; aquí se prioriza la estructura correcta y el etiquetado.

	Requisitos cubiertos: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 7.6, 7.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local WorldGenModel = require(ReplicatedStorage.Shared.WorldGenModel)

type World = Types.World
type Region = Types.Region
type Placement = Types.Placement
type Weather = Types.Weather

-- Estado de un nodo cosechable (árbol o roca) mantenido de forma autoritativa
-- en el servidor. Guarda golpes recibidos, si está talado/destruido, su posición
-- original en el mundo y la Instance viva en Workspace (nil mientras está talado).
export type NodeKind = "tree" | "stone"
export type WorldNode = {
	id: string,
	kind: NodeKind,
	cellX: number,
	cellY: number,
	position: Vector3,
	hits: number,
	felled: boolean,
	felledAt: number?,
	instance: Instance?,
}

--============================================================================
-- Configuración de construcción (studs por bloque y estética mínima).
--============================================================================

-- Cada bloque lógico del mapa mide BLOCK_SIZE studs en el mundo físico. Es una
-- elección mínima razonable: el mapa lógico de 500x500 bloques se materializa en
-- un baseplate de 500*BLOCK_SIZE studs por lado, centrado en el origen.
local BLOCK_SIZE = 4

-- Constantes de distribución (fuente de verdad: Constants.WORLD).
local MAP_SIZE: number = Constants.WORLD.MAP_SIZE
local RESPAWN_S: number = Constants.HARVEST.RESPAWN_S
local HITS_TO_FELL: number = Constants.HARVEST.HITS_TO_FELL

-- Número máximo de intentos de generación+validación antes de rendirse (Req. 5.6).
local MAX_ATTEMPTS = 3

-- Colores mínimos para distinguir elementos en Studio.
local COLOR_SNOW = Color3.fromRGB(240, 244, 248)
local COLOR_MOUNTAIN = Color3.fromRGB(120, 128, 140)
local COLOR_ICE = Color3.fromRGB(150, 205, 235)
local COLOR_STONE = Color3.fromRGB(105, 105, 105)
local COLOR_TRUNK = Color3.fromRGB(96, 64, 32)
local COLOR_LEAVES = Color3.fromRGB(48, 120, 72)

--============================================================================
-- Estado autoritativo del Sistema (nivel de servidor, un Mundo por servidor).
--============================================================================

local WorldSystem = {}

-- container: carpeta raíz en Workspace que agrupa todo lo construido.
local container: Folder? = nil
-- nodes: mapa id -> WorldNode para los árboles y rocas cosechables.
local nodes: { [string]: WorldNode } = {}
-- currentWorld: última distribución validada y construida.
local currentWorld: World? = nil
-- waterHoles: agujeros de agua creados al romper hielo (FishingSystem), por id.
-- El WorldState los mantiene para que otros sistemas (pesca, botella) los lean
-- y muten de forma centralizada.
local waterHoles: { [string]: Vector3 } = {}
-- weather: estado de clima autoritativo compartido; WeatherSystem lo escribe y
-- otros sistemas (necesidades, HUD) lo consultan. nil hasta que se inicialice.
local weather: Weather? = nil

--============================================================================
-- Ayudantes de coordenadas y construcción de Instances.
--============================================================================

-- cellToWorld — Convierte una celda lógica (cellX, cellY) del mapa a una posición
-- en studs sobre la superficie del baseplate. El mapa se centra en el origen y el
-- eje Y (topY) indica la altura de la cara superior donde se apoyan los objetos.
local function cellToWorld(cellX: number, cellY: number, topY: number): Vector3
	local half = (MAP_SIZE * BLOCK_SIZE) / 2
	local x = cellX * BLOCK_SIZE - half + BLOCK_SIZE / 2
	local z = cellY * BLOCK_SIZE - half + BLOCK_SIZE / 2
	return Vector3.new(x, topY, z)
end

-- makePart — Crea un Part anclado con propiedades básicas comunes.
local function makePart(name: string, size: Vector3, position: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = true
	part.Size = size
	part.Position = position
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- buildBaseplate — Terreno nevado transitable de 500x500 bloques (Req. 5.1).
-- La cara superior queda en y=0; devuelve esa altura para apoyar el resto.
local function buildBaseplate(parent: Instance): number
	local side = MAP_SIZE * BLOCK_SIZE
	local thickness = 4
	local base = makePart("SnowBaseplate", Vector3.new(side, thickness, side), Vector3.new(0, -thickness / 2, 0), COLOR_SNOW)
	base.Material = Enum.Material.Snow
	base.Parent = parent
	return 0 -- altura de la cara superior del baseplate
end

-- buildPerimeter — Banda perimetral infranqueable de montañas/colinas (Req. 5.2).
-- Se materializa como cuatro muros altos que rodean el área interior transitable,
-- cada uno con un grosor de `perimeter` bloques.
local function buildPerimeter(parent: Instance, world: World, topY: number)
	local band = Instance.new("Folder")
	band.Name = "Perimeter"
	band.Parent = parent

	local side = world.size * BLOCK_SIZE
	local bandStuds = world.perimeter * BLOCK_SIZE
	local wallHeight = 60
	local half = side / 2
	local y = topY + wallHeight / 2

	-- Muros norte/sur (a lo largo del eje X) y este/oeste (a lo largo del eje Z).
	local northSouth = Vector3.new(side, wallHeight, bandStuds)
	local eastWest = Vector3.new(bandStuds, wallHeight, side)
	local offset = half - bandStuds / 2

	local walls = {
		{ name = "PerimeterNorth", size = northSouth, pos = Vector3.new(0, y, -offset) },
		{ name = "PerimeterSouth", size = northSouth, pos = Vector3.new(0, y, offset) },
		{ name = "PerimeterWest", size = eastWest, pos = Vector3.new(-offset, y, 0) },
		{ name = "PerimeterEast", size = eastWest, pos = Vector3.new(offset, y, 0) },
	}

	for _, w in walls do
		local wall = makePart(w.name, w.size, w.pos, COLOR_MOUNTAIN)
		wall.Material = Enum.Material.Rock
		wall.Parent = band
	end
end

-- buildLakes — Lagos helados de hielo azul transparente en zonas bajas (Req. 5.3).
-- Cada lago se representa con una losa fina y semitransparente ligeramente hundida.
local function buildLakes(parent: Instance, world: World, topY: number)
	local lakesFolder = Instance.new("Folder")
	lakesFolder.Name = "Lakes"
	lakesFolder.Parent = parent

	for i, lake in world.lakes do
		local wStuds = lake.width * BLOCK_SIZE
		local hStuds = lake.height * BLOCK_SIZE
		-- Centro de la región del lago en coordenadas de mundo.
		local half = (world.size * BLOCK_SIZE) / 2
		local cx = (lake.x + lake.width / 2) * BLOCK_SIZE - half
		local cz = (lake.y + lake.height / 2) * BLOCK_SIZE - half
		local slabThickness = 1
		local part = makePart(
			"FrozenLake_" .. i,
			Vector3.new(wStuds, slabThickness, hStuds),
			Vector3.new(cx, topY - slabThickness / 2, cz),
			COLOR_ICE
		)
		part.Material = Enum.Material.Ice
		part.Transparency = 0.35
		part.CanCollide = true
		part:SetAttribute("kind", "lake")
		part.Parent = lakesFolder
	end
end

-- buildStone — Instancia mínima de una Roca cosechable (Part etiquetado).
local function buildStone(position: Vector3): Instance
	local stone = makePart("Stone", Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE), position + Vector3.new(0, BLOCK_SIZE / 2, 0), COLOR_STONE)
	stone.Material = Enum.Material.Rock
	return stone
end

-- buildTree — Instancia mínima de un Árbol cosechable: Model con tronco y copa.
-- El Model es el nodo etiquetado; su PrimaryPart es el tronco.
local function buildTree(position: Vector3): Instance
	local model = Instance.new("Model")
	model.Name = "Tree"

	local trunkHeight = BLOCK_SIZE * 2
	local trunk = makePart(
		"Trunk",
		Vector3.new(BLOCK_SIZE * 0.4, trunkHeight, BLOCK_SIZE * 0.4),
		position + Vector3.new(0, trunkHeight / 2, 0),
		COLOR_TRUNK
	)
	trunk.Material = Enum.Material.Wood
	trunk.Parent = model

	local leaves = makePart(
		"Leaves",
		Vector3.new(BLOCK_SIZE * 1.6, BLOCK_SIZE * 1.6, BLOCK_SIZE * 1.6),
		position + Vector3.new(0, trunkHeight + BLOCK_SIZE * 0.6, 0),
		COLOR_LEAVES
	)
	leaves.Material = Enum.Material.Grass
	leaves.Parent = model

	model.PrimaryPart = trunk
	return model
end

-- instantiateNode — Crea la Instance física de un nodo según su tipo y la etiqueta
-- con los atributos que HarvestSystem usará para localizarlo e identificarlo.
local function instantiateNode(node: WorldNode, parent: Instance): Instance
	local instance: Instance
	if node.kind == "tree" then
		instance = buildTree(node.position)
	else
		instance = buildStone(node.position)
	end
	instance:SetAttribute("kind", node.kind)
	instance:SetAttribute("id", node.id)
	instance:SetAttribute("hits", node.hits)
	instance.Parent = parent
	return instance
end

--============================================================================
-- API pública
--============================================================================

--[[
	init — Prepara el Sistema del Mundo. Crea (o reinicia) la carpeta contenedora
	en `Workspace`, limpia cualquier estado previo y deja el sistema listo para
	`generateAndBuild`. `parent` es opcional (por defecto `workspace`).
]]
function WorldSystem.init(parent: Instance?): ()
	-- Limpia una construcción anterior si la hubiera (reinicio de servidor/partida).
	if container then
		container:Destroy()
	end
	nodes = {}
	currentWorld = nil
	waterHoles = {}
	weather = nil

	local host = parent or workspace
	local folder = Instance.new("Folder")
	folder.Name = "ArcticWorld"
	folder.Parent = host
	container = folder
end

--[[
	buildWorld — Construye en `Workspace` la representación física de un Mundo YA
	validado: baseplate nevado, banda perimetral, lagos helados y los objetos de
	piedra y árbol en sus colocaciones. Registra cada árbol/roca como WorldNode en
	el estado autoritativo. Requiere haber llamado antes a `init`.

	Devuelve el mapa de nodos creados (id -> WorldNode).
]]
function WorldSystem.buildWorld(world: World): { [string]: WorldNode }
	if not container then
		WorldSystem.init()
	end
	local host = container :: Folder

	-- Reconstruye desde cero: elimina cualquier contenido previo del contenedor.
	host:ClearAllChildren()
	nodes = {}

	local topY = buildBaseplate(host)
	buildPerimeter(host, world, topY)
	buildLakes(host, world, topY)

	local resourcesFolder = Instance.new("Folder")
	resourcesFolder.Name = "Resources"
	resourcesFolder.Parent = host

	-- Contadores por tipo para generar ids estables y legibles.
	local treeCount = 0
	local stoneCount = 0

	for _, placement: Placement in world.placements do
		local id: string
		if placement.kind == "tree" then
			treeCount += 1
			id = "tree_" .. treeCount
		else
			stoneCount += 1
			id = "stone_" .. stoneCount
		end

		local node: WorldNode = {
			id = id,
			kind = placement.kind,
			cellX = placement.x,
			cellY = placement.y,
			position = cellToWorld(placement.x, placement.y, topY),
			hits = 0,
			felled = false,
			felledAt = nil,
			instance = nil,
		}
		node.instance = instantiateNode(node, resourcesFolder)
		nodes[id] = node
	end

	currentWorld = world
	return nodes
end

--[[
	generateAndBuild — Genera y valida un Mundo con hasta 3 intentos y, si alguno
	valida, lo construye en `Workspace`. Cada intento usa una semilla distinta.

	Parámetros:
	  - seed: semilla base opcional. Si es nil, se deriva del reloj para variar
	    entre partidas. Los reintentos usan seed + índice_intento.

	Devuelve:
	  - ok=true, world  cuando un intento valida y se construye el Mundo.
	  - ok=false, nil, reason  si tras 3 intentos ninguna distribución valida
	    (Req. 5.6). En ese caso NO se construye nada y el llamador (GameServer)
	    debe impedir el inicio de la partida y mostrar el error de generación.
]]
function WorldSystem.generateAndBuild(seed: number?): (boolean, World?, string?)
	local baseSeed = seed or (math.floor(os.clock() * 1e6) + os.time())
	local lastReason: string? = "generación no intentada"

	for attempt = 0, MAX_ATTEMPTS - 1 do
		local attemptSeed = baseSeed + attempt
		local world = WorldGenModel.generate(attemptSeed)
		local ok, reason = WorldGenModel.validate(world)
		if ok then
			WorldSystem.buildWorld(world)
			return true, world, nil
		end
		lastReason = reason
	end

	-- Tras 3 intentos ninguna distribución cumple las restricciones (Req. 5.6).
	return false, nil, lastReason
end

--[[
	getNode — Devuelve el WorldNode con el id dado, o nil si no existe.
]]
function WorldSystem.getNode(id: string): WorldNode?
	return nodes[id]
end

--[[
	getAllNodes — Devuelve el mapa completo de nodos (id -> WorldNode).
]]
function WorldSystem.getAllNodes(): { [string]: WorldNode }
	return nodes
end

--[[
	getWorld — Devuelve la última distribución validada y construida, o nil.
]]
function WorldSystem.getWorld(): World?
	return currentWorld
end

--============================================================================
-- Agujeros de agua (WorldState compartido: lo muta FishingSystem al romper hielo)
--============================================================================

--[[
	addWaterHole — Registra un Agujero_Agua en el estado del Mundo con un `id`
	estable y su posición en el mundo. Sobrescribe cualquier agujero previo con el
	mismo id. Devuelve el id registrado (útil para el llamador).
]]
function WorldSystem.addWaterHole(id: string, position: Vector3): string
	waterHoles[id] = position
	return id
end

--[[
	getWaterHole — Devuelve la posición del Agujero_Agua con el id dado, o nil.
]]
function WorldSystem.getWaterHole(id: string): Vector3?
	return waterHoles[id]
end

--[[
	removeWaterHole — Elimina el Agujero_Agua con el id dado del estado del Mundo.
	Devuelve true si existía y se eliminó.
]]
function WorldSystem.removeWaterHole(id: string): boolean
	if waterHoles[id] == nil then
		return false
	end
	waterHoles[id] = nil
	return true
end

--[[
	getWaterHoles — Devuelve el mapa completo de Agujeros_Agua (id -> Vector3).
]]
function WorldSystem.getWaterHoles(): { [string]: Vector3 }
	return waterHoles
end

--============================================================================
-- Clima compartido (WorldState: lo escribe WeatherSystem, lo leen otros sistemas)
--============================================================================

--[[
	setWeather — Almacena el estado de clima autoritativo compartido para que
	otros sistemas lo consulten (NeedsSystem para el doble consumo de Calor, HUD
	para la niebla/sonido). WeatherSystem es su propietario y lo actualiza.
]]
function WorldSystem.setWeather(newWeather: Weather): ()
	weather = newWeather
end

--[[
	getWeather — Devuelve el estado de clima compartido, o nil si aún no se ha
	inicializado.
]]
function WorldSystem.getWeather(): Weather?
	return weather
end

--[[
	respawnNode — Restaura un nodo talado/destruido en su ubicación original:
	reinstancia la Instance, reinicia golpes y desmarca el estado talado.
	Uso interno de `scheduleRespawn`, pero expuesto por si el llamador desea
	forzar una reaparición inmediata.
]]
function WorldSystem.respawnNode(id: string): boolean
	local node = nodes[id]
	if not node or not node.felled then
		return false
	end
	if not container then
		return false
	end

	local resources = (container :: Folder):FindFirstChild("Resources")
	local parent: Instance = resources or (container :: Folder)

	node.hits = 0
	node.felled = false
	node.felledAt = nil
	node.instance = instantiateNode(node, parent)
	return true
end

--[[
	scheduleRespawn — Programa la reaparición del nodo `id` tras `delaySeconds`
	(por defecto Constants.HARVEST.RESPAWN_S = 60 s) en su ubicación original
	(Req. 7.6, 7.7). Solo reaparece si el nodo sigue talado en ese momento.
]]
function WorldSystem.scheduleRespawn(id: string, delaySeconds: number?): ()
	local delay = delaySeconds or RESPAWN_S
	task.delay(delay, function()
		local node = nodes[id]
		if node and node.felled then
			WorldSystem.respawnNode(id)
		end
	end)
end

--[[
	markFelled — Marca un árbol como talado o una roca como destruida: elimina su
	Instance del mundo, registra el instante y programa su reaparición a los 60 s
	(Req. 7.6, 7.7). Devuelve true si el nodo existía y estaba en pie.
]]
function WorldSystem.markFelled(id: string): boolean
	local node = nodes[id]
	if not node or node.felled then
		return false
	end

	node.felled = true
	node.felledAt = os.clock()
	if node.instance then
		(node.instance :: Instance):Destroy()
		node.instance = nil
	end

	WorldSystem.scheduleRespawn(id)
	return true
end

--[[
	registerHit — Registra un golpe sobre el nodo `id` y, si alcanza el umbral de
	golpes para talar/desmoronar (Constants.HARVEST.HITS_TO_FELL = 5), lo marca
	como talado/destruido y programa su respawn. Mantiene sincronizado el atributo
	"hits" de la Instance para que otros sistemas puedan leerlo.

	Devuelve (hits, felled): golpes acumulados tras el registro y si quedó talado.
	Nota: la validación de herramienta correcta (Hacha/Pico) es responsabilidad de
	HarvestSystem (Req. 7.8); aquí solo se lleva la contabilidad del estado.
]]
function WorldSystem.registerHit(id: string): (number, boolean)
	local node = nodes[id]
	if not node or node.felled then
		return 0, false
	end

	node.hits += 1
	if node.instance then
		(node.instance :: Instance):SetAttribute("hits", node.hits)
	end

	if node.hits >= HITS_TO_FELL then
		WorldSystem.markFelled(id)
		return node.hits, true
	end

	return node.hits, false
end

return WorldSystem
