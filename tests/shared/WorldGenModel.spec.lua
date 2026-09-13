--!strict
--[[
	WorldGenModel.spec.lua — Prueba de propiedad de la generación del Mundo.

	Feature: juego-supervivencia-artico

	Spec de TestEZ que verifica la Property 10 del diseño: para cualquier semilla,
	`WorldGenModel.generate(seed)` produce un Mundo que satisface TODAS las
	restricciones de distribución del Requisito 5 y que `WorldGenModel.validate`
	acepta (ok == true).

	Además de comprobar que `validate` acepta el Mundo, la prueba verifica
	DIRECTAMENTE las restricciones clave (redundancia deliberada que ejercita a la
	vez el determinismo de `generate` y el acuerdo con `validate`):
	  - exactamente 40 piedras y 60 árboles (Req. 5.4, 5.5);
	  - separación mínima >= 2 entre TODA pareja de colocaciones, es decir,
	    distancia al cuadrado >= 4, y sin solapes (Req. 5.4, 5.5);
	  - ninguna colocación dentro de la banda perimetral (Req. 5.2);
	  - número de lagos en [3, 8] (Req. 5.3).

	Es una prueba PURA: se apoya en el ayudante `PropCheck` (Luau puro) y en el
	módulo bajo prueba (lógica pura en ReplicatedStorage/Shared). No crea Instances
	ni depende del estado del motor. Ejecutable en Studio, Lune o run-in-roblox.

	Validates: Requirements 5.2, 5.3, 5.4, 5.5
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGenModel = require(ReplicatedStorage.Shared.WorldGenModel)
local Constants = require(ReplicatedStorage.Shared.Constants)

-- PropCheck vive en tests/support/PropCheck.lua. Con el mapeo `tests` de
-- default.project.json, este spec (tests/shared/WorldGenModel.spec) se ubica en
-- ReplicatedStorage.Tests.shared.WorldGenModel, así que su ayudante hermano es
-- script.Parent.Parent.support.PropCheck (== ReplicatedStorage.Tests.support.PropCheck).
local PropCheck = require(script.Parent.Parent.support.PropCheck)

local WORLD = Constants.WORLD
local STONE_COUNT = WORLD.STONE_COUNT -- 40
local TREE_COUNT = WORLD.TREE_COUNT -- 60
local MIN_LAKES = WORLD.MIN_LAKES -- 3
local MAX_LAKES = WORLD.MAX_LAKES -- 8
local MIN_SEP = WORLD.MIN_RESOURCE_SEPARATION -- 2
local MIN_SEP_SQ = MIN_SEP * MIN_SEP -- 4
local PERIMETER = WORLD.PERIMETER_BAND -- 20
local MAP_SIZE = WORLD.MAP_SIZE -- 500

-- Número de iteraciones de la prueba de propiedad (mínimo exigido: 100).
local ITERATIONS = 100

return function()
	describe("WorldGenModel — restricciones de distribución del mundo", function()
		it("genera mundos que cumplen las restricciones y que validate acepta", function()
			-- Feature: juego-supervivencia-artico, Property 10: La generación del mundo cumple las restricciones de distribución
			PropCheck.forAll(
				-- Generador: una semilla entera sobre un rango amplio. Se cubre un
				-- espacio grande de semillas para ejercitar el determinismo de generate.
				PropCheck.genInt(0, 2147483647),
				function(seed: number): boolean
					local world = WorldGenModel.generate(seed)

					-- (a) validate DEBE aceptar el mundo generado (Req. 5.2–5.5, acuerdo generate/validate).
					local ok, reason = WorldGenModel.validate(world)
					if not ok then
						error(string.format("validate rechazó un mundo generado: %s", tostring(reason)))
					end

					-- (b) Tamaño y banda perimetral coherentes.
					if world.size ~= MAP_SIZE then
						return false
					end
					if world.perimeter < PERIMETER then
						return false
					end

					-- (c) Número de lagos en [3, 8] (Req. 5.3).
					local lakeCount = #world.lakes
					if lakeCount < MIN_LAKES or lakeCount > MAX_LAKES then
						return false
					end

					-- (d) Conteo exacto: 40 piedras y 60 árboles (Req. 5.4, 5.5).
					local stones = 0
					local trees = 0
					for _, p in world.placements do
						if p.kind == "stone" then
							stones += 1
						elseif p.kind == "tree" then
							trees += 1
						else
							return false
						end
					end
					if stones ~= STONE_COUNT or trees ~= TREE_COUNT then
						return false
					end

					-- (e) Ninguna colocación invade la banda perimetral (Req. 5.2).
					-- El área transitable interior es [PERIMETER, size - PERIMETER - 1].
					local minC = world.perimeter
					local maxC = world.size - world.perimeter - 1
					for _, p in world.placements do
						if p.x < minC or p.x > maxC or p.y < minC or p.y > maxC then
							return false
						end
					end

					-- (f) Separación mínima >= 2 (dist^2 >= 4) y sin solapes, entre
					-- TODA pareja de colocaciones (Req. 5.4, 5.5).
					local placements = world.placements
					local n = #placements
					for i = 1, n - 1 do
						local a = placements[i]
						for j = i + 1, n do
							local b = placements[j]
							local dx = a.x - b.x
							local dy = a.y - b.y
							local distSq = dx * dx + dy * dy
							-- distSq == 0 -> solape; 0 < distSq < 4 -> demasiado cerca.
							if distSq < MIN_SEP_SQ then
								return false
							end
						end
					end

					return true
				end,
				ITERATIONS
			)
		end)
	end)
end
