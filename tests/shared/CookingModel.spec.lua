--!strict
--[[
	CookingModel.spec.lua — Prueba de propiedad de la máquina de estados de cocinado.

	Feature: juego-supervivencia-artico
	Tarea 6.2 — Property 8: transiciones ordenadas y confluencia temporal.

	Spec de TestEZ (lógica pura). Verifica que `CookingModel.step`:
	  (a) deriva el estado del tiempo TOTAL acumulado sobre el fuego
	      (Raw si total<10, Cooked si 10<=total<18, Burned si total>=18),
	  (b) el estado nunca retrocede a lo largo de la secuencia de pasos (monotonía),
	  (c) es CONFLUENTE: el estado final tras trocear el tiempo en múltiples `dt`
	      coincide con el de un único `step` aplicado al tiempo total acumulado.

	El módulo bajo prueba vive en ReplicatedStorage/Shared (Rojo). El ayudante de
	property-based testing PropCheck vive en ReplicatedStorage/Tests/support.

	Validates: Requirements 13.8, 13.10
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local CookingModel = require(Shared.CookingModel)
-- Tests.shared.CookingModel.spec -> Tests.support.PropCheck
local PropCheck = require(script.Parent.Parent.support.PropCheck)

-- Umbrales del diseño (Req. 13.8 / 13.10). Se replican como literales para que
-- la prueba sea un oráculo INDEPENDIENTE de la implementación del módulo.
local RAW_TO_COOKED_S = 10
local TOTAL_TO_BURNED_S = 18

-- Rango de avance de un estado (Raw < Cooked < Burned) para comprobar monotonía.
local RANK = { Raw = 0, Cooked = 1, Burned = 2 }

-- Estado esperado a partir del tiempo total acumulado sobre el fuego.
local function expectedState(total: number): string
	if total >= TOTAL_TO_BURNED_S then
		return "Burned"
	elseif total >= RAW_TO_COOKED_S then
		return "Cooked"
	else
		return "Raw"
	end
end

return function()
	describe("CookingModel", function()
		it("transita en orden y es confluente en el tiempo (Property 8)", function()
			-- Feature: juego-supervivencia-artico, Property 8: La máquina de estados de cocinado transita en orden y es confluente en el tiempo
			PropCheck.forAll(
				-- Genera una secuencia de rebanadas de tiempo positivas (0..5 s cada una).
				function(rng)
					local slices = PropCheck.genArray(PropCheck.genNumber(0, 5), 12)(rng)
					return { slices = slices }
				end,
				function(case)
					-- Partimos SIEMPRE de un pez crudo con 0 s sobre el fuego.
					local fish = { state = "Raw", timeOnFire = 0 }
					local total = 0
					local lastRank = RANK.Raw

					for _, dt in case.slices do
						fish = CookingModel.step(fish, dt)
						total += dt

						-- (a) El estado deriva del tiempo total acumulado.
						if fish.state ~= expectedState(total) then
							return false
						end

						-- (b) El estado nunca retrocede entre pasos (monotonía).
						local rank = RANK[fish.state]
						if rank < lastRank then
							return false
						end
						lastRank = rank
					end

					-- (c) Confluencia: un único step con el tiempo total acumulado
					-- produce el mismo estado que la secuencia troceada.
					local single = CookingModel.step({ state = "Raw", timeOnFire = 0 }, total)
					return single.state == fish.state
				end
			)
		end)
	end)
end
