--!strict
--[[
	NeedsSystem.lua — Sistema de servidor autoritativo de necesidades vitales.

	Feature: juego-supervivencia-artico

	Este ModuleScript vive en ServerScriptService/Systems y es "pegamento" del
	motor Roblox: NO contiene lógica de reglas propia, sino que APLICA el modelo
	PURO `NeedsModel` a cada jugador activo en cada tick de simulación. Toda la
	aritmética temporal (consumo de Calor/Hambre/Sed, caída de Salud) vive en
	`ReplicatedStorage/Shared/NeedsModel`, de modo que este sistema solo aporta
	el `dt`, compone el entorno `Env` de cada jugador y persiste el resultado.

	Regla arquitectónica: SERVIDOR AUTORITATIVO. El estado de necesidades lo posee
	el servidor (dentro de PlayerState). El cliente nunca decide su valor; solo
	renderiza el estado que el servidor confirma vía StateUpdate (lo hace el
	orquestador, no este sistema).

	Regla de bucle: este sistema NO arranca su propio `Heartbeat`. Expone
	`NeedsSystem.step(dt)` para que el bucle de simulación de `GameServer` lo
	conduzca de forma determinista junto al resto de sistemas dependientes del
	tiempo (coincide con la sección "Bucle de simulación" del diseño).

	Responsabilidades (Requisitos 4.3, 4.5, 4.6, 4.7, 4.8, 6.6):
	  4.3  Consumo de Calor al DOBLE cuando el jugador está expuesto a nieve/ventisca
	       (lo modela NeedsModel.step a partir del Env compuesto).
	  4.5  Consumo de Hambre a 1%/s.
	  4.6  Consumo de Sed a 1%/s.
	  4.7  Caída de Salud a 5%/s mientras alguna necesidad (Calor/Hambre/Sed) está a 0.
	  4.8  Cuando la Salud llega a 0, provocar la muerte del jugador dentro de ~1 s.
	  6.6  El doble consumo de Calor aplica bajo nieve/ventisca a la intemperie.

	Composición del entorno (Env) — INYECTADA:
	  El `Env { underSnow, blizzardExposed, nearFire }` de cada jugador se obtiene
	  de dependencias externas mediante `deps.getEnv(player)`. El propio SISTEMA NO
	  consulta WeatherSystem ni DiggingSystem: es el LLAMADOR (GameServer) quien
	  compone `getEnv` combinando, por ejemplo:
	      - WeatherSystem: ¿hay ventisca activa?, ¿está el jugador a la intemperie?
	      - DiggingSystem.isProtected(player): dentro de una Cueva el frío/viento se
	        anula, por lo que `blizzardExposed` debe ser FALSE aunque haya ventisca
	        (Req. 8.3). Aquí solo se CONSUME el resultado ya compuesto.
	  Esta inversión de dependencias mantiene el sistema testeable y desacoplado.

	Inyección de dependencias (todas opcionales; hay fallbacks documentados):
	    NeedsSystem.init({
	        getActivePlayers = function(): { Player } ... end,
	        getPlayerNeeds   = function(player: Player): Needs ... end,
	        setPlayerNeeds   = function(player: Player, needs: Needs) ... end,
	        getEnv           = function(player: Player): Env ... end,
	        onDeath          = function(player: Player) ... end,
	    })

	Uso desde el orquestador (GameServer):
	    local NeedsSystem = require(script.Systems.NeedsSystem)
	    NeedsSystem.init({
	        getActivePlayers = function() return PlayerStateStore.activePlayers() end,
	        getPlayerNeeds   = function(p) return PlayerStateStore.get(p).needs end,
	        setPlayerNeeds   = function(p, n) PlayerStateStore.get(p).needs = n end,
	        getEnv           = composeEnv,   -- WeatherSystem + DiggingSystem.isProtected
	        onDeath          = function(p) ... end,
	    })
	    -- dentro del bucle Heartbeat:
	    NeedsSystem.step(dt)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NeedsModel = require(ReplicatedStorage.Shared.NeedsModel)
local Types = require(ReplicatedStorage.Shared.Types)

type Needs = Types.Needs
type Env = Types.Env

--[[
	Deps — Contrato de dependencias inyectables. Todos los campos son opcionales;
	los que falten se sustituyen por fallbacks seguros (ver `resolveDeps`).

	- getActivePlayers: jugadores en partida activa a los que aplicar el tick.
	- getPlayerNeeds:   necesidades actuales de un jugador (propiedad de PlayerState).
	- setPlayerNeeds:   guarda las necesidades resultantes tras el paso de tiempo.
	- getEnv:           entorno compuesto del jugador (nieve/ventisca/fuego).
	- onDeath:          efecto de muerte a disparar cuando la Salud llega a 0 (Req. 4.8).
]]
export type Deps = {
	getActivePlayers: (() -> { Player })?,
	getPlayerNeeds: ((player: Player) -> Needs)?,
	setPlayerNeeds: ((player: Player, needs: Needs) -> ())?,
	getEnv: ((player: Player) -> Env)?,
	onDeath: ((player: Player) -> ())?,
}

local NeedsSystem = {}

------------------------------------------------------------------------------
-- Entorno por defecto (sin exposición) usado como fallback seguro.
------------------------------------------------------------------------------

-- Env neutro: sin nieve, sin ventisca y sin fuego cercano. Con este entorno el
-- Calor decae a su tasa base (sin el ×2 del Req. 4.3/6.6). Se usa como fallback
-- cuando no se inyecta `getEnv`.
local DEFAULT_ENV: Env = {
	underSnow = false,
	blizzardExposed = false,
	nearFire = false,
}

------------------------------------------------------------------------------
-- Estado del sistema: dependencias resueltas y control de muertes.
------------------------------------------------------------------------------

-- Dependencias efectivas (inyectadas o fallbacks). Se resuelven en `init`.
local deps: Deps = {}

-- Jugadores para los que ya se disparó la muerte, para no invocar `onDeath`
-- repetidamente mientras la Salud permanece en 0 en ticks sucesivos (Req. 4.8).
-- Se limpia por jugador cuando su Salud vuelve a ser > 0 (p. ej. al reaparecer).
local deathTriggered: { [Player]: boolean } = {}

------------------------------------------------------------------------------
-- Resolución de dependencias con fallbacks documentados.
------------------------------------------------------------------------------

--[[
	fallbackGetActivePlayers — Si no se inyecta, se asume que "activos" son todos
	los jugadores conectados. GameServer normalmente inyecta una versión que solo
	devuelve los que están en partida activa (tras el tutorial).
]]
local function fallbackGetActivePlayers(): { Player }
	return Players:GetPlayers()
end

--[[
	fallbackGetEnv — Si no se inyecta `getEnv`, se devuelve el entorno neutro.
	Esto degrada de forma segura (el Calor decae a tasa base, sin ×2) en lugar de
	fallar. En producción, GameServer inyecta la composición real.
]]
local function fallbackGetEnv(_player: Player): Env
	return DEFAULT_ENV
end

--[[
	fallbackOnDeath — Si no se inyecta `onDeath`, se intenta matar al Humanoid del
	personaje directamente (Req. 4.8), que es el efecto de muerte natural en Roblox.
	Si no hay Humanoid disponible, no hace nada (no puede fallar).
]]
local function fallbackOnDeath(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = 0
	end
end

-- Fallbacks de acceso a necesidades. Sin un almacén real inyectado no hay estado
-- que leer/escribir; se devuelve un estado "lleno" y la escritura es un no-op.
-- GameServer SIEMPRE debe inyectar getPlayerNeeds/setPlayerNeeds contra PlayerState.
local function fallbackGetPlayerNeeds(_player: Player): Needs
	-- Copia defensiva para no exponer la tabla compartida.
	return { warmth = 100, hunger = 100, thirst = 100, health = 100 }
end

local function fallbackSetPlayerNeeds(_player: Player, _needs: Needs)
	-- No-op: sin almacén inyectado no hay dónde persistir.
end

-- Resuelve las dependencias efectivas combinando lo inyectado con los fallbacks.
local function resolveDeps(injected: Deps?): Deps
	local d: Deps = injected or {}
	return {
		getActivePlayers = d.getActivePlayers or fallbackGetActivePlayers,
		getPlayerNeeds = d.getPlayerNeeds or fallbackGetPlayerNeeds,
		setPlayerNeeds = d.setPlayerNeeds or fallbackSetPlayerNeeds,
		getEnv = d.getEnv or fallbackGetEnv,
		onDeath = d.onDeath or fallbackOnDeath,
	}
end

------------------------------------------------------------------------------
-- Arranque / inyección
------------------------------------------------------------------------------

--[[
	init — Almacena las dependencias inyectadas (sustituyendo las que falten por
	fallbacks seguros). NO arranca ningún bucle: el orquestador conduce `step`.
	Idempotente: llamarlo de nuevo re-resuelve las dependencias.
]]
function NeedsSystem.init(injected: Deps?)
	deps = resolveDeps(injected)
end

------------------------------------------------------------------------------
-- Aplicación de un jugador (paso de tiempo + muerte)
------------------------------------------------------------------------------

--[[
	applyToPlayer — Aplica el paso de tiempo a UN jugador y gestiona su muerte.

	1. Lee las necesidades actuales del jugador (getPlayerNeeds).
	2. Compone su entorno (getEnv) y aplica NeedsModel.step(needs, env, dt).
	3. Persiste el resultado (setPlayerNeeds).
	4. Si el resultado está muerto (Salud <= 0) y aún no se disparó, invoca onDeath
	   exactamente una vez (Req. 4.8). Si la Salud vuelve a ser > 0, se rearma.

	Devuelve las necesidades resultantes (útil para pruebas).
]]
local function applyToPlayer(player: Player, dt: number): Needs
	local current = deps.getPlayerNeeds :: (Player) -> Needs
	local setNeeds = deps.setPlayerNeeds :: (Player, Needs) -> ()
	local getEnv = deps.getEnv :: (Player) -> Env
	local onDeath = deps.onDeath :: (Player) -> ()

	local needs = current(player)
	local env = getEnv(player)
	local newNeeds = NeedsModel.step(needs, env, dt)

	setNeeds(player, newNeeds)

	if NeedsModel.isDead(newNeeds) then
		-- Dispara la muerte una sola vez mientras la Salud siga a 0 (Req. 4.8).
		if not deathTriggered[player] then
			deathTriggered[player] = true
			onDeath(player)
		end
	else
		-- La Salud es > 0: rearmar por si el jugador reaparece/se recupera.
		deathTriggered[player] = nil
	end

	return newNeeds
end

------------------------------------------------------------------------------
-- Paso de simulación (conducido por GameServer)
------------------------------------------------------------------------------

--[[
	step — Aplica un paso de tiempo `dt` (segundos) a TODOS los jugadores activos.

	Es el único punto de entrada del bucle de simulación. No arranca Heartbeat por
	sí mismo (el diseño lo deja a GameServer para conducir todos los sistemas con
	un `dt` común y de forma determinista).

	`dt` negativo o cero no produce cambios significativos (NeedsModel es lineal en
	`dt`); aun así se ignoran `dt <= 0` para evitar restauraciones espurias.
]]
function NeedsSystem.step(dt: number)
	if type(dt) ~= "number" or dt <= 0 then
		return
	end

	local getActivePlayers = deps.getActivePlayers :: () -> { Player }
	local players = getActivePlayers()
	for _, player in players do
		applyToPlayer(player, dt)
	end
end

------------------------------------------------------------------------------
-- Utilidades de estado (pruebas / otros sistemas)
------------------------------------------------------------------------------

--[[
	applyToPlayer (público) — Expone la aplicación de un único jugador para pruebas
	e integración puntual, reutilizando la misma ruta que `step`.
]]
function NeedsSystem.applyToPlayer(player: Player, dt: number): Needs
	return applyToPlayer(player, dt)
end

-- ¿Se ha disparado ya la muerte de este jugador en el tick actual/previo? (test)
function NeedsSystem.isDeathTriggered(player: Player): boolean
	return deathTriggered[player] == true
end

-- Limpia el marcador de muerte de un jugador (p. ej. al reaparecer manualmente).
function NeedsSystem.resetDeath(player: Player)
	deathTriggered[player] = nil
end

-- Inicializa las dependencias con fallbacks aunque no se llame a `init`, de modo
-- que `step` sea seguro desde el primer instante.
deps = resolveDeps(nil)

return NeedsSystem
