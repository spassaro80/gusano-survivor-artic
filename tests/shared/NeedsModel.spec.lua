--[[
	NeedsModel.spec.lua — Pruebas basadas en propiedades de NeedsModel.

	Feature: juego-supervivencia-artico

	Spec de TestEZ (estilo `return function() ... end`) que verifica las 6
	propiedades de correctitud de la lógica pura de necesidades vitales
	(`ReplicatedStorage/Shared/NeedsModel`). Cada `it` cubre exactamente una
	propiedad del diseño y se etiqueta con el comentario canónico
	`-- Feature: juego-supervivencia-artico, Property {n}: {texto}`.

	Se apoya en el ayudante puro `PropCheck` (>= 100 iteraciones por propiedad)
	para generar casos deterministas y reportar contraejemplos reproducibles.

	Rutas `require` resueltas por el árbol de Rojo (default.project.json):
	  - NeedsModel / Constants → ReplicatedStorage/Shared
	  - PropCheck             → ReplicatedStorage/Tests/support

	Requisitos cubiertos: 4.1, 4.3, 4.5, 4.6, 4.7, 6.6, 11.1, 11.2, 13.9, 13.11.
]]

return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local NeedsModel = require(ReplicatedStorage.Shared.NeedsModel)
	local Constants = require(ReplicatedStorage.Shared.Constants)
	local PropCheck = require(ReplicatedStorage.Tests.support.PropCheck)

	local NEEDS = Constants.NEEDS
	local MIN = NEEDS.MIN
	local MAX = NEEDS.MAX
	local COLD_MULT = NEEDS.COLD_EXPOSURE_MULTIPLIER
	local HUNGER_DECAY = NEEDS.HUNGER_DECAY_PER_S
	local THIRST_DECAY = NEEDS.THIRST_DECAY_PER_S
	local HEALTH_DECAY = NEEDS.HEALTH_DECAY_PER_S_WHEN_DEPLETED

	-- Cada propiedad se evalúa sobre este número de casos (>= 100 exigido).
	local ITERATIONS = 200

	-- Rango de `dt` (segundos) acotado para mantener el error de coma flotante
	-- despreciable al multiplicar por las tasas de consumo.
	local MAX_DT = 500

	-- Comparación aproximada (tolerancia absoluta + relativa) para las igualdades
	-- que implican multiplicación por `dt`.
	local function approx(a: number, b: number): boolean
		return math.abs(a - b) <= 1e-6 + 1e-9 * math.abs(b)
	end

	-- Generador de un estado de necesidades con los cuatro valores en [0, 100].
	local genValue = PropCheck.genNumber(MIN, MAX)
	local genDt = PropCheck.genNumber(0, MAX_DT)
	local genBool = PropCheck.genBool()

	local function genNeeds(rng)
		return {
			warmth = genValue(rng),
			hunger = genValue(rng),
			thirst = genValue(rng),
			health = genValue(rng),
		}
	end

	local NORMAL_ENV = { underSnow = false, blizzardExposed = false, nearFire = false }

	describe("NeedsModel (pruebas basadas en propiedades)", function()
		it("mantiene las necesidades acotadas en [0, 100] tras step", function()
			-- Feature: juego-supervivencia-artico, Property 1: Las necesidades permanecen acotadas en [0, 100]
			local seed = PropCheck.forAll(function(rng)
				return {
					needs = genNeeds(rng),
					env = {
						underSnow = genBool(rng),
						blizzardExposed = genBool(rng),
						nearFire = genBool(rng),
					},
					dt = genDt(rng),
				}
			end, function(case)
				local r = NeedsModel.step(case.needs, case.env, case.dt)
				return r.warmth >= MIN
					and r.warmth <= MAX
					and r.hunger >= MIN
					and r.hunger <= MAX
					and r.thirst >= MIN
					and r.thirst <= MAX
					and r.health >= MIN
					and r.health <= MAX
			end, ITERATIONS)
			expect(type(seed)).to.equal("number")
		end)

		it("consume Calor al doble bajo nieve o ventisca, respetando el clamp a 0", function()
			-- Feature: juego-supervivencia-artico, Property 2: El Calor se consume al doble bajo nieve o ventisca
			local seed = PropCheck.forAll(function(rng)
				return {
					needs = genNeeds(rng),
					dt = genDt(rng),
					coldBySnow = genBool(rng),
				}
			end, function(case)
				local n = case.needs
				local dt = case.dt
				local coldEnv = if case.coldBySnow
					then { underSnow = true, blizzardExposed = false, nearFire = false }
					else { underSnow = false, blizzardExposed = true, nearFire = false }

				local rNormal = NeedsModel.step(n, NORMAL_ENV, dt)
				local rCold = NeedsModel.step(n, coldEnv, dt)

				local decNormal = n.warmth - rNormal.warmth
				local decCold = n.warmth - rCold.warmth

				-- La caída bajo frío es el doble de la normal, pero nunca puede
				-- retirar más Calor del disponible (clamp a 0).
				local expectedCold = math.min(COLD_MULT * decNormal, n.warmth)
				return approx(decCold, expectedCold)
			end, ITERATIONS)
			expect(type(seed)).to.equal("number")
		end)

		it("disminuye Hambre y Sed proporcionalmente a dt (según la tasa configurada), sin bajar de 0", function()
			-- Feature: juego-supervivencia-artico, Property 3: Hambre y Sed disminuyen de forma proporcional al tiempo
			local seed = PropCheck.forAll(function(rng)
				return {
					needs = genNeeds(rng),
					dt = genDt(rng),
				}
			end, function(case)
				local n = case.needs
				local dt = case.dt
				local r = NeedsModel.step(n, NORMAL_ENV, dt)

				local expHunger = math.max(MIN, n.hunger - HUNGER_DECAY * dt)
				local expThirst = math.max(MIN, n.thirst - THIRST_DECAY * dt)
				return approx(r.hunger, expHunger) and approx(r.thirst, expThirst)
			end, ITERATIONS)
			expect(type(seed)).to.equal("number")
		end)

		it("decae la Salud 5%/s solo cuando una necesidad está agotada", function()
			-- Feature: juego-supervivencia-artico, Property 4: La Salud decae mientras una necesidad está agotada
			local genIndex = PropCheck.genInt(1, 3)
			local seed = PropCheck.forAll(function(rng)
				local needs = genNeeds(rng)
				-- Con ~50% de probabilidad, fuerza una necesidad a 0 para ejercitar
				-- de forma fiable la rama de decaimiento de Salud.
				if genBool(rng) then
					local idx = genIndex(rng)
					if idx == 1 then
						needs.warmth = MIN
					elseif idx == 2 then
						needs.hunger = MIN
					else
						needs.thirst = MIN
					end
				end
				return { needs = needs, dt = genDt(rng) }
			end, function(case)
				local n = case.needs
				local dt = case.dt
				local r = NeedsModel.step(n, NORMAL_ENV, dt)

				local depleted = n.warmth <= MIN or n.hunger <= MIN or n.thirst <= MIN
				if depleted then
					local expected = math.max(MIN, n.health - HEALTH_DECAY * dt)
					return approx(r.health, expected)
				else
					-- Sin necesidad agotada, esta causa no reduce la Salud.
					return approx(r.health, n.health)
				end
			end, ITERATIONS)
			expect(type(seed)).to.equal("number")
		end)

		it("restaura Sed/Hambre a min(prev+amount, 100) sin desbordar 100", function()
			-- Feature: juego-supervivencia-artico, Property 5: La restauración aditiva de necesidades nunca desborda 100
			local genAmount = PropCheck.genNumber(0, MAX)
			local seed = PropCheck.forAll(function(rng)
				return {
					needs = genNeeds(rng),
					amount = genAmount(rng),
				}
			end, function(case)
				local n = case.needs
				local amount = case.amount

				local afterDrink = NeedsModel.applyDrink(n, amount)
				local afterEat = NeedsModel.applyEat(n, amount)

				local expThirst = math.min(n.thirst + amount, MAX)
				local expHunger = math.min(n.hunger + amount, MAX)

				local drinkOk = approx(afterDrink.thirst, expThirst)
					and afterDrink.thirst <= MAX
					and afterDrink.warmth == n.warmth
					and afterDrink.hunger == n.hunger
					and afterDrink.health == n.health

				local eatOk = approx(afterEat.hunger, expHunger)
					and afterEat.hunger <= MAX
					and afterEat.warmth == n.warmth
					and afterEat.thirst == n.thirst
					and afterEat.health == n.health

				return drinkOk and eatOk
			end, ITERATIONS)
			expect(type(seed)).to.equal("number")
		end)

		it("penaliza la Salud a max(prev-penalty, 0) sin bajar de 0 (pez quemado)", function()
			-- Feature: juego-supervivencia-artico, Property 6: La penalización por pez quemado nunca baja de 0
			local genPenalty = PropCheck.genNumber(0, MAX)
			local seed = PropCheck.forAll(function(rng)
				return {
					needs = genNeeds(rng),
					penalty = genPenalty(rng),
				}
			end, function(case)
				local n = case.needs
				local penalty = case.penalty
				local r = NeedsModel.applyBurnedFish(n, penalty)

				local expected = math.max(n.health - penalty, MIN)
				return approx(r.health, expected)
					and r.health >= MIN
					and r.warmth == n.warmth
					and r.hunger == n.hunger
					and r.thirst == n.thirst
			end, ITERATIONS)
			expect(type(seed)).to.equal("number")
		end)
	end)
end
