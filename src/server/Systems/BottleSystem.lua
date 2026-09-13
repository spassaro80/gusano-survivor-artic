--!strict
--[[
	BottleSystem.lua — Sistema de servidor AUTORITATIVO de la Botella de Agua.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es la única autoridad sobre las
	acciones de la Botella de Agua del Jugador: beber y rellenar. Envuelve el
	modelo PURO `BottleModel` (que no depende del motor) y aplica sus resultados
	sobre el estado autoritativo del Jugador, que es propiedad de PlayerState
	(construido más adelante por GameServer) y se accede mediante dependencias
	inyectables.

	Responsabilidades (Requisitos 11.1–11.7):
	  - 11.1: Beber con la Botella no vacía aumenta la Sed en +40 (sin superar 100,
	          el clamp lo garantiza el modelo puro) en <= 500 ms. El servidor lo
	          resuelve de forma síncrona (inmediata), muy por debajo de 500 ms.
	  - 11.2: La suma de Sed + 40 se fija en 100 como máximo (clamp del modelo).
	  - 11.3: Al beber, la Botella pasa al estado "Empty" (Vacía).
	  - 11.4: Beber con la Botella vacía no cambia la Sed y envía una señal de
	          "botella vacía" por `Remotes.StateUpdate`.
	  - 11.5: Con la Botella vacía y a <= 2 m de un Agujero_Agua, se debe mostrar la
	          acción "Rellenar Botella". Se provee un ayudante de consulta
	          (`canRefill` / `getRefillPrompt`) que GameServer/HUD pueden usar.
	  - 11.6: Con la Botella vacía y a > 2 m de todo Agujero_Agua, la acción
	          "Rellenar Botella" debe ocultarse (el mismo ayudante lo indica).
	  - 11.7: Rellenar deja la Botella en estado "Full" (Llena), habilitada para
	          restaurar 40 puntos de Sed al beber.

	Diseño (servidor autoritativo, ver design.md): el cliente solo envía intención
	por `Remotes.ConsumeAction`; el servidor valida herramienta (Botella equipada) y
	estado antes de tocar el estado, aplica la lógica PURA de `BottleModel` y replica
	la retroalimentación por `Remotes.StateUpdate`. Ninguna validación de éxito
	ocurre en el cliente.

	Propiedad del estado (bajo acoplamiento):
	  - Las necesidades (`Needs`) y la Botella (`Bottle`) son propiedad de
	    PlayerState, que GameServer construye más adelante. Este sistema NO posee
	    ese estado: lo lee y lo escribe mediante las dependencias inyectadas por
	    `init(deps)` (`getPlayerNeeds`/`setPlayerNeeds`,
	    `getPlayerBottle`/`setPlayerBottle`).
	  - Los Agujeros_Agua son propiedad de WorldSystem/FishingSystem. Para no acoplar
	    de forma dura con ellos, la distancia al Agujero_Agua más cercano se consulta
	    mediante `deps.getNearestWaterHoleDistance(player) -> number?` inyectada.
	  Todas las dependencias tienen valores por defecto razonables y documentados,
	  de modo que el sistema arranca y se prueba sin depender del orden de carga.

	Requisitos cubiertos: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local BottleModel = require(ReplicatedStorage.Shared.BottleModel)

type Bottle = Types.Bottle
type Needs = Types.Needs

--=============================================================================
-- Constantes
--=============================================================================

-- Nombre de la Herramienta que debe estar equipada para beber/rellenar (Req. 11.1).
local BOTTLE_TOOL_NAME = "Botella de Agua"
-- Distancia máxima (metros/studs) para poder rellenar junto a un Agujero_Agua.
local REFILL_DISTANCE_M: number = Constants.INTERACTION.REFILL_BOTTLE_M
-- Etiqueta de la acción de rellenado que muestra/oculta el HUD (Req. 11.5, 11.6).
local REFILL_ACTION_LABEL = "Rellenar Botella"

--=============================================================================
-- Tipos
--=============================================================================

-- Dependencias inyectables. Todas tienen un valor por defecto razonable, de forma
-- que el sistema puede arrancar y probarse de manera aislada. En producción,
-- GameServer inyecta accesores reales al PlayerState y a WorldSystem/FishingSystem.
export type Deps = {
	-- Devuelve las Necesidades actuales del Jugador (propiedad de PlayerState).
	getPlayerNeeds: ((player: Player) -> Needs?)?,
	-- Persiste las nuevas Necesidades del Jugador tras beber (propiedad de PlayerState).
	setPlayerNeeds: ((player: Player, needs: Needs) -> ())?,
	-- Devuelve el estado actual de la Botella del Jugador (propiedad de PlayerState).
	getPlayerBottle: ((player: Player) -> Bottle?)?,
	-- Persiste el nuevo estado de la Botella del Jugador (propiedad de PlayerState).
	setPlayerBottle: ((player: Player, bottle: Bottle) -> ())?,
	-- Herramienta equipada por el Jugador (se valida "Botella de Agua", Req. 11.1).
	getEquippedTool: ((player: Player) -> string?)?,
	-- Distancia (studs) al Agujero_Agua más cercano, o nil si no hay ninguno.
	-- La proveen WorldSystem/FishingSystem; inyectada para bajo acoplamiento (11.5, 11.6).
	getNearestWaterHoleDistance: ((player: Player) -> number?)?,
}

-- Resultado de beber (Req. 11.1, 11.2, 11.3, 11.4).
export type DrinkResult = {
	ok: boolean, -- true si se bebió (Botella llena); false en caso contrario.
	reason: string?, -- "noBottleEquipped" | "noState" | "bottleEmpty"
	needs: Needs?, -- Necesidades resultantes (con la Sed clampada a 100).
	bottle: Bottle?, -- Estado de la Botella resultante ("Empty" tras beber).
}

-- Resultado de rellenar (Req. 11.5, 11.6, 11.7).
export type RefillResult = {
	ok: boolean, -- true si se rellenó (Botella -> "Full").
	reason: string?, -- "noBottleEquipped" | "noState" | "tooFar" | "noWaterHole"
	bottle: Bottle?, -- Estado de la Botella resultante ("Full" si ok).
}

-- Estado de la acción "Rellenar Botella" para el HUD (Req. 11.5, 11.6).
export type RefillPrompt = {
	visible: boolean, -- true => mostrar la acción; false => ocultarla.
	label: string, -- Etiqueta a mostrar ("Rellenar Botella").
	distance: number?, -- Distancia al Agujero_Agua más cercano (informativo).
}

--=============================================================================
-- Estado del módulo
--=============================================================================

local BottleSystem = {}

local deps: Deps = {}

--=============================================================================
-- Dependencias por defecto (fallbacks documentados)
--=============================================================================

-- getEquippedTool por defecto: lee la Tool equipada del Character en Workspace.
local function defaultGetEquippedTool(player: Player): string?
	local character = player.Character
	if not character then
		return nil
	end
	local tool = character:FindFirstChildOfClass("Tool")
	return tool and tool.Name or nil
end

-- Almacén interno de respaldo para Needs/Bottle por userId. Solo se usa si
-- GameServer NO inyecta accesores de PlayerState (útil en pruebas aisladas). NO es
-- la fuente de verdad en producción: PlayerState lo es.
local fallbackNeeds: { [number]: Needs } = {}
local fallbackBottles: { [number]: Bottle } = {}

-- Needs por defecto si no hay estado previo ni inyección (todo al máximo).
local function makeDefaultNeeds(): Needs
	local maxV = Constants.NEEDS.MAX
	return { warmth = maxV, hunger = maxV, thirst = maxV, health = maxV }
end

local function defaultGetPlayerNeeds(player: Player): Needs?
	local existing = fallbackNeeds[player.UserId]
	if existing == nil then
		existing = makeDefaultNeeds()
		fallbackNeeds[player.UserId] = existing
	end
	return existing
end

local function defaultSetPlayerNeeds(player: Player, needs: Needs): ()
	fallbackNeeds[player.UserId] = needs
end

-- Botella por defecto: llena (el kit inicial arranca al 100%, Req. 3.4).
local function defaultGetPlayerBottle(player: Player): Bottle?
	local existing = fallbackBottles[player.UserId]
	if existing == nil then
		existing = { state = "Full" }
		fallbackBottles[player.UserId] = existing
	end
	return existing
end

local function defaultSetPlayerBottle(player: Player, bottle: Bottle): ()
	fallbackBottles[player.UserId] = bottle
end

-- getNearestWaterHoleDistance por defecto: sin fuente de Agujeros_Agua inyectada,
-- se devuelve nil (no hay ninguno conocido), por lo que la acción de rellenado
-- permanece oculta hasta que GameServer inyecte la consulta real (Req. 11.5, 11.6).
local function defaultGetNearestWaterHoleDistance(_player: Player): number?
	return nil
end

--=============================================================================
-- Resolutores de dependencias (aplican el fallback si falta la inyección)
--=============================================================================

local function resolveGetEquippedTool(): (player: Player) -> string?
	return deps.getEquippedTool or defaultGetEquippedTool
end

local function resolveGetPlayerNeeds(): (player: Player) -> Needs?
	return deps.getPlayerNeeds or defaultGetPlayerNeeds
end

local function resolveSetPlayerNeeds(): (player: Player, needs: Needs) -> ()
	return deps.setPlayerNeeds or defaultSetPlayerNeeds
end

local function resolveGetPlayerBottle(): (player: Player) -> Bottle?
	return deps.getPlayerBottle or defaultGetPlayerBottle
end

local function resolveSetPlayerBottle(): (player: Player, bottle: Bottle) -> ()
	return deps.setPlayerBottle or defaultSetPlayerBottle
end

local function resolveGetNearestWaterHoleDistance(): (player: Player) -> number?
	return deps.getNearestWaterHoleDistance or defaultGetNearestWaterHoleDistance
end

--=============================================================================
-- Retroalimentación al cliente (canal S->C por StateUpdate)
--=============================================================================

--[[
	sendBottleState — Replica el estado de la Botella del Jugador por StateUpdate.
	`event` puede ser:
	  "drank"      -> se bebió: incluye needs y bottle (Req. 11.1, 11.3)
	  "bottleEmpty"-> intento de beber con Botella vacía (Req. 11.4)
	  "refilled"   -> Botella rellenada a "Full" (Req. 11.7)
	  "refillPrompt"-> mostrar/ocultar la acción "Rellenar Botella" (Req. 11.5, 11.6)
	  "rejected"   -> intento rechazado (con motivo)
]]
local function sendBottleState(player: Player, event: string, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		kind = "bottle",
		event = event,
	}
	if extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	Remotes.StateUpdate:FireClient(player, payload)
end

--=============================================================================
-- Consulta de la acción "Rellenar Botella" (Req. 11.5, 11.6)
--=============================================================================

--[[
	getRefillPrompt — Ayudante de consulta que GameServer/HUD pueden usar para
	decidir si mostrar u ocultar la acción "Rellenar Botella". La acción se muestra
	SOLO cuando (Req. 11.5, 11.6):
	  - la Botella del Jugador está vacía ("Empty"), y
	  - existe un Agujero_Agua a una distancia <= 2 m (REFILL_BOTTLE_M).
	No muta ningún estado; es una consulta pura de presentación.
]]
function BottleSystem.getRefillPrompt(player: Player): RefillPrompt
	local getBottle = resolveGetPlayerBottle()
	local bottle = getBottle(player)

	-- Con la Botella llena (o sin estado conocido) no aplica rellenar.
	if bottle == nil or bottle.state ~= "Empty" then
		return { visible = false, label = REFILL_ACTION_LABEL, distance = nil }
	end

	local getDistance = resolveGetNearestWaterHoleDistance()
	local distance = getDistance(player)

	-- Sin Agujero_Agua conocido => ocultar (Req. 11.6).
	if distance == nil then
		return { visible = false, label = REFILL_ACTION_LABEL, distance = nil }
	end

	local visible = distance <= REFILL_DISTANCE_M
	return { visible = visible, label = REFILL_ACTION_LABEL, distance = distance }
end

--[[
	canRefill — Azúcar booleana sobre getRefillPrompt: ¿debe mostrarse (y por tanto
	permitirse) la acción "Rellenar Botella" ahora mismo para este Jugador?
	(Req. 11.5, 11.6)
]]
function BottleSystem.canRefill(player: Player): boolean
	return BottleSystem.getRefillPrompt(player).visible
end

--=============================================================================
-- Núcleo: beber (Req. 11.1, 11.2, 11.3, 11.4)
--=============================================================================

--[[
	tryDrink — Procesa la intención de beber. Valida en el servidor (Botella
	equipada y estado disponible), aplica la lógica PURA de `BottleModel.drink` y
	persiste el resultado en PlayerState mediante las dependencias.

	Comportamiento:
	  - Botella "Full": +40 Sed (clamp a 100 por el modelo), Botella -> "Empty",
	    ok=true (Req. 11.1, 11.2, 11.3).
	  - Botella "Empty": Sed sin cambios, ok=false y señal de "botella vacía"
	    por StateUpdate (Req. 11.4).
	  - Sin Botella equipada o sin estado: se rechaza sin tocar el estado.
]]
function BottleSystem.tryDrink(player: Player): DrinkResult
	-- Validación de servidor: Botella equipada (Req. 11.1).
	local getTool = resolveGetEquippedTool()
	if getTool(player) ~= BOTTLE_TOOL_NAME then
		return { ok = false, reason = "noBottleEquipped" }
	end

	-- Estado autoritativo (propiedad de PlayerState).
	local getBottle = resolveGetPlayerBottle()
	local getNeeds = resolveGetPlayerNeeds()
	local bottle = getBottle(player)
	local needs = getNeeds(player)
	if bottle == nil or needs == nil then
		return { ok = false, reason = "noState" }
	end

	-- Lógica PURA: decide el resultado (clamp de Sed a 100 incluido).
	local newBottle, newNeeds, ok = BottleModel.drink(bottle, needs)

	if not ok then
		-- Botella vacía: nada cambia; señal de "botella vacía" (Req. 11.4).
		sendBottleState(player, "bottleEmpty", {})
		return { ok = false, reason = "bottleEmpty", needs = newNeeds, bottle = newBottle }
	end

	-- Persiste el estado nuevo en PlayerState (Req. 11.1, 11.3).
	local setBottle = resolveSetPlayerBottle()
	local setNeeds = resolveSetPlayerNeeds()
	setNeeds(player, newNeeds)
	setBottle(player, newBottle)

	-- Replica al cliente el estado confirmado por el servidor.
	sendBottleState(player, "drank", { thirst = newNeeds.thirst, bottle = newBottle.state })

	return { ok = true, needs = newNeeds, bottle = newBottle }
end

--=============================================================================
-- Núcleo: rellenar (Req. 11.5, 11.6, 11.7)
--=============================================================================

--[[
	tryRefill — Procesa la intención de rellenar la Botella junto a un Agujero_Agua.
	Valida en el servidor:
	  - Botella equipada (Req. 11.1 aplicada al mismo criterio de herramienta).
	  - Estado disponible en PlayerState.
	  - Existe un Agujero_Agua a <= 2 m (REFILL_BOTTLE_M) (Req. 11.6).
	Si todo es válido, aplica `BottleModel.refill` (Botella -> "Full", Req. 11.7) y
	persiste el resultado.
]]
function BottleSystem.tryRefill(player: Player): RefillResult
	-- Validación de servidor: Botella equipada.
	local getTool = resolveGetEquippedTool()
	if getTool(player) ~= BOTTLE_TOOL_NAME then
		return { ok = false, reason = "noBottleEquipped" }
	end

	local getBottle = resolveGetPlayerBottle()
	local bottle = getBottle(player)
	if bottle == nil then
		return { ok = false, reason = "noState" }
	end

	-- Debe haber un Agujero_Agua a <= 2 m (Req. 11.6). La consulta se inyecta.
	local getDistance = resolveGetNearestWaterHoleDistance()
	local distance = getDistance(player)
	if distance == nil then
		return { ok = false, reason = "noWaterHole" }
	end
	if distance > REFILL_DISTANCE_M then
		return { ok = false, reason = "tooFar" }
	end

	-- Lógica PURA: la Botella pasa a "Full" (Req. 11.7).
	local newBottle = BottleModel.refill(bottle)

	local setBottle = resolveSetPlayerBottle()
	setBottle(player, newBottle)

	sendBottleState(player, "refilled", { bottle = newBottle.state })

	return { ok = true, bottle = newBottle }
end

--=============================================================================
-- Enrutado del RemoteEvent ConsumeAction (C->S)
--=============================================================================

--[[
	onConsumeAction — Handler de `Remotes.ConsumeAction`. `ConsumeAction` cubre
	beber, comer pez y rellenar botella (ver design.md). Este sistema atiende SOLO
	las acciones de la Botella, identificadas por `kind`:
	  { kind = "drink" }        -> beber (Req. 11.1–11.4)
	  { kind = "refillBottle" } -> rellenar junto a un Agujero_Agua (Req. 11.5–11.7)
	Compatibilidad: una cadena "drink"/"refillBottle" suelta equivale al payload de
	tabla con ese `kind`. Cualquier otro `kind` (p. ej. "eatFish") se ignora aquí,
	pues lo atiende otro sistema (FireSystem).
]]
local function onConsumeAction(player: Player, payload: any)
	local kind: string? = nil
	if type(payload) == "string" then
		kind = payload
	elseif type(payload) == "table" then
		kind = payload.kind
	end

	if kind == "drink" then
		local result = BottleSystem.tryDrink(player)
		if not result.ok and result.reason ~= "bottleEmpty" then
			-- La señal de "bottleEmpty" ya se envía dentro de tryDrink (Req. 11.4).
			sendBottleState(player, "rejected", { reason = result.reason, action = "drink" })
		end
	elseif kind == "refillBottle" then
		local result = BottleSystem.tryRefill(player)
		if not result.ok then
			sendBottleState(player, "rejected", { reason = result.reason, action = "refillBottle" })
		end
	end
	-- Otros `kind` (comer pez, etc.) no son responsabilidad de este sistema.
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

local consumeConnection: RBXScriptConnection? = nil

--[[
	init — Inicializa el sistema con sus dependencias y conecta el handler a
	`Remotes.ConsumeAction`. Idempotente: reconectar reemplaza las dependencias sin
	duplicar conexiones (usa una única conexión almacenada). Devuelve el módulo para
	encadenar.
]]
function BottleSystem.init(injected: Deps?)
	deps = injected or {}

	if not consumeConnection then
		consumeConnection = Remotes.ConsumeAction.OnServerEvent:Connect(function(player: Player, ...)
			local payload = (...)
			onConsumeAction(player, payload)
		end)
	end

	return BottleSystem
end

--[[
	shutdown — Desconecta el handler y limpia el estado de respaldo. Útil para
	pruebas o reinicios controlados. No afecta al PlayerState real (inyectado).
]]
function BottleSystem.shutdown()
	if consumeConnection then
		consumeConnection:Disconnect()
		consumeConnection = nil
	end
	fallbackNeeds = {}
	fallbackBottles = {}
	deps = {}
end

return BottleSystem
