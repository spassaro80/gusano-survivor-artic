--!strict
--[[
	NeedsModel.lua — Lógica PURA de necesidades vitales de "7 Días en el Ártico".

	Feature: juego-supervivencia-artico

	ModuleScript de lógica pura ubicado en ReplicatedStorage/Shared. NO tiene
	dependencias del motor de Roblox ni efectos secundarios: cada función recibe
	estado y devuelve estado nuevo. Toda la aritmética temporal se expresa en
	tasas "por segundo" que el bucle de simulación aplica multiplicadas por `dt`.

	Gestiona Calor (warmth), Hambre (hunger), Sed (thirst) y Salud (health).
	Todos los valores se mantienen dentro del rango cerrado [0, 100] mediante
	clamp (Constants.NEEDS.MIN / Constants.NEEDS.MAX).

	Reglas modeladas (ver documento de diseño y requisitos):
	- Hambre y Sed disminuyen a Constants.NEEDS.HUNGER_DECAY_PER_S / THIRST_DECAY_PER_S
	  (%/s) (Req. 4.5, 4.6).
	- Calor disminuye a una tasa base y al DOBLE cuando el entorno expone al
	  Jugador a nieve o ventisca (Req. 4.3, 6.6).
	- Cuando al menos una de Calor/Hambre/Sed vale 0, la Salud cae 5%/s (Req. 4.7).
	- Beber restaura Sed y comer pez cocinado restaura Hambre, sin superar 100
	  (Req. 11.1, 11.2, 13.9).
	- Comer pez quemado penaliza la Salud, sin bajar de 0 (Req. 13.11).

	Requisitos cubiertos: 4.1, 4.3, 4.5, 4.6, 4.7, 4.8, 6.6, 11.1, 11.2, 13.9, 13.11.
]]

local Constants = require(script.Parent.Constants)
local Types = require(script.Parent.Types)

type Needs = Types.Needs
type Env = Types.Env

local MIN = Constants.NEEDS.MIN
local MAX = Constants.NEEDS.MAX
local HUNGER_DECAY_PER_S = Constants.NEEDS.HUNGER_DECAY_PER_S
local THIRST_DECAY_PER_S = Constants.NEEDS.THIRST_DECAY_PER_S
local COLD_EXPOSURE_MULTIPLIER = Constants.NEEDS.COLD_EXPOSURE_MULTIPLIER
local HEALTH_DECAY_PER_S_WHEN_DEPLETED = Constants.NEEDS.HEALTH_DECAY_PER_S_WHEN_DEPLETED

-- Tasa base de consumo de Calor en %/s (Constants.NEEDS.WARMTH_DECAY_PER_S). Bajo
-- nieve o ventisca esta tasa se multiplica por COLD_EXPOSURE_MULTIPLIER (Req. 4.3, 6.6).
local BASE_WARMTH_DECAY_PER_S = Constants.NEEDS.WARMTH_DECAY_PER_S

local NeedsModel = {}

-- Restringe `value` al rango cerrado [MIN, MAX]. Implementación local para
-- mantener el módulo libre de dependencias del motor.
local function clamp(value: number): number
	if value < MIN then
		return MIN
	elseif value > MAX then
		return MAX
	end
	return value
end

--[[
	step: aplica un paso de tiempo `dt` (en segundos) al estado de necesidades.

	- Hambre y Sed disminuyen HUNGER_DECAY_PER_S / THIRST_DECAY_PER_S por segundo.
	- Calor disminuye a la tasa base, multiplicada por COLD_EXPOSURE_MULTIPLIER
	  cuando `env.underSnow` o `env.blizzardExposed` es verdadero.
	- Si al menos una de Calor/Hambre/Sed en el estado de ENTRADA vale 0, la Salud
	  disminuye HEALTH_DECAY_PER_S_WHEN_DEPLETED por segundo.
	- Los cuatro valores resultantes se acotan a [0, 100].
]]
function NeedsModel.step(needs: Needs, env: Env, dt: number): Needs
	local coldExposed = env.underSnow or env.blizzardExposed
	local warmthMultiplier = if coldExposed then COLD_EXPOSURE_MULTIPLIER else 1

	local newWarmth = clamp(needs.warmth - BASE_WARMTH_DECAY_PER_S * warmthMultiplier * dt)
	local newHunger = clamp(needs.hunger - HUNGER_DECAY_PER_S * dt)
	local newThirst = clamp(needs.thirst - THIRST_DECAY_PER_S * dt)

	-- La caída de Salud depende del estado de entrada: si alguna necesidad ya
	-- está agotada (== 0), la Salud decae proporcionalmente a `dt`.
	local depleted = needs.warmth <= MIN or needs.hunger <= MIN or needs.thirst <= MIN
	local newHealth = needs.health
	if depleted then
		newHealth = clamp(needs.health - HEALTH_DECAY_PER_S_WHEN_DEPLETED * dt)
	end

	return {
		warmth = newWarmth,
		hunger = newHunger,
		thirst = newThirst,
		health = newHealth,
	}
end

-- applyDrink: suma `amount` a la Sed, acotando a 100 (Req. 11.1, 11.2).
function NeedsModel.applyDrink(needs: Needs, amount: number): Needs
	return {
		warmth = needs.warmth,
		hunger = needs.hunger,
		thirst = clamp(needs.thirst + amount),
		health = needs.health,
	}
end

-- applyEat: suma `amount` al Hambre, acotando a 100 (Req. 13.9).
function NeedsModel.applyEat(needs: Needs, amount: number): Needs
	return {
		warmth = needs.warmth,
		hunger = clamp(needs.hunger + amount),
		thirst = needs.thirst,
		health = needs.health,
	}
end

-- applyBurnedFish: resta `penalty` a la Salud, sin bajar de 0 (Req. 13.11).
function NeedsModel.applyBurnedFish(needs: Needs, penalty: number): Needs
	return {
		warmth = needs.warmth,
		hunger = needs.hunger,
		thirst = needs.thirst,
		health = clamp(needs.health - penalty),
	}
end

-- isDead: verdadero si y solo si la Salud es 0 o menos (Req. 4.8).
function NeedsModel.isDead(needs: Needs): boolean
	return needs.health <= MIN
end

return NeedsModel
