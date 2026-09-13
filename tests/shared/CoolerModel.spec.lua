--!strict
--[[
	CoolerModel.spec.lua — Prueba de propiedad de la Neverita Portátil.

	Feature: juego-supervivencia-artico

	Spec de TestEZ para la capa de lógica pura `ReplicatedStorage/Shared/CoolerModel`.
	Verifica la Propiedad 7 del diseño con >= 100 iteraciones usando el ayudante
	de property-based testing `PropCheck` (Luau puro, determinista y sembrado).

	Requiere el módulo bajo prueba a través del árbol de Rojo
	(`ReplicatedStorage.Shared.CoolerModel`) y `PropCheck` a través del árbol de
	pruebas (`ReplicatedStorage.Tests.support.PropCheck`), que `default.project.json`
	mapea desde la carpeta `tests` en disco. Dentro del spec eso equivale a
	`script.Parent.Parent.support.PropCheck` (spec en `Tests/shared/` → sube a
	`Tests/` → baja a `support/PropCheck`).

	Ejecución diferida: no hay runtime de Roblox/Lune disponible en este entorno;
	la suite se ejecuta con TestEZ dentro de Roblox Studio o con Lune/run-in-roblox.

	Cubre: Property 7. Validates: Requirements 10.2, 10.3, 10.4
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoolerModel = require(ReplicatedStorage.Shared.CoolerModel)
local Constants = require(ReplicatedStorage.Shared.Constants)

-- PropCheck vive en tests/support; desde este spec (tests/shared/CoolerModel.spec)
-- se alcanza subiendo a la raíz `Tests` y bajando a `support`.
local PropCheck = require(script.Parent.Parent.support.PropCheck)

local CAPACITY: number = Constants.COOLER.CAPACITY -- 30 (Req. 10.2)

return function()
	describe("CoolerModel (Property 7)", function()
		it("respeta su capacidad [0,30] y señala lleno/vacío correctamente", function()
			-- Feature: juego-supervivencia-artico, Property 7: La Neverita respeta su capacidad y señala lleno/vacío correctamente
			--
			-- Para toda secuencia de operaciones add/remove partiendo de un contador
			-- aleatorio en [0, 30]: el contador se mantiene siempre en [0, 30];
			-- `add` devuelve ok=false exactamente cuando el contador vale 30 (dejándolo
			-- intacto) y `remove` devuelve ok=false exactamente cuando vale 0.
			local genCase = function(rng: PropCheck.Rng)
				return {
					startCount = PropCheck.genInt(0, CAPACITY)(rng),
					ops = PropCheck.genArray(PropCheck.genOneOf({ "add", "remove" }), 60)(rng),
				}
			end

			PropCheck.forAll(genCase, function(case)
				local cooler = { count = case.startCount }

				for _, op in case.ops do
					local before = cooler.count
					local next, ok

					if op == "add" then
						next, ok = CoolerModel.add(cooler)
						if before == CAPACITY then
							-- Llena: add no debe tener éxito ni alterar el contador.
							if ok ~= false then
								return false
							end
							if next.count ~= before then
								return false
							end
						else
							-- No llena: add tiene éxito y sube exactamente en 1.
							if ok ~= true then
								return false
							end
							if next.count ~= before + 1 then
								return false
							end
						end
					else -- "remove"
						next, ok = CoolerModel.remove(cooler)
						if before == 0 then
							-- Vacía: remove no debe tener éxito ni alterar el contador.
							if ok ~= false then
								return false
							end
							if next.count ~= before then
								return false
							end
						else
							-- No vacía: remove tiene éxito y baja exactamente en 1.
							if ok ~= true then
								return false
							end
							if next.count ~= before - 1 then
								return false
							end
						end
					end

					-- Invariante de rango tras cada operación: contador en [0, 30].
					if next.count < 0 or next.count > CAPACITY then
						return false
					end

					-- El estado original no se muta (lógica pura): la tabla de entrada
					-- conserva su contador y la operación devuelve una tabla nueva.
					if cooler.count ~= before then
						return false
					end

					cooler = next
				end

				-- isFull es consistente con el contador final.
				if CoolerModel.isFull(cooler) ~= (cooler.count >= CAPACITY) then
					return false
				end

				return true
			end, 100)
		end)
	end)
end
