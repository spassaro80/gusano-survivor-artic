--!strict
--[[
	FireSystem.lua — Sistema de servidor AUTORITATIVO de hogueras y cocinado.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es la única autoridad sobre:
	  - Soltar Madera como Tronco en el suelo (Req. 12.1, 12.2).
	  - Encender un Tronco como Hoguera_Emergencia con el Mechero (Req. 12.3, 12.4).
	  - El calor que aportan las Hogueras_Emergencia y su expiración a los 45 s
	    (Req. 12.5, 12.6).
	  - La construcción de la Hoguera_Base (plano de 5 Piedra, 3 Madera al centro,
	    encendido con Mechero, tope de 20 Madera) (Req. 13.1..13.6).
	  - El cocinado de Peces sobre una Hoguera_Base encendida (máx. 5 simultáneos)
	    y los efectos de comer Pez_Cocinado / Pez_Quemado (Req. 13.7..13.11).

	Regla arquitectónica: SERVIDOR AUTORITATIVO. El cliente solo envía intención
	por `Remotes.FireAction`; el servidor valida herramienta (Mechero), distancia,
	recursos y estado ANTES de tocar el estado autoritativo, y replica la
	retroalimentación por `Remotes.StateUpdate`.

	Envoltura de la lógica PURA: la máquina de estados del pescado vive en
	`ReplicatedStorage.Shared.CookingModel` (funciones puras `step`,
	`hungerRestored`, `healthPenalty`). Este sistema NO reimplementa esa lógica:
	solo acumula el tiempo de cocinado por Pez y delega en el modelo. Toda la
	aritmética temporal se dirige con `dt` (ver `FireSystem.step`).

	Bucle de simulación (decisión de diseño): se PREFIERE exponer
	`FireSystem.step(dt)` para que el bucle `Heartbeat` de GameServer lo dirija de
	forma DETERMINISTA (igual que los modelos puros reciben `dt`). Así el cocinado
	y el reparto de calor son reproducibles en pruebas sin depender del reloj real.
	La expiración de la Hoguera_Emergencia a los 45 s usa `task.delay` (Req. 12.6),
	pero `step` también comprueba la edad como red de seguridad determinista.

	Inyección de dependencias (bajo acoplamiento): la mutación de necesidades y el
	inventario pertenecen a `PlayerState` (propiedad de GameServer más adelante).
	Este sistema no los posee: los recibe por `FireSystem.init(deps)`. Todas las
	dependencias tienen valores por defecto razonables basados en el motor de
	Roblox y documentados en su punto de uso; si falta alguna, el efecto se degrada
	de forma segura (no-op o atributo del personaje) sin romper la validación.

	Requisitos cubiertos: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6,
	                      13.1, 13.2, 13.3, 13.4, 13.5, 13.6, 13.7, 13.8, 13.9,
	                      13.10, 13.11
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-- Lógica pura y contrato de Remotes.
local CookingModel = require(game:GetService("ReplicatedStorage").Shared.CookingModel)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes)

type CookingFish = Types.CookingFish

--=============================================================================
-- Constantes de balance (del diseño, vía Constants.lua)
--=============================================================================

local FIRE = Constants.FIRE
local COOKING = Constants.COOKING
local INTERACTION = Constants.INTERACTION

-- Hoguera de emergencia (Req. 12).
local EMERGENCY_DURATION_S: number = FIRE.EMERGENCY_DURATION_S -- 45
local EMERGENCY_WARMTH_PER_S: number = FIRE.EMERGENCY_WARMTH_PER_S -- 10
local EMERGENCY_RADIUS_M: number = FIRE.EMERGENCY_RADIUS_M -- 5

-- Hoguera de base y cocinado (Req. 13).
local BASE_STONE_COST: number = FIRE.BASE_STONE_COST -- 5
local BASE_WOOD_COST: number = FIRE.BASE_WOOD_COST -- 3
local BASE_WOOD_CAP: number = FIRE.BASE_WOOD_CAP -- 20
local MAX_COOKING_FISH: number = FIRE.MAX_COOKING_FISH -- 5

-- Distancia para encender un Tronco con el Mechero (Req. 12.3, 12.4).
local IGNITE_LOG_M: number = INTERACTION.IGNITE_LOG_M -- 3

-- Distancia para soltar un Pez crudo sobre una Hoguera_Base encendida (Req. 13.7:
-- "a 3 unidades o menos"). No hay constante global dedicada; se fija a 3 m aquí.
local COOK_RANGE_M: number = 3

-- Distancia a la que se suelta el Tronco frente al Jugador (Req. 12.1: "a 1 metro
-- frente al Jugador"). 1 stud se trata como 1 metro para las interacciones.
local DROP_WOOD_FRONT_M: number = 1

-- Cota superior de las necesidades (para acotar el Calor a 100, Req. 12.5).
local NEEDS_MAX: number = Constants.NEEDS.MAX -- 100

--=============================================================================
-- Tipos
--=============================================================================

-- Tronco soltado en el suelo, candidato a Hoguera_Emergencia (Req. 12.1, 12.3).
export type DroppedLog = {
	id: string,
	position: Vector3,
	instance: Instance?,
}

-- Hoguera de emergencia encendida (Req. 12.5, 12.6).
export type EmergencyFire = {
	id: string,
	position: Vector3,
	ignitedAt: number, -- os.clock() del encendido
	active: boolean,
	instance: Instance?,
}

-- Etapas de la Hoguera_Base a lo largo de su construcción (Req. 13.1..13.5).
--   "blueprint" -> círculo de piedras colocado, aún sin madera (13.1).
--   "woodReady" -> 3 Madera colocadas en el centro, lista para encender (13.3).
--   "lit"       -> encendida y permanente (13.4).
export type BaseFireStage = "blueprint" | "woodReady" | "lit"

-- Pez en cocinado con identificador, para poder consumirlo por id (Req. 13.7..13.11).
export type CookingEntry = {
	id: string,
	fish: CookingFish,
}

-- Hoguera de base autoritativa (Req. 13).
export type BaseFire = {
	id: string,
	ownerUserId: number,
	position: Vector3,
	stage: BaseFireStage,
	woodStock: number, -- 0..BASE_WOOD_CAP
	lit: boolean,
	cooking: { [string]: CookingEntry }, -- máx. MAX_COOKING_FISH simultáneos
	instance: Instance?,
}

--[[
	Deps — Dependencias inyectables. Todas opcionales; cada una tiene un valor por
	defecto documentado. La mutación de necesidades e inventario pertenece a
	PlayerState (GameServer); aquí solo se invocan las funciones inyectadas.
]]
export type Deps = {
	-- Herramienta equipada por el Jugador ("Mechero" para encender). Por defecto
	-- lee el Tool hijo del personaje.
	getEquippedTool: ((player: Player) -> string?)?,
	-- Posición del Jugador (para soltar Tronco/validar distancias). Por defecto
	-- la del HumanoidRootPart.
	getPlayerPosition: ((player: Player) -> Vector3?)?,
	-- Dirección de la mira del Jugador (para soltar el Tronco 1 m al frente,
	-- Req. 12.1). Por defecto LookVector del HumanoidRootPart.
	getPlayerLook: ((player: Player) -> Vector3?)?,
	-- Conjunto de Jugadores a los que aplicar calor. Por defecto Players:GetPlayers().
	getPlayers: (() -> { Player })?,
	-- Concede Calor a un Jugador. `amount` es el incremento YA calculado para este
	-- paso (EMERGENCY_WARMTH_PER_S * dt). El dueño de PlayerState debe acotarlo a
	-- NEEDS_MAX (Req. 12.5). Por defecto usa un atributo "Warmth" del personaje.
	grantWarmth: ((player: Player, amount: number) -> ())?,
	-- Consume `n` unidades de Madera del Inventario; devuelve true si había
	-- suficiente (y las descontó) o false si no (sin cambios). Por defecto usa un
	-- atributo "Wood" del jugador.
	consumeWood: ((player: Player, n: number) -> boolean)?,
	-- Consume `n` unidades de Piedra del Inventario; devuelve true/false igual que
	-- consumeWood. Por defecto usa un atributo "Stone" del jugador.
	consumeStone: ((player: Player, n: number) -> boolean)?,
	-- Aplica el efecto de comer un Pez_Cocinado (+40 Hambre, acotado a 100,
	-- Req. 13.9). Por defecto no-op documentado.
	applyEatCooked: ((player: Player) -> ())?,
	-- Aplica el efecto de comer un Pez_Quemado (-15 Salud, sin bajar de 0,
	-- Req. 13.11). Por defecto no-op documentado.
	applyEatBurned: ((player: Player) -> ())?,
}

-- Resultados de acción (útiles para pruebas y para el enrutado del Remote).
export type DropWoodResult = { ok: boolean, reason: string?, logId: string?, position: Vector3? }
export type IgniteResult = { ok: boolean, reason: string?, fireId: string? }
export type BaseResult = { ok: boolean, reason: string?, fireId: string?, stage: BaseFireStage?, woodStock: number? }
export type CookResult = { ok: boolean, reason: string?, fireId: string?, fishId: string?, cookingCount: number? }
export type EatResult = { ok: boolean, reason: string?, effect: string? }

--=============================================================================
-- Estado del módulo
--=============================================================================

local FireSystem = {}

local deps: Deps = {}

local droppedLogs: { [string]: DroppedLog } = {}
local emergencyFires: { [string]: EmergencyFire } = {}
local baseFires: { [string]: BaseFire } = {}

local nextLogId = 1
local nextFireId = 1
local nextBaseId = 1
local nextFishId = 1

--=============================================================================
-- Dependencias por defecto (motor de Roblox)
--=============================================================================

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

local function defaultGetPlayerLook(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.CFrame.LookVector
	end
	return nil
end

local function defaultGetPlayers(): { Player }
	return Players:GetPlayers()
end

-- Fallback de Calor: acumula en el atributo numérico "Warmth" del personaje,
-- acotado a [0, NEEDS_MAX]. El dueño real (PlayerState) debería sustituir esto.
local function defaultGrantWarmth(player: Player, amount: number)
	local character = player.Character
	if not character then
		return
	end
	local current = character:GetAttribute("Warmth")
	local value = (type(current) == "number" and current or 0) + amount
	value = math.clamp(value, 0, NEEDS_MAX)
	character:SetAttribute("Warmth", value)
end

-- Fallback de consumo de recurso sobre un atributo numérico del jugador.
local function makeDefaultConsumer(attribute: string): (Player, number) -> boolean
	return function(player: Player, n: number): boolean
		local current = player:GetAttribute(attribute)
		local have = type(current) == "number" and current or 0
		if have < n then
			return false
		end
		player:SetAttribute(attribute, have - n)
		return true
	end
end

local defaultConsumeWood = makeDefaultConsumer("Wood")
local defaultConsumeStone = makeDefaultConsumer("Stone")

-- Fallbacks de comer: sin PlayerState no hay a qué aplicar; se documentan como
-- no-op. GameServer inyectará las funciones reales que mutan las necesidades.
local function defaultApplyEatCooked(_player: Player) end
local function defaultApplyEatBurned(_player: Player) end

-- Accesores que resuelven dep o valor por defecto.
local function getTool(player: Player): string?
	return (deps.getEquippedTool or defaultGetEquippedTool)(player)
end
local function getPos(player: Player): Vector3?
	return (deps.getPlayerPosition or defaultGetPlayerPosition)(player)
end
local function getLook(player: Player): Vector3?
	return (deps.getPlayerLook or defaultGetPlayerLook)(player)
end
local function getPlayers(): { Player }
	return (deps.getPlayers or defaultGetPlayers)()
end
local function grantWarmth(player: Player, amount: number)
	(deps.grantWarmth or defaultGrantWarmth)(player, amount)
end
local function consumeWood(player: Player, n: number): boolean
	return (deps.consumeWood or defaultConsumeWood)(player, n)
end
local function consumeStone(player: Player, n: number): boolean
	return (deps.consumeStone or defaultConsumeStone)(player, n)
end
local function applyEatCooked(player: Player)
	(deps.applyEatCooked or defaultApplyEatCooked)(player)
end
local function applyEatBurned(player: Player)
	(deps.applyEatBurned or defaultApplyEatBurned)(player)
end

--=============================================================================
-- Instancias físicas por defecto (efectos en Workspace)
--=============================================================================

local function defaultSpawnLog(id: string, position: Vector3): Instance?
	local part = Instance.new("Part")
	part.Name = "Tronco_" .. id
	part.Anchored = false
	part.CanCollide = true
	part.Size = Vector3.new(3, 1, 1)
	part.Position = position
	part.BrickColor = BrickColor.new("Reddish brown")
	part.Material = Enum.Material.Wood
	part:SetAttribute("LogId", id)
	part.Parent = Workspace
	return part
end

local function defaultSpawnEmergencyFire(id: string, position: Vector3): Instance?
	local part = Instance.new("Part")
	part.Name = "Hoguera_Emergencia_" .. id
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(2, 1, 2)
	part.Position = position
	part.BrickColor = BrickColor.new("Bright orange")
	part.Material = Enum.Material.Neon
	part:SetAttribute("EmergencyFireId", id)
	part.Parent = Workspace
	return part
end

local function defaultSpawnBaseFire(id: string, position: Vector3): Instance?
	local part = Instance.new("Part")
	part.Name = "Hoguera_Base_" .. id
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(4, 0.5, 4)
	part.Position = position
	part.BrickColor = BrickColor.new("Dark stone grey")
	part.Material = Enum.Material.Slate
	part:SetAttribute("BaseFireId", id)
	part.Parent = Workspace
	return part
end

--=============================================================================
-- Retroalimentación al cliente (StateUpdate, canal S->C)
--=============================================================================

-- sendFireState — Replica el estado/rechazo de fuego por StateUpdate. Se usa
-- tanto para éxitos (encendido, cocinado) como para rechazos con motivo.
local function sendFireState(player: Player, phase: string, extra: { [string]: any }?)
	local payload: { [string]: any } = { kind = "fire", phase = phase }
	if extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	Remotes.StateUpdate:FireClient(player, payload)
end

--=============================================================================
-- Utilidades de distancia (planar X,Z para tolerar diferencias de altura)
--=============================================================================

local function planarDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function countCooking(fire: BaseFire): number
	local n = 0
	for _ in fire.cooking do
		n += 1
	end
	return n
end

--=============================================================================
-- Núcleo: soltar Madera como Tronco (Req. 12.1, 12.2)
--=============================================================================

--[[
	dropWood — Suelta un Tronco 1 m frente al Jugador y descuenta 1 Madera del
	Inventario (Req. 12.1). Si no hay Madera disponible, rechaza sin crear Tronco
	y sin cambios de Inventario, señalando "sin Madera" (Req. 12.2).
]]
function FireSystem.dropWood(player: Player): DropWoodResult
	local pos = getPos(player)
	if pos == nil then
		return { ok = false, reason = "noCharacter" }
	end

	-- Descuenta 1 Madera de forma autoritativa; si no hay, no-op (Req. 12.2).
	if not consumeWood(player, 1) then
		sendFireState(player, "rejected", { action = "dropWood", reason = "noWood" })
		return { ok = false, reason = "noWood" }
	end

	-- Posición 1 m al frente. Se aplana la mira para dejar el Tronco en el suelo.
	local look = getLook(player) or Vector3.new(0, 0, -1)
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 0 then
		flat = flat.Unit
	else
		flat = Vector3.new(0, 0, -1)
	end
	local dropPos = pos + flat * DROP_WOOD_FRONT_M

	local id = "log_" .. tostring(nextLogId)
	nextLogId += 1
	local instance = defaultSpawnLog(id, dropPos)
	droppedLogs[id] = { id = id, position = dropPos, instance = instance }

	sendFireState(player, "woodDropped", { logId = id, position = dropPos })
	return { ok = true, logId = id, position = dropPos }
end

--=============================================================================
-- Núcleo: encender Hoguera_Emergencia (Req. 12.3, 12.4, 12.6)
--=============================================================================

-- extinguishEmergency — Apaga y retira una Hoguera_Emergencia (Req. 12.6).
local function extinguishEmergency(id: string)
	local fire = emergencyFires[id]
	if fire == nil or not fire.active then
		return
	end
	fire.active = false
	if fire.instance then
		fire.instance:Destroy()
		fire.instance = nil
	end
	emergencyFires[id] = nil
end

-- findLogNear — Devuelve el id del Tronco soltado más cercano a `target` dentro
-- de `radius`, o nil.
local function findLogNear(target: Vector3, radius: number): string?
	local bestId: string? = nil
	local bestDist = radius
	for id, log in droppedLogs do
		local dist = planarDistance(target, log.position)
		if dist <= bestDist then
			bestDist = dist
			bestId = id
		end
	end
	return bestId
end

--[[
	igniteEmergency — Enciende un Tronco soltado como Hoguera_Emergencia (Req. 12.3).
	Requiere el Mechero equipado y que el Tronco esté a 3 m o menos del Jugador
	(Req. 12.4). Se puede indicar el Tronco por `logId` o por posición `target`.
	La hoguera dura EXACTAMENTE 45 s (Req. 12.6) mediante task.delay.
]]
function FireSystem.igniteEmergency(player: Player, logId: string?, target: Vector3?): IgniteResult
	-- Mechero equipado (Req. 12.4).
	if getTool(player) ~= "Mechero" then
		sendFireState(player, "rejected", { action = "igniteEmergency", reason = "noLighter" })
		return { ok = false, reason = "noLighter" }
	end

	-- Resolver el Tronco objetivo por id o por posición.
	local resolvedId: string? = logId
	if resolvedId == nil and typeof(target) == "Vector3" then
		resolvedId = findLogNear(target :: Vector3, IGNITE_LOG_M)
	end
	if resolvedId == nil or droppedLogs[resolvedId] == nil then
		sendFireState(player, "rejected", { action = "igniteEmergency", reason = "noLog" })
		return { ok = false, reason = "noLog" }
	end

	local log = droppedLogs[resolvedId]

	-- El Tronco debe estar a 3 m o menos del Jugador (Req. 12.4).
	local pos = getPos(player)
	if pos == nil then
		return { ok = false, reason = "noCharacter" }
	end
	if planarDistance(pos, log.position) > IGNITE_LOG_M then
		sendFireState(player, "rejected", { action = "igniteEmergency", reason = "tooFar" })
		return { ok = false, reason = "tooFar" }
	end

	-- Consumir el Tronco y crear la Hoguera_Emergencia en su posición.
	if log.instance then
		log.instance:Destroy()
	end
	droppedLogs[resolvedId] = nil

	local fireId = "efire_" .. tostring(nextFireId)
	nextFireId += 1
	local instance = defaultSpawnEmergencyFire(fireId, log.position)
	emergencyFires[fireId] = {
		id = fireId,
		position = log.position,
		ignitedAt = os.clock(),
		active = true,
		instance = instance,
	}

	-- Expiración EXACTA a los 45 s (Req. 12.6).
	task.delay(EMERGENCY_DURATION_S, function()
		extinguishEmergency(fireId)
	end)

	sendFireState(player, "emergencyLit", { fireId = fireId, position = log.position })
	return { ok = true, fireId = fireId }
end

--=============================================================================
-- Núcleo: Hoguera_Base (Req. 13.1..13.6)
--=============================================================================

--[[
	placeBaseBlueprint — Coloca el plano de la Hoguera_Base consumiendo 5 Piedra y
	disponiendo el círculo de piedras (Req. 13.1). Si hay menos de 5 Piedra,
	rechaza conservando el Inventario y señala que se necesitan 5 (Req. 13.2).
]]
function FireSystem.placeBaseBlueprint(player: Player, position: Vector3?): BaseResult
	local pos = position
	if typeof(pos) ~= "Vector3" then
		pos = getPos(player)
	end
	if typeof(pos) ~= "Vector3" then
		return { ok = false, reason = "noPosition" }
	end
	local p: Vector3 = pos :: Vector3

	-- Consumo autoritativo de 5 Piedra; si no hay, no-op (Req. 13.2).
	if not consumeStone(player, BASE_STONE_COST) then
		sendFireState(player, "rejected", { action = "placeBaseBlueprint", reason = "notEnoughStone" })
		return { ok = false, reason = "notEnoughStone" }
	end

	local id = "base_" .. tostring(nextBaseId)
	nextBaseId += 1
	local instance = defaultSpawnBaseFire(id, p)
	baseFires[id] = {
		id = id,
		ownerUserId = player.UserId,
		position = p,
		stage = "blueprint",
		woodStock = 0,
		lit = false,
		cooking = {},
		instance = instance,
	}

	sendFireState(player, "baseBlueprint", { fireId = id, position = p })
	return { ok = true, fireId = id, stage = "blueprint", woodStock = 0 }
end

--[[
	addBaseWoodCenter — Coloca las 3 Madera en el centro del círculo, consumiéndolas
	del Inventario, dejando la Hoguera_Base lista para encender (Req. 13.3). Si no
	hay 3 Madera, rechaza conservando el Inventario.
]]
function FireSystem.addBaseWoodCenter(player: Player, fireId: string): BaseResult
	local fire = baseFires[fireId]
	if fire == nil then
		return { ok = false, reason = "noBaseFire" }
	end
	if fire.stage ~= "blueprint" then
		return { ok = false, reason = "wrongStage", stage = fire.stage, woodStock = fire.woodStock }
	end

	if not consumeWood(player, BASE_WOOD_COST) then
		sendFireState(player, "rejected", { action = "addBaseWoodCenter", reason = "notEnoughWood" })
		return { ok = false, reason = "notEnoughWood" }
	end

	fire.stage = "woodReady"
	fire.woodStock = BASE_WOOD_COST

	sendFireState(player, "baseWoodReady", { fireId = fireId, woodStock = fire.woodStock })
	return { ok = true, fireId = fireId, stage = fire.stage, woodStock = fire.woodStock }
end

--[[
	igniteBase — Enciende la Hoguera_Base de forma permanente (Req. 13.4). Requiere
	el Mechero equipado y que la Madera ya esté colocada en el centro. Sin Mechero,
	no crea la hoguera y conserva la Madera del centro (Req. 13.5).
]]
function FireSystem.igniteBase(player: Player, fireId: string): BaseResult
	local fire = baseFires[fireId]
	if fire == nil then
		return { ok = false, reason = "noBaseFire" }
	end

	-- Mechero equipado; si no, se conserva la Madera colocada (Req. 13.5).
	if getTool(player) ~= "Mechero" then
		sendFireState(player, "rejected", { action = "igniteBase", reason = "noLighter" })
		return { ok = false, reason = "noLighter", stage = fire.stage, woodStock = fire.woodStock }
	end

	if fire.stage ~= "woodReady" then
		return { ok = false, reason = "wrongStage", stage = fire.stage, woodStock = fire.woodStock }
	end

	fire.stage = "lit"
	fire.lit = true

	sendFireState(player, "baseLit", { fireId = fireId, woodStock = fire.woodStock })
	return { ok = true, fireId = fireId, stage = fire.stage, woodStock = fire.woodStock }
end

--[[
	feedBaseWood — Añade Madera a una Hoguera_Base encendida, manteniéndola
	encendida hasta un máximo de 20 unidades acumuladas (Req. 13.6). Consume del
	Inventario solo la cantidad que realmente cabe por debajo del tope; si ya está
	en el tope, rechaza sin consumir.
]]
function FireSystem.feedBaseWood(player: Player, fireId: string, amount: number?): BaseResult
	local fire = baseFires[fireId]
	if fire == nil then
		return { ok = false, reason = "noBaseFire" }
	end
	if not fire.lit then
		return { ok = false, reason = "notLit", stage = fire.stage, woodStock = fire.woodStock }
	end

	local n = amount or 1
	if n <= 0 then
		return { ok = false, reason = "invalidAmount", woodStock = fire.woodStock }
	end

	-- No superar el tope de 20 Madera (Req. 13.6): solo se acepta lo que cabe.
	local room = BASE_WOOD_CAP - fire.woodStock
	if room <= 0 then
		sendFireState(player, "rejected", { action = "feedBaseWood", reason = "woodCapReached", woodStock = fire.woodStock })
		return { ok = false, reason = "woodCapReached", woodStock = fire.woodStock }
	end
	local toAdd = math.min(n, room)

	if not consumeWood(player, toAdd) then
		sendFireState(player, "rejected", { action = "feedBaseWood", reason = "notEnoughWood" })
		return { ok = false, reason = "notEnoughWood", woodStock = fire.woodStock }
	end

	fire.woodStock += toAdd
	-- Permanece encendida (Req. 13.6): no se toca `lit`.
	sendFireState(player, "baseFed", { fireId = fireId, woodStock = fire.woodStock })
	return { ok = true, fireId = fireId, stage = fire.stage, woodStock = fire.woodStock }
end

--=============================================================================
-- Núcleo: cocinado de Peces (Req. 13.7..13.11)
--=============================================================================

-- findLitBaseFireNear — Devuelve el id de la Hoguera_Base encendida más cercana a
-- `target` dentro de `radius`, o nil.
local function findLitBaseFireNear(target: Vector3, radius: number): string?
	local bestId: string? = nil
	local bestDist = radius
	for id, fire in baseFires do
		if fire.lit then
			local dist = planarDistance(target, fire.position)
			if dist <= bestDist then
				bestDist = dist
				bestId = id
			end
		end
	end
	return bestId
end

--[[
	dropRawFish — Suelta un Pez crudo a 3 m o menos de una Hoguera_Base encendida e
	inicia su cocinado, admitiendo un máximo de 5 Peces simultáneos (Req. 13.7). Si
	no hay hoguera encendida cerca, o ya hay 5 cocinándose, rechaza.
]]
function FireSystem.dropRawFish(player: Player, target: Vector3?): CookResult
	local pos = target
	if typeof(pos) ~= "Vector3" then
		pos = getPos(player)
	end
	if typeof(pos) ~= "Vector3" then
		return { ok = false, reason = "noPosition" }
	end

	local fireId = findLitBaseFireNear(pos :: Vector3, COOK_RANGE_M)
	if fireId == nil then
		sendFireState(player, "rejected", { action = "dropRawFish", reason = "noLitBaseFire" })
		return { ok = false, reason = "noLitBaseFire" }
	end

	local fire = baseFires[fireId]
	if countCooking(fire) >= MAX_COOKING_FISH then
		sendFireState(player, "rejected", { action = "dropRawFish", reason = "cookingFull", fireId = fireId })
		return { ok = false, reason = "cookingFull", fireId = fireId, cookingCount = MAX_COOKING_FISH }
	end

	local fishId = "fish_" .. tostring(nextFishId)
	nextFishId += 1
	-- Estado inicial CRUDO con 0 s sobre el fuego (modelo puro).
	fire.cooking[fishId] = { id = fishId, fish = { state = "Raw", timeOnFire = 0 } }

	local count = countCooking(fire)
	sendFireState(player, "cookingStarted", { fireId = fireId, fishId = fishId, cookingCount = count })
	return { ok = true, fireId = fireId, fishId = fishId, cookingCount = count }
end

--[[
	eatFish — Consume un Pez que se está cocinando en una Hoguera_Base. Si está
	Cocinado, aplica +40 Hambre (Req. 13.9); si está Quemado, aplica -15 Salud
	(Req. 13.11). En ambos casos el Pez se retira del fuego. Delega la decisión de
	efecto en el modelo puro (hungerRestored / healthPenalty).
]]
function FireSystem.eatFish(player: Player, fireId: string, fishId: string): EatResult
	local fire = baseFires[fireId]
	if fire == nil then
		return { ok = false, reason = "noBaseFire" }
	end
	local entry = fire.cooking[fishId]
	if entry == nil then
		return { ok = false, reason = "noFish" }
	end

	local effect: string? = nil
	if CookingModel.hungerRestored(entry.fish) > 0 then
		-- Pez_Cocinado: +40 Hambre (Req. 13.9).
		applyEatCooked(player)
		effect = "cooked"
	elseif CookingModel.healthPenalty(entry.fish) > 0 then
		-- Pez_Quemado: -15 Salud (Req. 13.11).
		applyEatBurned(player)
		effect = "burned"
	else
		-- Pez crudo: sin efecto de necesidades definido; solo se retira.
		effect = "raw"
	end

	fire.cooking[fishId] = nil
	sendFireState(player, "fishEaten", { fireId = fireId, fishId = fishId, effect = effect })
	return { ok = true, effect = effect }
end

--=============================================================================
-- Bucle de simulación dirigido por dt (preferido sobre Heartbeat interno)
--=============================================================================

--[[
	step — Avanza `dt` segundos de simulación de fuego. Lo dirige el bucle de
	GameServer para que el reparto de Calor y el cocinado sean DETERMINISTAS:
	  1. Cada Hoguera_Emergencia activa aporta +10 Calor/s (radio 5 m, acotado a
	     100) a cada Jugador dentro del radio (Req. 12.5). Como red de seguridad
	     determinista, se apaga si su edad alcanza 45 s (Req. 12.6; el task.delay
	     es el mecanismo primario).
	  2. Cada Pez en cocinado avanza según CookingModel.step (Raw->Cooked a 10 s,
	     Cooked->Burned a 18 s) (Req. 13.8, 13.10).
]]
function FireSystem.step(dt: number)
	if dt <= 0 then
		dt = 0
	end

	-- (1) Calor de las Hogueras_Emergencia.
	local now = os.clock()
	local players = getPlayers()
	for id, fire in emergencyFires do
		if fire.active then
			-- Red de seguridad determinista para la expiración (Req. 12.6).
			if now - fire.ignitedAt >= EMERGENCY_DURATION_S then
				extinguishEmergency(id)
			elseif dt > 0 then
				local warmthAmount = EMERGENCY_WARMTH_PER_S * dt
				for _, player in players do
					local pos = getPos(player)
					if pos ~= nil and planarDistance(pos, fire.position) <= EMERGENCY_RADIUS_M then
						grantWarmth(player, warmthAmount)
					end
				end
			end
		end
	end

	-- (2) Cocinado de Peces sobre cada Hoguera_Base encendida (Req. 13.8, 13.10).
	if dt > 0 then
		for _, fire in baseFires do
			if fire.lit then
				for fishId, entry in fire.cooking do
					entry.fish = CookingModel.step(entry.fish, dt)
				end
			end
		end
	end
end

--=============================================================================
-- Enrutado del RemoteEvent FireAction (C->S)
--=============================================================================

--[[
	onFireAction — Handler de `Remotes.FireAction`. Admite un payload de tabla con
	`kind`:
	  { kind = "dropWood" }                                   -> soltar Madera (12.1)
	  { kind = "igniteEmergency", logId?, target? }           -> encender Tronco (12.3)
	  { kind = "placeBaseBlueprint", target? }                -> plano de base (13.1)
	  { kind = "addBaseWoodCenter", fireId }                  -> 3 Madera centro (13.3)
	  { kind = "igniteBase", fireId }                         -> encender base (13.4)
	  { kind = "feedBaseWood", fireId, amount? }              -> alimentar base (13.6)
	  { kind = "dropRawFish", target? }                       -> cocinar Pez (13.7)
	  { kind = "eatFish", fireId, fishId }                    -> comer Pez (13.9/13.11)
]]
local function onFireAction(player: Player, payload: any)
	if type(payload) ~= "table" then
		return
	end

	local kind = payload.kind
	if kind == "dropWood" then
		FireSystem.dropWood(player)
	elseif kind == "igniteEmergency" then
		FireSystem.igniteEmergency(player, payload.logId, payload.target)
	elseif kind == "placeBaseBlueprint" then
		FireSystem.placeBaseBlueprint(player, payload.target)
	elseif kind == "addBaseWoodCenter" then
		if type(payload.fireId) == "string" then
			FireSystem.addBaseWoodCenter(player, payload.fireId)
		end
	elseif kind == "igniteBase" then
		if type(payload.fireId) == "string" then
			FireSystem.igniteBase(player, payload.fireId)
		end
	elseif kind == "feedBaseWood" then
		if type(payload.fireId) == "string" then
			FireSystem.feedBaseWood(player, payload.fireId, payload.amount)
		end
	elseif kind == "dropRawFish" then
		FireSystem.dropRawFish(player, payload.target)
	elseif kind == "eatFish" then
		if type(payload.fireId) == "string" and type(payload.fishId) == "string" then
			FireSystem.eatFish(player, payload.fireId, payload.fishId)
		end
	end
end

--=============================================================================
-- Consultas públicas (inspección / pruebas)
--=============================================================================

function FireSystem.getDroppedLogs(): { [string]: DroppedLog }
	local copy: { [string]: DroppedLog } = {}
	for id, log in droppedLogs do
		copy[id] = log
	end
	return copy
end

function FireSystem.getEmergencyFires(): { [string]: EmergencyFire }
	local copy: { [string]: EmergencyFire } = {}
	for id, fire in emergencyFires do
		copy[id] = fire
	end
	return copy
end

function FireSystem.getBaseFire(fireId: string): BaseFire?
	return baseFires[fireId]
end

function FireSystem.getBaseFires(): { [string]: BaseFire }
	local copy: { [string]: BaseFire } = {}
	for id, fire in baseFires do
		copy[id] = fire
	end
	return copy
end

function FireSystem.getCookingCount(fireId: string): number
	local fire = baseFires[fireId]
	if fire == nil then
		return 0
	end
	return countCooking(fire)
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

local fireConnection: RBXScriptConnection? = nil

--[[
	init — Inicializa el sistema con sus dependencias y conecta el handler a
	`Remotes.FireAction`. Idempotente: reconectar reemplaza las dependencias sin
	duplicar conexiones (usa una única conexión almacenada).
]]
function FireSystem.init(injected: Deps?)
	deps = injected or {}

	if not fireConnection then
		fireConnection = Remotes.FireAction.OnServerEvent:Connect(function(player: Player, ...)
			local payload = (...)
			onFireAction(player, payload)
		end)
	end

	return FireSystem
end

--[[
	shutdown — Desconecta el handler y limpia el estado del módulo. Útil para
	pruebas o reinicios controlados. No destruye los Instances físicos ya creados
	salvo los que gestione la lógica normal.
]]
function FireSystem.shutdown()
	if fireConnection then
		fireConnection:Disconnect()
		fireConnection = nil
	end
	droppedLogs = {}
	emergencyFires = {}
	baseFires = {}
	nextLogId = 1
	nextFireId = 1
	nextBaseId = 1
	nextFishId = 1
end

return FireSystem
