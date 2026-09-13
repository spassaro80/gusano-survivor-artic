--!strict
--[[
	PropCheck.lua — Ayudante ligero de *property-based testing* para Luau.

	Feature: juego-supervivencia-artico

	Utilidad de PRUEBAS (no forma parte del juego). Está pensada para usarse
	desde specs de TestEZ, pero es Luau PURO: NO requiere el motor de Roblox en
	tiempo de carga (no llama a `game:GetService`, no toca `Workspace`, ni crea
	Instances). Gracias a ello puede ejecutarse indistintamente dentro de Roblox
	Studio o con runners externos como Lune / run-in-roblox.

	Motivación (ver Testing Strategy del diseño): al no existir un estándar
	consolidado de PBT para Luau equivalente a QuickCheck / Hypothesis / fast-check,
	este módulo aporta lo mínimo imprescindible:
	  - un PRNG determinista sembrado (para reproducir contraejemplos), y
	  - un conjunto de generadores base componibles,
	  - un runner `forAll` que evalúa una propiedad sobre >= 100 casos y, ante un
	    fallo, lanza un error que incluye el caso falsante SERIALIZADO y la SEMILLA
	    usada, de modo que el contraejemplo sea 100% reproducible.

	Determinismo: el PRNG replica el enfoque de `src/shared/WorldGenModel.lua`
	(xorshift de 32 bits sobre `bit32`), evitando `Random.new` para garantizar
	el mismo resultado en cualquier entorno con la misma semilla.

	CONVENCIÓN DE ETIQUETADO DE PROPIEDADES
	---------------------------------------
	Cada prueba de propiedad escrita con este ayudante DEBE etiquetarse con un
	comentario que referencie la propiedad del diseño, con el formato exacto:

	    -- Feature: juego-supervivencia-artico, Property {n}: {texto}

	Ejemplo de uso dentro de un spec de TestEZ:

	    local PropCheck = require(script.Parent.Parent.support.PropCheck)

	    it("mantiene las necesidades en [0, 100]", function()
	        -- Feature: juego-supervivencia-artico, Property 1: Las necesidades permanecen acotadas en [0, 100]
	        PropCheck.forAll(
	            function(rng)
	                return {
	                    heat = PropCheck.genNumber(0, 100)(rng),
	                    dt = PropCheck.genNumber(0, 5)(rng),
	                }
	            end,
	            function(case)
	                local n = NeedsModel.step(...)
	                return n.heat >= 0 and n.heat <= 100
	            end
	        )
	    end)

	Infraestructura de soporte para las Propiedades 1-12 (sin requisito funcional
	directo).
]]

local PropCheck = {}

--============================================================================
-- Tipos
--============================================================================

-- Rng — Fuente de aleatoriedad: función sin argumentos que devuelve un número
-- en el rango semiabierto [0, 1).
export type Rng = () -> number

-- Generator<T> — Recibe un `Rng` y produce un valor de tipo T. Los generadores
-- son componibles: un generador puede invocar a otros con el mismo `rng`.
export type Generator<T> = (Rng) -> T

-- Predicate<T> — La propiedad a comprobar. Devuelve `true` si el caso la cumple,
-- `false` (o lanza un error) si la falsa.
export type Predicate<T> = (T) -> boolean

--============================================================================
-- PRNG determinista (xorshift de 32 bits). Sin dependencias del motor.
-- Mismo enfoque que src/shared/WorldGenModel.lua para consistencia.
--============================================================================

--[[
	newRng — Crea un generador determinista a partir de una semilla entera.

	Devuelve una función `() -> number` que produce valores uniformes en el
	rango semiabierto [0, 1). Con la misma semilla, la secuencia es idéntica en
	cualquier entorno (Studio, Lune, run-in-roblox).
]]
function PropCheck.newRng(seed: number): Rng
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

-- deriveSeed — Deriva una semilla no determinista cuando la persona que llama
-- no proporciona una. Usa relojes puros de Luau (`os.clock`, `os.time`) para no
-- depender del motor de Roblox. La semilla resultante se REGISTRA y se reporta
-- en los fallos para poder reproducir el contraejemplo pasándola de vuelta.
local function deriveSeed(): number
	local clockPart = math.floor((os.clock() % 1) * 1e9)
	local timePart = os.time()
	return bit32.band(clockPart + timePart * 2654435761, 0xFFFFFFFF)
end

--============================================================================
-- Serialización de casos (para mensajes de fallo legibles y reproducibles)
--============================================================================

-- serialize — Convierte un valor Luau arbitrario en una cadena legible, apta
-- para incrustar en el mensaje de error de un contraejemplo. Soporta nil,
-- boolean, number, string y tablas anidadas (arrays y diccionarios). Protege
-- frente a referencias cíclicas.
local function serialize(value: any, seen: { [any]: boolean }?): string
	local t = typeof(value)
	if value == nil then
		return "nil"
	elseif t == "boolean" or t == "number" then
		return tostring(value)
	elseif t == "string" then
		return string.format("%q", value)
	elseif t == "table" then
		local visited = seen or {}
		if visited[value] then
			return "<cycle>"
		end
		visited[value] = true

		local parts: { string } = {}
		-- Parte de array (índices contiguos 1..n).
		local n = #value
		for i = 1, n do
			table.insert(parts, serialize(value[i], visited))
		end
		-- Parte de diccionario (claves no numéricas del array), ordenada para
		-- que la salida sea estable entre ejecuciones.
		local keys: { any } = {}
		for k in pairs(value) do
			if not (type(k) == "number" and k >= 1 and k <= n and math.floor(k) == k) then
				table.insert(keys, k)
			end
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, k in keys do
			table.insert(parts, string.format("[%s] = %s", serialize(k, visited), serialize(value[k], visited)))
		end

		visited[value] = nil
		return "{ " .. table.concat(parts, ", ") .. " }"
	else
		-- Instances, funciones, etc. No deberían aparecer en la lógica pura.
		return string.format("<%s>", t)
	end
