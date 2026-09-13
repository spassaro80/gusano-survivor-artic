--!strict
--[[
	WorldGenModel.lua — Generación y validación PURA de la distribución del Mundo.

	Feature: juego-supervivencia-artico

	ModuleScript de lógica PURA ubicado en ReplicatedStorage/Shared. NO depende
	del motor de Roblox: no crea Instances, no accede a Workspace y no lee estado
	del motor. Solo calcula estructuras de datos a partir de una semilla.

	Determinismo: la generación es completamente reproducible dada una semilla.
	Para garantizar pureza total y reproducibilidad en cualquier entorno (Studio,
	Lune, run-in-Roblox) se implementa un PRNG propio (xorshift de 32 bits sobre
	`bit32`), en lugar de depender de `Random.new`. Con la misma semilla, `generate`
	produce SIEMPRE el mismo Mundo.

	Restricciones de distribución (Requisito 5):
	  - Mapa de 500x500 bloques (tamaño desde Constants.WORLD.MAP_SIZE). (5.1)
	  - Banda perimetral infranqueable de >= 20 bloques de ancho. (5.2)
	  - Entre 3 y 8 lagos helados en zonas bajas, sin solapar el perímetro. (5.3)
	  - Exactamente 40 bloques de piedra, sin solape, separación mínima 2. (5.4)
	  - Exactamente 60 árboles interactivos, sin solape, separación mínima 2. (5.5)
	  - Si no se cumplen las restricciones, `validate` devuelve (false, razón) para
	    que la capa de servidor impida iniciar la partida tras 3 reintentos. (5.6)

	Requisitos cubiertos: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

type Placement = Types.Placement
type Region = Types.Region
type World = Types.World

-- Constantes de distribución del Mundo (Req. 5).
local MAP_SIZE: number = Constants.WORLD.MAP_SIZE -- 500
local PERIMETER: number = Constants.WORLD.PERIMETER_BAND -- 20
local STONE_COUNT: number = Constants.WORLD.STONE_COUNT -- 40
local TREE_COUNT: number = Constants.WORLD.TREE_COUNT -- 60
local MIN_LAKES: number = Constants.WORLD.MIN_LAKES -- 3
local MAX_LAKES: number = Constants.WORLD.MAX_LAKES -- 8
local MIN_SEP: number = Constants.WORLD.MIN_RESOURCE_SEPARATION -- 2

-- La separación mínima se comprueba con distancia euclídea al cuadrado para
-- evitar aritmética en coma flotante (dist >= MIN_SEP  <=>  dist^2 >= MIN_SEP^2).
local MIN_SEP_SQ: number = MIN_SEP * MIN_SEP

local WorldGenModel = {}

--============================================================================
-- PRNG puro (xorshift de 32 bits). Determinista y sin dependencias del motor.
--============================================================================

type Rng = () -> number

-- makeRng — Crea un generador determinista a partir de una semilla entera.
-- Devuelve una función que produce números en el rango semiabierto [0, 1).
-- Usa `bit32` (aritmética de 32 bits pura), evitando el desbordamiento de
-- precisión de coma flotante que tendría un LCG multiplicativo grande.
local function makeRng(seed: number): Rng
	-- Normaliza la semilla a un entero de 32 bits sin signo distinto de 0.
	local state = bit32.band(math.floor(seed), 0xFFFFFFFF)
	if state == 0 then
		state = 0x9E3779B9 -- constante no nula (fracción áurea) para semilla 0
	end
	return function(): number
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		-- bit32.* devuelve enteros sin signo en [0, 2^32); normaliza a [0, 1).
		return state / 4294967296
	end
end

-- randInt — Entero uniforme en el rango cerrado [lo, hi] a partir del PRNG.
local function randInt(rng: Rng, lo: number, hi: number): number
	return lo + math.floor(rng() * (hi - lo + 1))
end

--============================================================================
-- Ayudantes de geometría (puros)
--============================================================================

-- invadesPerimeter — Indica si una celda (x, y) cae dentro de la banda
-- perimetral infranqueable o fuera de los límites del mapa (Req. 5.2).
-- El área transitable interior es [PERIMETER, size - PERIMETER - 1] en cada eje.
local function invadesPerimeter(x: number, y: number, size: number, perimeter: number): boolean
	local minC = perimeter
	local maxC = size - perimeter - 1
	return x < minC or x > maxC or y < minC or y > maxC
end

-- insideRegion — Indica si la celda (x, y) cae dentro de la región rectangular.
local function insideRegion(x: number, y: number, region: Region): boolean
	return x >= region.x
		and x <= region.x + region.width - 1
		and y >= region.y
		and y <= region.y + region.height - 1
end

-- insideAnyLake — Indica si la celda (x, y) cae dentro de algún lago.
local function insideAnyLake(x: number, y: number, lakes: { Region }): boolean
	for _, lake in lakes do
		if insideRegion(x, y, lake) then
			return true
		end
	end
	return false
end

-- respectsSeparation — Comprueba que (x, y) mantiene la separación mínima con
-- todas las colocaciones ya existentes (Req. 5.4, 5.5). Devuelve false si la
-- nueva celda solapa o queda demasiado cerca de alguna colocación previa.
local function respectsSeparation(x: number, y: number, placements: { Placement }): boolean
	for _, p in placements do
		local dx = x - p.x
		local dy = y - p.y
		if dx * dx + dy * dy < MIN_SEP_SQ then
			return false
		end
	end
	return true
end

--============================================================================
-- Generación
--============================================================================

-- generateLakes — Coloca entre 3 y 8 lagos helados dentro del área interior,
-- sin solapar la banda perimetral (Req. 5.3). Los lagos representan las zonas
-- de menor elevación; al no existir un mapa de elevación real, se distribuyen
-- de forma determinista dentro de los límites transitables.
local function generateLakes(rng: Rng, size: number, perimeter: number): { Region }
	local lakes: { Region } = {}
	local count = randInt(rng, MIN_LAKES, MAX_LAKES)
	local minC = perimeter
	local maxC = size - perimeter - 1

	for _ = 1, count do
		-- Lagos GRANDES: dimensiones amplias que aún caben en el interior sin invadir
		-- la banda perimetral (x + width - 1 <= maxC garantizado por el rango de x).
		local width = randInt(rng, 32, 72)
		local height = randInt(rng, 32, 72)
		local x = randInt(rng, minC, maxC - width + 1)
		local y = randInt(rng, minC, maxC - height + 1)
		table.insert(lakes, { x = x, y = y, width = width, height = height })
	end

	return lakes
end

-- placeResources — Coloca `count` recursos de un tipo mediante muestreo por
-- rechazo: dentro del área interior, sin invadir el perímetro, sin caer sobre
-- un lago y respetando la separación mínima frente a TODO lo ya colocado.
-- Acumula sobre la tabla `placements` (piedras + árboles comparten separación).
local function placeResources(
	rng: Rng,
	kind: "stone" | "tree",
	count: number,
	size: number,
	perimeter: number,
	lakes: { Region },
	placements: { Placement }
): boolean
	local minC = perimeter
	local maxC = size - perimeter - 1
	-- Cota de intentos generosa; el área interior (~460x460) admite de sobra
	-- 100 colocaciones con separación 2, así que en la práctica no se agota.
	local maxAttempts = count * 2000
	local placed = 0
	local attempts = 0

	while placed < count and attempts < maxAttempts do
		attempts += 1
		local x = randInt(rng, minC, maxC)
		local y = randInt(rng, minC, maxC)
		if not insideAnyLake(x, y, lakes) and respectsSeparation(x, y, placements) then
			table.insert(placements, { x = x, y = y, kind = kind })
			placed += 1
		end
	end

	return placed == count
end

--[[
	generate — Produce un Mundo determinista a partir de una semilla.

	Mapa de `MAP_SIZE`x`MAP_SIZE`, banda perimetral de `PERIMETER` bloques,
	entre 3 y 8 lagos en el interior, y exactamente 40 piedras + 60 árboles
	dentro de los límites, sin solapes, con separación mínima de 2 bloques y sin
	invadir el perímetro (Req. 5.1–5.5).

	La misma semilla produce siempre el mismo Mundo. El resultado debería pasar
	`validate`; la capa de servidor puede reintentar con otra semilla y, si tras
	3 intentos no se valida, impedir el inicio de la partida (Req. 5.6).
]]
function WorldGenModel.generate(seed: number): World
	local rng = makeRng(seed)

	local lakes = generateLakes(rng, MAP_SIZE, PERIMETER)

	local placements: { Placement } = {}
	placeResources(rng, "stone", STONE_COUNT, MAP_SIZE, PERIMETER, lakes, placements)
	placeResources(rng, "tree", TREE_COUNT, MAP_SIZE, PERIMETER, lakes, placements)

	return {
		size = MAP_SIZE,
		lakes = lakes,
		perimeter = PERIMETER,
		placements = placements,
		seed = seed,
	}
end

--============================================================================
-- Validación
--============================================================================

--[[
	validate — Comprueba TODAS las restricciones de distribución del Mundo.

	Devuelve (true, nil) si el Mundo cumple todas las restricciones, o
	(false, razón) indicando la primera restricción incumplida:
	  - tamaño y perímetro coherentes (>= 20);
	  - número de lagos entre 3 y 8;
	  - exactamente 40 piedras y 60 árboles;
	  - ninguna colocación invade el perímetro ni sale de los límites;
	  - ninguna pareja de colocaciones solapa ni incumple la separación mínima 2.
	(Req. 5.2, 5.3, 5.4, 5.5, 5.6)
]]
function WorldGenModel.validate(world: World): (boolean, string?)
	local size = world.size
	local perimeter = world.perimeter

	-- Tamaño y banda perimetral coherentes.
	if size ~= MAP_SIZE then
		return false, string.format("tamaño de mapa inválido: %d (esperado %d)", size, MAP_SIZE)
	end
	if perimeter < PERIMETER then
		return false, string.format("banda perimetral insuficiente: %d (mínimo %d)", perimeter, PERIMETER)
	end

	-- Número de lagos en el rango [3, 8].
	local lakeCount = #world.lakes
	if lakeCount < MIN_LAKES or lakeCount > MAX_LAKES then
		return false, string.format("número de lagos fuera de rango: %d (esperado %d-%d)", lakeCount, MIN_LAKES, MAX_LAKES)
	end

	-- Los lagos no deben invadir la banda perimetral.
	for _, lake in world.lakes do
		if
			invadesPerimeter(lake.x, lake.y, size, perimeter)
			or invadesPerimeter(lake.x + lake.width - 1, lake.y + lake.height - 1, size, perimeter)
		then
			return false, "un lago invade la banda perimetral"
		end
	end

	-- Conteo exacto de piedras y árboles.
	local stones = 0
	local trees = 0
	for _, p in world.placements do
		if p.kind == "stone" then
			stones += 1
		elseif p.kind == "tree" then
			trees += 1
		else
			return false, string.format("tipo de colocación desconocido: %s", tostring(p.kind))
		end
	end
	if stones ~= STONE_COUNT then
		return false, string.format("número de piedras inválido: %d (esperado %d)", stones, STONE_COUNT)
	end
	if trees ~= TREE_COUNT then
		return false, string.format("número de árboles inválido: %d (esperado %d)", trees, TREE_COUNT)
	end

	-- Ninguna colocación invade el perímetro ni sale de los límites.
	for _, p in world.placements do
		if invadesPerimeter(p.x, p.y, size, perimeter) then
			return false, string.format("colocación fuera del área transitable en (%d, %d)", p.x, p.y)
		end
	end

	-- Sin solapes y con separación mínima entre TODAS las colocaciones.
	local placements = world.placements
	local n = #placements
	for i = 1, n - 1 do
		local a = placements[i]
		for j = i + 1, n do
			local b = placements[j]
			local dx = a.x - b.x
			local dy = a.y - b.y
			local distSq = dx * dx + dy * dy
			if distSq == 0 then
				return false, string.format("colocaciones solapadas en (%d, %d)", a.x, a.y)
			end
			if distSq < MIN_SEP_SQ then
				return false, string.format("separación mínima incumplida cerca de (%d, %d)", a.x, a.y)
			end
		end
	end

	return true, nil
end

return WorldGenModel
