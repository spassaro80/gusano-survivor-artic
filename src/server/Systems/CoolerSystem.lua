--!strict
--[[
	CoolerSystem.lua — Sistema de servidor AUTORITATIVO de la Neverita Portátil.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es "pegamento" del motor de Roblox que
	envuelve el modelo PURO `CoolerModel`: mantiene el estado autoritativo de la
	Neverita por Jugador, aplica las reglas puras y replica el contador al HUD por
	`Remotes.StateUpdate`. Toda la aritmética de capacidad vive en `CoolerModel`;
	este sistema solo aporta identidad de Jugador, enrutado de eventos y efectos.

	Responsabilidades (Requisitos 10.1–10.6):
	  - 10.1: Cuando el Jugador recoge un Pez, este se enruta EXCLUSIVAMENTE a la
	          Neverita, no al inventario normal. `CoolerSystem.addFish(player)` es el
	          único destino de un Pez recogido; el llamador (GameServer/pickup) no
	          debe añadirlo al inventario.
	  - 10.2: La Neverita tiene capacidad máxima `Constants.COOLER.CAPACITY` (30).
	  - 10.3: Añadir un Pez incrementa el contador en 1 mientras `count < 30`
	          (vía `CoolerModel.add`).
	  - 10.4: Si se intenta recoger/añadir un Pez con la Neverita ya llena (30), se
	          RECHAZA: el contador se mantiene en 30, el Pez queda en el mundo y se
	          envía un aviso de "Neverita llena" por `StateUpdate` que el HUD muestra
	          durante >= 3 s (se envía una vez con un hint de duración; el cliente
	          controla el tiempo de visualización).
	  - 10.5: Retirar un Pez extrae EXACTAMENTE 1 por operación (decrementa en 1),
	          vía `CoolerModel.remove`.
	  - 10.6: Mientras la Neverita está abierta, el contador actual (0..30) se
	          expone para el HUD: hay un getter `getCount(player)` y se empuja por
	          `StateUpdate` en cada cambio y al abrir.

	Diseño (servidor autoritativo, ver design.md): el cliente solo envía intención;
	el servidor valida y aplica la lógica pura antes de tocar el estado, y replica
	la retroalimentación por `Remotes.StateUpdate`. El estado real de la Neverita
	(el `Cooler` inmutable) reside aquí, no en el cliente.

	Acoplamiento limpio: NO se depende de forma dura de otros sistemas. La identidad
	del Jugador y el evento de recogida de Pez se cablean por `init(deps)`, de modo
	que GameServer puede inyectarlos sin imponer orden de carga. Todas las
	dependencias tienen valores por defecto razonables basados en el motor.

	Supuestos documentados:
	  - Un Jugador tiene UNA Neverita (el kit inicial incluye 1). El estado se
	    indexa por `player.UserId`.
	  - La duración del aviso de "Neverita llena" (>= 3 s, Req. 10.4) la controla el
	    HUD; el servidor solo envía el mensaje una vez con `minDurationSeconds = 3`.
	  - "Retirar" un Pez (Req. 10.5) es una operación lógica sobre el contador; la
	    materialización del Pez en el mundo (si aplica) la resuelve el llamador
	    mediante la dependencia opcional `depositFish`.
	  - El contador persistido (`SaveData.coolerFish`) lo gestiona SaveSystem; este
	    sistema expone `setCount`/`getCount` para que GameServer sincronice la carga.

	Requisitos cubiertos: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoolerModel = require(ReplicatedStorage.Shared.CoolerModel)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes)

type Cooler = Types.Cooler

--=============================================================================
-- Tipos
--=============================================================================

-- Dependencias inyectables. Todas son opcionales y tienen un valor por defecto
-- razonable; se inyectan por `init(deps)` para bajo acoplamiento con GameServer.
export type Deps = {
	-- Deposita EXACTAMENTE 1 Pez como objeto físico en el mundo cuando se retira
	-- de la Neverita (Req. 10.5). Opcional: si falta, la retirada es solo lógica.
	depositFish: ((player: Player, cooler: Cooler) -> Instance?)?,
	-- Duración mínima (segundos) del aviso de "Neverita llena" en el HUD (Req. 10.4).
	fullMessageMinSeconds: number?,
}

-- Resultado de añadir un Pez a la Neverita (Req. 10.3, 10.4).
export type AddResult = {
	ok: boolean,
	count: number,
	reason: string?, -- "full" cuando se rechaza por Neverita llena (Req. 10.4)
}

-- Resultado de retirar un Pez de la Neverita (Req. 10.5).
export type RemoveResult = {
	ok: boolean,
	count: number,
	reason: string?, -- "empty" cuando no hay Peces que retirar
}

--=============================================================================
-- Constantes locales
--=============================================================================

-- Capacidad máxima de la Neverita (Req. 10.2). Se lee del balance global.
local CAPACITY: number = Constants.COOLER.CAPACITY
-- Duración mínima por defecto del aviso "Neverita llena" en el HUD (Req. 10.4).
local DEFAULT_FULL_MESSAGE_SECONDS: number = 3

--=============================================================================
-- Estado del módulo
--=============================================================================

local CoolerSystem = {}

local deps: Deps = {}
local fullMessageMinSeconds: number = DEFAULT_FULL_MESSAGE_SECONDS

-- Estado autoritativo de la Neverita por Jugador, indexado por userId. Cada
-- valor es un `Cooler` inmutable ({ count = 0..30 }) tal y como lo produce
-- CoolerModel (se reemplaza, nunca se muta en sitio).
local coolers: { [number]: Cooler } = {}

--=============================================================================
-- Utilidades de estado
--=============================================================================

-- ensureCooler — Devuelve el Cooler del Jugador, creándolo en 0 si no existía
-- (Req. 10.1: la Neverita arranca vacía).
local function ensureCooler(userId: number): Cooler
	local cooler = coolers[userId]
	if cooler == nil then
		cooler = { count = 0 }
		coolers[userId] = cooler
	end
	return cooler
end

--=============================================================================
-- Retroalimentación al cliente (contador del HUD y avisos, Req. 10.4, 10.6)
--=============================================================================

--[[
	pushCount — Empuja el contador actual de la Neverita (0..30) al HUD por
	StateUpdate (canal S->C). Se llama en cada cambio y al abrir la Neverita
	(Req. 10.6).
]]
local function pushCount(player: Player, cooler: Cooler)
	Remotes.StateUpdate:FireClient(player, {
		kind = "cooler",
		phase = "count",
		count = cooler.count,
		capacity = CAPACITY,
	})
end

--[[
	sendFullMessage — Envía el aviso de "Neverita llena" (Req. 10.4). Incluye un
	hint de duración mínima (`minDurationSeconds`) para que el HUD lo muestre
	durante >= 3 s. Se envía una sola vez por rechazo; el cliente controla el
	tiempo de visualización.
]]
local function sendFullMessage(player: Player)
	Remotes.StateUpdate:FireClient(player, {
		kind = "cooler",
		phase = "full",
		count = CAPACITY,
		capacity = CAPACITY,
		message = "Neverita llena",
		minDurationSeconds = fullMessageMinSeconds,
	})
end

--=============================================================================
-- Núcleo: añadir un Pez (Req. 10.1, 10.2, 10.3, 10.4)
--=============================================================================

--[[
	addFish — Enruta un Pez recogido a la Neverita del Jugador (Req. 10.1). Usa
	`CoolerModel.add`: si `count < 30` incrementa en 1 y devuelve ok=true; si la
	Neverita está llena (30), rechaza (Req. 10.4): el contador se mantiene en 30, el
	Pez debe quedar en el mundo (responsabilidad del llamador) y se envía el aviso
	de "Neverita llena" al HUD. Empuja el contador actualizado al HUD (Req. 10.6).
]]
function CoolerSystem.addFish(player: Player): boolean
	local userId = player.UserId
	local cooler = ensureCooler(userId)

	local newCooler, ok = CoolerModel.add(cooler)
	coolers[userId] = newCooler

	if not ok then
		-- Neverita llena: el Pez permanece en el mundo (no se añade al inventario
		-- ni a la Neverita) y se avisa al HUD (Req. 10.4).
		sendFullMessage(player)
		pushCount(player, newCooler)
		return false
	end

	-- Pez almacenado en la Neverita (Req. 10.3). Se refleja en el HUD (Req. 10.6).
	pushCount(player, newCooler)
	return true
end

--=============================================================================
-- Núcleo: retirar un Pez (Req. 10.5)
--=============================================================================

--[[
	removeFish — Extrae EXACTAMENTE 1 Pez de la Neverita (Req. 10.5). Usa
	`CoolerModel.remove`: si `count > 0` decrementa en 1 y devuelve ok=true; si está
	vacía, no cambia nada y devuelve ok=false. Si se inyectó `depositFish`, se
	materializa 1 Pez en el mundo. Empuja el contador actualizado al HUD (Req. 10.6).
]]
function CoolerSystem.removeFish(player: Player): boolean
	local userId = player.UserId
	local cooler = ensureCooler(userId)

	local newCooler, ok = CoolerModel.remove(cooler)
	coolers[userId] = newCooler

	if not ok then
		-- Neverita vacía: nada que retirar.
		pushCount(player, newCooler)
		return false
	end

	-- Materializa 1 Pez en el mundo si el llamador inyectó el efecto (Req. 10.5).
	local depositFish = deps.depositFish
	if depositFish then
		depositFish(player, newCooler)
	end

	pushCount(player, newCooler)
	return true
end

--=============================================================================
-- Consultas y sincronización públicas (HUD, carga, pruebas)
--=============================================================================

--[[
	getCount — Contador actual de la Neverita del Jugador (0..30). Getter para el
	HUD (Req. 10.6). Un Jugador sin Neverita registrada aún devuelve 0.
]]
function CoolerSystem.getCount(player: Player): number
	local cooler = coolers[player.UserId]
	return cooler and cooler.count or 0
end

--[[
	isFull — ¿La Neverita del Jugador está llena (count >= 30)? Delega en el modelo
	puro `CoolerModel.isFull` (Req. 10.2, 10.4).
]]
function CoolerSystem.isFull(player: Player): boolean
	return CoolerModel.isFull(ensureCooler(player.UserId))
end

--[[
	openCooler — Señala que el Jugador abre la Neverita: empuja el contador actual
	al HUD para que muestre 0..30 (Req. 10.6).
]]
function CoolerSystem.openCooler(player: Player)
	pushCount(player, ensureCooler(player.UserId))
end

--[[
	setCount — Fija el contador de la Neverita a un valor concreto, saturado al
	rango [0, 30]. Lo usa GameServer/SaveSystem para restaurar el estado persistido
	(`SaveData.coolerFish`) al entrar el Jugador. Empuja el contador al HUD.
]]
function CoolerSystem.setCount(player: Player, count: number)
	local clamped = math.clamp(math.floor(count), 0, CAPACITY)
	local cooler: Cooler = { count = clamped }
	coolers[player.UserId] = cooler
	pushCount(player, cooler)
end

--[[
	clearPlayer — Elimina el estado de la Neverita del Jugador (al salir). Evita
	fugas de estado entre sesiones.
]]
function CoolerSystem.clearPlayer(player: Player)
	coolers[player.UserId] = nil
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

--[[
	init — Inicializa el sistema con sus dependencias inyectables. Idempotente:
	reinvocarlo reemplaza las dependencias sin duplicar estado ni conexiones. Este
	sistema no conecta ningún RemoteEvent propio (la recogida de Pez la enruta
	GameServer llamando a `addFish`); si en el futuro se enrutara un Remote aquí, la
	conexión se guardaría en una única variable para mantener la idempotencia.
]]
function CoolerSystem.init(injected: Deps?)
	deps = injected or {}
	fullMessageMinSeconds = deps.fullMessageMinSeconds or DEFAULT_FULL_MESSAGE_SECONDS
	return CoolerSystem
end

--[[
	shutdown — Limpia todo el estado. Útil para pruebas o reinicios controlados.
]]
function CoolerSystem.shutdown()
	coolers = {}
	deps = {}
	fullMessageMinSeconds = DEFAULT_FULL_MESSAGE_SECONDS
end

return CoolerSystem
