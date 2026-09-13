--!strict
--[[
	WeatherSystem.lua — Sistema de servidor AUTORITATIVO del clima y las ventiscas.

	Feature: juego-supervivencia-artico

	Vive en ServerScriptService/Systems (ver default.project.json:
	`ServerScriptService` -> `src/server`). Es "pegamento" del motor Roblox:
	posee el estado de clima autoritativo del servidor y CONDUCE el modelo PURO
	`WeatherModel` (que contiene toda la aritmética del temporizador y del ciclo
	de ventisca). Este sistema NO reimplementa esa lógica: solo aporta el `dt`, la
	fuente de aleatoriedad y la aplicación de efectos (niebla, sonido, doble
	consumo de Calor) sobre el mundo/clientes.

	Regla arquitectónica: SERVIDOR AUTORITATIVO. El estado de clima lo decide y
	mantiene el servidor; los clientes solo reciben, vía `StateUpdate`, los valores
	de presentación (factor de visibilidad para la niebla y volumen del viento) que
	deben renderizar. El doble consumo de Calor NO se aplica aquí: lo calcula
	`NeedsModel` a través del `Env` del jugador; este sistema únicamente EXPONE los
	ayudantes con los que GameServer compone ese `Env` (ver `composeEnv`).

	Responsabilidades (Requisitos 6.1–6.7):
	  - 6.1/6.2/6.3: Avanzar `WeatherModel.step(weather, dt, rng)`: cuando el
	    temporizador llega a 0 se activa una Ventisca (timer -> 600 s,
	    blizzardRemaining -> 60 s) y la Ventisca se desactiva al agotarse sus 60 s.
	    Toda esta lógica vive en el modelo puro; aquí solo se conduce.
	  - 6.4: Durante la Ventisca la visibilidad se reduce al 30%
	    (`WeatherModel.visibilityFactor` = 0.3). Se difunde a los clientes por
	    `StateUpdate` para que el HUD/entorno pinte la niebla.
	  - 6.5: Durante la Ventisca se pide reproducir el viento rugiente a un volumen
	    >= 80% (`BLIZZARD_WIND_VOLUME`). También se difunde por `StateUpdate`.
	  - 6.6: Durante la Ventisca, y para el jugador a la intemperie (no protegido en
	    una Cueva), el Calor se consume al doble. Este sistema no toca `Needs`; en su
	    lugar expone `isBlizzardActive()` y `composeEnv(player, isProtected)` para que
	    GameServer construya el `getEnv` de NeedsSystem con
	    `blizzardExposed = blizzardActive AND not protegido-en-cueva`.
	  - 6.7: Al desactivarse la Ventisca se restauran los valores de clima despejado
	    (visibilidad 1.0, volumen de viento de reposo, multiplicador de Calor 1) y se
	    difunde ese estado despejado por `StateUpdate`.

	IMPORTANTE (bucle de simulación): este sistema NO arranca su propio `Heartbeat`.
	El orquestador (GameServer) es quien conduce el tiempo llamando a
	`WeatherSystem.step(dt)` en cada tick del bucle del servidor (ver design.md,
	"Bucle de simulación"). Así todo el `dt` del servidor procede de una única fuente.

	Acoplamiento limpio: las dependencias se INYECTAN por `init(deps)` con valores
	por defecto razonables (ver más abajo), de modo que el sistema se prueba y
	arranca sin depender del orden de carga de otros sistemas.

	Requisitos cubiertos: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local WeatherModel = require(ReplicatedStorage.Shared.WeatherModel)
local Remotes = require(ReplicatedStorage.Remotes)

type Weather = Types.Weather
type Env = Types.Env

local WeatherSystem = {}

--=============================================================================
-- Constantes de presentación y balance de la Ventisca
--=============================================================================

-- Duración del ciclo de cambio y de la ventisca las provee el modelo puro a
-- través de Constants; aquí solo se referencian para inicializar el estado.
local CHANGE_INTERVAL_S: number = Constants.WEATHER.CHANGE_INTERVAL_S -- 600 s (Req. 6.1)
local CLEAR_VISIBILITY: number = Constants.WEATHER.CLEAR_VISIBILITY_FACTOR -- 1.0 (Req. 6.4/6.7)

-- Volumen del sonido de viento rugiente durante la ventisca (>= 80% del máximo
-- del canal ambiental, Req. 6.5). Se difunde a los clientes por StateUpdate.
local BLIZZARD_WIND_VOLUME: number = 0.8
-- Volumen de viento en clima despejado (reposo). Al desactivarse la ventisca se
-- restaura a este valor (Req. 6.7). Se elige 0 (sin viento rugiente ambiental).
local CLEAR_WIND_VOLUME: number = 0

-- Multiplicador del consumo de Calor. Informativo para el HUD/otros consumidores;
-- el doble consumo real lo aplica NeedsModel vía Env (Req. 6.6/6.7).
local BLIZZARD_WARMTH_MULTIPLIER: number = Constants.NEEDS.COLD_EXPOSURE_MULTIPLIER -- 2
local CLEAR_WARMTH_MULTIPLIER: number = 1

--=============================================================================
-- Tipos de dependencias inyectables
--=============================================================================

--[[
	Deps — Dependencias inyectables de WeatherSystem. Todas son opcionales; si no
	se proporcionan, se usan los valores por defecto documentados:

	  - rng(): number
	      Fuente de aleatoriedad en [0, 1) para `WeatherModel.step`. Por defecto
	      `math.random`. Inyectable para pruebas deterministas.
	  - broadcastState(payload): any
	      Difunde el estado de presentación del clima a todos los clientes. Por
	      defecto `Remotes.StateUpdate:FireAllClients(payload)`.
	  - setSharedWeather(weather): any
	      Publica el clima autoritativo en el estado del Mundo compartido para que
	      otros sistemas (NeedsSystem, HUD) lo lean. Por defecto
	      `WorldSystem.setWeather` si el módulo hermano está disponible; si no, no-op.
	  - getPlayers(): { Player }
	      Lista de jugadores en partida. Por defecto `Players:GetPlayers()`.
]]
export type Deps = {
	rng: (() -> number)?,
	broadcastState: ((payload: { [string]: any }) -> any)?,
	setSharedWeather: ((weather: Weather) -> any)?,
	getPlayers: (() -> { Player })?,
}

--=============================================================================
-- Estado autoritativo (nivel de servidor)
--=============================================================================

-- makeClearWeather — Estado de clima despejado inicial: temporizador completo,
-- sin ventisca activa.
local function makeClearWeather(): Weather
	return {
		timer = CHANGE_INTERVAL_S,
		blizzardActive = false,
		blizzardRemaining = 0,
	}
end

-- weather: estado de clima autoritativo. Se mantiene siempre como el último
-- resultado de `WeatherModel.step`.
local weather: Weather = makeClearWeather()

-- initialized: guarda la idempotencia de `init` (evita re-difundir/re-resetear).
local initialized = false

-- Dependencias resueltas (con sus valores por defecto aplicados en init).
local rng: () -> number = math.random
local broadcastState: (payload: { [string]: any }) -> any
local setSharedWeather: (weather: Weather) -> any
local getPlayers: () -> { Player }

--=============================================================================
-- Valores por defecto de las dependencias
--=============================================================================

-- defaultBroadcastState — Difunde el estado de clima a todos los clientes por el
-- RemoteEvent StateUpdate (Servidor -> Cliente).
local function defaultBroadcastState(payload: { [string]: any })
	Remotes.StateUpdate:FireAllClients(payload)
end

-- defaultSetSharedWeather — Publica el clima en WorldSystem si el módulo hermano
-- está disponible (mismo directorio). Se resuelve con `pcall` para no acoplar
-- duramente el orden de carga; si no existe o no expone `setWeather`, es no-op.
local function defaultSetSharedWeather(newWeather: Weather)
	local ok, world = pcall(function()
		return require(script.Parent.WorldSystem)
	end)
	if ok and type(world) == "table" and typeof(world.setWeather) == "function" then
		world.setWeather(newWeather)
	end
end

-- defaultGetPlayers — Jugadores actualmente conectados.
local function defaultGetPlayers(): { Player }
	return Players:GetPlayers()
end

--=============================================================================
-- Difusión del estado de presentación (Req. 6.4, 6.5, 6.7)
--=============================================================================

-- buildWeatherPayload — Construye el payload de presentación coherente con el
-- estado de clima dado: factor de visibilidad para la niebla (6.4), volumen del
-- viento (6.5) y el multiplicador informativo de Calor (6.6/6.7).
local function buildWeatherPayload(w: Weather): { [string]: any }
	local active = w.blizzardActive
	return {
		kind = "weather",
		blizzardActive = active,
		-- Visibilidad: 0.3 en ventisca, 1.0 despejado (delegado al modelo puro).
		visibilityFactor = WeatherModel.visibilityFactor(w),
		-- Volumen del viento rugiente: >= 80% en ventisca, reposo despejado.
		windVolume = if active then BLIZZARD_WIND_VOLUME else CLEAR_WIND_VOLUME,
		-- Multiplicador de consumo de Calor (informativo para el HUD).
		warmthDecayMultiplier = if active then BLIZZARD_WARMTH_MULTIPLIER else CLEAR_WARMTH_MULTIPLIER,
		-- Tiempo restante de ventisca (para efectos de cuenta atrás en el HUD).
		blizzardRemaining = w.blizzardRemaining,
	}
end

-- broadcastCurrent — Difunde el estado de presentación del clima actual.
local function broadcastCurrent()
	broadcastState(buildWeatherPayload(weather))
end

--=============================================================================
-- API pública
--=============================================================================

--[[
	init — Inicializa el sistema de clima. IDEMPOTENTE: la primera llamada fija el
	estado despejado inicial y difunde su presentación a los clientes; las llamadas
	posteriores solo actualizan las dependencias inyectadas (sin re-resetear el
	estado ni re-difundir), de modo que puede invocarse varias veces sin efectos
	duplicados.

	NO arranca ningún `Heartbeat`: GameServer debe llamar a `step(dt)` en su bucle.

	@param injected Dependencias opcionales (ver tipo `Deps`).
]]
function WeatherSystem.init(injected: Deps?): ()
	local d = injected or {}

	-- Resuelve dependencias con sus valores por defecto documentados.
	rng = d.rng or math.random
	broadcastState = d.broadcastState or defaultBroadcastState
	setSharedWeather = d.setSharedWeather or defaultSetSharedWeather
	getPlayers = d.getPlayers or defaultGetPlayers

	if initialized then
		-- Idempotencia: no reinicia el estado ni vuelve a difundir.
		return
	end
	initialized = true

	-- Estado despejado inicial: publícalo en el Mundo compartido y difúndelo.
	weather = makeClearWeather()
	setSharedWeather(weather)
	broadcastCurrent()
end

--[[
	step — Avanza el clima `dt` segundos conduciendo el modelo PURO `WeatherModel`.

	Almacena el nuevo estado autoritativo, lo publica en el Mundo compartido
	(`setSharedWeather`) para que otros sistemas lo lean, y —solo cuando la
	ventisca cambia de estado (activación o desactivación)— difunde a los clientes
	el estado de presentación correspondiente:
	  - Activación (Req. 6.4/6.5): niebla al 30% y viento rugiente >= 80%.
	  - Desactivación (Req. 6.7): visibilidad, volumen y multiplicador de Calor
	    restaurados a clima despejado.

	Es seguro llamarlo antes de `init` (usa valores por defecto perezosos), pero lo
	esperado es que GameServer llame primero a `init` una vez y luego a `step` cada
	tick.

	@param dt Tiempo transcurrido en segundos (>= 0).
	@return Weather Nuevo estado de clima autoritativo.
]]
function WeatherSystem.step(dt: number): Weather
	-- Asegura dependencias resueltas aunque `step` se llame sin `init` previo.
	if broadcastState == nil then
		broadcastState = defaultBroadcastState
	end
	if setSharedWeather == nil then
		setSharedWeather = defaultSetSharedWeather
	end
	if getPlayers == nil then
		getPlayers = defaultGetPlayers
	end
	if rng == nil then
		rng = math.random
	end

	local wasActive = weather.blizzardActive

	-- Conduce el modelo puro (única fuente de la lógica de temporizador/ventisca).
	weather = WeatherModel.step(weather, dt, rng)

	-- Publica el clima autoritativo para NeedsSystem/HUD.
	setSharedWeather(weather)

	-- Solo difunde presentación cuando la ventisca cruza un umbral (activa/inactiva),
	-- que es cuando cambian visibilidad, sonido y multiplicador (Req. 6.4/6.5/6.7).
	if weather.blizzardActive ~= wasActive then
		broadcastCurrent()
	end

	return weather
end

--[[
	getWeather — Devuelve el estado de clima autoritativo actual.
]]
function WeatherSystem.getWeather(): Weather
	return weather
end

--[[
	isBlizzardActive — ¿Hay una Ventisca activa ahora mismo? (Req. 6.6)
	GameServer/NeedsSystem lo usan para decidir el doble consumo de Calor.
]]
function WeatherSystem.isBlizzardActive(): boolean
	return weather.blizzardActive
end

--[[
	visibilityFactor — Factor de visibilidad actual (0.3 en ventisca, 1.0 despejado).
	Atajo sobre el modelo puro para consumidores del servidor (Req. 6.4).
]]
function WeatherSystem.visibilityFactor(): number
	return WeatherModel.visibilityFactor(weather)
end

--[[
	isBlizzardExposed — ¿Está el jugador expuesto al frío/viento de la ventisca?
	Es verdadero cuando hay ventisca activa Y el jugador NO está protegido (p. ej.
	completamente dentro de una Cueva, según `DiggingSystem.isProtected`). Este es
	el predicado que activa el doble consumo de Calor (Req. 6.6).

	@param isProtected true si el jugador está resguardado (Cueva/techo).
]]
function WeatherSystem.isBlizzardExposed(isProtected: boolean): boolean
	return weather.blizzardActive and not isProtected
end

--[[
	composeEnv — Construye el `Env` que NeedsSystem consume para un jugador,
	fijando `blizzardExposed` según el clima actual y si el jugador está protegido.

	GameServer llama a este ayudante al montar el `getEnv` de NeedsSystem, de forma
	que la única fuente de verdad de "¿hay ventisca?" sea WeatherSystem (Req. 6.6).
	Se puede pasar un `baseEnv` para conservar `underSnow`/`nearFire` calculados por
	otros sistemas; si se omite, esos campos quedan en `false`.

	@param player      Jugador para el que se compone el entorno (parte del contrato;
	                   el estado de ventisca es global, pero la firma admite futuras
	                   variaciones por jugador).
	@param isProtected true si el jugador está resguardado (Cueva/techo).
	@param baseEnv     Env base opcional con `underSnow`/`nearFire` ya calculados.
	@return Env        Entorno listo para `NeedsModel.step`.
]]
function WeatherSystem.composeEnv(player: Player, isProtected: boolean, baseEnv: Env?): Env
	local base = baseEnv
	return {
		underSnow = if base ~= nil then base.underSnow else false,
		blizzardExposed = WeatherSystem.isBlizzardExposed(isProtected),
		nearFire = if base ~= nil then base.nearFire else false,
	}
end

return WeatherSystem
