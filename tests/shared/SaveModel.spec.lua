--!strict
--[[
	SaveModel.spec.lua — Pruebas de propiedad del guardado (Properties 11 y 12).

	Feature: juego-supervivencia-artico

	Spec de TestEZ para la capa de lógica pura `ReplicatedStorage/Shared/SaveModel`.
	Verifica DOS propiedades del diseño con >= 100 iteraciones usando el ayudante
	de property-based testing `PropCheck` (Luau puro, determinista y sembrado):

	  - Property 11 (round-trip serializar → deserializar). Requiere el motor de
	    Roblox porque `serialize`/`deserialize` usan `HttpService` (JSONEncode/
	    JSONDecode) internamente. Se ejecuta dentro de Roblox Studio / TestEZ.
	  - Property 12 (detección de guardados corruptos o incompletos). La parte de
	    `isValid` es PURA; los casos de cadena JSON corrupta usan `HttpService`
	    para codificar y también corren dentro de Studio.

	Requiere el módulo bajo prueba a través del árbol de Rojo
	(`ReplicatedStorage.Shared.SaveModel`) y `PropCheck` a través del árbol de
	pruebas (`script.Parent.Parent.support.PropCheck`), que `default.project.json`
	mapea desde la carpeta `tests` en disco.

	Ejecución diferida: no hay runtime de Roblox/Lune disponible en este entorno;
	la suite se ejecuta con TestEZ dentro de Roblox Studio o con Lune/run-in-roblox.

	Cubre: Property 11 (Req. 16.3, 16.4), Property 12 (Req. 16.7).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local SaveModel = require(ReplicatedStorage.Shared.SaveModel)
local Constants = require(ReplicatedStorage.Shared.Constants)

-- PropCheck vive en tests/support; desde este spec (tests/shared/SaveModel.spec)
-- se alcanza subiendo a la raíz `Tests` y bajando a `support`.
local PropCheck = require(script.Parent.Parent.support.PropCheck)

local FORMAT_VERSION: number = Constants.SAVE.FORMAT_VERSION -- 1 (Req. 16.3, 16.7)
local CAPACITY: number = Constants.COOLER.CAPACITY -- 30 (Req. 10.2)

-- genValidSaveData — Genera un SaveData bien formado y dentro de rango.
-- version = FORMAT_VERSION; pos con x/y/z finitos aleatorios; day >= 1;
-- wood/stone >= 0; coolerFish en [0, 30]; freeMode booleano.
local function genValidSaveData(rng: PropCheck.Rng)
	return {
		version = FORMAT_VERSION,
		pos = {
			x = PropCheck.genNumber(-10000, 10000)(rng),
			y = PropCheck.genNumber(-10000, 10000)(rng),
			z = PropCheck.genNumber(-10000, 10000)(rng),
		},
		day = PropCheck.genInt(1, 999)(rng),
		wood = PropCheck.genInt(0, 500)(rng),
		stone = PropCheck.genInt(0, 500)(rng),
		coolerFish = PropCheck.genInt(0, CAPACITY)(rng),
		freeMode = PropCheck.genBool()(rng),
	}
end

return function()
	describe("SaveModel (Property 11)", function()
		it("preserva los datos en un ciclo serializar → deserializar", function()
			-- Feature: juego-supervivencia-artico, Property 11: El guardado preserva los datos en un ciclo serializar → deserializar
			--
			-- Para todo SaveData válido `x`, deserialize(serialize(x)) devuelve
			-- ok == true y un valor igual campo a campo a `x` (pos.x/y/z, day,
			-- wood, stone, coolerFish, freeMode, version).
			PropCheck.forAll(genValidSaveData, function(x)
				local raw = SaveModel.serialize(x)
				local data, ok = SaveModel.deserialize(raw)

				if ok ~= true then
					return false
				end
				if data == nil then
					return false
				end

				-- Igualdad campo a campo.
				if data.version ~= x.version then
					return false
				end
				if data.pos.x ~= x.pos.x or data.pos.y ~= x.pos.y or data.pos.z ~= x.pos.z then
					return false
				end
				if data.day ~= x.day then
					return false
				end
				if data.wood ~= x.wood then
					return false
				end
				if data.stone ~= x.stone then
					return false
				end
				if data.coolerFish ~= x.coolerFish then
					return false
				end
				if data.freeMode ~= x.freeMode then
					return false
				end

				return true
			end, 100)
		end)
	end)

	describe("SaveModel (Property 12)", function()
		it("detecta guardados corruptos o incompletos", function()
			-- Feature: juego-supervivencia-artico, Property 12: Los guardados corruptos o incompletos se detectan
			--
			-- Para toda entrada mal formada, deserialize devuelve (nil, false) e
			-- `isValid` sobre la tabla corrupta devuelve false. Se cubren:
			--   (a) entradas que no son cadena (number/boolean/table/nil),
			--   (b) cadenas que no son JSON válido,
			--   (c) JSON válido de una tabla con un campo faltante o fuera de rango
			--       (coolerFish > 30, wood/stone negativos, day < 1, version desconocida).
			--
			-- El generador parte de un SaveData válido y "corrompe" exactamente un
			-- aspecto, seleccionando aleatoriamente entre las tres familias de fallo.

			-- Lista de campos que se pueden eliminar para provocar "incompleto".
			local removableFields = { "version", "pos", "day", "wood", "stone", "coolerFish", "freeMode" }

			-- genCase — Produce un caso de corrupción con su "tipo".
			-- Devuelve { kind, raw?, badTable? } donde:
			--   kind = "non-string" | "invalid-json" | "bad-table"
			--   raw     : la entrada a pasar a deserialize (cualquier tipo)
			--   badTable: la tabla que se espera que isValid rechace (solo bad-table)
			local function genCase(rng: PropCheck.Rng)
				local choice = PropCheck.genInt(1, 3)(rng)

				if choice == 1 then
					-- (a) Entrada que no es cadena: number, boolean, table o nil.
					local variants: { any } = {
						PropCheck.genNumber(-100, 100)(rng),
						PropCheck.genBool()(rng),
						{ some = "table" },
					}
					local idx = PropCheck.genInt(1, #variants + 1)(rng)
					local raw: any = if idx <= #variants then variants[idx] else nil
					return { kind = "non-string", raw = raw }
				elseif choice == 2 then
					-- (b) Cadena que no es JSON válido.
					local junk: { string } = {
						"{ this is not json",
						"not json at all",
						"{ \"version\": 1, ",
						"]]]}}}",
						"{ unterminated: ",
					}
					local raw = PropCheck.genOneOf(junk)(rng)
					return { kind = "invalid-json", raw = raw }
				else
					-- (c) JSON válido de una tabla corrupta: partimos de un válido y
					-- rompemos exactamente un aspecto.
					local base = genValidSaveData(rng)
					local mode = PropCheck.genInt(1, 6)(rng)

					if mode == 1 then
						-- Campo faltante: eliminar uno al azar.
						local field = PropCheck.genOneOf(removableFields)(rng)
						base[field] = nil
					elseif mode == 2 then
						-- coolerFish fuera de rango (> 30).
						base.coolerFish = CAPACITY + PropCheck.genInt(1, 50)(rng)
					elseif mode == 3 then
						-- wood negativo.
						base.wood = -PropCheck.genInt(1, 100)(rng)
					elseif mode == 4 then
						-- stone negativo.
						base.stone = -PropCheck.genInt(1, 100)(rng)
					elseif mode == 5 then
						-- day < 1.
						base.day = PropCheck.genInt(-50, 0)(rng)
					else
						-- version desconocida.
						base.version = FORMAT_VERSION + PropCheck.genInt(1, 9)(rng)
					end

					return { kind = "bad-table", badTable = base }
				end
			end

			PropCheck.forAll(genCase, function(case)
				if case.kind == "bad-table" then
					-- isValid PURA debe rechazar la tabla corrupta.
					if SaveModel.isValid(case.badTable) ~= false then
						return false
					end

					-- Y su forma JSON debe rechazarse en deserialize (nil, false).
					local raw = HttpService:JSONEncode(case.badTable)
					local data, ok = SaveModel.deserialize(raw)
					if ok ~= false or data ~= nil then
						return false
					end
				else
					-- non-string / invalid-json: deserialize devuelve (nil, false).
					local data, ok = SaveModel.deserialize(case.raw)
					if ok ~= false or data ~= nil then
						return false
					end
				end

				return true
			end, 100)
		end)
	end)
end
