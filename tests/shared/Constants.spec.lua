--!strict
--[[
	Constants.spec.lua — Prueba unitaria (por ejemplos) de las constantes de balance.

	Feature: juego-supervivencia-artico

	Spec de TestEZ para la capa de lógica pura `ReplicatedStorage/Shared/Constants`.
	Verifica que los valores de balance declarados coinciden EXACTAMENTE con la tabla
	"Constantes de balance" del documento de diseño. No es una prueba de propiedad:
	comprueba valores concretos y documentados (ejemplos), sin generación aleatoria.

	Requiere el módulo bajo prueba a través del árbol de Rojo
	(`ReplicatedStorage.Shared.Constants`), que `default.project.json` mapea desde
	`src/shared` en disco.

	Ejecución diferida: no hay runtime de Roblox/Lune disponible en este entorno;
	la suite se ejecuta con TestEZ dentro de Roblox Studio o con Lune/run-in-roblox.

	_Requisitos: 7.1, 7.3, 11.1, 13.9_
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)

return function()
	describe("Constants (balance)", function()
		describe("NEEDS — necesidades vitales", function()
			it("declara los valores exactos de rango y tasas de consumo", function()
				expect(Constants.NEEDS.MAX).to.equal(100)
				expect(Constants.NEEDS.MIN).to.equal(0)
				expect(Constants.NEEDS.HUNGER_DECAY_PER_S).to.equal(1)
				expect(Constants.NEEDS.THIRST_DECAY_PER_S).to.equal(1)
				expect(Constants.NEEDS.COLD_EXPOSURE_MULTIPLIER).to.equal(2)
				expect(Constants.NEEDS.HEALTH_DECAY_PER_S_WHEN_DEPLETED).to.equal(5)
			end)

			it("declara las recuperaciones y penalizaciones de consumo (Req. 11.1, 13.9)", function()
				expect(Constants.NEEDS.DRINK_THIRST_RESTORE).to.equal(40)
				expect(Constants.NEEDS.EAT_HUNGER_RESTORE).to.equal(40)
				expect(Constants.NEEDS.BURNED_FISH_HEALTH_PENALTY).to.equal(15)
			end)
		end)

		describe("HARVEST — talado, minería y respawn", function()
			it("declara golpes, rendimientos y respawn (Req. 7.1, 7.3)", function()
				expect(Constants.HARVEST.HITS_TO_FELL).to.equal(5)
				expect(Constants.HARVEST.WOOD_PER_LOG).to.equal(3)
				expect(Constants.HARVEST.STONE_PER_FRAGMENT).to.equal(1)
				expect(Constants.HARVEST.RESPAWN_S).to.equal(60)
			end)
		end)

		describe("COOLER — neverita", function()
			it("declara la capacidad máxima de peces", function()
				expect(Constants.COOLER.CAPACITY).to.equal(30)
			end)
		end)

		describe("FIRE — hoguera de emergencia y de base", function()
			it("declara los parámetros de la hoguera de emergencia", function()
				expect(Constants.FIRE.EMERGENCY_DURATION_S).to.equal(45)
				expect(Constants.FIRE.EMERGENCY_WARMTH_PER_S).to.equal(10)
				expect(Constants.FIRE.EMERGENCY_RADIUS_M).to.equal(5)
			end)

			it("declara los costes y topes de la hoguera de base", function()
				expect(Constants.FIRE.BASE_STONE_COST).to.equal(5)
				expect(Constants.FIRE.BASE_WOOD_COST).to.equal(3)
				expect(Constants.FIRE.BASE_WOOD_CAP).to.equal(20)
				expect(Constants.FIRE.MAX_COOKING_FISH).to.equal(5)
			end)
		end)

		describe("COOKING — máquina de estados del pescado", function()
			it("declara los tiempos de cocinado y los efectos (Req. 13.9)", function()
				expect(Constants.COOKING.RAW_TO_COOKED_S).to.equal(10)
				expect(Constants.COOKING.COOKED_TO_BURNED_S).to.equal(8)
				expect(Constants.COOKING.TOTAL_TO_BURNED_S).to.equal(18)
				expect(Constants.COOKING.COOKED_HUNGER_RESTORE).to.equal(40)
				expect(Constants.COOKING.BURNED_HEALTH_PENALTY).to.equal(15)
			end)

			it("mantiene la coherencia RAW_TO_COOKED_S + COOKED_TO_BURNED_S = TOTAL_TO_BURNED_S", function()
				expect(Constants.COOKING.RAW_TO_COOKED_S + Constants.COOKING.COOKED_TO_BURNED_S)
					.to.equal(Constants.COOKING.TOTAL_TO_BURNED_S)
			end)
		end)

		describe("WEATHER — clima y ventiscas", function()
			it("declara los intervalos y factores de visibilidad", function()
				expect(Constants.WEATHER.CHANGE_INTERVAL_S).to.equal(600)
				expect(Constants.WEATHER.BLIZZARD_DURATION_S).to.equal(60)
				expect(Constants.WEATHER.BLIZZARD_VISIBILITY_FACTOR).to.equal(0.3)
				expect(Constants.WEATHER.CLEAR_VISIBILITY_FACTOR).to.equal(1.0)
			end)
		end)

		describe("SAVE — guardado automático", function()
			it("declara el intervalo de guardado y la versión de formato", function()
				expect(Constants.SAVE.INTERVAL_S).to.equal(120)
				expect(Constants.SAVE.FORMAT_VERSION).to.equal(1)
			end)
		end)

		describe("RESCUE — rescate", function()
			it("declara el día de llegada del helicóptero", function()
				expect(Constants.RESCUE.DAY).to.equal(7)
			end)
		end)

		describe("WORLD — generación y distribución del mundo", function()
			it("declara el tamaño del mapa, la banda perimetral y los conteos de recursos", function()
				expect(Constants.WORLD.MAP_SIZE).to.equal(500)
				expect(Constants.WORLD.PERIMETER_BAND).to.equal(20)
				expect(Constants.WORLD.STONE_COUNT).to.equal(40)
				expect(Constants.WORLD.TREE_COUNT).to.equal(60)
				expect(Constants.WORLD.MIN_LAKES).to.equal(3)
				expect(Constants.WORLD.MAX_LAKES).to.equal(8)
				expect(Constants.WORLD.MIN_RESOURCE_SEPARATION).to.equal(2)
			end)
		end)
	end)
end
