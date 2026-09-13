--!strict
--[[
	FishingSystem.lua — Sistema de servidor AUTORITATIVO de pesca y agujeros de agua.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es la única autoridad sobre:
	  - la creación de Agujeros_Agua al romper hielo de un Lago_Helado con el Pico,
	  - el ciclo completo de pesca con la Caña de Pescar (lanzar, esperar, sacar),
	  - el estado de sesión de pesca por Jugador y el registro de Agujeros_Agua.

	Responsabilidades (Requisitos 9.1–9.6):
	  - 9.1: Golpear con el Pico un bloque de hielo de un Lago_Helado crea un
	         Agujero_Agua en la posición del bloque roto en <= 1 s. El servidor lo
	         resuelve de forma síncrona (inmediata), muy por debajo de 1 s.
	  - 9.2: Con la Caña de Pescar equipada, al hacer clic sobre el agua de un
	         Agujero_Agua se inicia una espera de EXACTAMENTE 5 s y se envía un
	         indicador visual de "Caña lanzada" por StateUpdate.
	  - 9.3: Transcurridos exactamente 5 s sin cancelación, se muestra un Pez en el
	         anzuelo y la acción "¡Sacar Pez!" (también por StateUpdate).
	  - 9.4: Con un solo clic en "¡Sacar Pez!" se deposita EXACTAMENTE 1 Pez en el
	         suelo en la casilla adyacente al Jugador.
	  - 9.5: Si pasan 10 s desde que aparece "¡Sacar Pez!" sin ejecutarla, el Pez se
	         retira sin entregarlo, la sesión termina y el Agujero_Agua queda libre
	         para un nuevo lanzamiento.
	  - 9.6: Si se lanza la Caña sobre una casilla que NO es agua de un Agujero_Agua,
	         no se inicia la cuenta de 5 s y la Caña queda sin lanzar.

	Diseño (servidor autoritativo, ver design.md): el cliente solo envía intención
	por `Remotes.FishingAction`; el servidor valida herramienta, objetivo y estado
	de sesión antes de tocar el estado, y replica la retroalimentación por
	`Remotes.StateUpdate`. Los temporizadores viven en el SERVIDOR (task.delay +
	os.clock), no en el cliente.

	Integración del rotura de hielo con el Pico (decisión documentada):
	  El "golpe del Pico sobre hielo" se enruta a este sistema mediante la API
	  pública `FishingSystem.breakIce(player, position)`. Esta es la integración
	  ELEGIDA (en lugar de escuchar `HarvestAction` para el hielo): HarvestSystem se
	  ocupa de árboles y rocas, y el hielo de lago es una interacción de pesca, por
	  lo que su autoridad reside aquí. El orquestador (GameServer) o el enrutador de
	  entrada llama a `breakIce` cuando un impacto del Pico cae sobre hielo de lago.
	  Por conveniencia, `FishingAction` también acepta un payload con
	  `kind = "breakIce"` para permitir el enrutado directo desde el cliente; ambos
	  caminos convergen en la misma lógica autoritativa.

	Acoplamiento limpio: NO se requiere WorldSystem de forma dura. Las consultas y
	efectos de mundo se inyectan mediante `FishingSystem.init(deps)`. Así el sistema
	se prueba y arranca sin depender del orden de carga de otros sistemas. Si se
	inyecta `world.addWaterHole`/`world.removeWaterHole` (la API de WorldSystem), los
	Agujeros_Agua también se registran allí para que BottleSystem pueda localizarlos
	(Req. 11.6).

	Requisitos cubiertos: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Remotes)

--=============================================================================
-- Tipos
--=============================================================================

-- Material del terreno apuntado. Para romper hielo se acepta "ice"/"lakeIce".
export type Material = "snow" | "rock" | "ice" | "lakeIce" | string

-- Interfaz de mundo que FishingSystem necesita. Todo es opcional salvo cuando se
-- documenta lo contrario; se inyecta por `init(deps)` para bajo acoplamiento.
export type WorldQuery = {
	-- Material del terreno en la posición apuntada (para validar hielo en 9.1).
	getMaterial: ((position: Vector3) -> Material)?,
	-- Registra el Agujero_Agua en el mundo (p. ej. WorldSystem.addWaterHole).
	addWaterHole: ((id: string, position: Vector3) -> any)?,
	-- Elimina el registro del Agujero_Agua del mundo (WorldSystem.removeWaterHole).
	removeWaterHole: ((id: string) -> boolean)?,
	-- Crea/elimina el efecto físico del Agujero_Agua en Workspace. Opcionales.
	spawnWaterHoleInstance: ((id: string, position: Vector3) -> Instance?)?,
}

-- Dependencias inyectables. Todas tienen valores por defecto razonables basados
-- en el motor de Roblox salvo `world`, que si falta desactiva la validación de
-- material (se confía en que el llamador ya validó el hielo).
export type Deps = {
	-- Consultas/efectos de mundo (WorldSystem u otro). Opcional.
	world: WorldQuery?,
	-- Herramienta equipada por el Jugador ("Pico" para romper, "Caña de Pescar").
	getEquippedTool: ((player: Player) -> string?)?,
	-- Posición del Jugador (para depositar el Pez adyacente, 9.4).
	getPlayerPosition: ((player: Player) -> Vector3?)?,
	-- Deposita EXACTAMENTE 1 Pez en el suelo en `position` (9.4). Opcional.
	depositFish: ((player: Player, position: Vector3) -> Instance?)?,
	-- Radio (studs) para considerar que un clic cae sobre el agua de un agujero.
	waterHoleRadius: number?,
	-- Tamaño en studs de un bloque del mundo (para posicionar el Pez adyacente).
	cubeSize: number?,
}

-- Agujero_Agua registrado por este sistema.
export type WaterHole = {
	id: string,
	position: Vector3,
	instance: Instance?,
}

-- Fase de una sesión de pesca por Jugador.
export type FishingPhase = "casting" | "fishReady"

-- Estado autoritativo de la sesión de pesca de un Jugador.
export type Session = {
	userId: number,
	player: Player,
	holeId: string,
	phase: FishingPhase,
	castClock: number, -- os.clock() del lanzamiento
	token: number, -- invalida temporizadores obsoletos (cancelación/relanzado)
}

-- Resultado de romper hielo (Req. 9.1).
export type BreakIceResult = {
	ok: boolean,
	reason: string?, -- "noPickaxe" | "notLakeIce" | "badTarget" | "alreadyHole"
	holeId: string?,
	position: Vector3?,
}

-- Resultado de lanzar la Caña (Req. 9.2, 9.6).
export type CastResult = {
	ok: boolean,
	reason: string?, -- "noRod" | "badTarget" | "notWaterHole" | "holeBusy" | "busy"
	holeId: string?,
}

-- Resultado de "¡Sacar Pez!" (Req. 9.4).
export type ReelResult = {
	ok: boolean,
	reason: string?, -- "noSession" | "notReady"
	deposited: boolean,
}

--=============================================================================
-- Constantes de pesca (específicas del Req. 9; no son balance global)
--=============================================================================

-- Espera EXACTA desde el lanzamiento hasta que el Pez pica (Req. 9.2, 9.3).
local CAST_WAIT_S = 5
-- Ventana para ejecutar "¡Sacar Pez!" antes de perder el Pez (Req. 9.5).
local REEL_TIMEOUT_S = 10

--=============================================================================
-- Estado del módulo
--=============================================================================

local FishingSystem = {}

local deps: Deps = {}
local waterHoleRadius: number = 4
local cubeSize: number = 4

-- Agujeros_Agua registrados, indexados por id.
local waterHoles: { [string]: WaterHole } = {}
local nextHoleId = 1

-- Sesiones de pesca activas, indexadas por userId (una por Jugador).
local sessions: { [number]: Session } = {}
-- Agujeros ocupados por una sesión activa: holeId -> userId. Al terminar la
-- sesión el agujero se libera para un nuevo lanzamiento (Req. 9.5).
local occupiedHoles: { [string]: number } = {}
-- Contador para tokens de temporizador (invalida callbacks obsoletos).
local tokenCounter = 0

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

-- Crea un Part anclado sencillo que representa el agua del Agujero_Agua.
local function defaultSpawnWaterHoleInstance(id: string, position: Vector3): Instance?
	local part = Instance.new("Part")
	part.Name = "Agujero_Agua_" .. id
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(cubeSize, 0.4, cubeSize)
	part.Position = position
	part.BrickColor = BrickColor.new("Steel blue")
	part.Material = Enum.Material.Water
	part.Transparency = 0.25
	part:SetAttribute("WaterHoleId", id)
	part.Parent = Workspace
	return part
end

-- Deposita EXACTAMENTE 1 Pez como objeto físico en el suelo en `position` (9.4).
local function defaultDepositFish(player: Player, position: Vector3): Instance?
	local fish = Instance.new("Part")
	fish.Name = "Pez"
	fish.Anchored = false
	fish.CanCollide = true
	fish.Size = Vector3.new(1.5, 0.5, 0.6)
	fish.Position = position
	fish.BrickColor = BrickColor.new("Bright blue")
	fish.Material = Enum.Material.SmoothPlastic
	fish:SetAttribute("Resource", "Pez")
	fish.Parent = Workspace
	return fish
end

--=============================================================================
-- Retroalimentación al cliente (indicador visual de pesca, Req. 9.2, 9.3)
--=============================================================================

--[[
	sendFishingState — Replica el estado de pesca del Jugador por StateUpdate
	(canal S->C). `phase` puede ser:
	  "lineCast"  -> Caña lanzada, esperando (indicador visual, Req. 9.2)
	  "fishReady" -> Pez en el anzuelo + acción "¡Sacar Pez!" (Req. 9.3)
	  "ended"     -> sesión finalizada (por sacada o por timeout de 10 s)
	  "rejected"  -> intento de lanzar/sacar rechazado (con motivo)
]]
local function sendFishingState(player: Player, phase: string, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		kind = "fishing",
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
-- Utilidades de Agujero_Agua y sesión
--=============================================================================

-- ¿Es `material` hielo de lago rompible? (Req. 9.1)
local function isLakeIce(material: Material): boolean
	return material == "ice" or material == "lakeIce"
end

-- findWaterHoleNear — Devuelve el id del Agujero_Agua cuyo agua cubre `target`,
-- o nil si el clic no cae sobre agua de ningún agujero (Req. 9.2 / 9.6). Usa
-- distancia planar (X,Z) para tolerar diferencias de altura del punto apuntado.
local function findWaterHoleNear(target: Vector3): string?
	local bestId: string? = nil
	local bestDist = waterHoleRadius
	for id, hole in waterHoles do
		local dx = target.X - hole.position.X
		local dz = target.Z - hole.position.Z
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist <= bestDist then
			bestDist = dist
			bestId = id
		end
	end
	return bestId
end

-- newToken — Reserva un token único para un temporizador de sesión.
local function newToken(): number
	tokenCounter += 1
	return tokenCounter
end

--[[
	endSession — Finaliza y limpia la sesión de un Jugador, liberando el
	Agujero_Agua para un nuevo lanzamiento (Req. 9.5). Invalida cualquier
	temporizador pendiente al descartar la sesión (los callbacks comparan token).
]]
local function endSession(userId: number)
	local session = sessions[userId]
	if session == nil then
		return
	end
	if occupiedHoles[session.holeId] == userId then
		occupiedHoles[session.holeId] = nil
	end
	sessions[userId] = nil
end

--=============================================================================
-- Núcleo: romper hielo (Req. 9.1)
--=============================================================================

--[[
	breakIce — Rompe un bloque de hielo de un Lago_Helado con el Pico y crea un
	Agujero_Agua en la posición del bloque roto (Req. 9.1). Integración pública:
	GameServer/InputRouter la invoca cuando un impacto del Pico cae sobre hielo.

	Devuelve BreakIceResult. Crea el agujero de forma inmediata (<< 1 s) y lo
	rastrea autoritativamente; si se inyectó `world.addWaterHole`, también lo
	registra allí para BottleSystem (Req. 11.6).
]]
function FishingSystem.breakIce(player: Player, position: Vector3?): BreakIceResult
	if typeof(position) ~= "Vector3" then
		return { ok = false, reason = "badTarget" }
	end
	local pos: Vector3 = position :: Vector3

	-- Pico equipado (Req. 9.1).
	local getTool = deps.getEquippedTool or defaultGetEquippedTool
	if getTool(player) ~= "Pico" then
		return { ok = false, reason = "noPickaxe" }
	end

	-- Material: hielo de lago. Si no hay consulta de mundo, se confía en el
	-- llamador (que ya determinó que el impacto fue sobre hielo).
	local world = deps.world
	if world and world.getMaterial then
		if not isLakeIce(world.getMaterial(pos)) then
			return { ok = false, reason = "notLakeIce" }
		end
	end

	-- Evita crear dos agujeros en el mismo bloque (idempotencia por posición).
	local existing = findWaterHoleNear(pos)
	if existing then
		return { ok = false, reason = "alreadyHole", holeId = existing, position = waterHoles[existing].position }
	end

	-- Crea y rastrea el Agujero_Agua.
	local id = "hole_" .. tostring(nextHoleId)
	nextHoleId += 1

	local instance: Instance? = nil
	if world and world.spawnWaterHoleInstance then
		instance = world.spawnWaterHoleInstance(id, pos)
	else
		instance = defaultSpawnWaterHoleInstance(id, pos)
	end

	local hole: WaterHole = { id = id, position = pos, instance = instance }
	waterHoles[id] = hole

	-- Registro en el mundo para otros sistemas (BottleSystem, Req. 11.6).
	if world and world.addWaterHole then
		world.addWaterHole(id, pos)
	end

	return { ok = true, holeId = id, position = pos }
end

--=============================================================================
-- Núcleo: lanzar la Caña (Req. 9.2, 9.3, 9.5, 9.6)
--=============================================================================

--[[
	tryCast — Procesa la intención de lanzar la Caña sobre `target`. Si el clic
	cae sobre el agua de un Agujero_Agua libre y la Caña está equipada, inicia la
	espera de EXACTAMENTE 5 s (Req. 9.2) y programa la aparición del Pez (9.3) y el
	timeout de 10 s (9.5). Si el clic NO es agua de un agujero, no inicia nada y la
	Caña queda sin lanzar (Req. 9.6).
]]
function FishingSystem.tryCast(player: Player, target: Vector3?): CastResult
	if typeof(target) ~= "Vector3" then
		return { ok = false, reason = "badTarget" }
	end
	local pos: Vector3 = target :: Vector3

	-- Caña de Pescar equipada (Req. 9.2).
	local getTool = deps.getEquippedTool or defaultGetEquippedTool
	if getTool(player) ~= "Caña de Pescar" then
		return { ok = false, reason = "noRod" }
	end

	-- Una sesión de pesca por Jugador a la vez.
	if sessions[player.UserId] ~= nil then
		return { ok = false, reason = "busy" }
	end

	-- El clic debe caer sobre el agua de un Agujero_Agua (Req. 9.6).
	local holeId = findWaterHoleNear(pos)
	if holeId == nil then
		return { ok = false, reason = "notWaterHole" }
	end

	-- El agujero no puede estar ocupado por otra sesión activa.
	if occupiedHoles[holeId] ~= nil then
		return { ok = false, reason = "holeBusy", holeId = holeId }
	end

	-- Abre la sesión en fase de espera (Req. 9.2).
	local token = newToken()
	local session: Session = {
		userId = player.UserId,
		player = player,
		holeId = holeId,
		phase = "casting",
		castClock = os.clock(),
		token = token,
	}
	sessions[player.UserId] = session
	occupiedHoles[holeId] = player.UserId

	-- Indicador visual de "Caña lanzada" (Req. 9.2).
	sendFishingState(player, "lineCast", { holeId = holeId })

	-- Tras EXACTAMENTE 5 s sin cancelación, aparece el Pez y "¡Sacar Pez!" (9.3).
	task.delay(CAST_WAIT_S, function()
		local current = sessions[player.UserId]
		if current == nil or current.token ~= token or current.phase ~= "casting" then
			return -- sesión cancelada/relanzada: temporizador obsoleto.
		end
		current.phase = "fishReady"
		sendFishingState(player, "fishReady", { holeId = holeId, action = "¡Sacar Pez!" })

		-- Ventana de 10 s para ejecutar "¡Sacar Pez!" (Req. 9.5).
		task.delay(REEL_TIMEOUT_S, function()
			local s = sessions[player.UserId]
			if s == nil or s.token ~= token or s.phase ~= "fishReady" then
				return -- ya se sacó el Pez o la sesión terminó.
			end
			-- Timeout: se retira el Pez sin entregarlo y termina la sesión,
			-- dejando el Agujero_Agua libre (Req. 9.5).
			endSession(player.UserId)
			sendFishingState(player, "ended", { holeId = holeId, reason = "timeout" })
		end)
	end)

	return { ok = true, holeId = holeId }
end

--=============================================================================
-- Núcleo: sacar el Pez (Req. 9.4)
--=============================================================================

--[[
	tryReel — Procesa la acción "¡Sacar Pez!" con un solo clic (Req. 9.4). Solo es
	válida si el Jugador tiene una sesión en fase `fishReady`. Deposita EXACTAMENTE
	1 Pez en el suelo en la casilla adyacente al Jugador y finaliza la sesión,
	liberando el Agujero_Agua.
]]
function FishingSystem.tryReel(player: Player): ReelResult
	local session = sessions[player.UserId]
	if session == nil then
		return { ok = false, reason = "noSession", deposited = false }
	end
	if session.phase ~= "fishReady" then
		return { ok = false, reason = "notReady", deposited = false }
	end

	-- Calcula la casilla adyacente al Jugador donde cae el Pez (Req. 9.4).
	local getPos = deps.getPlayerPosition or defaultGetPlayerPosition
	local playerPos = getPos(player) or waterHoles[session.holeId].position
	local dropPos = playerPos + Vector3.new(cubeSize, 0, 0)

	-- Deposita EXACTAMENTE 1 Pez.
	local depositFish = deps.depositFish or defaultDepositFish
	depositFish(player, dropPos)

	-- Termina la sesión y libera el agujero.
	endSession(player.UserId)
	sendFishingState(player, "ended", { holeId = session.holeId, reason = "caught" })

	return { ok = true, deposited = true }
end

--=============================================================================
-- Consultas públicas (inspección / pruebas)
--=============================================================================

-- getWaterHoles — Copia del registro de Agujeros_Agua (tabla nueva).
function FishingSystem.getWaterHoles(): { [string]: WaterHole }
	local copy: { [string]: WaterHole } = {}
	for id, hole in waterHoles do
		copy[id] = hole
	end
	return copy
end

-- getWaterHole — Un Agujero_Agua concreto por id (o nil).
function FishingSystem.getWaterHole(id: string): WaterHole?
	return waterHoles[id]
end

-- getWaterHoleCount — Número de Agujeros_Agua registrados.
function FishingSystem.getWaterHoleCount(): number
	local n = 0
	for _ in waterHoles do
		n += 1
	end
	return n
end

-- getSession — Sesión de pesca activa de un Jugador (o nil).
function FishingSystem.getSession(player: Player): Session?
	return sessions[player.UserId]
end

-- getActiveSessionCount — Número de sesiones de pesca activas.
function FishingSystem.getActiveSessionCount(): number
	local n = 0
	for _ in sessions do
		n += 1
	end
	return n
end

-- isHoleAvailable — ¿El Agujero_Agua existe y no está ocupado por una sesión?
function FishingSystem.isHoleAvailable(id: string): boolean
	return waterHoles[id] ~= nil and occupiedHoles[id] == nil
end

--=============================================================================
-- Enrutado del RemoteEvent FishingAction (C->S)
--=============================================================================

--[[
	onFishingAction — Handler de `Remotes.FishingAction`. Admite un payload de
	tabla con `kind`:
	  { kind = "cast",     target = Vector3 }  -> lanzar Caña (9.2)
	  { kind = "reel" }                        -> "¡Sacar Pez!" (9.4)
	  { kind = "breakIce", target = Vector3 }  -> romper hielo con Pico (9.1)
	Compatibilidad: si el primer argumento es un Vector3 suelto, se trata como
	lanzamiento de la Caña sobre esa posición.
]]
local function onFishingAction(player: Player, payload: any)
	-- Compatibilidad: Vector3 suelto => lanzar Caña.
	if typeof(payload) == "Vector3" then
		local result = FishingSystem.tryCast(player, payload :: Vector3)
		if not result.ok then
			sendFishingState(player, "rejected", { reason = result.reason, action = "cast" })
		end
		return
	end

	if type(payload) ~= "table" then
		return
	end

	local kind = payload.kind
	if kind == "cast" then
		local result = FishingSystem.tryCast(player, payload.target)
		if not result.ok then
			sendFishingState(player, "rejected", { reason = result.reason, action = "cast" })
		end
	elseif kind == "reel" then
		local result = FishingSystem.tryReel(player)
		if not result.ok then
			sendFishingState(player, "rejected", { reason = result.reason, action = "reel" })
		end
	elseif kind == "breakIce" then
		local result = FishingSystem.breakIce(player, payload.target)
		if not result.ok then
			sendFishingState(player, "rejected", { reason = result.reason, action = "breakIce" })
		end
	end
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

local fishingConnection: RBXScriptConnection? = nil

--[[
	init — Inicializa el sistema con sus dependencias y conecta el handler a
	`Remotes.FishingAction`. Idempotente: reconectar reemplaza las dependencias sin
	duplicar conexiones (usa una única conexión almacenada).
]]
function FishingSystem.init(injected: Deps?)
	deps = injected or {}
	waterHoleRadius = deps.waterHoleRadius or 4
	cubeSize = deps.cubeSize or 4

	if not fishingConnection then
		fishingConnection = Remotes.FishingAction.OnServerEvent:Connect(function(player: Player, ...)
			local payload = (...)
			onFishingAction(player, payload)
		end)
	end

	return FishingSystem
end

--[[
	shutdown — Desconecta el handler y limpia el estado. Útil para pruebas o
	reinicios controlados. No destruye los Instances físicos ya creados.
]]
function FishingSystem.shutdown()
	if fishingConnection then
		fishingConnection:Disconnect()
		fishingConnection = nil
	end
	waterHoles = {}
	sessions = {}
	occupiedHoles = {}
	nextHoleId = 1
	tokenCounter = 0
end

return FishingSystem