end

PropCheck.serialize = serialize

--============================================================================
-- Runner de propiedades
--============================================================================

local DEFAULT_ITERATIONS = 100
local MIN_ITERATIONS = 100

--[[
	forAll — Evalúa una propiedad sobre múltiples casos generados.

	Ejecuta `predicate(value)` para `iterations` valores producidos por
	`generator(rng)`. Por defecto realiza 100 iteraciones y NUNCA menos de 100
	(cualquier valor inferior se eleva al mínimo).

	El runner elige una semilla (usa `seed` si se proporciona; si no, deriva una)
	y la REGISTRA, de modo que ante un fallo el mensaje incluye tanto el caso
	falsante SERIALIZADO como la SEMILLA, haciendo el contraejemplo reproducible:
	basta con volver a llamar a `forAll(gen, pred, iterations, seed)` con esa
	misma semilla.

	`predicate` debe devolver un booleano; si devuelve `false` o lanza un error,
	se considera que el caso falsa la propiedad y `forAll` lanza un error
	descriptivo. Si todos los casos pasan, `forAll` retorna con normalidad.

	@param generator  produce el caso de prueba a partir del `rng`
	@param predicate  la propiedad a verificar sobre cada caso
	@param iterations (opcional) número de casos; por defecto y mínimo 100
	@param seed       (opcional) semilla explícita para reproducir un fallo
	@return la semilla usada (útil para depurar / registrar)
]]
function PropCheck.forAll<T>(
	generator: Generator<T>,
	predicate: Predicate<T>,
	iterations: number?,
	seed: number?
): number
	local count = math.max(iterations or DEFAULT_ITERATIONS, MIN_ITERATIONS)
	local usedSeed = seed or deriveSeed()
	local rng = PropCheck.newRng(usedSeed)

	for i = 1, count do
		local case = generator(rng)

		-- Envolver la evaluación para capturar tanto el `false` explícito como
		-- cualquier error lanzado dentro del predicado.
		local ok, result = pcall(predicate, case)

		if not ok then
			-- El predicado lanzó un error (p. ej. un assert interno).
			error(
				string.format(
					"PropCheck: propiedad falsada por error en la iteración %d/%d\n"
						.. "  semilla   = %d\n"
						.. "  caso      = %s\n"
						.. "  error     = %s",
					i,
					count,
					usedSeed,
					serialize(case),
					tostring(result)
				),
				2
			)
		elseif result == false then
			-- El predicado devolvió `false`: contraejemplo encontrado.
			error(
				string.format(
					"PropCheck: propiedad falsada en la iteración %d/%d\n"
						.. "  semilla   = %d\n"
						.. "  caso      = %s",
					i,
					count,
					usedSeed,
					serialize(case)
				),
				2
			)
		end
		-- Cualquier otro valor de retorno truthy se considera "propiedad cumplida".
	end

	return usedSeed
end

--============================================================================
-- Generadores base
--============================================================================

--[[
	genNumber — Generador de números reales uniformes en el rango cerrado
	[min, max]. Útil para `dt`, valores de necesidades, etc.
]]
function PropCheck.genNumber(min: number, max: number): Generator<number>
	assert(max >= min, "PropCheck.genNumber: max debe ser >= min")
	return function(rng: Rng): number
		return min + rng() * (max - min)
	end
end

--[[
	genInt — Generador de enteros uniformes en el rango cerrado [min, max].
]]
function PropCheck.genInt(min: number, max: number): Generator<number>
	local lo = math.floor(min)
	local hi = math.floor(max)
	assert(hi >= lo, "PropCheck.genInt: max debe ser >= min")
	return function(rng: Rng): number
		-- +1 para incluir el extremo superior; math.min protege el caso límite
		-- improbable en que rng() devuelva un valor muy cercano a 1.
		return math.min(hi, lo + math.floor(rng() * (hi - lo + 1)))
	end
end

--[[
	genBool — Generador booleano uniforme (50/50).
]]
function PropCheck.genBool(): Generator<boolean>
	return function(rng: Rng): boolean
		return rng() < 0.5
	end
end

--[[
	genArray — Construye un generador de arrays cuyos elementos produce `elemGen`.
	La longitud es aleatoria en [0, maxLen]. Sirve para generar secuencias de
	operaciones (p. ej. add/remove sobre la Neverita) o listas de valores.
]]
function PropCheck.genArray<T>(elemGen: Generator<T>, maxLen: number): Generator<{ T }>
	local cap = math.max(0, math.floor(maxLen))
	return function(rng: Rng): { T }
		local len = math.min(cap, math.floor(rng() * (cap + 1)))
		local result: { T } = {}
		for i = 1, len do
			result[i] = elemGen(rng)
		end
		return result
	end
end

--[[
	genOneOf — Elige uniformemente uno de los valores de una lista fija.
	Útil para estados discretos ("Raw"/"Cooked"/"Burned", tipos de recurso, etc.).
]]
function PropCheck.genOneOf<T>(list: { T }): Generator<T>
	local n = #list
	assert(n > 0, "PropCheck.genOneOf: la lista no puede estar vacía")
	return function(rng: Rng): T
		local index = math.min(n, 1 + math.floor(rng() * n))
		return list[index]
	end
end

return PropCheck
