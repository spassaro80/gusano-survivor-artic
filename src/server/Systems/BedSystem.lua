--!strict
--[[
	BedSystem.lua — Sistema de servidor AUTORITATIVO de la Cama: colocación,
	punto de reaparición y dormir.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es la única autoridad sobre:
	  - la COLOCACIÓN de la Cama (validando que sea dentro de la base o de una
	    Cueva, sobre una superficie válida),
	  - el PUNTO DE REAPARICIÓN del Jugador (una Cama fijada es su respawn único),
	  - el flujo de DORMIR (solo de noche: oscurece, avanza al amanecer y restaura).

	Regla arquitectónica (ver design.md): SERVIDOR AUTORITATIVO. El cliente solo
	envía la intención por `Remotes.BedAction`; el servidor valida ubicación,
	estado (día/noche) y existencia de la Cama ANTES de aplicar cualquier efecto, y
	replica la retroalimentación visual por `Remotes.StateUpdate`.

	Responsabilidades (Requisitos 14.1–14.7):
	  - 14.1: Colocar la Cama sobre una superficie válida dentro de la base o de una
	          Cueva la fija en esa ubicación hasta que el Jugador la retire.
	  - 14.2: Colocar la Cama fuera de base/Cueva o en una superficie no válida se
	          rechaza: no se fija la Cama y se envía retroalimentación visual de
	          ubicación no válida por StateUpdate.
	  - 14.3: Interactuar con una Cama fijada la establece como punto de reaparición
	          ÚNICO del Jugador, reemplazando cualquier punto previo.
	  - 14.4: Al morir, si hay una Cama fijada como respawn, el Jugador reaparece en
	          una posición transitable adyacente a la Cama, a <= 2 m (BED_RESPAWN_M).
	  - 14.5: Al morir sin Cama de respawn (o si la Cama fue retirada/destruida), el
	          Jugador reaparece en el punto de reaparición por defecto del Mundo.
	  - 14.6: De noche, acostarse en la Cama oscurece la pantalla (<= 1 s), avanza el
	          tiempo hasta el amanecer (<= 3 s reales) y restaura la visibilidad.
	  - 14.7: Intentar dormir cuando NO es de noche se rechaza con retroalimentación
	          visual "solo puedes dormir de noche".

	Acoplamiento limpio (patrón de FishingSystem): las consultas y efectos del
	motor/otros sistemas se INYECTAN por `BedSystem.init(deps)`. Así el sistema se
	prueba y arranca sin depender del orden de carga de otros sistemas ni del reloj
	de juego real.

	Supuestos documentados:
	  - "Base": el concepto de "base" del jugador NO es todavía una entidad concreta
	    del proyecto. Por eso la validación de ubicación se delega en el predicado
	    inyectable `deps.isInsideBaseOrCave(position) -> boolean`. Su valor por
	    defecto reconoce SOLO las Cuevas (consultando `DiggingSystem.getCaves()`), de
	    modo que hoy una Cama válida es la que se coloca dentro de una Cueva
	    registrada. Cuando exista una entidad "base" concreta, basta con inyectar un
	    predicado que además la reconozca, sin tocar este módulo.
	  - "Superficie válida": se modela con `deps.isValidBedLocation(player, position)`.
	    Su valor por defecto consulta `isInsideBaseOrCave`. Se puede inyectar una
	    validación más rica (normal de la superficie, pendiente, colisiones) sin
	    cambiar la lógica de este sistema.
	  - "Noche" / "amanecer": el ciclo día/noche tampoco es una entidad concreta aún.
	    Se inyecta `deps.isNight() -> boolean` y `deps.advanceToDawn()`; por defecto
	    `isNight` devuelve false (no se puede dormir) para no acelerar el tiempo sin
	    un sistema de ciclo horario real, y `advanceToDawn` es un no-op.
	  - La reaparición efectiva (teletransporte) se delega en
	    `deps.respawnAt(player, position)` / `deps.respawnDefault(player)`. Por
	    defecto mueven el `HumanoidRootPart` del personaje / disparan `LoadCharacter`.

	Requisitos cubiertos: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6, 14.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Remotes)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DiggingSystem = require(script.Parent.DiggingSystem)

--=============================================================================
-- Constantes de la Cama
--=============================================================================

-- Distancia máxima (studs/metros) a la que reaparece el Jugador junto a la Cama
-- (Req. 14.4). Fuente de verdad: Constants.INTERACTION.BED_RESPAWN_M = 2.
local BED_RESPAWN_M: number = Constants.INTERACTION.BED_RESPAWN_M

-- Tamaño en studs de un bloque del mundo (para posicionar la Cama y su respawn).
local CUBE_SIZE: number = 4

-- Motivos de rechazo enviados al HUD por StateUpdate.
local REASON_INVALID_LOCATION: string = "ubicación no válida"
local REASON_NO_BED: string = "no hay cama"
local REASON_ONLY_AT_NIGHT: string = "solo puedes dormir de noche"

--=============================================================================
-- Tipos
--=============================================================================

-- Registro autoritativo de la Cama fijada de un Jugador (una por Jugador).
export type Bed = {
	userId: number,
	position: Vector3,
	instance: Instance?, -- Instance física en Workspace (nil si aún no se creó).
	placedAt: number, -- os.clock() de la colocación.
}

-- Dependencias inyectables. Todas tienen valores por defecto razonables. Los
-- predicados de "ubicación" y "noche" son deliberadamente conservadores por
-- defecto (ver supuestos de la cabecera).
export type Deps = {
	-- ¿Es `position` una ubicación de Cama válida para `player`? (Req. 14.1, 14.2)
	-- Por defecto consulta `isInsideBaseOrCave`.
	isValidBedLocation: ((player: Player, position: Vector3) -> boolean)?,
	-- ¿Está `position` dentro de la base o de una Cueva? (Req. 14.1)
	-- Por defecto reconoce solo Cuevas (DiggingSystem.getCaves()).
	isInsideBaseOrCave: ((position: Vector3) -> boolean)?,
	-- Posición actual del Jugador (para colocar la Cama frente a él si no se da).
	getPlayerPosition: ((player: Player) -> Vector3?)?,
	-- Crea/elimina la Instance física de la Cama en Workspace. Opcional.
	spawnBedInstance: ((player: Player, position: Vector3) -> Instance?)?,
	-- Busca una posición transitable dentro de `radius` de `center` (Req. 14.4).
	-- Devuelve nil si no encuentra ninguna; por defecto ofrece una celda adyacente.
	findWalkablePosition: ((center: Vector3, radius: number) -> Vector3?)?,
	-- ¿Es de noche? (Req. 14.6, 14.7). Por defecto false (no se puede dormir).
	isNight: (() -> boolean)?,
	-- Avanza el tiempo del juego hasta el amanecer (Req. 14.6). Por defecto no-op.
	advanceToDawn: (() -> ())?,
	-- Reaparece al Jugador en `position` (Req. 14.4). Por defecto mueve el root.
	respawnAt: ((player: Player, position: Vector3) -> ())?,
	-- Reaparece al Jugador en el spawn por defecto del Mundo (Req. 14.5).
	respawnDefault: ((player: Player) -> ())?,
	-- Overrides de constantes (útiles para pruebas).
	respawnRadius: number?,
	cubeSize: number?,
}

-- Resultado de colocar la Cama (Req. 14.1, 14.2).
export type PlaceResult = {
	ok: boolean,
	reason: string?, -- "badTarget" | "invalidLocation"
	position: Vector3?,
}

-- Resultado de fijar el respawn interactuando con la Cama (Req. 14.3).
export type SetRespawnResult = {
	ok: boolean,
	reason: string?, -- "noBed"
}

-- Resultado de dormir (Req. 14.6, 14.7).
export type SleepResult = {
	ok: boolean,
	reason: string?, -- "noBed" | "notNight"
}

--=============================================================================
-- Estado del módulo
--=============================================================================

local BedSystem = {}

local deps: Deps = {}
local respawnRadius: number = BED_RESPAWN_M
local cubeSize: number = CUBE_SIZE

-- Cama fijada por Jugador, indexada por userId (Req. 14.1). Una por Jugador.
local beds: { [number]: Bed } = {}

-- Jugadores cuyo respawn ÚNICO es su Cama (Req. 14.3), indexado por userId.
-- true significa "usar la Cama de este Jugador como respawn". La ausencia (o
-- false) significa "usar el spawn por defecto" (Req. 14.5).
local respawnBed: { [number]: boolean } = {}

--=============================================================================
-- Dependencias por defecto (motor de Roblox / DiggingSystem)
--=============================================================================

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

-- Comprobación de punto dentro de una caja AABB de Cueva (DiggingSystem.Cave).
local function pointInCave(p: Vector3, cave: DiggingSystem.Cave): boolean
	return p.X >= cave.min.X
		and p.X <= cave.max.X
		and p.Y >= cave.min.Y
		and p.Y <= cave.max.Y
		and p.Z >= cave.min.Z
		and p.Z <= cave.max.Z
end

--[[
	defaultIsInsideBaseOrCave — Valor por defecto del predicado de ubicación.
	Reconoce SOLO Cuevas registradas (consultando DiggingSystem.getCaves()), ya que
	el concepto de "base" no es todavía una entidad concreta del proyecto (ver
	supuestos de la cabecera). Inyecta un predicado propio para reconocer la base.
]]
local function defaultIsInsideBaseOrCave(position: Vector3): boolean
	for _, cave in DiggingSystem.getCaves() do
		if pointInCave(position, cave) then
			return true
		end
	end
	return false
end

--[[
	defaultIsValidBedLocation — Valor por defecto de la validación de superficie.
	Delega en `isInsideBaseOrCave` (inyectado o por defecto). Se puede inyectar una
	validación más estricta (normal/pendiente de la superficie, colisiones) sin
	cambiar la lógica de este sistema.
]]
local function defaultIsValidBedLocation(_player: Player, position: Vector3): boolean
	local insideCheck = deps.isInsideBaseOrCave or defaultIsInsideBaseOrCave
	return insideCheck(position)
end

-- Crea un Part anclado sencillo que representa la Cama fijada en el mundo.
local function defaultSpawnBedInstance(player: Player, position: Vector3): Instance?
	local bed = Instance.new("Part")
	bed.Name = "Cama_" .. tostring(player.UserId)
	bed.Anchored = true
	bed.CanCollide = true
	bed.Size = Vector3.new(cubeSize * 0.9, cubeSize * 0.4, cubeSize * 1.8)
	bed.Position = position
	bed.BrickColor = BrickColor.new("Reddish brown")
	bed.Material = Enum.Material.Fabric
	bed:SetAttribute("Bed", true)
	bed:SetAttribute("OwnerUserId", player.UserId)
	bed.Parent = Workspace
	return bed
end

--[[
	defaultFindWalkablePosition — Valor por defecto: ofrece una celda adyacente a
	`center` dentro de `radius`. No hace comprobación real de transitabilidad (eso
	depende del motor/navmesh); mantiene el desplazamiento acotado a `radius` para
	respetar el máximo de 2 m del Req. 14.4. Inyecta una versión con raycast/pathfind
	para una comprobación de transitabilidad real.
]]
local function defaultFindWalkablePosition(center: Vector3, radius: number): Vector3?
	-- Un paso lateral acotado por el radio (nunca supera `radius` metros).
	local step = math.min(radius, cubeSize)
	return center + Vector3.new(step, 0, 0)
end

-- Reaparición por defecto en `position`: mueve el HumanoidRootPart del personaje.
local function defaultRespawnAt(player: Player, position: Vector3)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		-- Eleva ligeramente para no incrustar el personaje en el suelo.
		root.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
	end
end

-- Reaparición en el spawn por defecto del Mundo: recarga el personaje, que Roblox
-- coloca en un SpawnLocation por defecto (Req. 14.5).
local function defaultRespawnDefault(player: Player)
	player:LoadCharacter()
end

--=============================================================================
-- Retroalimentación al cliente (canal S->C, Req. 14.2, 14.6, 14.7)
--=============================================================================

--[[
	sendBedState — Replica el estado de la Cama por StateUpdate. `phase` puede ser:
	  "placed"      -> Cama fijada correctamente (Req. 14.1)
	  "respawnSet"  -> Cama fijada como punto de reaparición (Req. 14.3)
	  "sleepFadeOut"-> oscurecer la pantalla al dormir (Req. 14.6)
	  "sleepFadeIn" -> restaurar la visibilidad tras avanzar al amanecer (Req. 14.6)
	  "rejected"    -> colocación/dormir rechazado, con `reason` (Req. 14.2, 14.7)
]]
local function sendBedState(player: Player, phase: string, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		kind = "bed",
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
-- Núcleo: colocar la Cama (Req. 14.1, 14.2)
--=============================================================================

--[[
	tryPlace — Procesa la intención de colocar la Cama en `position` (o frente al
	Jugador si no se da). Si la ubicación es válida (dentro de base/Cueva y sobre
	una superficie válida), fija la Cama y la mantiene hasta que se retire (14.1).
	Si no lo es, rechaza la colocación y envía retroalimentación visual (14.2).
]]
function BedSystem.tryPlace(player: Player, position: Vector3?): PlaceResult
	-- Resuelve la posición objetivo: la dada, o frente al Jugador si falta.
	local target: Vector3? = nil
	if typeof(position) == "Vector3" then
		target = position :: Vector3
	else
		local getPos = deps.getPlayerPosition or defaultGetPlayerPosition
		target = getPos(player)
	end

	if target == nil then
		sendBedState(player, "rejected", { reason = "badTarget", action = "place" })
		return { ok = false, reason = "badTarget" }
	end
	local pos: Vector3 = target :: Vector3

	-- Validación de ubicación (Req. 14.1, 14.2).
	local isValid = deps.isValidBedLocation or defaultIsValidBedLocation
	if not isValid(player, pos) then
		-- No se fija la Cama; retroalimentación visual de ubicación no válida.
		sendBedState(player, "rejected", { reason = REASON_INVALID_LOCATION, action = "place" })
		return { ok = false, reason = "invalidLocation" }
	end

	-- Retira una Cama previa del mismo Jugador antes de fijar la nueva.
	BedSystem.removeBed(player)

	-- Crea/rastrea la Cama fijada.
	local spawnBed = deps.spawnBedInstance or defaultSpawnBedInstance
	local instance = spawnBed(player, pos)

	local bed: Bed = {
		userId = player.UserId,
		position = pos,
		instance = instance,
		placedAt = os.clock(),
	}
	beds[player.UserId] = bed

	sendBedState(player, "placed", { position = pos })
	return { ok = true, position = pos }
end

--[[
	removeBed — Retira la Cama fijada del Jugador (Req. 14.1: "hasta que la retire").
	Destruye la Instance física si existe y limpia el estado de respawn asociado, de
	modo que morir tras retirar la Cama reaparezca en el spawn por defecto (14.5).
	Devuelve true si existía una Cama y se retiró.
]]
function BedSystem.removeBed(player: Player): boolean
	local bed = beds[player.UserId]
	if bed == nil then
		return false
	end
	if bed.instance then
		(bed.instance :: Instance):Destroy()
	end
	beds[player.UserId] = nil
	respawnBed[player.UserId] = nil
	return true
end

--=============================================================================
-- Núcleo: fijar el punto de reaparición (Req. 14.3)
--=============================================================================

--[[
	trySetRespawn — Interactuar con una Cama fijada la establece como punto de
	reaparición ÚNICO del Jugador, reemplazando cualquier punto previo (Req. 14.3).
	Solo es válido si el Jugador tiene una Cama fijada.
]]
function BedSystem.trySetRespawn(player: Player): SetRespawnResult
	local bed = beds[player.UserId]
	if bed == nil then
		sendBedState(player, "rejected", { reason = REASON_NO_BED, action = "setRespawn" })
		return { ok = false, reason = "noBed" }
	end

	-- Único punto de reaparición: reemplaza cualquiera anterior (Req. 14.3).
	respawnBed[player.UserId] = true

	sendBedState(player, "respawnSet", { position = bed.position })
	return { ok = true }
end

--=============================================================================
-- Reaparición al morir (Req. 14.4, 14.5)
--=============================================================================

-- ¿Sigue viva la Instance de la Cama en el mundo? Una Cama cuya Instance fue
-- destruida (retirada) deja de ser un respawn válido (Req. 14.5).
local function bedInstanceAlive(bed: Bed): boolean
	local instance = bed.instance
	if instance == nil then
		-- Sin Instance de motor (p. ej. pruebas): se considera viva mientras el
		-- registro exista.
		return true
	end
	return (instance :: Instance).Parent ~= nil
end

--[[
	getRespawnPosition — Devuelve la posición transitable a <= 2 m de la Cama donde
	reaparecería el Jugador (Req. 14.4), o `nil` si NO hay una Cama de respawn válida
	(sin Cama fijada, sin respawn establecido, o Cama retirada/destruida), en cuyo
	caso el flujo de muerte debe usar el spawn por defecto (Req. 14.5).
]]
function BedSystem.getRespawnPosition(player: Player): Vector3?
	if not respawnBed[player.UserId] then
		return nil
	end
	local bed = beds[player.UserId]
	if bed == nil or not bedInstanceAlive(bed) then
		return nil
	end

	local findWalkable = deps.findWalkablePosition or defaultFindWalkablePosition
	local spot = findWalkable(bed.position, respawnRadius)
	if spot == nil then
		-- Sin punto transitable adyacente: cae sobre la propia posición de la Cama.
		return bed.position
	end

	-- Garantía dura del Req. 14.4: nunca a más de `respawnRadius` (2 m) de la Cama.
	local offset = spot - bed.position
	if offset.Magnitude > respawnRadius then
		if offset.Magnitude > 0 then
			spot = bed.position + offset.Unit * respawnRadius
		else
			spot = bed.position
		end
	end
	return spot
end

--[[
	handleDeath — Hook que el flujo de muerte del juego (NeedsSystem/GameServer)
	invoca cuando el Jugador muere. Reaparece al Jugador junto a su Cama de respawn
	(Req. 14.4) o, si no hay una válida, en el spawn por defecto del Mundo (14.5).
	El teletransporte efectivo se delega en `deps.respawnAt` / `deps.respawnDefault`.

	Devuelve la posición usada (o nil si se reapareció en el spawn por defecto).
]]
function BedSystem.handleDeath(player: Player): Vector3?
	local position = BedSystem.getRespawnPosition(player)
	if position ~= nil then
		local respawnAt = deps.respawnAt or defaultRespawnAt
		respawnAt(player, position)
		return position
	end

	-- Sin Cama de respawn válida: spawn por defecto (Req. 14.5).
	local respawnDefault = deps.respawnDefault or defaultRespawnDefault
	respawnDefault(player)
	return nil
end

--=============================================================================
-- Núcleo: dormir (Req. 14.6, 14.7)
--=============================================================================

--[[
	trySleep — Procesa la intención de acostarse en la Cama. Requiere una Cama
	fijada del Jugador. Si es de noche (Req. 14.6): envía la señal de oscurecer la
	pantalla, avanza el tiempo hasta el amanecer y restaura la visibilidad. Si NO es
	de noche (Req. 14.7): rechaza con retroalimentación "solo puedes dormir de noche"
	y no acelera el tiempo.

	La temporización visual (oscurecer <= 1 s, avanzar <= 3 s reales) es del cliente,
	que la anima al recibir las fases por StateUpdate; el servidor es la autoridad
	que decide si se puede dormir y avanza el tiempo (deps.advanceToDawn).
]]
function BedSystem.trySleep(player: Player): SleepResult
	-- Debe haber una Cama fijada para acostarse.
	if beds[player.UserId] == nil then
		sendBedState(player, "rejected", { reason = REASON_NO_BED, action = "sleep" })
		return { ok = false, reason = "noBed" }
	end

	-- Solo de noche (Req. 14.7).
	local isNight = deps.isNight or function()
		return false
	end
	if not isNight() then
		sendBedState(player, "rejected", { reason = REASON_ONLY_AT_NIGHT, action = "sleep" })
		return { ok = false, reason = "notNight" }
	end

	-- Es de noche: oscurecer, avanzar al amanecer y restaurar (Req. 14.6).
	sendBedState(player, "sleepFadeOut", {})

	local advanceToDawn = deps.advanceToDawn or function() end
	advanceToDawn()

	sendBedState(player, "sleepFadeIn", {})
	return { ok = true }
end

--=============================================================================
-- Consultas públicas (inspección / pruebas)
--=============================================================================

-- getBed — Cama fijada de un Jugador (o nil).
function BedSystem.getBed(player: Player): Bed?
	return beds[player.UserId]
end

-- hasRespawnBed — ¿Tiene el Jugador su Cama fijada como punto de reaparición?
function BedSystem.hasRespawnBed(player: Player): boolean
	return respawnBed[player.UserId] == true and beds[player.UserId] ~= nil
end

--=============================================================================
-- Enrutado del RemoteEvent BedAction (C->S)
--=============================================================================

--[[
	onBedAction — Handler de `Remotes.BedAction`. Admite un payload de tabla con
	`kind`:
	  { kind = "place",      position = Vector3? }  -> colocar Cama (14.1/14.2)
	  { kind = "setRespawn" | "interact" }          -> fijar respawn (14.3)
	  { kind = "sleep" }                             -> dormir (14.6/14.7)
	Compatibilidad: un Vector3 suelto se trata como colocación de la Cama.
]]
local function onBedAction(player: Player, payload: any)
	-- Compatibilidad: Vector3 suelto => colocar Cama.
	if typeof(payload) == "Vector3" then
		BedSystem.tryPlace(player, payload :: Vector3)
		return
	end

	if type(payload) ~= "table" then
		return
	end

	local kind = payload.kind
	if kind == "place" then
		BedSystem.tryPlace(player, payload.position)
	elseif kind == "setRespawn" or kind == "interact" then
		BedSystem.trySetRespawn(player)
	elseif kind == "sleep" then
		BedSystem.trySleep(player)
	end
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

local bedConnection: RBXScriptConnection? = nil

--[[
	init — Inicializa el sistema con sus dependencias y conecta el handler a
	`Remotes.BedAction`. Idempotente: reconectar reemplaza las dependencias sin
	duplicar conexiones (usa una única conexión almacenada).
]]
function BedSystem.init(injected: Deps?)
	deps = injected or {}
	respawnRadius = deps.respawnRadius or BED_RESPAWN_M
	cubeSize = deps.cubeSize or CUBE_SIZE

	if not bedConnection then
		bedConnection = Remotes.BedAction.OnServerEvent:Connect(function(player: Player, ...)
			local payload = (...)
			onBedAction(player, payload)
		end)
	end

	return BedSystem
end

--[[
	shutdown — Desconecta el handler y limpia el estado. Útil para pruebas o
	reinicios controlados. No destruye las Instances físicas ya creadas.
]]
function BedSystem.shutdown()
	if bedConnection then
		bedConnection:Disconnect()
		bedConnection = nil
	end
	beds = {}
	respawnBed = {}
end

return BedSystem
