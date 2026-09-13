--!strict
--[[
	CookingModel.lua — Máquina de estados del pescado sobre el fuego.

	Feature: juego-supervivencia-artico

	ModuleScript de lógica PURA ubicado en ReplicatedStorage/Shared. No tiene
	dependencias del motor: recibe estado y devuelve estado NUEVO, sin mutar la
	entrada ni provocar efectos secundarios.

	Modela la transición Raw -> Cooked -> Burned del Requisito 13:
	  - Raw    -> Cooked  al acumular 10 s sobre el fuego (Req. 13.8).
	  - Cooked -> Burned  al acumular 18 s (10 + 8) sobre el fuego (Req. 13.10).

	El estado es una función MONÓTONA del tiempo total acumulado (`timeOnFire`):
	depende solo de ese total y nunca del troceo del `dt` (confluencia). Por eso
	`step` primero acumula el tiempo y luego deriva el estado del total, lo que
	garantiza que nunca se salte `Cooked` ni se retroceda de estado.

	Requisitos cubiertos: 13.8, 13.9, 13.10, 13.11
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Types = require(Shared.Types)
local Constants = require(Shared.Constants)

type FishState = Types.FishState
type CookingFish = Types.CookingFish

local COOKING = Constants.COOKING

local CookingModel = {}

-- Deriva el estado del pescado a partir del tiempo total acumulado sobre el fuego.
-- Función monótona: a mayor tiempo, estado igual o más avanzado, sin saltar Cooked.
local function stateForTime(timeOnFire: number): FishState
	if timeOnFire >= COOKING.TOTAL_TO_BURNED_S then
		return "Burned"
	elseif timeOnFire >= COOKING.RAW_TO_COOKED_S then
		return "Cooked"
	else
		return "Raw"
	end
end

-- Avanza el cocinado en `dt` segundos y devuelve un pez NUEVO (no muta la entrada).
-- El estado resultante se deriva del tiempo total acumulado, por lo que el
-- resultado depende solo del total y no de cómo se trocee el `dt` (confluencia).
function CookingModel.step(fish: CookingFish, dt: number): CookingFish
	local newTime = fish.timeOnFire + dt
	return {
		state = stateForTime(newTime),
		timeOnFire = newTime,
	}
end

-- Hambre restaurada al comer el pez: 40 solo si está Cooked, 0 en otro caso (Req. 13.9).
function CookingModel.hungerRestored(fish: CookingFish): number
	if fish.state == "Cooked" then
		return COOKING.COOKED_HUNGER_RESTORE
	end
	return 0
end

-- Penalización de Salud al comer el pez: 15 solo si está Burned, 0 en otro caso (Req. 13.11).
function CookingModel.healthPenalty(fish: CookingFish): number
	if fish.state == "Burned" then
		return COOKING.BURNED_HEALTH_PENALTY
	end
	return 0
end

return CookingModel
