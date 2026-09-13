--!strict
--[[
	SaveSystem.lua — Guardado automático autoritativo (DataStoreService).

	Feature: juego-supervivencia-artico

	Ubicación: ServerScriptService/Systems (src/server/Systems). Este módulo es la
	ÚNICA capa del proyecto con efectos de I/O contra `DataStoreService`. Toda la
	transformación de datos ocurre en el módulo PURO `SaveModel`
	(ReplicatedStorage/Shared); aquí solo se orquesta lectura/escritura y se
	gestionan los fallos del servicio.

	Contrato con SaveModel (puro):
	  - SaveModel.serialize(state: SaveData) -> string        : JSON del subconjunto.
	  - SaveModel.deserialize(raw: string)  -> (SaveData?, ok): parsea y valida.
	  - SaveModel.isValid(data)             -> boolean         : validación pura.

	Comportamiento (Requisitos 16.1–16.7):
	  - 16.1: guardado automático cada Constants.SAVE.INTERVAL_S (120 s) por jugador,
	    conducido por `step(dt)` (lo llama GameServer desde su bucle Heartbeat), o
	    forzable con `saveNow(player)`.
	  - 16.2: guardado al salir el jugador (Players.PlayerRemoving) y al cerrar el
	    servidor (game:BindToClose).
	  - 16.3: se serializa SOLO el subconjunto persistido vía SaveModel.serialize,
	    obtenido con la dependencia inyectada `deps.getSaveData(player)`.
	  - 16.4: al entrar, si hay guardado válido se restaura exactamente vía
	    `deps.applySaveData(player, data)`.
	  - 16.5: si el guardado falla (pcall lanza o se agotan reintentos), se conserva
	    intacto el último guardado válido (NO se sobrescribe con datos parciales) y
	    se notifica al jugador que el guardado no se completó vía `deps.notify` (que
	    por defecto usa Remotes.StateUpdate).
	  - 16.6: si no existe guardado (lectura devuelve nil), partida nueva desde Día 1.
	  - 16.7: si el guardado está corrupto/incompleto (deserialize ok=false), se
	    muestra aviso y se inicia partida nueva desde Día 1.

	IMPORTANTE sobre DataStore:
	  `DataStoreService` SOLO funciona en juegos publicados o en Roblox Studio con
	  "Enable Studio Access to API Services" activado. En un `.rbxl` local sin esa
	  opción, `GetDataStore`/`GetAsync`/`SetAsync` lanzan error. Todas las llamadas
	  van dentro de `pcall`, de modo que un entorno sin acceso a API degrada con
	  gracia (se trata como fallo de I/O) en lugar de romper el servidor. Para tests
	  se puede inyectar `deps.dataStore` (mock en memoria con GetAsync/SetAsync/
	  UpdateAsync) y así ejercitar la lógica sin el servicio real.

	Requisitos cubiertos: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6, 16.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local SaveModel = require(ReplicatedStorage.Shared.SaveModel)

type SaveData = Types.SaveData

--============================================================================
-- Configuración
--============================================================================

-- Intervalo de guardado automático por jugador (Req. 16.1).
local SAVE_INTERVAL_S: number = Constants.SAVE.INTERVAL_S

-- Nombre del DataStore. Configurable mediante `deps.storeName` en `init`.
local DEFAULT_STORE_NAME: string = "ArcticSurvivorSaves"

-- Reintentos acotados para operaciones de I/O contra el DataStore. El total de
-- intentos es 1 + MAX_RETRIES; entre reintentos se espera RETRY_BACKOFF_S.
local MAX_RETRIES: number = 3
local RETRY_BACKOFF_S: number = 1

-- Estado de carga devuelto por `load`.
export type LoadStatus = "loaded" | "new" | "corrupt" | "error"

-- Dependencias inyectables. Todas tienen fallback documentado (ver `init`).
export type SaveDeps = {
	-- getSaveData: devuelve el subconjunto persistido del jugador (Req. 16.3).
	getSaveData: ((player: Player) -> SaveData)?,
	-- applySaveData: restaura el estado del jugador desde un guardado (Req. 16.4).
	applySaveData: ((player: Player, data: SaveData) -> ())?,
	-- getActivePlayers: jugadores en partida activa a considerar en `step`/BindToClose.
	getActivePlayers: (() -> { Player })?,
	-- dataStore: override del DataStore (p. ej. mock en memoria para tests). Debe
	-- exponer GetAsync/SetAsync/UpdateAsync compatibles con GlobalDataStore.
	dataStore: any?,
	-- storeName: nombre del DataStore real cuando no se inyecta `dataStore`.
	storeName: string?,
	-- notify: notifica un mensaje al jugador (Req. 16.5, 16.7). Fallback: Remotes.StateUpdate.
	notify: ((player: Player, message: string) -> ())?,
}

--============================================================================
-- Estado del módulo (nivel de servidor)
--============================================================================

local SaveSystem = {}

-- Dependencias resueltas tras `init`. nil hasta inicializar.
local deps: SaveDeps? = nil
-- DataStore resuelto (real o inyectado). nil si no hay acceso a API y no hay mock.
local store: any = nil
-- Acumulador de tiempo por jugador para el temporizador de 120 s (Req. 16.1).
local elapsedByUser: { [number]: number } = {}
-- Conexiones del ciclo de vida, para desconectarlas en un `init` idempotente.
local removingConn: RBXScriptConnection? = nil
-- Marca de si ya se registró el BindToClose (no se puede desconectar; se guarda
-- para no registrar múltiples veces en `init` idempotente).
local bindToCloseRegistered: boolean = false
-- Marca de inicialización efectiva.
local initialized: boolean = false

--============================================================================
-- Fallbacks de dependencias
--============================================================================

-- notifyFallback — Notifica al jugador vía Remotes.StateUpdate. Se requiere
-- Remotes de forma perezosa para no acoplar el arranque del módulo a que los
-- Remotes existan en el momento del `require` (y para no fallar en tests que
-- inyectan su propio `notify`).
local function notifyFallback(player: Player, message: string): ()
	local ok, Remotes = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Remotes"))
	end)
	if ok and Remotes and Remotes.StateUpdate then
		Remotes.StateUpdate:FireClient(player, { kind = "saveNotice", message = message })
	else
		-- Último recurso: registrar el aviso en el servidor (no crítico).
		warn(string.format("[SaveSystem] aviso para %s no entregado: %s", player.Name, message))
	end
end

-- resolveDeps — Devuelve la tabla de dependencias resuelta o lanza si no se ha
-- inicializado. Todos los accesos a dependencias pasan por aquí.
local function resolveDeps(): SaveDeps
	assert(initialized and deps, "SaveSystem no inicializado: llama a SaveSystem.init(deps) primero")
	return deps :: SaveDeps
end

-- notify — Envuelve la dependencia `notify` con su fallback.
local function notify(player: Player, message: string): ()
	local d = resolveDeps()
	local fn = d.notify or notifyFallback
	-- El envío nunca debe tumbar el flujo de guardado; se aísla en pcall.
	pcall(fn, player, message)
end

--============================================================================
-- Acceso al DataStore (única capa de I/O; todo en pcall con reintentos)
--============================================================================

-- resolveStore — Obtiene el DataStore a usar: el inyectado (`deps.dataStore`) o,
-- en su defecto, el real vía DataStoreService:GetDataStore(storeName). La
-- obtención del DataStore real también va en pcall porque `GetDataStore` puede
-- lanzar si la API de DataStores no está disponible (Studio sin acceso a API).
-- Devuelve el store o nil si no se pudo obtener.
local function resolveStore(): any
	local d = resolveDeps()
	if d.dataStore ~= nil then
		return d.dataStore
	end

	local storeName = d.storeName or DEFAULT_STORE_NAME
	local ok, result = pcall(function()
		local DataStoreService = game:GetService("DataStoreService")
		return DataStoreService:GetDataStore(storeName)
	end)
	if ok then
		return result
	end

	warn("[SaveSystem] DataStore no disponible (¿Studio sin acceso a API?): " .. tostring(result))
	return nil
end

-- keyFor — Clave estable por jugador en el DataStore.
local function keyFor(player: Player): string
	return "player_" .. tostring(player.UserId)
end

-- withRetries — Ejecuta `fn` dentro de pcall con reintentos acotados. Devuelve
-- (ok, resultOrError). Entre reintentos espera RETRY_BACKOFF_S. Se usa para toda
-- lectura/escritura contra el DataStore (Req. 16.1, 16.2, 16.5).
local function withRetries(fn: () -> any): (boolean, any)
	local lastErr: any = nil
	for attempt = 0, MAX_RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < MAX_RETRIES then
			task.wait(RETRY_BACKOFF_S)
		end
	end
	return false, lastErr
end

--============================================================================
-- API pública
--============================================================================

--[[
	init — Inicializa el sistema con dependencias inyectadas. IDEMPOTENTE: puede
	llamarse varias veces; desconecta conexiones previas y reinicia el estado sin
	duplicar handlers.

	deps (todos opcionales, con fallback):
	  - getSaveData(player) -> SaveData     (fallback: lanza aviso; sin datos no se guarda)
	  - applySaveData(player, data)          (fallback: no-op con warn)
	  - getActivePlayers() -> {Player}       (fallback: Players:GetPlayers())
	  - dataStore                            (fallback: DataStoreService real)
	  - storeName                            (fallback: "ArcticSurvivorSaves")
	  - notify(player, message)              (fallback: Remotes.StateUpdate)

	Conecta Players.PlayerRemoving y game:BindToClose para guardar al salir (16.2).
	El temporizador de 120 s (16.1) NO usa Heartbeat propio: se conduce con
	`step(dt)` desde el bucle de GameServer.
]]
function SaveSystem.init(newDeps: SaveDeps?): ()
	-- Desconecta conexiones de una inicialización previa (idempotencia).
	if removingConn then
		removingConn:Disconnect()
		removingConn = nil
	end

	deps = newDeps or {}
	elapsedByUser = {}
	initialized = true

	-- Resuelve el DataStore (real o inyectado) una sola vez.
	store = resolveStore()

	-- 16.2: guardar cuando un jugador abandona la partida.
	removingConn = Players.PlayerRemoving:Connect(function(player: Player)
		SaveSystem.saveOnLeave(player)
	end)

	-- 16.2: guardar a todos los jugadores activos al cerrar el servidor. BindToClose
	-- no se puede desconectar, así que se registra solo una vez aunque `init` se
	-- llame de nuevo.
	if not bindToCloseRegistered then
		bindToCloseRegistered = true
		game:BindToClose(function()
			-- En Studio BindToClose concede un margen breve; guardamos secuencialmente.
			local players = SaveSystem.getActivePlayers()
			for _, player in players do
				SaveSystem.saveNow(player)
			end
		end)
	end
end

--[[
	getActivePlayers — Jugadores a considerar en `step`/BindToClose. Usa la
	dependencia inyectada o, por defecto, Players:GetPlayers().
]]
function SaveSystem.getActivePlayers(): { Player }
	local d = resolveDeps()
	if d.getActivePlayers then
		return d.getActivePlayers()
	end
	return Players:GetPlayers()
end

--[[
	load — Carga el guardado de un jugador al entrar (Req. 16.4, 16.6, 16.7).

	Flujo:
	  1. Lee el `raw` del DataStore (GetAsync) dentro de pcall con reintentos.
	  2. Si la lectura FALLA (I/O): devuelve (nil, "error"). El llamador decide;
	     por seguridad NO se debe sobrescribir un guardado que no se pudo leer.
	  3. Si `raw` es nil: no hay partida guardada -> (nil, "new") (Req. 16.6).
	  4. Si hay `raw`: SaveModel.deserialize. Si ok=false -> aviso de corrupción y
	     (nil, "corrupt") (Req. 16.7). Si ok=true -> deps.applySaveData(player, data)
	     y (data, "loaded") (Req. 16.4).

	Devuelve (SaveData?, LoadStatus).
]]
function SaveSystem.load(player: Player): (SaveData?, LoadStatus)
	local d = resolveDeps()

	if store == nil then
		-- Sin DataStore accesible: no se puede afirmar que no haya guardado, así que
		-- se trata como error de I/O (no como partida nueva) para no arriesgar
		-- sobrescribir en un guardado posterior.
		return nil, "error"
	end

	local ok, raw = withRetries(function()
		return store:GetAsync(keyFor(player))
	end)

	if not ok then
		-- Fallo de lectura tras reintentos: I/O error.
		return nil, "error"
	end

	if raw == nil then
		-- 16.6: sin partida guardada -> partida nueva desde Día 1.
		return nil, "new"
	end

	local data, valid = SaveModel.deserialize(raw)
	if not valid or data == nil then
		-- 16.7: guardado corrupto/incompleto -> aviso + partida nueva desde Día 1.
		notify(player, "Tu partida guardada estaba dañada. Empiezas una nueva desde el Día 1.")
		return nil, "corrupt"
	end

	-- 16.4: restaurar exactamente el estado guardado.
	if d.applySaveData then
		d.applySaveData(player, data)
	else
		warn("[SaveSystem] applySaveData no inyectado: guardado leído pero no aplicado")
	end

	return data, "loaded"
end

--[[
	writeSave — Interno. Serializa el SaveData del jugador y lo escribe en el
	DataStore con reintentos (Req. 16.3, 16.5). NO sobrescribe con datos parciales:
	si la obtención del SaveData o la serialización fallan, aborta ANTES de tocar
	el DataStore, dejando intacto el último guardado válido.

	Devuelve true si la escritura se completó; false en cualquier fallo.
]]
local function writeSave(player: Player): boolean
	local d = resolveDeps()

	if store == nil then
		return false
	end

	if not d.getSaveData then
		warn("[SaveSystem] getSaveData no inyectado: no hay datos que guardar")
		return false
	end

	-- Obtener y serializar en pcall: si algo falla, NO se escribe nada (16.5).
	local prepared, serialized = pcall(function()
		local saveData = (d.getSaveData :: any)(player)
		return SaveModel.serialize(saveData)
	end)
	if not prepared then
		warn(string.format("[SaveSystem] preparación de guardado falló para %s: %s", player.Name, tostring(serialized)))
		return false
	end

	-- Escritura con reintentos acotados; todo dentro de pcall (16.5).
	local ok = withRetries(function()
		store:SetAsync(keyFor(player), serialized)
		return true
	end)

	return ok
end

--[[
	saveNow — Fuerza un guardado inmediato del jugador (Req. 16.1, 16.2). Reinicia
	el temporizador de 120 s de ese jugador. Si el guardado falla (I/O o reintentos
	agotados), conserva el guardado previo intacto y notifica al jugador (16.5).

	Devuelve true si el guardado se completó.
]]
function SaveSystem.saveNow(player: Player): boolean
	resolveDeps()
	elapsedByUser[player.UserId] = 0

	local ok = writeSave(player)
	if not ok then
		-- 16.5: no se sobrescribió con datos parciales; se avisa al jugador.
		notify(player, "No se pudo guardar tu progreso. Se reintentará automáticamente.")
	end
	return ok
end

--[[
	saveOnLeave — Guarda al abandonar el jugador la partida (Req. 16.2) y limpia su
	temporizador. Igual que `saveNow` pero pensado para PlayerRemoving; no reintenta
	indefinidamente para no retrasar la salida (reintentos acotados de `writeSave`).

	Devuelve true si el guardado se completó.
]]
function SaveSystem.saveOnLeave(player: Player): boolean
	resolveDeps()
	local ok = writeSave(player)
	if not ok then
		-- El jugador puede haber salido ya; el aviso es best-effort.
		notify(player, "No se pudo guardar tu progreso al salir.")
	end
	elapsedByUser[player.UserId] = nil
	return ok
end

--[[
	step — Avanza el temporizador de guardado automático (Req. 16.1). Lo llama
	GameServer desde su bucle Heartbeat con el `dt` del frame. Por cada jugador
	activo acumula `dt`; cuando alcanza Constants.SAVE.INTERVAL_S (120 s), dispara
	un guardado y reinicia su acumulador.

	No inicia ningún Heartbeat propio: el control del bucle es de GameServer.
]]
function SaveSystem.step(dt: number): ()
	resolveDeps()

	local players = SaveSystem.getActivePlayers()
	-- Conjunto de userIds activos para poder purgar acumuladores obsoletos.
	local active: { [number]: boolean } = {}

	for _, player in players do
		local userId = player.UserId
		active[userId] = true
		local elapsed = (elapsedByUser[userId] or 0) + dt
		if elapsed >= SAVE_INTERVAL_S then
			-- saveNow reinicia el acumulador a 0.
			SaveSystem.saveNow(player)
		else
			elapsedByUser[userId] = elapsed
		end
	end

	-- Purga acumuladores de jugadores que ya no están activos.
	for userId in elapsedByUser do
		if not active[userId] then
			elapsedByUser[userId] = nil
		end
	end
end

return SaveSystem
