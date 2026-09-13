--!strict
--[[
	BottleModel.spec.lua — Prueba unitaria (por ejemplos) de la Botella de Agua.

	Feature: juego-supervivencia-artico

	Spec de TestEZ para la capa de lógica pura `ReplicatedStorage/Shared/BottleModel`.
	A diferencia de las specs de propiedad de este proyecto, ésta es una prueba
	UNITARIA basada en ejemplos concretos: comprueba las transiciones discretas de
	la Botella ("Full" ↔ "Empty") y su efecto sobre la Sed mediante casos fijos,
	incluido el ciclo completo Llena → beber → Vacía → rellenar → Llena.

	Requiere el módulo bajo prueba a través del árbol de Rojo
	(`ReplicatedStorage.Shared.BottleModel`) y las constantes de balance
	(`ReplicatedStorage.Shared.Constants`), que `default.project.json` mapea desde
	`src/shared` en disco.

	Ejecución diferida: no hay runtime de Roblox/Lune disponible en este entorno;
	la suite se ejecuta con TestEZ dentro de Roblox Studio o con Lune/run-in-roblox.

	_Requisitos: 11.3, 11.4, 11.7_
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BottleModel = require(ReplicatedStorage.Shared.BottleModel)
local Constants = require(ReplicatedStorage.Shared.Constants)

local DRINK_RESTORE: number = Constants.BOTTLE.DRINK_THIRST_RESTORE -- 40 (Req. 11.1)
local NEEDS_MAX: number = Constants.NEEDS.MAX -- 100 (Req. 11.2)

-- Necesidades de ejemplo con una Sed dada; el resto de barras a valores fijos que
-- sirven para verificar que beber SOLO toca la Sed.
local function makeNeeds(thirst: number)
	return {
		warmth = 50,
		hunger = 60,
		thirst = thirst,
		health = 70,
	}
end

return function()
	describe("BottleModel (transiciones de la Botella)", function()
		it("beber con Botella Llena aumenta la Sed en 40 y deja la Botella Vacía (ok=true)", function()
			-- Req. 11.3: al beber, la Botella pasa a "Empty".
			local bottle = { state = "Full" }
			local needs = makeNeeds(30)

			local newBottle, newNeeds, ok = BottleModel.drink(bottle, needs)

			expect(ok).to.equal(true)
			expect(newBottle.state).to.equal("Empty")
			expect(newNeeds.thirst).to.equal(30 + DRINK_RESTORE) -- 70
			-- El resto de necesidades no cambia.
			expect(newNeeds.warmth).to.equal(50)
			expect(newNeeds.hunger).to.equal(60)
			expect(newNeeds.health).to.equal(70)
		end)

		it("beber cerca del máximo fija la Sed en 100 (clamp) al beber desde Llena", function()
			-- Req. 11.2 + 11.3: 80 + 40 = 120 → se recorta a 100 y la Botella queda Vacía.
			local bottle = { state = "Full" }
			local needs = makeNeeds(80)

			local newBottle, newNeeds, ok = BottleModel.drink(bottle, needs)

			expect(ok).to.equal(true)
			expect(newBottle.state).to.equal("Empty")
			expect(newNeeds.thirst).to.equal(NEEDS_MAX) -- 100, no 120
		end)

		it("beber con Botella Vacía no cambia las necesidades y devuelve ok=false", function()
			-- Req. 11.4: Botella vacía → Sed sin cambios, sigue Vacía, ok=false.
			local bottle = { state = "Empty" }
			local needs = makeNeeds(45)

			local newBottle, newNeeds, ok = BottleModel.drink(bottle, needs)

			expect(ok).to.equal(false)
			expect(newBottle.state).to.equal("Empty")
			expect(newNeeds.thirst).to.equal(45)
			expect(newNeeds.warmth).to.equal(50)
			expect(newNeeds.hunger).to.equal(60)
			expect(newNeeds.health).to.equal(70)
		end)

		it("rellenar deja una Botella Vacía en estado Llena", function()
			-- Req. 11.7: la acción "Rellenar Botella" pasa la Botella a "Full".
			local emptyBottle = { state = "Empty" }

			local refilled = BottleModel.refill(emptyBottle)

			expect(refilled.state).to.equal("Full")
		end)

		it("ciclo completo Llena → beber → Vacía → rellenar → Llena aplica la Sed solo al beber", function()
			-- Requisitos 11.3, 11.4, 11.7: recorrido completo del estado de la Botella.
			local bottle = { state = "Full" }
			local needs = makeNeeds(20)

			-- Paso 1: beber desde Llena → +40 de Sed y Botella Vacía.
			local afterDrink, needsAfterDrink, drankOk = BottleModel.drink(bottle, needs)
			expect(drankOk).to.equal(true)
			expect(afterDrink.state).to.equal("Empty")
			expect(needsAfterDrink.thirst).to.equal(20 + DRINK_RESTORE) -- 60

			-- Paso 2: intentar beber estando Vacía → sin efecto sobre la Sed, ok=false.
			local afterEmptyDrink, needsAfterEmptyDrink, emptyOk = BottleModel.drink(afterDrink, needsAfterDrink)
			expect(emptyOk).to.equal(false)
			expect(afterEmptyDrink.state).to.equal("Empty")
			expect(needsAfterEmptyDrink.thirst).to.equal(60) -- inalterada

			-- Paso 3: rellenar → Botella vuelve a Llena.
			local afterRefill = BottleModel.refill(afterEmptyDrink)
			expect(afterRefill.state).to.equal("Full")

			-- El rellenado no altera la Sed: solo el beber-desde-Llena tuvo efecto.
			expect(needsAfterEmptyDrink.thirst).to.equal(60)
		end)
	end)
end
