--!strict
--[[
	GameServer.lua — Orquestador AUTORITATIVO del ciclo de partida.

	Feature: juego-supervivencia-artico

	Vive en la RAÍZ de ServerScriptService (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es el HUB DE INTEGRACIÓN del servidor:
	POSEE el `PlayerState` (única fuente de verdad del estado del Jugador) y CABLEA
	entre sí todos los sistemas existentes (WorldSystem, NeedsSystem, WeatherSystem,
	FireSystem, HarvestSystem, DiggingSystem, FishingSystem, CoolerSystem,
	BottleSystem, BedSystem, RescueSystem, SaveSystem) inyectándoles las
	dependencias que leen/escriben ese `PlayerState`.

	Regla arquitectónica: SERVIDOR AUTORITATIVO. Cada sistema valida las intenciones
	del cliente antes de tocar el estado; este orquestador se limita a: (1) crear e
	inicializar el estado por Jugador, (2) inyectar las dependencias que conectan
	esos sistemas con el `PlayerState`, (3) conducir el bucle de simulación con un
	`dt` común y (4) replicar el estado confirmado al HUD por `Remotes.StateUpdate`.

	Responsabilidades (Requisitos 2.6, 2.8, 3.3, 3.4, 3.5, 4.1, 5.1):
	  - 5.1: Genera el Mundo UNA vez con `WorldSystem.generateAndBuild`. Si la
	         generación falla tras sus reintentos (Req. 5.6, ya resuelto por
	         WorldSystem), se impide iniciar la partida y se avisa al Jugador.
	  - 3.3/3.4: Al entrar, crea el kit inicial de EXACTAMENTE 7 herramientas con la
	         Botella al 100% (estado "Full").
	  - 3.5: Si el kit no puede crearse completo, NO se deja un estado jugable
	         parcial: se retiran las herramientas creadas, se marca al Jugador como
	         "no puede iniciar" y `StartSurvival` se rechaza con un aviso.
	  - 2.6: El consumo de necesidades permanece PAUSADO durante el tutorial: el
	         bucle solo aplica `NeedsSystem.step` a los Jugadores cuya partida está
	         ACTIVA (no se pisa el estado mientras el tutorial está abierto).
	  - 2.8: Al pulsar SOBREVIVIR / cerrar el tutorial (`StartSurvival`), la partida
	         pasa a ACTIVA y comienza el consumo de necesidades.
	  - 4.1: Las necesidades arrancan a 100 y se mantienen en [0, 100] (el clamp lo
	         garantiza NeedsModel; aquí solo se inicializan y se replican).

	Bucle de simulación (design.md, "Bucle de simulación"): un único
	`RunService.Heartbeat` aporta el `dt` a NeedsSystem, WeatherSystem, FireSystem,
	RescueSystem y SaveSystem. Ningún sistema arranca su propio Heartbeat.

	Arranque: este ModuleScript se auto-inicializa en el servidor al final del
	archivo (`GameServer.init()` es idempotente). Si en el futuro se prefiere un
	Script bootstrap dedicado, basta con requerir este módulo y llamar a `init()`;
	la idempotencia evita dobles inicializaciones.

	Requisitos cubiertos: 2.6, 2.8, 3.3, 3.4, 3.5, 4.1, 5.1
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Contrato de Remotes y lógica pura / balance compartidos.
local Remotes = require(ReplicatedStorage.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NeedsModel = require(ReplicatedStorage.Shared.NeedsModel)

-- Carpeta de sistemas (ServerScriptService.Systems). GameServer es su hermano en
-- la raíz de ServerScriptService, de modo que se accede vía `script.Parent.Systems`.
local SystemsFolder = script.Parent:WaitForChild("Systems")

local WorldSystem = require(SystemsFolder.WorldSystem)
local NeedsSystem = require(SystemsFolder.NeedsSystem)
local WeatherSystem = require(SystemsFolder.WeatherSystem)
local HarvestSystem = require(SystemsFolder.HarvestSystem)
local DiggingSystem = require(SystemsFolder.DiggingSystem)
local FishingSystem = require(SystemsFolder.FishingSystem)
local CoolerSystem = require(SystemsFolder.CoolerSystem)
local BottleSystem = require(SystemsFolder.BottleSystem)
local FireSystem = require(SystemsFolder.FireSystem)
local BedSystem = require(SystemsFolder.BedSystem)
local RescueSystem = require(SystemsFolder.RescueSystem)
local SaveSystem = require(SystemsFolder.SaveSystem)

type Needs = Types.Needs
type Env = Types.Env
type Bottle = Types.Bottle
type Inventory = Types.Inventory
type PlayerState = Types.PlayerState
type SaveData = Types.SaveData

--=============================================================================
-- Constantes locales de orquestación
--=============================================================================

-- Las EXACTAMENTE 7 herramientas del kit inicial (Req. 3.1, 3.3). El orden y los
-- nombres son parte del contrato: varios sistemas validan la herramienta equipada
-- por su nombre exacto (p. ej. DiggingSystem="Pala", HarvestSystem="Hacha"/"Pico",
-- FishingSystem="Pico"/"Caña de Pescar", BottleSystem="Botella de Agua").
local KIT_TOOLS: { string } = {
	"Pala",
	"Hacha",
	"Pico",
	"Caña de Pescar",
	"Neverita Portátil",
	"Cama",
	"Botella de Agua",
}

-- Máximo de las necesidades (arrancan a 100, Req. 4.1).
local NEEDS_MAX: number = Constants.NEEDS.MAX

-- Capacidad de recursos apilables del Inventario (madera + piedra combinadas).
-- El diseño define el campo `capacity` pero no un valor exacto; se adopta un tope
-- amplio y se documenta. Cuando el Inventario se llena, `grantResource` devuelve
-- false y el recurso se deja en el suelo (Req. 7.9, ya manejado por HarvestSystem).
local INVENTORY_CAPACITY: number = 100

-- Día inicial de una partida nueva (Req. 16.6: sin guardado -> Día 1).
local START_DAY: number = 1

-- Intervalo (s) de replicación del estado al HUD. Se replica de forma periódica
-- (no cada frame) para no saturar la red; también se replica ante cambios de fase
-- (inicio de partida, carga, muerte) de forma explícita.
local REPLICATION_INTERVAL_S: number = 0.25

--=============================================================================
-- Estado del módulo (autoritativo, nivel de servidor)
--=============================================================================

local GameServer = {}

-- PlayerState por Jugador, indexado por userId. ÚNICA fuente de verdad del estado
-- del Jugador en el servidor (Req. 3.3).
local playerStates: { [number]: PlayerState } = {}

-- ¿Está la partida del Jugador ACTIVA (tras el tutorial)? El consumo de
-- necesidades solo se aplica a los Jugadores activos (Req. 2.6, 2.8).
local activePlayers: { [number]: boolean } = {}

-- ¿Puede el Jugador iniciar la partida? Falso si su kit inicial no se creó completo
-- (Req. 3.5): en ese caso `StartSurvival` se rechaza y no se activa la partida.
local canStart: { [number]: boolean } = {}

-- Última posición conocida/restaurada del Jugador (para restaurar al cargar y para
-- persistir en el guardado). Se actualiza desde el personaje cuando existe.
local lastKnownPosition: { [number]: Vector3 } = {}

-- Control de arranque idempotente y del bucle.
local initialized = false
local worldOk = false
local worldReason: string? = nil
local heartbeatConn: RBXScriptConnection? = nil
local replicationAccumulator = 0

--=============================================================================
-- Utilidades de PlayerState
--=============================================================================

-- makeDefaultNeeds — Necesidades iniciales al máximo (Req. 4.1).
local function makeDefaultNeeds(): Needs
	return { warmth = NEEDS_MAX, hunger = NEEDS_MAX, thirst = NEEDS_MAX, health = NEEDS_MAX }
end

-- makeDefaultInventory — Inventario inicial: las 7 herramientas presentes y 0
-- recursos apilables (Req. 3.3). `capacity` acota madera + piedra combinadas.
local function makeDefaultInventory(): Inventory
	local tools: { [string]: boolean } = {}
	for _, name in KIT_TOOLS do
		tools[name] = true
	end
	return {
		tools = tools,
		wood = 0,
		stone = 0,
		capacity = INVENTORY_CAPACITY,
	}
end

-- makeDefaultState — PlayerState de una partida nueva desde el Día 1 (Req. 3.3,
-- 3.4, 4.1, 16.6): necesidades a 100, kit completo, Neverita vacía, Botella llena.
local function makeDefaultState(userId: number): PlayerState
	return {
		userId = userId,
		needs = makeDefaultNeeds(),
		inventory = makeDefaultInventory(),
		cooler = { count = 0 },
		bottle = { state = "Full" }, -- Botella al 100% (Req. 3.4)
		day = START_DAY,
		freeMode = false,
		respawnBedId = nil,
		lastSaveClock = 0,
	}
end

-- ensureState — Devuelve el PlayerState del Jugador, creándolo por defecto si aún
-- no existía. Nunca devuelve nil (así el resto del módulo puede asumir estado).
local function ensureState(player: Player): PlayerState
	local state = playerStates[player.UserId]
	if state == nil then
		state = makeDefaultState(player.UserId)
		playerStates[player.UserId] = state
	end
	return state
end

--=============================================================================
-- Accesores del personaje (posición, mira, herramienta equipada)
--=============================================================================

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- getPlayerPosition — Posición del Jugador; si no hay personaje, la última posición
-- conocida (útil justo tras cargar, antes de que el personaje aparezca).
local function getPlayerPosition(player: Player): Vector3?
	local root = getCharacterRoot(player)
	if root then
		lastKnownPosition[player.UserId] = root.Position
		return root.Position
	end
	return lastKnownPosition[player.UserId]
end

local function getPlayerLook(player: Player): Vector3?
	local root = getCharacterRoot(player)
	if root then
		return root.CFrame.LookVector
	end
	return nil
end

-- getEquippedTool — Nombre de la Tool equipada (hija del personaje), o nil.
local function getEquippedTool(player: Player): string?
	local character = player.Character
	if not character then
		return nil
	end
	local tool = character:FindFirstChildOfClass("Tool")
	return tool and tool.Name or nil
end

--=============================================================================
-- Callbacks de estado (PlayerState como ÚNICA fuente de verdad)
--=============================================================================

-- Necesidades (leídas/escritas por NeedsSystem, BottleSystem, FireSystem).
local function getPlayerNeeds(player: Player): Needs
	return ensureState(player).needs
end

local function setPlayerNeeds(player: Player, needs: Needs)
	ensureState(player).needs = needs
end

-- Botella (leída/escrita por BottleSystem).
local function getPlayerBottle(player: Player): Bottle
	return ensureState(player).bottle
end

local function setPlayerBottle(player: Player, bottle: Bottle)
	ensureState(player).bottle = bottle
end

-- Recursos apilables (Madera/Piedra) del Inventario (HarvestSystem, FireSystem).

-- grantResource — Intenta añadir `amount` de `kind` ("Wood"/"Stone") al Inventario.
-- Devuelve false si el Inventario está lleno (madera+piedra alcanzarían la
-- capacidad), en cuyo caso HarvestSystem deja el recurso en el suelo (Req. 7.9).
local function grantResource(player: Player, kind: string, amount: number): boolean
	local inv = ensureState(player).inventory
	if amount <= 0 then
		return true
	end
	if inv.wood + inv.stone + amount > inv.capacity then
		return false -- Inventario lleno (Req. 7.9).
	end
	if kind == "Wood" then
		inv.wood += amount
		return true
	elseif kind == "Stone" then
		inv.stone += amount
		return true
	end
	-- Tipo de recurso desconocido: no se otorga.
	return false
end

-- consumeWood/consumeStone — Descuentan `n` unidades si hay suficientes; devuelven
-- true si se descontaron (FireSystem las usa para troncos y hogueras).
local function consumeWood(player: Player, n: number): boolean
	local inv = ensureState(player).inventory
	if n <= 0 then
		return true
	end
	if inv.wood < n then
		return false
	end
	inv.wood -= n
	return true
end

local function consumeStone(player: Player, n: number): boolean
	local inv = ensureState(player).inventory
	if n <= 0 then
		return true
	end
	if inv.stone < n then
		return false
	end
	inv.stone -= n
	return true
end

-- Efectos de comer (FireSystem) resueltos vía el modelo puro NeedsModel.
local function applyEatCooked(player: Player)
	local state = ensureState(player)
	state.needs = NeedsModel.applyEat(state.needs, Constants.NEEDS.EAT_HUNGER_RESTORE) -- +40 Hambre (Req. 13.9)
end

local function applyEatBurned(player: Player)
	local state = ensureState(player)
	state.needs = NeedsModel.applyBurnedFish(state.needs, Constants.NEEDS.BURNED_FISH_HEALTH_PENALTY) -- -15 Salud (Req. 13.11)
end

-- grantWarmth — Suma `amount` de Calor, acotado a [0, 100] (Req. 12.5). Lo invoca
-- FireSystem con el incremento ya calculado del paso (EMERGENCY_WARMTH_PER_S * dt).
local function grantWarmth(player: Player, amount: number)
	local state = ensureState(player)
	local needs = state.needs
	local newWarmth = math.clamp(needs.warmth + amount, 0, NEEDS_MAX)
	state.needs = {
		warmth = newWarmth,
		hunger = needs.hunger,
		thirst = needs.thirst,
		health = needs.health,
	}
end

--=============================================================================
-- Días y Modo_Libre (poseídos por PlayerState; usados por RescueSystem)
--=============================================================================

local function getDay(player: Player): number
	return ensureState(player).day
end

local function setDay(player: Player, day: number)
	local state = ensureState(player)
	state.day = day
	-- Notifica a RescueSystem el día alcanzado; al llegar al Día 7 dispara la
	-- escena de rescate una sola vez (idempotente en RescueSystem).
	RescueSystem.onDayReached(day)
end

local function incrementDay(player: Player)
	setDay(player, ensureState(player).day + 1)
end

local function setFreeMode(player: Player, enabled: boolean)
	ensureState(player).freeMode = enabled
end

--=============================================================================
-- Composición del entorno (Env) para NeedsSystem (Req. 4.3, 6.6, 8.3)
--=============================================================================

--[[
	composeEnv — Construye el `Env` de un Jugador combinando el clima autoritativo
	(WeatherSystem) y si está resguardado en una Cueva (DiggingSystem.isProtected).
	`underSnow` y `nearFire` quedan por defecto en false (no hay aún detección de
	terreno bajo nieve ni de proximidad al fuego para el consumo de Calor; el calor
	de la hoguera lo aporta FireSystem sumando directamente a `warmth`). Se documenta
	este supuesto: cuando exista esa detección, basta con pasar un `baseEnv` con esos
	campos ya calculados a WeatherSystem.composeEnv.
]]
local function composeEnv(player: Player): Env
	local isProtected = DiggingSystem.isProtected(player)
	return WeatherSystem.composeEnv(player, isProtected, nil)
end

--=============================================================================
-- Muerte y reaparición (Req. 4.8, 14.4, 14.5)
--=============================================================================

--[[
	onDeath — Gancho que NeedsSystem invoca cuando la Salud llega a 0 (Req. 4.8).
	Delega la reaparición en BedSystem (junto a la Cama de respawn, Req. 14.4, o en
	el spawn por defecto, Req. 14.5) y REINICIA las necesidades a 100 para que el
	Jugador no muera de inmediato tras reaparecer. Rearma el disparador de muerte de
	NeedsSystem.
]]
local function onDeath(player: Player)
	BedSystem.handleDeath(player)
	local state = ensureState(player)
	state.needs = makeDefaultNeeds()
	NeedsSystem.resetDeath(player)
	GameServer.replicateState(player)
end

--=============================================================================
-- Agujeros de agua: distancia al más cercano (para BottleSystem, Req. 11.5/11.6)
--=============================================================================

local function planarDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- getNearestWaterHoleDistance — Distancia planar al Agujero_Agua más cercano del
-- Mundo, o nil si no hay ninguno o no se conoce la posición del Jugador. Los
-- Agujeros_Agua los registra FishingSystem en WorldSystem al romper hielo.
local function getNearestWaterHoleDistance(player: Player): number?
	local pos = getPlayerPosition(player)
	if pos == nil then
		return nil
	end
	local best: number? = nil
	for _, holePos in WorldSystem.getWaterHoles() do
		local dist = planarDistance(pos, holePos)
		if best == nil or dist < best then
			best = dist
		end
	end
	return best
end

--=============================================================================
-- Pesca -> Neverita: los Peces capturados van a la Neverita (Req. 10.1)
--=============================================================================

-- routeCaughtFish — Dependencia `depositFish` de FishingSystem. En lugar de dejar
-- el Pez en el suelo, se enruta EXCLUSIVAMENTE a la Neverita (Req. 10.1) vía
-- CoolerSystem.addFish. Si la Neverita está llena (Req. 10.4), addFish avisa al HUD
-- y devuelve false; en ese caso el Pez se materializa en el suelo para no perderlo.
local function routeCaughtFish(player: Player, position: Vector3): Instance?
	local ok = CoolerSystem.addFish(player)
	if ok then
		-- Sincroniza el contador espejo del PlayerState con la Neverita autoritativa.
		ensureState(player).cooler = { count = CoolerSystem.getCount(player) }
		return nil
	end
	-- Neverita llena: deja el Pez como objeto físico en el suelo (Req. 10.4).
	local fish = Instance.new("Part")
	fish.Name = "Pez"
	fish.Size = Vector3.new(1.5, 0.5, 0.6)
	fish.Position = position
	fish.BrickColor = BrickColor.new("Bright blue")
	fish.Material = Enum.Material.SmoothPlastic
	fish:SetAttribute("Resource", "Pez")
	fish.Parent = workspace
	return fish
end

--=============================================================================
-- Kit inicial de 7 herramientas (Req. 3.3, 3.4, 3.5)
--=============================================================================

-- makeToolInstance — Crea una Tool placeholder con nombre EXACTO y un Handle
-- válido. La fidelidad del modelo 3D queda fuera de alcance de esta tarea; lo
-- importante es que el nombre coincida con lo que validan los sistemas y que la
-- Tool sea equipable (RequiresHandle + Handle).
local function makeToolInstance(name: string): Tool
	local tool = Instance.new("Tool")
	tool.Name = name
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.CanCollide = false
	handle.Parent = tool

	-- La Botella arranca al 100% (Req. 3.4). Se refleja también como atributo de la
	-- Tool para fidelidad visual del HUD; la verdad del estado vive en PlayerState.
	if name == "Botella de Agua" then
		tool:SetAttribute("Fill", 100)
	end
	return tool
end

--[[
	buildInitialKit — Crea las 7 herramientas del kit inicial en el StarterGear (para
	que persistan entre reapariciones) y en la Backpack actual del Jugador (Req. 3.3,
	3.4). Devuelve true SOLO si las 7 se crearon completas; si algo falla, retira lo
	creado y devuelve false para no dejar un estado jugable parcial (Req. 3.5).
]]
local function buildInitialKit(player: Player): boolean
	local starterGear = player:FindFirstChildOfClass("StarterGear")
	local backpack = player:FindFirstChildOfClass("Backpack")

	-- Limpia herramientas del kit previas (evita duplicados en recargas).
	local function clearExisting(container: Instance?)
		if container == nil then
			return
		end
		for _, name in KIT_TOOLS do
			local existing = container:FindFirstChild(name)
			if existing then
				existing:Destroy()
			end
		end
	end
	clearExisting(starterGear)
	clearExisting(backpack)

	local created: { Instance } = {}
	local ok = pcall(function()
		for _, name in KIT_TOOLS do
			if starterGear then
				local t = makeToolInstance(name)
				t.Parent = starterGear
				table.insert(created, t)
			end
			if backpack then
				local t = makeToolInstance(name)
				t.Parent = backpack
				table.insert(created, t)
			end
		end
	end)

	-- Verifica completitud: las 7 deben existir en al menos un contenedor.
	local complete = ok
	if complete then
		for _, name in KIT_TOOLS do
			local inGear = starterGear ~= nil and starterGear:FindFirstChild(name) ~= nil
			local inBackpack = backpack ~= nil and backpack:FindFirstChild(name) ~= nil
			if not inGear and not inBackpack then
				complete = false
				break
			end
		end
	end

	if not complete then
		-- No dejar un estado parcial: retirar lo creado (Req. 3.5).
		for _, inst in created do
			inst:Destroy()
		end
		return false
	end

	return true
end

--=============================================================================
-- Guardado: subconjunto persistido (SaveSystem, Req. 16.3, 16.4)
--=============================================================================

--[[
	getSaveData — Construye el subconjunto persistido del Jugador (Req. 16.3). La
	Neverita es autoritativa en CoolerSystem, de modo que `coolerFish` se toma de
	CoolerSystem.getCount. La posición se toma del personaje (o la última conocida).
]]
local function getSaveData(player: Player): SaveData
	local state = ensureState(player)
	local pos = getPlayerPosition(player) or Vector3.new(0, 0, 0)
	return {
		version = Constants.SAVE.FORMAT_VERSION,
		pos = { x = pos.X, y = pos.Y, z = pos.Z },
		day = state.day,
		wood = state.inventory.wood,
		stone = state.inventory.stone,
		coolerFish = CoolerSystem.getCount(player),
		freeMode = state.freeMode,
	}
end

--[[
	applySaveData — Restaura el estado del Jugador desde un guardado válido
	(Req. 16.4). SaveSystem.load invoca esta función cuando hay datos válidos.
	Restaura día, madera, piedra, Neverita (vía CoolerSystem.setCount), Modo_Libre y
	la posición (se teletransporta si el personaje ya existe; si no, se recuerda para
	aplicarla al aparecer).
]]
local function applySaveData(player: Player, data: SaveData)
	local state = ensureState(player)
	state.day = data.day
	state.inventory.wood = data.wood
	state.inventory.stone = data.stone
	state.freeMode = data.freeMode

	-- Neverita autoritativa (CoolerSystem) y su espejo en PlayerState.
	CoolerSystem.setCount(player, data.coolerFish)
	state.cooler = { count = CoolerSystem.getCount(player) }

	-- Posición restaurada.
	local pos = Vector3.new(data.pos.x, data.pos.y, data.pos.z)
	lastKnownPosition[player.UserId] = pos
	local root = getCharacterRoot(player)
	if root then
		root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
	end

	-- Si el día restaurado ya alcanzó el rescate, notifícalo (idempotente).
	RescueSystem.onDayReached(state.day)
end

--=============================================================================
-- Replicación del estado al HUD (Req. 4.2/4.4 vía StateUpdate)
--=============================================================================

-- buildClientSnapshot — Instantánea del estado que el HUD necesita renderizar:
-- necesidades, contadores de inventario, día, Modo_Libre, Neverita y clima.
local function buildClientSnapshot(player: Player): { [string]: any }
	local state = ensureState(player)
	local weather = WeatherSystem.getWeather()
	return {
		kind = "state",
		active = activePlayers[player.UserId] == true,
		needs = {
			warmth = state.needs.warmth,
			hunger = state.needs.hunger,
			thirst = state.needs.thirst,
			health = state.needs.health,
		},
		inventory = {
			wood = state.inventory.wood,
			stone = state.inventory.stone,
			capacity = state.inventory.capacity,
		},
		cooler = CoolerSystem.getCount(player),
		bottle = state.bottle.state,
		day = state.day,
		freeMode = state.freeMode,
		weather = {
			blizzardActive = weather.blizzardActive,
			visibilityFactor = WeatherSystem.visibilityFactor(),
		},
	}
end

-- replicateState — Envía la instantánea del estado a un Jugador por StateUpdate.
function GameServer.replicateState(player: Player)
	Remotes.StateUpdate:FireClient(player, buildClientSnapshot(player))
end

-- replicateAll — Replica el estado a todos los Jugadores con estado creado.
local function replicateAll()
	for _, player in Players:GetPlayers() do
		if playerStates[player.UserId] ~= nil then
			GameServer.replicateState(player)
		end
	end
end

--=============================================================================
-- Lista de Jugadores activos (para NeedsSystem, WeatherSystem, FireSystem, etc.)
--=============================================================================

-- getActivePlayerList — Jugadores cuya partida está ACTIVA (tras el tutorial). El
-- consumo de necesidades solo aplica a estos (Req. 2.6, 2.8).
local function getActivePlayerList(): { Player }
	local list: { Player } = {}
	for _, player in Players:GetPlayers() do
		if activePlayers[player.UserId] then
			table.insert(list, player)
		end
	end
	return list
end

--=============================================================================
-- StartSurvival: comienzo de la partida activa (Req. 2.8, 3.5)
--=============================================================================

--[[
	handleStartSurvival — Handler de `Remotes.StartSurvival` (pulsar SOBREVIVIR /
	cerrar el tutorial). Comienza la partida ACTIVA e inicia el consumo de
	necesidades (Req. 2.8). Se rechaza si el Mundo no se generó (Req. 5.6) o si el
	kit inicial del Jugador no está completo (Req. 3.5), avisando al HUD.
]]
local function handleStartSurvival(player: Player)
	-- Mundo no disponible: no se puede iniciar (Req. 5.6).
	if not worldOk then
		Remotes.StateUpdate:FireClient(player, {
			kind = "startRejected",
			reason = "worldGenerationFailed",
			message = "No se pudo generar el mapa. No es posible iniciar la partida.",
		})
		return
	end

	-- Kit incompleto: no se inicia una partida jugable parcial (Req. 3.5).
	if canStart[player.UserId] ~= true then
		Remotes.StateUpdate:FireClient(player, {
			kind = "startRejected",
			reason = "incompleteKit",
			message = "No se pudo crear el equipo inicial completo. No es posible iniciar la partida.",
		})
		return
	end

	-- Activa la partida: a partir de aquí el bucle aplica el consumo de necesidades.
	activePlayers[player.UserId] = true
	ensureState(player).lastSaveClock = os.clock()

	Remotes.StateUpdate:FireClient(player, { kind = "started" })
	GameServer.replicateState(player)
end

--=============================================================================
-- onVictory: regreso al Menu_Principal tras escapar (Req. 15.4)
--=============================================================================

local function onVictory(player: Player)
	-- La partida deja de estar activa; el cliente muestra la victoria y vuelve al
	-- Menu_Principal. La escena/animación es responsabilidad del cliente.
	activePlayers[player.UserId] = false
	Remotes.StateUpdate:FireClient(player, { kind = "victory" })
end

--=============================================================================
-- Ciclo de vida del Jugador (PlayerAdded / PlayerRemoving / CharacterAdded)
--=============================================================================

--[[
	onPlayerAdded — Inicializa el estado del Jugador al entrar:
	  1. Crea un PlayerState por defecto (Día 1, kit completo, Botella al 100%).
	  2. Carga el guardado vía SaveSystem.load (que aplica applySaveData si es
	     válido; si es nuevo/corrupto/error, se mantiene el Día 1) (Req. 16.4/16.6/16.7).
	  3. Construye el kit inicial de 7 herramientas; si no se completa, marca al
	     Jugador como "no puede iniciar" (Req. 3.5).
	  4. Replica el estado inicial al HUD.
]]
local function onPlayerAdded(player: Player)
	-- (1) Estado por defecto ANTES de cargar, para que applySaveData tenga sobre qué
	-- escribir.
	playerStates[player.UserId] = makeDefaultState(player.UserId)
	activePlayers[player.UserId] = false
	CoolerSystem.setCount(player, 0)

	-- (2) Carga del guardado (aplica applySaveData internamente si es válido).
	local okLoad = pcall(function()
		SaveSystem.load(player)
	end)
	if not okLoad then
		warn("[GameServer] SaveSystem.load falló para " .. player.Name .. "; se inicia Día 1.")
	end

	-- (3) Kit inicial. Requiere StarterGear/Backpack, que pueden tardar; se intenta
	-- ahora y también al aparecer el personaje.
	canStart[player.UserId] = buildInitialKit(player)

	-- (4) Estado inicial al HUD.
	GameServer.replicateState(player)

	-- Al (re)aparecer el personaje: re-crear el kit si hiciera falta, restaurar la
	-- posición conocida y refrescar el estado.
	player.CharacterAdded:Connect(function(_character)
		task.defer(function()
			local built = buildInitialKit(player)
			-- Solo mejora el estado de arranque: si ya podía iniciar, no lo degrada.
			if not canStart[player.UserId] then
				canStart[player.UserId] = built
			end
			local root = getCharacterRoot(player)
			local pos = lastKnownPosition[player.UserId]
			if root and pos then
				root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
			end
			GameServer.replicateState(player)
		end)
	end)
end

--[[
	onPlayerRemoving — Al salir el Jugador: SaveSystem ya guarda por su propia
	conexión a PlayerRemoving (Req. 16.2). Aquí solo se limpia el estado en memoria
	para no filtrarlo entre sesiones.
]]
local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	playerStates[userId] = nil
	activePlayers[userId] = nil
	canStart[userId] = nil
	lastKnownPosition[userId] = nil
	CoolerSystem.clearPlayer(player)
end

--=============================================================================
-- Cableado de dependencias de los sistemas
--=============================================================================

-- initSystems — Inicializa TODOS los sistemas inyectándoles las dependencias que
-- leen/escriben el PlayerState. Idempotente: los `init` de los sistemas admiten
-- reinvocación sin duplicar conexiones.
local function initSystems()
	-- Mundo: se inicializa aquí; la generación se hace una vez en GameServer.init.
	WorldSystem.init()

	-- Excavación (sin dependencias). Expone isProtected para composeEnv.
	DiggingSystem.init()

	-- Neverita: al retirar un Pez se materializa junto al Jugador (efecto simple).
	CoolerSystem.init({
		depositFish = function(player: Player, _cooler)
			-- Sincroniza el espejo del PlayerState tras el cambio.
			ensureState(player).cooler = { count = CoolerSystem.getCount(player) }
			local pos = getPlayerPosition(player)
			if pos == nil then
				return nil
			end
			local fish = Instance.new("Part")
			fish.Name = "Pez"
			fish.Size = Vector3.new(1.5, 0.5, 0.6)
			fish.Position = pos + Vector3.new(2, 0, 0)
			fish.BrickColor = BrickColor.new("Bright blue")
			fish.Material = Enum.Material.SmoothPlastic
			fish:SetAttribute("Resource", "Pez")
			fish.Parent = workspace
			return fish
		end,
	})

	-- Cosecha (talado/minería): otorga recursos al Inventario del PlayerState.
	HarvestSystem.init({
		world = nil, -- usa WorldSystem por defecto (mismo estado de nodos).
		grantResource = grantResource,
		getEquippedTool = getEquippedTool,
		getPlayerPosition = getPlayerPosition,
	})

	-- Pesca: los Peces capturados van a la Neverita (Req. 10.1). Registra los
	-- Agujeros_Agua en WorldSystem para que BottleSystem los localice (Req. 11.6).
	FishingSystem.init({
		world = {
			addWaterHole = function(id: string, position: Vector3)
				return WorldSystem.addWaterHole(id, position)
			end,
			removeWaterHole = function(id: string): boolean
				return WorldSystem.removeWaterHole(id)
			end,
		},
		getEquippedTool = getEquippedTool,
		getPlayerPosition = getPlayerPosition,
		depositFish = routeCaughtFish,
	})

	-- Botella: lee/escribe necesidades y estado de Botella del PlayerState; consulta
	-- la distancia al Agujero_Agua más cercano para el prompt de rellenado.
	BottleSystem.init({
		getPlayerNeeds = getPlayerNeeds,
		setPlayerNeeds = setPlayerNeeds,
		getPlayerBottle = getPlayerBottle,
		setPlayerBottle = setPlayerBottle,
		getEquippedTool = getEquippedTool,
		getNearestWaterHoleDistance = getNearestWaterHoleDistance,
	})

	-- Fuego y cocinado: consume recursos y aplica calor/comida sobre el PlayerState.
	FireSystem.init({
		getEquippedTool = getEquippedTool,
		getPlayerPosition = getPlayerPosition,
		getPlayerLook = getPlayerLook,
		getPlayers = getActivePlayerList,
		grantWarmth = grantWarmth,
		consumeWood = consumeWood,
		consumeStone = consumeStone,
		applyEatCooked = applyEatCooked,
		applyEatBurned = applyEatBurned,
	})

	-- Necesidades: solo se aplican a los Jugadores activos; entorno compuesto con
	-- clima + protección de Cueva; muerte -> reaparición (BedSystem).
	NeedsSystem.init({
		getActivePlayers = getActivePlayerList,
		getPlayerNeeds = getPlayerNeeds,
		setPlayerNeeds = setPlayerNeeds,
		getEnv = composeEnv,
		onDeath = onDeath,
	})

	-- Clima: RNG por defecto; publica el clima autoritativo en WorldSystem.
	WeatherSystem.init({
		setSharedWeather = function(weather)
			WorldSystem.setWeather(weather)
		end,
		getPlayers = getActivePlayerList,
	})

	-- Cama: usa la posición del Jugador; el resto de predicados quedan por defecto
	-- (reconocen Cuevas de DiggingSystem; dormir solo de noche cuando exista ciclo
	-- día/noche).
	BedSystem.init({
		getPlayerPosition = getPlayerPosition,
	})

	-- Rescate del Día 7 y Modo_Libre: el conteo de días vive en PlayerState.
	RescueSystem.init({
		getPlayers = getActivePlayerList,
		getPlayerPosition = getPlayerPosition,
		onVictory = onVictory,
		setFreeMode = setFreeMode,
		incrementDay = incrementDay,
		getDay = getDay,
		setDay = setDay,
	})

	-- Guardado automático: subconjunto persistido del PlayerState; jugadores activos.
	SaveSystem.init({
		getSaveData = getSaveData,
		applySaveData = applySaveData,
		getActivePlayers = getActivePlayerList,
	})
end

--=============================================================================
-- Bucle de simulación (Heartbeat) — Req. 2.6, 2.8 y "Bucle de simulación"
--=============================================================================

local function onHeartbeat(dt: number)
	-- Necesidades (solo Jugadores activos, vía getActivePlayers inyectado): 2.6/2.8.
	NeedsSystem.step(dt)
	-- Clima autoritativo (global al servidor).
	WeatherSystem.step(dt)
	-- Fuego: calor de hogueras y cocinado de peces.
	FireSystem.step(dt)
	-- Rescate: proximidad al helicóptero cuando está posado.
	RescueSystem.step(dt)
	-- Guardado automático (temporizador de 120 s por jugador).
	SaveSystem.step(dt)

	-- Replicación periódica del estado al HUD.
	replicationAccumulator += dt
	if replicationAccumulator >= REPLICATION_INTERVAL_S then
		replicationAccumulator = 0
		replicateAll()
	end
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

--[[
	init — Arranque idempotente del servidor:
	  1. Inicializa todos los sistemas inyectando las dependencias del PlayerState.
	  2. Genera el Mundo UNA vez (WorldSystem.generateAndBuild). Si falla, marca
	     `worldOk=false` y StartSurvival rechazará el inicio (Req. 5.1/5.6).
	  3. Conecta GetSaveState (RemoteFunction), StartSurvival y el ciclo de vida de
	     Jugadores (incluye los ya presentes).
	  4. Arranca el bucle Heartbeat.
]]
function GameServer.init()
	if initialized then
		return GameServer
	end
	initialized = true

	-- (1) Sistemas y dependencias.
	initSystems()

	-- (2) Generación única del Mundo (Req. 5.1).
	local ok, _world, reason = WorldSystem.generateAndBuild()
	worldOk = ok
	worldReason = reason
	if not ok then
		warn("[GameServer] Generación del Mundo fallida (Req. 5.6): " .. tostring(reason))
	end

	-- (3a) RemoteFunction: estado inicial al entrar (Req. 16.4 lado cliente).
	Remotes.GetSaveState.OnServerInvoke = function(player: Player)
		return buildClientSnapshot(player)
	end

	-- (3b) StartSurvival (Req. 2.8).
	Remotes.StartSurvival.OnServerEvent:Connect(function(player: Player)
		handleStartSurvival(player)
	end)

	-- (3c) Ciclo de vida de Jugadores. Incluye los ya conectados (init tardío).
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		if playerStates[player.UserId] == nil then
			task.spawn(onPlayerAdded, player)
		end
	end

	-- (4) Bucle de simulación.
	if not heartbeatConn then
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
	end

	return GameServer
end

--[[
	shutdown — Detiene el bucle y limpia el estado en memoria. Útil para pruebas o
	reinicios controlados. No revierte la generación del Mundo ni desconecta los
	handlers de los sistemas (cada sistema gestiona su propio shutdown).
]]
function GameServer.shutdown()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	playerStates = {}
	activePlayers = {}
	canStart = {}
	lastKnownPosition = {}
	replicationAccumulator = 0
	initialized = false
end

--=============================================================================
-- Consultas públicas (inspección / pruebas)
--=============================================================================

-- getPlayerState — PlayerState de un Jugador (o nil). Para pruebas/depuración.
function GameServer.getPlayerState(player: Player): PlayerState?
	return playerStates[player.UserId]
end

-- isActive — ¿Está la partida del Jugador activa (tras el tutorial)?
function GameServer.isActive(player: Player): boolean
	return activePlayers[player.UserId] == true
end

-- canPlayerStart — ¿Se creó el kit inicial completo para el Jugador? (Req. 3.5)
function GameServer.canPlayerStart(player: Player): boolean
	return canStart[player.UserId] == true
end

-- isWorldReady — ¿Se generó el Mundo correctamente? (Req. 5.1/5.6)
function GameServer.isWorldReady(): boolean
	return worldOk
end

-- getWorldFailureReason — Motivo del fallo de generación del Mundo, si lo hubo.
function GameServer.getWorldFailureReason(): string?
	return worldReason
end

--=============================================================================
-- Auto-arranque en el servidor
--=============================================================================

-- Al requerirse en el servidor, GameServer se auto-inicializa (idempotente). Si se
-- prefiere un Script bootstrap dedicado, puede requerir este módulo y llamar a
-- `GameServer.init()` sin efectos duplicados.
if RunService:IsServer() then
	GameServer.init()
end

return GameServer
