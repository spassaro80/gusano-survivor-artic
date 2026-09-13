--!strict
--[[
	RescueSystem.lua — Sistema de servidor AUTORITATIVO del rescate del Día 7 y
	el Modo_Libre infinito.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es "pegamento" del motor Roblox
	(Instances en Workspace, RemoteEvents, temporizadores), NO lógica pura. Toda
	la aritmética de días/necesidades vive en GameServer/PlayerState y en los
	modelos puros; aquí solo se orquesta la escena de rescate y el estado de la
	elección del Jugador.

	Regla arquitectónica: SERVIDOR AUTORITATIVO. El cliente solo envía su elección
	("escape" / "keepSurviving") por `Remotes.RescueChoice`; el servidor decide el
	resultado (victoria o Modo_Libre) y replica la escena y los paneles por
	`Remotes.StateUpdate`. La proximidad al helicóptero se comprueba en el servidor.

	Responsabilidades (Requisitos 15.1–15.7):
	  - 15.1: Al comenzar el Día 7, reproducir el sonido de aspas del helicóptero
	          gigante durante un máximo de 5 s (se anuncia por StateUpdate para que
	          el cliente lo reproduzca; la duración es orientativa 0..5 s).
	  - 15.2: Al comenzar el Día 7, hacer aterrizar el Helicoptero_Rescate en una
	          zona del Mundo con luces y sonidos en un plazo máximo de 10 s.
	  - 15.3: Cuando el Jugador se aproxima a <= 5 m del helicóptero, mostrar una
	          pantalla con EXACTAMENTE dos opciones: "Escapar" y "Seguir
	          Sobreviviendo".
	  - 15.4: Si elige "Escapar" y confirma, mostrar victoria y, tras confirmar,
	          regresar al Menu_Principal (delegado en deps.onVictory).
	  - 15.5: Si elige "Seguir Sobreviviendo", el helicóptero despega en un máximo
	          de 10 s y se activa el Modo_Libre.
	  - 15.6: En Modo_Libre la partida continúa indefinidamente incrementando el
	          contador de Días en 1 al final de cada Día (8, 9, 10, ...) sin
	          condición de victoria. El conteo de días lo posee GameServer/
	          PlayerState; aquí se integra vía deps.setFreeMode / deps.incrementDay.
	  - 15.7: Si el Jugador se aleja sin elegir, ocultar la pantalla de opciones y
	          mantener el helicóptero disponible para una nueva aproximación.

	Bajo acoplamiento: como FishingSystem, este sistema NO requiere de forma dura a
	otros sistemas. Todas las consultas/efectos de mundo se inyectan por
	`RescueSystem.init(deps)`, con valores por defecto razonables. Así se prueba y
	arranca sin depender del orden de carga.

	Supuestos documentados:
	  - 1 stud == 1 metro para las distancias de interacción (como en los demás
	    sistemas). La aproximación usa distancia planar (X,Z) para tolerar
	    diferencias de altura entre el Jugador y el helicóptero.
	  - El "comienzo del Día 7" lo notifica GameServer llamando a
	    `RescueSystem.onDayReached(day)` en cada cambio de día. Cuando `day` alcanza
	    Constants.RESCUE.DAY (7) por primera vez, se dispara la escena de rescate.
	  - La escena del helicóptero es única y compartida por el servidor (un mapa,
	    una zona de aterrizaje). La elección de rescate es POR Jugador.
	  - Si no se inyecta `spawnHelicopter`, se crea un Part simple anclado como
	    marcador de posición del helicóptero (fidelidad visual básica).

	Requisitos cubiertos: 15.1, 15.2, 15.3, 15.4, 15.5, 15.6, 15.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Remotes)
local Constants = require(ReplicatedStorage.Shared.Constants)

--=============================================================================
-- Tipos
--=============================================================================

-- Interfaz de dependencias inyectables. Todo es opcional: los que faltan usan un
-- comportamiento por defecto basado en el motor de Roblox o en no-ops seguros.
export type Deps = {
	-- Crea la Instance física del helicóptero en la posición de aterrizaje y la
	-- devuelve (o nil). Por defecto crea un Part anclado sencillo (15.2).
	spawnHelicopter: ((position: Vector3) -> Instance?)?,
	-- Posición de aterrizaje del helicóptero en el Mundo (15.2). Por defecto una
	-- zona fija cercana al origen.
	getLandingPosition: (() -> Vector3)?,
	-- Jugadores actualmente en partida (para la comprobación de proximidad, 15.3).
	getPlayers: (() -> { Player })?,
	-- Posición del Jugador (para medir la aproximación, 15.3/15.7).
	getPlayerPosition: ((player: Player) -> Vector3?)?,
	-- Se invoca al escapar: muestra victoria y regresa al Menu_Principal (15.4).
	onVictory: ((player: Player) -> ())?,
	-- Activa/desactiva el Modo_Libre en el estado autoritativo del Jugador (15.5).
	setFreeMode: ((player: Player, enabled: boolean) -> ())?,
	-- Incrementa el contador de Días del Jugador (propiedad de GameServer, 15.6).
	incrementDay: ((player: Player) -> ())?,
	-- Consulta el Día actual del Jugador (propiedad de GameServer/PlayerState).
	getDay: ((player: Player) -> number)?,
	-- Fija el Día actual del Jugador (propiedad de GameServer/PlayerState).
	setDay: ((player: Player, day: number) -> ())?,
	-- Radio (studs) de aproximación al helicóptero. Por defecto 5 m (15.3).
	approachRadius: number?,
	-- Duración (s) del sonido de aspas antes del aterrizaje (0..5 s, 15.1).
	bladeSoundDuration: number?,
	-- Retardo (s) hasta que el helicóptero aterriza (<= 10 s, 15.2).
	landingDelay: number?,
	-- Retardo (s) hasta que el helicóptero despega al Seguir Sobreviviendo (<= 10 s, 15.5).
	takeoffDelay: number?,
}

-- Estado de rescate por Jugador.
export type RescueChoice = "escape" | "keepSurviving"

export type PlayerRescueState = {
	userId: number,
	-- ¿Se le está mostrando ahora mismo el panel de opciones? (15.3/15.7)
	panelShown: boolean,
	-- Elección confirmada (nil mientras no elige). Al elegir se bloquea el panel.
	choice: RescueChoice?,
	-- ¿Está en Modo_Libre? (15.5/15.6)
	freeMode: boolean,
}

-- Resultado de procesar una elección de rescate (útil para pruebas).
export type ChoiceResult = {
	ok: boolean,
	reason: string?, -- "notActive" | "alreadyChosen" | "badChoice" | "tooFar"
	choice: RescueChoice?,
	freeMode: boolean?,
}

--=============================================================================
-- Constantes de la escena de rescate (específicas del Req. 15)
--=============================================================================

-- Día en que llega el helicóptero (fuente de verdad: Constants.RESCUE.DAY = 7).
local RESCUE_DAY: number = Constants.RESCUE.DAY
-- Distancia de aproximación por defecto (fuente de verdad: 5 m, Req. 15.3).
local DEFAULT_APPROACH_M: number = Constants.INTERACTION.HELICOPTER_APPROACH_M

-- Máximos de diseño (Req. 15.1, 15.2, 15.5).
local DEFAULT_BLADE_SOUND_S: number = 5 -- máx. 5 s de aspas (15.1)
local DEFAULT_LANDING_DELAY_S: number = 10 -- máx. 10 s hasta aterrizar (15.2)
local DEFAULT_TAKEOFF_DELAY_S: number = 10 -- máx. 10 s hasta despegar (15.5)

-- Las EXACTAMENTE dos opciones del panel de rescate (Req. 15.3). El orden y el
-- texto son parte del contrato con el cliente.
local RESCUE_OPTIONS: { string } = { "Escapar", "Seguir Sobreviviendo" }

--=============================================================================
-- Estado del módulo
--=============================================================================

local RescueSystem = {}

local deps: Deps = {}
local approachRadius: number = DEFAULT_APPROACH_M
local bladeSoundDuration: number = DEFAULT_BLADE_SOUND_S
local landingDelay: number = DEFAULT_LANDING_DELAY_S
local takeoffDelay: number = DEFAULT_TAKEOFF_DELAY_S

-- ¿Ya se disparó la escena de rescate del Día 7? (idempotente; una sola escena).
local rescueTriggered = false
-- ¿Está el helicóptero actualmente posado y disponible para aproximación? (15.7)
local helicopterAvailable = false
-- Instance física del helicóptero (nil mientras no aterriza o tras despegar).
local helicopterInstance: Instance? = nil
-- Posición de aterrizaje usada (para la comprobación de proximidad).
local landingPosition: Vector3? = nil

-- Estado de rescate por Jugador, indexado por userId.
local playerStates: { [number]: PlayerRescueState } = {}

--=============================================================================
-- Dependencias por defecto (motor de Roblox / no-ops seguros)
--=============================================================================

local function defaultGetLandingPosition(): Vector3
	-- Zona de aterrizaje por defecto: un claro cercano al origen, ligeramente
	-- elevado sobre el baseplate. GameServer/WorldSystem puede inyectar una zona
	-- real del mapa mediante deps.getLandingPosition.
	return Vector3.new(0, 3, 40)
end

-- Crea un marcador físico sencillo del helicóptero con "luces y sonidos" (15.2).
local function defaultSpawnHelicopter(position: Vector3): Instance?
	local model = Instance.new("Model")
	model.Name = "Helicoptero_Rescate"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Anchored = true
	body.CanCollide = true
	body.Size = Vector3.new(8, 4, 16)
	body.Position = position
	body.BrickColor = BrickColor.new("Dark stone grey")
	body.Material = Enum.Material.Metal
	body.Parent = model

	-- Luz de aterrizaje (parte visible de "luces y sonidos" del Req. 15.2).
	local light = Instance.new("PointLight")
	light.Brightness = 5
	light.Range = 30
	light.Color = Color3.fromRGB(255, 240, 180)
	light.Parent = body

	-- Sonido ambiental del helicóptero posado.
	local sound = Instance.new("Sound")
	sound.Name = "HelicopterAmbient"
	sound.Looped = true
	sound.Volume = 0.8
	sound.Parent = body

	model.PrimaryPart = body
	model.Parent = Workspace
	return model
end

local function defaultGetPlayers(): { Player }
	return Players:GetPlayers()
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

-- Fallbacks no-op para los efectos de estado poseídos por GameServer.
local function defaultOnVictory(_player: Player) end
local function defaultSetFreeMode(_player: Player, _enabled: boolean) end
local function defaultIncrementDay(_player: Player) end

--=============================================================================
-- Utilidades
--=============================================================================

-- Devuelve (creando si falta) el estado de rescate de un Jugador.
local function ensureState(player: Player): PlayerRescueState
	local state = playerStates[player.UserId]
	if state == nil then
		state = {
			userId = player.UserId,
			panelShown = false,
			choice = nil,
			freeMode = false,
		}
		playerStates[player.UserId] = state
	end
	return state
end

-- Distancia planar (X,Z) entre dos posiciones. Tolera diferencias de altura.
local function planarDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Envía retroalimentación de rescate al cliente por StateUpdate (canal S->C).
local function sendRescueState(player: Player, phase: string, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		kind = "rescue",
		phase = phase,
	}
	if extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	Remotes.StateUpdate:FireClient(player, payload)
end

-- Difunde un estado de escena de rescate a todos los jugadores en partida.
local function broadcastRescueState(phase: string, extra: { [string]: any }?)
	local getPlayers = deps.getPlayers or defaultGetPlayers
	for _, player in getPlayers() do
		sendRescueState(player, phase, extra)
	end
end

--=============================================================================
-- Núcleo: aparición del helicóptero (Req. 15.1, 15.2)
--=============================================================================

--[[
	spawnHelicopter — Dispara la escena de llegada del Día 7: anuncia el sonido de
	aspas (<= 5 s, 15.1) y programa el aterrizaje del Helicoptero_Rescate con luces
	y sonidos (<= 10 s, 15.2). Idempotente: solo se ejecuta la primera vez; las
	llamadas posteriores no re-disparan la escena.

	Devuelve true si esta llamada disparó la escena; false si ya estaba disparada.
]]
function RescueSystem.spawnHelicopter(): boolean
	if rescueTriggered then
		return false
	end
	rescueTriggered = true

	-- (15.1) Anuncia el sonido de aspas del helicóptero gigante (máx. 5 s). El
	-- cliente lo reproduce; enviamos la duración orientativa.
	broadcastRescueState("bladeSound", { durationS = bladeSoundDuration })

	-- (15.2) Programa el aterrizaje en la zona del Mundo dentro de <= 10 s.
	local getLanding = deps.getLandingPosition or defaultGetLandingPosition
	local pos = getLanding()
	landingPosition = pos

	task.delay(landingDelay, function()
		-- Crea la Instance física del helicóptero (con luces/sonidos).
		local spawn = deps.spawnHelicopter or defaultSpawnHelicopter
		helicopterInstance = spawn(pos)
		helicopterAvailable = true
		broadcastRescueState("landed", { position = pos })
	end)

	return true
end

--[[
	onDayReached — Notificación de GameServer al cambiar de Día. Cuando `day`
	alcanza el Día de rescate (Constants.RESCUE.DAY = 7), dispara la escena de
	rescate una sola vez (Req. 15.1, 15.2). Días posteriores (Modo_Libre) no la
	re-disparan.

	Devuelve true si esta llamada disparó la escena de rescate.
]]
function RescueSystem.onDayReached(day: number): boolean
	if day >= RESCUE_DAY and not rescueTriggered then
		return RescueSystem.spawnHelicopter()
	end
	return false
end

--=============================================================================
-- Núcleo: proximidad y panel de opciones (Req. 15.3, 15.7)
--=============================================================================

--[[
	updatePlayerProximity — Comprueba la proximidad de UN Jugador al helicóptero y
	muestra/oculta el panel de opciones en consecuencia:
	  - Si está a <= approachRadius (5 m) y no ha elegido aún, muestra el panel con
	    EXACTAMENTE las dos opciones "Escapar" y "Seguir Sobreviviendo" (15.3).
	  - Si se aleja sin elegir, oculta el panel y mantiene el helicóptero
	    disponible para una nueva aproximación (15.7).

	Devuelve el nuevo valor de panelShown para este Jugador (útil en pruebas).
]]
function RescueSystem.updatePlayerProximity(player: Player): boolean
	-- Sin helicóptero disponible no hay panel posible.
	if not helicopterAvailable or landingPosition == nil then
		return false
	end

	local state = ensureState(player)

	-- Si ya eligió, el panel no vuelve a mostrarse.
	if state.choice ~= nil then
		return false
	end

	local getPos = deps.getPlayerPosition or defaultGetPlayerPosition
	local pos = getPos(player)
	if pos == nil then
		-- Sin posición conocida: por seguridad, oculta el panel si estaba visible.
		if state.panelShown then
			state.panelShown = false
			sendRescueState(player, "optionsHidden")
		end
		return false
	end

	local withinRange = planarDistance(pos, landingPosition :: Vector3) <= approachRadius

	if withinRange and not state.panelShown then
		-- (15.3) Muestra el panel con EXACTAMENTE dos opciones.
		state.panelShown = true
		sendRescueState(player, "options", { options = RESCUE_OPTIONS })
	elseif not withinRange and state.panelShown then
		-- (15.7) Se alejó sin elegir: oculta el panel; el helicóptero sigue disponible.
		state.panelShown = false
		sendRescueState(player, "optionsHidden")
	end

	return state.panelShown
end

--[[
	step — Punto de entrada para el bucle del juego (GameServer llama cada tick).
	Recalcula la proximidad de todos los jugadores en partida. `dt` se acepta por
	consistencia con otros sistemas aunque la comprobación no dependa de él.
]]
function RescueSystem.step(_dt: number?): ()
	if not helicopterAvailable then
		return
	end
	local getPlayers = deps.getPlayers or defaultGetPlayers
	for _, player in getPlayers() do
		RescueSystem.updatePlayerProximity(player)
	end
end

--=============================================================================
-- Núcleo: elección de rescate (Req. 15.4, 15.5, 15.6)
--=============================================================================

--[[
	handleChoice — Procesa la elección de rescate de un Jugador (autoritativo).
	  - "escape" (15.4): valida proximidad, muestra victoria y delega el regreso al
	    Menu_Principal en deps.onVictory.
	  - "keepSurviving" (15.5, 15.6): activa el Modo_Libre y programa el despegue
	    del helicóptero (<= 10 s). En Modo_Libre el conteo de días sigue por
	    GameServer (deps.incrementDay) sin condición de victoria.

	Solo se acepta una elección por Jugador y solo si el panel está disponible
	(el Jugador está en rango). Devuelve un ChoiceResult para inspección/pruebas.
]]
function RescueSystem.handleChoice(player: Player, rawChoice: any): ChoiceResult
	-- La escena debe estar activa (helicóptero posado).
	if not helicopterAvailable then
		return { ok = false, reason = "notActive" }
	end

	-- Validación de la elección.
	if rawChoice ~= "escape" and rawChoice ~= "keepSurviving" then
		return { ok = false, reason = "badChoice" }
	end
	local choice: RescueChoice = rawChoice :: RescueChoice

	local state = ensureState(player)

	-- Una sola elección por Jugador.
	if state.choice ~= nil then
		return { ok = false, reason = "alreadyChosen", choice = state.choice, freeMode = state.freeMode }
	end

	-- Autoritativo: el Jugador debe estar en rango del helicóptero (Req. 15.3).
	local getPos = deps.getPlayerPosition or defaultGetPlayerPosition
	local pos = getPos(player)
	if pos == nil or landingPosition == nil or planarDistance(pos, landingPosition :: Vector3) > approachRadius then
		return { ok = false, reason = "tooFar" }
	end

	state.choice = choice
	state.panelShown = false

	if choice == "escape" then
		-- (15.4) Victoria y regreso al Menu_Principal (delegado).
		sendRescueState(player, "victory")
		local onVictory = deps.onVictory or defaultOnVictory
		onVictory(player)
		return { ok = true, choice = choice, freeMode = false }
	else
		-- (15.5) Seguir Sobreviviendo: activa Modo_Libre y despega el helicóptero.
		state.freeMode = true
		local setFreeMode = deps.setFreeMode or defaultSetFreeMode
		setFreeMode(player, true)
		sendRescueState(player, "freeMode", { takeoffDelayS = takeoffDelay })

		-- Programa el despegue del helicóptero dentro de <= 10 s (15.5). Como la
		-- escena es compartida, solo despega una vez y deja de estar disponible.
		task.delay(takeoffDelay, function()
			if helicopterInstance then
				(helicopterInstance :: Instance):Destroy()
				helicopterInstance = nil
			end
			helicopterAvailable = false
			broadcastRescueState("helicopterDeparted")
		end)

		return { ok = true, choice = choice, freeMode = true }
	end
end

--[[
	onDayEnded — Gancho del final de un Día para el Modo_Libre (Req. 15.6). Si el
	Jugador está en Modo_Libre, incrementa su contador de Días en 1 de forma
	indefinida (8, 9, 10, ...) sin condición de victoria. El conteo real lo posee
	GameServer/PlayerState; aquí solo se delega en deps.incrementDay.

	Devuelve true si se incrementó el Día (jugador en Modo_Libre).
]]
function RescueSystem.onDayEnded(player: Player): boolean
	local state = playerStates[player.UserId]
	if state == nil or not state.freeMode then
		return false
	end
	local incrementDay = deps.incrementDay or defaultIncrementDay
	incrementDay(player)
	return true
end

--=============================================================================
-- Consultas públicas (inspección / pruebas)
--=============================================================================

-- isFreeMode — ¿Está el Jugador en Modo_Libre? (Req. 15.5, 15.6)
function RescueSystem.isFreeMode(player: Player): boolean
	local state = playerStates[player.UserId]
	return state ~= nil and state.freeMode
end

-- getPlayerState — Estado de rescate de un Jugador (o nil).
function RescueSystem.getPlayerState(player: Player): PlayerRescueState?
	return playerStates[player.UserId]
end

-- isHelicopterAvailable — ¿Está el helicóptero posado y disponible? (Req. 15.7)
function RescueSystem.isHelicopterAvailable(): boolean
	return helicopterAvailable
end

-- isRescueTriggered — ¿Se disparó ya la escena de rescate del Día 7?
function RescueSystem.isRescueTriggered(): boolean
	return rescueTriggered
end

-- getHelicopterInstance — Instance física del helicóptero (o nil).
function RescueSystem.getHelicopterInstance(): Instance?
	return helicopterInstance
end

-- getLandingPosition — Posición de aterrizaje usada (o nil si aún no se decidió).
function RescueSystem.getLandingPosition(): Vector3?
	return landingPosition
end

-- getRescueOptions — Copia de las EXACTAMENTE dos opciones del panel (Req. 15.3).
function RescueSystem.getRescueOptions(): { string }
	return { RESCUE_OPTIONS[1], RESCUE_OPTIONS[2] }
end

--=============================================================================
-- API de módulo: init / shutdown
--=============================================================================

local choiceConnection: RBXScriptConnection? = nil

--[[
	init — Inicializa el sistema con sus dependencias y conecta el handler de
	`Remotes.RescueChoice` UNA sola vez (idempotente): reconectar reemplaza las
	dependencias sin duplicar la conexión. Documenta sus supuestos en la cabecera.

	Devuelve el propio módulo para encadenar.
]]
function RescueSystem.init(injected: Deps?)
	deps = injected or {}
	approachRadius = deps.approachRadius or DEFAULT_APPROACH_M
	bladeSoundDuration = deps.bladeSoundDuration or DEFAULT_BLADE_SOUND_S
	landingDelay = deps.landingDelay or DEFAULT_LANDING_DELAY_S
	takeoffDelay = deps.takeoffDelay or DEFAULT_TAKEOFF_DELAY_S

	if not choiceConnection then
		choiceConnection = Remotes.RescueChoice.OnServerEvent:Connect(function(player: Player, ...)
			local payload = (...)
			-- Admite un string suelto ("escape"/"keepSurviving") o una tabla { choice = ... }.
			local choice: any = payload
			if type(payload) == "table" then
				choice = payload.choice
			end
			RescueSystem.handleChoice(player, choice)
		end)
	end

	return RescueSystem
end

--[[
	shutdown — Desconecta el handler y limpia el estado. Útil para pruebas o
	reinicios controlados. No destruye la Instance del helicóptero ya creada salvo
	que se solicite explícitamente en otro lugar.
]]
function RescueSystem.shutdown()
	if choiceConnection then
		choiceConnection:Disconnect()
		choiceConnection = nil
	end
	playerStates = {}
	rescueTriggered = false
	helicopterAvailable = false
	helicopterInstance = nil
	landingPosition = nil
end

return RescueSystem
