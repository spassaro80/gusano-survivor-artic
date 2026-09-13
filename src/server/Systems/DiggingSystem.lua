--!strict
--[[
	DiggingSystem.lua — Sistema de servidor autoritativo de excavación de nieve.

	Feature: juego-supervivencia-artico

	Este Script/ModuleScript vive en ServerScriptService/Systems y es "pegamento"
	del motor Roblox (raycasts, partes de Workspace, RemoteEvents): NO es lógica
	pura, pero mantiene la detección geométrica del hueco 2x2x2 aislada en una
	función auxiliar pura (`DiggingSystem.detectHollow`) fácil de razonar y probar.

	Regla arquitectónica: SERVIDOR AUTORITATIVO. El cliente solo envía la intención
	de excavar (origen y dirección de la mira); el servidor valida herramienta,
	distancia y material ANTES de retirar cualquier cubo de nieve.

	Responsabilidades (Requisitos 8.1–8.5):
	  8.1  Con la Pala equipada, apuntando a un bloque de nieve del suelo a <=3 m,
	       al hacer clic se retira EXACTAMENTE un cubo de nieve (dentro de 500 ms).
	  8.2  Al retirar >=8 cubos consecutivos que forman un hueco de al menos 2x2x2,
	       ese espacio se registra como Cueva subterránea accesible por un túnel.
	  8.3  Mientras un Jugador está completamente dentro de una Cueva durante una
	       ventisca, el daño de frío/viento se reduce a cero. Este módulo expone
	       la consulta `isInsideCave(player)` / `isProtected(player)` que consumen
	       NeedsSystem/WeatherSystem para anular ese daño durante la ventisca.
	  8.4  Excavar sobre roca o hielo de lago se rechaza: no se retira cubo alguno
	       y se envía la señal "material no excavable".
	  8.5  Excavar donde la nieve tiene menos de 1 cubo de profundidad se rechaza:
	       no se retira cubo alguno y se envía la señal "no hay nieve suficiente".

	Supuestos de representación del mundo (a coordinar con WorldSystem, tarea 12.1):
	  - Los cubos del terreno son BaseParts con un atributo `kind` (string):
	        kind = "snow"  -> nieve excavable
	        kind = "rock"  -> roca (no excavable, Req. 8.4)
	        kind = "ice"   -> hielo de lago (no excavable, Req. 8.4)
	  - La profundidad de nieve de una columna se expone en el atributo numérico
	    `snowDepth` (en cubos) de la parte de nieve. Si está ausente, se asume 1
	    (la propia parte cuenta como un cubo completo). Una capa de nieve más fina
	    que un cubo se modela con `snowDepth < 1` (Req. 8.5).
	  - La Pala del kit inicial es un `Tool` llamado "Pala" equipado en el personaje.
	  - Los cubos están alineados a una rejilla regular de lado `CUBE_SIZE` studs;
	    en este proyecto 1 stud se trata como 1 metro para las distancias de interacción.

	Uso desde el orquestador (GameServer):
	    local DiggingSystem = require(script.Systems.DiggingSystem)
	    DiggingSystem.init()
	    -- NeedsSystem/WeatherSystem:
	    if weather.blizzardActive and not DiggingSystem.isProtected(player) then ... end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = require(ReplicatedStorage.Remotes)
local Constants = require(ReplicatedStorage.Shared.Constants)

local DiggingSystem = {}

------------------------------------------------------------------------------
-- Constantes de configuración
------------------------------------------------------------------------------

-- Distancia máxima de excavación (Req. 8.1). En metros de diseño; se trata 1
-- stud == 1 metro para las comprobaciones de alcance.
local DIG_MAX_DISTANCE: number = Constants.INTERACTION.DIG_M -- 3

-- Lado del cubo de nieve en studs. Supuesto de rejilla del mundo; debe coincidir
-- con el tamaño de bloque que use WorldSystem al construir el terreno.
local CUBE_SIZE: number = 4

-- Dimensión del hueco mínimo que constituye una Cueva (2x2x2) y número de cubos
-- que contiene (Req. 8.2).
local HOLLOW_DIM: number = 2
local MIN_CUBES_FOR_CAVE: number = 8

-- Tolerancia (studs) entre el origen de la mira enviado por el cliente y el
-- personaje del jugador. Evita que un cliente falsee un origen lejano para
-- excavar fuera de su alcance real (validación autoritativa del Req. 8.1).
local ORIGIN_TOLERANCE: number = 8

-- Materiales excavables / no excavables (atributo `kind`).
local KIND_SNOW: string = "snow"
local KIND_ROCK: string = "rock"
local KIND_ICE: string = "ice"

-- Señales de rechazo enviadas al HUD (Req. 8.4, 8.5).
local REASON_NOT_DIGGABLE: string = "material no excavable"
local REASON_NOT_ENOUGH_SNOW: string = "no hay nieve suficiente"

------------------------------------------------------------------------------
-- Tipos
------------------------------------------------------------------------------

-- Volumen de una Cueva registrada, como caja alineada a ejes (AABB) en mundo.
export type Cave = {
	min: Vector3,
	max: Vector3,
}

-- Conjunto de celdas de la rejilla ya excavadas, indexado por su clave textual.
type CellSet = { [string]: boolean }

------------------------------------------------------------------------------
-- Estado del mundo (autoritativo, global al servidor)
------------------------------------------------------------------------------

-- Cubos de nieve ya retirados, por clave de celda "cx_cy_cz". El mundo es
-- compartido por todos los jugadores del servidor, de modo que el registro es
-- global (no por jugador).
local removedCubes: CellSet = {}

-- Cuevas registradas y su deduplicación por esquina mínima del bloque 2x2x2.
local caves: { Cave } = {}
local registeredCaveCorners: { [string]: boolean } = {}

------------------------------------------------------------------------------
-- Utilidades de rejilla (puras)
------------------------------------------------------------------------------

-- Clave textual estable de una celda entera de la rejilla.
local function cellKey(cx: number, cy: number, cz: number): string
	return string.format("%d_%d_%d", cx, cy, cz)
end

-- Convierte una posición del mundo a coordenadas enteras de celda.
local function worldToCell(pos: Vector3): (number, number, number)
	return math.floor(pos.X / CUBE_SIZE), math.floor(pos.Y / CUBE_SIZE), math.floor(pos.Z / CUBE_SIZE)
end

------------------------------------------------------------------------------
-- Detección geométrica del hueco 2x2x2 (pura)
------------------------------------------------------------------------------

-- ¿Están retiradas TODAS las celdas del bloque 2x2x2 cuya esquina mínima es
-- (ox, oy, oz)? Función pura sobre el conjunto de celdas.
local function isHollowBlock(removed: CellSet, ox: number, oy: number, oz: number): boolean
	for dx = 0, HOLLOW_DIM - 1 do
		for dy = 0, HOLLOW_DIM - 1 do
			for dz = 0, HOLLOW_DIM - 1 do
				if not removed[cellKey(ox + dx, oy + dy, oz + dz)] then
					return false
				end
			end
		end
	end
	return true
end

--[[
	detectHollow — Auxiliar PURA: dada la celda recién excavada (cx, cy, cz) y el
	conjunto de celdas excavadas, devuelve la esquina mínima del primer bloque
	2x2x2 completamente hueco que contiene a esa celda, o `nil` si aún no se forma.

	Un bloque 2x2x2 completo son exactamente 8 cubos consecutivos (Req. 8.2), por
	lo que encontrar uno implica >= MIN_CUBES_FOR_CAVE cubos retirados.

	Se comprueban las 8 posiciones posibles del bloque que pueden contener a la
	celda (desplazamientos -1 y 0 en cada eje).

	@return (ox, oy, oz) esquina mínima del bloque, o nil.
]]
function DiggingSystem.detectHollow(
	removed: CellSet,
	cx: number,
	cy: number,
	cz: number
): (number?, number?, number?)
	for ox = cx - (HOLLOW_DIM - 1), cx do
		for oy = cy - (HOLLOW_DIM - 1), cy do
			for oz = cz - (HOLLOW_DIM - 1), cz do
				if isHollowBlock(removed, ox, oy, oz) then
					return ox, oy, oz
				end
			end
		end
	end
	return nil, nil, nil
end

-- Registra (una sola vez) una Cueva a partir de la esquina mínima del bloque
-- 2x2x2. Devuelve la Cueva creada o `nil` si ya estaba registrada.
local function registerCaveFromCorner(ox: number, oy: number, oz: number): Cave?
	local key = cellKey(ox, oy, oz)
	if registeredCaveCorners[key] then
		return nil
	end
	registeredCaveCorners[key] = true

	local cave: Cave = {
		min = Vector3.new(ox * CUBE_SIZE, oy * CUBE_SIZE, oz * CUBE_SIZE),
		max = Vector3.new((ox + HOLLOW_DIM) * CUBE_SIZE, (oy + HOLLOW_DIM) * CUBE_SIZE, (oz + HOLLOW_DIM) * CUBE_SIZE),
	}
	table.insert(caves, cave)
	return cave
end

------------------------------------------------------------------------------
-- Consulta de material y profundidad (glue de motor)
------------------------------------------------------------------------------

-- Lee el atributo `kind` de una parte del terreno; devuelve nil si no lo tiene.
local function getKind(part: BasePart): string?
	local kind = part:GetAttribute("kind")
	if type(kind) == "string" then
		return kind
	end
	return nil
end

-- Profundidad de nieve (en cubos) de la parte. Si no expone `snowDepth`, se
-- asume 1 (la parte es un cubo completo). Ver supuestos de la cabecera.
local function getSnowDepth(part: BasePart): number
	local depth = part:GetAttribute("snowDepth")
	if type(depth) == "number" then
		return depth
	end
	return 1
end

------------------------------------------------------------------------------
-- Raycast autoritativo
------------------------------------------------------------------------------

-- Personaje y raíz del jugador, si existen.
local function getRoot(player: Player): BasePart?
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

-- ¿Tiene el jugador la Pala equipada? (Tool "Pala" hijo del personaje).
local function hasShovelEquipped(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	local tool = character:FindFirstChildOfClass("Tool")
	return tool ~= nil and tool.Name == "Pala"
end

-- Lanza un rayo desde `origin` en `direction`, acotado a DIG_MAX_DISTANCE,
-- excluyendo a los personajes de los jugadores. Devuelve el RaycastResult o nil.
local function castDigRay(origin: Vector3, direction: Vector3): RaycastResult?
	if direction.Magnitude <= 0 then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(excluded, plr.Character)
		end
	end
	params.FilterDescendantsInstances = excluded

	return workspace:Raycast(origin, direction.Unit * DIG_MAX_DISTANCE, params)
end

-- Envía al cliente la señal de rechazo con el motivo (Req. 8.4, 8.5).
local function signalReject(player: Player, reason: string)
	Remotes.StateUpdate:FireClient(player, {
		kind = "digRejected",
		reason = reason,
	})
end

------------------------------------------------------------------------------
-- Manejo de la intención de excavar
------------------------------------------------------------------------------

--[[
	handleDig — Valida y resuelve una intención de excavación en el servidor.

	Flujo (todo validado en servidor, Req. 8.1–8.5):
	  1. Comprobar que `origin`/`direction` son Vector3 válidos.
	  2. Comprobar que la Pala está equipada; si no, no hay acción.
	  3. Comprobar que el origen de la mira está cerca del personaje (anti-trampa).
	  4. Raycast acotado a 3 m; si no impacta nada, no hay acción.
	  5. Si el material no es nieve (roca/hielo u otro) -> "material no excavable".
	  6. Si la profundidad de nieve < 1 cubo -> "no hay nieve suficiente".
	  7. Retirar EXACTAMENTE un cubo, registrar la celda y comprobar el hueco 2x2x2.

	@return boolean, string?  true si se retiró un cubo; en caso de rechazo,
	                          false y el motivo (útil para pruebas unitarias).
]]
function DiggingSystem.handleDig(player: Player, origin: any, direction: any): (boolean, string?)
	-- (1) Validación de tipos de la carga del cliente.
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return false, "entrada no válida"
	end

	-- (2) Herramienta correcta.
	if not hasShovelEquipped(player) then
		return false, "pala no equipada"
	end

	-- (3) El origen debe estar cerca del personaje (validación autoritativa).
	local root = getRoot(player)
	if not root then
		return false, "sin personaje"
	end
	if (origin - root.Position).Magnitude > ORIGIN_TOLERANCE then
		return false, "origen fuera de alcance"
	end

	-- (4) Raycast acotado a la distancia de excavación.
	local result = castDigRay(origin, direction)
	if not result then
		return false, "sin objetivo"
	end

	local hit = result.Instance
	if not hit or not hit:IsA("BasePart") then
		return false, "sin objetivo"
	end

	-- (5) Material excavable. Roca/hielo (o cualquier no-nieve) se rechaza (Req. 8.4).
	local kind = getKind(hit)
	if kind ~= KIND_SNOW then
		-- Roca, hielo de lago o material desconocido: no excavable.
		signalReject(player, REASON_NOT_DIGGABLE)
		return false, REASON_NOT_DIGGABLE
	end

	-- (6) Profundidad suficiente (Req. 8.5).
	if getSnowDepth(hit) < 1 then
		signalReject(player, REASON_NOT_ENOUGH_SNOW)
		return false, REASON_NOT_ENOUGH_SNOW
	end

	-- (7) Retirar exactamente un cubo de nieve y registrar su celda.
	local cx, cy, cz = worldToCell(hit.Position)
	removedCubes[cellKey(cx, cy, cz)] = true
	hit:Destroy()

	-- Detección del hueco 2x2x2 que registra una Cueva (Req. 8.2).
	local ox, oy, oz = DiggingSystem.detectHollow(removedCubes, cx, cy, cz)
	if ox ~= nil and oy ~= nil and oz ~= nil then
		local cave = registerCaveFromCorner(ox, oy, oz)
		if cave then
			Remotes.StateUpdate:FireClient(player, {
				kind = "caveRegistered",
				min = cave.min,
				max = cave.max,
			})
		end
	end

	return true, nil
end

------------------------------------------------------------------------------
-- Consulta de protección en Cueva (consumida por NeedsSystem/WeatherSystem)
------------------------------------------------------------------------------

-- Punto dentro de una caja alineada a ejes (AABB).
local function pointInBounds(p: Vector3, cave: Cave): boolean
	return p.X >= cave.min.X
		and p.X <= cave.max.X
		and p.Y >= cave.min.Y
		and p.Y <= cave.max.Y
		and p.Z >= cave.min.Z
		and p.Z <= cave.max.Z
end

--[[
	isInsideCave — ¿Está el jugador completamente dentro de alguna Cueva? (Req. 8.3)
	Comprueba la posición de la raíz del personaje contra los volúmenes registrados.
]]
function DiggingSystem.isInsideCave(player: Player): boolean
	local root = getRoot(player)
	if not root then
		return false
	end
	local p = root.Position
	for _, cave in caves do
		if pointInBounds(p, cave) then
			return true
		end
	end
	return false
end

--[[
	isProtected — Alias semántico de `isInsideCave`: el jugador está protegido del
	frío/viento cuando está dentro de una Cueva. NeedsSystem/WeatherSystem aplican
	esta consulta DURANTE la ventisca para anular el daño de frío/viento (Req. 8.3).
]]
function DiggingSystem.isProtected(player: Player): boolean
	return DiggingSystem.isInsideCave(player)
end

------------------------------------------------------------------------------
-- Consultas de estado (útiles para pruebas / otros sistemas)
------------------------------------------------------------------------------

-- Copia superficial de las Cuevas registradas.
function DiggingSystem.getCaves(): { Cave }
	local copy: { Cave } = {}
	for _, cave in caves do
		table.insert(copy, cave)
	end
	return copy
end

------------------------------------------------------------------------------
-- Arranque
------------------------------------------------------------------------------

-- Conecta el RemoteEvent DigAction. Idempotente frente a llamadas repetidas.
local connected = false
function DiggingSystem.init()
	if connected then
		return
	end
	connected = true
	Remotes.DigAction.OnServerEvent:Connect(function(player: Player, origin: any, direction: any)
		DiggingSystem.handleDig(player, origin, direction)
	end)
end

return DiggingSystem
