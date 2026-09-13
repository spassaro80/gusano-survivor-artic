--!strict
--[[
	WeatherModel.spec.lua — Prueba basada en propiedades del clima y ciclo de ventisca.

	Feature: juego-supervivencia-artico

	Spec de TestEZ (se carga con el runner estándar: Lune / run-in-roblox / Studio).
	Verifica la Propiedad 9 del diseño sobre la lógica pura de `WeatherModel`.

	Requiere los módulos a través del árbol Rojo definido en `default.project.json`:
		- ReplicatedStorage/Shared  -> src/shared      (WeatherModel, Constants)
		- ReplicatedStorage/Tests   -> tests           (este spec y support/PropCheck)

	El módulo bajo prueba es Luau PURO (sin dependencias del motor en su lógica),
	de modo que la propiedad se evalúa de forma determinista sobre >= 100 casos.
]]

return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local WeatherModel = require(ReplicatedStorage.Shared.WeatherModel)
	local Constants = require(ReplicatedStorage.Shared.Constants)
	-- tests/shared/WeatherModel.spec -> Tests.shared.["WeatherModel.spec"]
	-- script.Parent = shared ; script.Parent.Parent = Tests ; .support.PropCheck
	local PropCheck = require(script.Parent.Parent.support.PropCheck)

	local CHANGE_INTERVAL_S: number = Constants.WEATHER.CHANGE_INTERVAL_S -- 600 s
	local BLIZZARD_DURATION_S: number = Constants.WEATHER.BLIZZARD_DURATION_S -- 60 s

	-- Tolerancia para comparaciones de punto flotante. Los valores implicados
	-- rondan como mucho ~660, cuyo error acumulado en resta es << 1e-6.
	local EPS = 1e-6

	-- `step` exige una función rng () -> number en [0, 1). El resultado del sorteo
	-- no altera el comportamiento (por diseño siempre se activa la ventisca), así
	-- que basta una fuente constante determinista para respetar el contrato.
	local function roll(): number
		return 0.5
	end

	local function approx(a: number, b: number): boolean
		return math.abs(a - b) <= EPS
	end

	describe("WeatherModel (Propiedad 9)", function()
		it("reinicia el temporizador a 600 al activar la ventisca y la ventisca dura 60 s", function()
			-- Feature: juego-supervivencia-artico, Property 9: El temporizador de clima se reinicia a 600 y la ventisca dura 60 s
			-- **Validates: Requirements 6.1, 6.2, 6.3**
			PropCheck.forAll(
				function(rng)
					return {
						-- Escenario A — cruce del temporizador desde clima despejado.
						-- timer inicial en [0, 600]; `extraA` es el tiempo sobrante que
						-- se consume DENTRO de la ventisca recién activada. Se mantiene
						-- estrictamente < 60 s para que la ventisca siga activa tras el paso.
						timerA = PropCheck.genNumber(0, CHANGE_INTERVAL_S)(rng),
						extraA = PropCheck.genNumber(0, BLIZZARD_DURATION_S * 0.999)(rng),

						-- Escenario B — fin de una ventisca ya activa.
						-- `blizRemB` estrictamente > 0 (ventisca genuinamente activa) para
						-- garantizar dt > 0 y que el paso la desactive.
						blizRemB = PropCheck.genNumber(0.001, BLIZZARD_DURATION_S)(rng),
						timerB = PropCheck.genNumber(0.001, CHANGE_INTERVAL_S)(rng),
						-- fracción del temporizador que consume el tiempo sobrante tras la
						-- ventisca; < 1 asegura que no se cruce un nuevo cambio de clima.
						leftoverFracB = PropCheck.genNumber(0, 0.999)(rng),
					}
				end,
				function(case)
					-- ── Escenario A: al agotarse el temporizador se activa la ventisca ──
					-- Un `dt` que consume exactamente el temporizador y luego `extraA`
					-- segundos ya dentro de la ventisca.
					local dtA = case.timerA + case.extraA
					local wA = WeatherModel.step({
						timer = case.timerA,
						blizzardActive = false,
						blizzardRemaining = 0,
					}, dtA, roll)

					-- Solo se afirma el cruce cuando realmente transcurre tiempo (dt > 0);
					-- con dt == 0 (timer == 0 y extra == 0) no hay avance y no debe cambiar.
					if dtA > 0 then
						-- La ventisca queda activa (Req. 6.2).
						if not wA.blizzardActive then
							return false
						end
						-- El temporizador se reinicia exactamente a 600 s (Req. 6.1, 6.2).
						if not approx(wA.timer, CHANGE_INTERVAL_S) then
							return false
						end
						-- `blizzardRemaining` se fija en 60 s y luego consume el sobrante:
						-- queda en 60 - extraA (Req. 6.3), siempre en [0, 60].
						if not approx(wA.blizzardRemaining, BLIZZARD_DURATION_S - case.extraA) then
							return false
						end
						if wA.blizzardRemaining < -EPS or wA.blizzardRemaining > BLIZZARD_DURATION_S + EPS then
							return false
						end
					end

					-- ── Escenario B: la ventisca se desactiva al llegar su tiempo a 0 ──
					-- `leftoverB` < timerB, de modo que tras terminar la ventisca el
					-- tiempo sobrante NO agota el temporizador (no reactiva otra ventisca).
					local leftoverB = case.leftoverFracB * case.timerB
					local dtB = case.blizRemB + leftoverB
					local wB = WeatherModel.step({
						timer = case.timerB,
						blizzardActive = true,
						blizzardRemaining = case.blizRemB,
					}, dtB, roll)

					-- La ventisca se ha desactivado (Req. 6.3).
					if wB.blizzardActive then
						return false
					end
					-- Al desactivarse, su tiempo restante es exactamente 0.
					if not approx(wB.blizzardRemaining, 0) then
						return false
					end
					-- El temporizador de clima ha descontado solo el tiempo sobrante.
					if not approx(wB.timer, case.timerB - leftoverB) then
						return false
					end

					return true
				end
			)
		end)
	end)
end
