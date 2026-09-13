--!strict
--[[
	BottleModel.lua — Lógica pura de la Botella de Agua.

	Feature: juego-supervivencia-artico

	ModuleScript de lógica PURA ubicado en ReplicatedStorage/Shared. No tiene
	dependencias del motor de Roblox: recibe estado y devuelve estado NUEVO, sin
	mutar las entradas ni producir efectos secundarios. Esto lo hace testeable de
	forma determinista (property-based testing).

	Modela los estados discretos de la Botella ("Full" | "Empty") y su efecto
	sobre la Sed del Jugador:
		- drink : si la Botella está llena, recupera +40 de Sed (clamp a 100),
		          deja la Botella vacía y devuelve ok=true. Si está vacía, no
		          cambia nada y devuelve ok=false.
		- refill: devuelve la Botella con estado "Full".

	La cantidad de restauración de Sed (+40) y el máximo (100) se reutilizan de
	Constants para no duplicar valores de balance.

	Requisitos cubiertos: 11.1, 11.2, 11.3, 11.4, 11.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

type Bottle = Types.Bottle
type Needs = Types.Needs

local BottleModel = {}

-- Cantidad de Sed que restaura beber (+40) y tope superior de las necesidades (100).
local THIRST_RESTORE = Constants.BOTTLE.DRINK_THIRST_RESTORE
local NEEDS_MAX = Constants.NEEDS.MAX

-- Bebe de la Botella.
-- Si la Botella está llena ("Full"): aumenta thirst en +40 (clamp a 100), deja la
-- Botella vacía ("Empty") y devuelve ok=true. Si está vacía ("Empty"): devuelve la
-- Botella y las necesidades sin cambios y ok=false.
-- Devuelve SIEMPRE tablas nuevas; no muta las entradas. (Req. 11.1, 11.2, 11.4, 11.7)
function BottleModel.drink(bottle: Bottle, needs: Needs): (Bottle, Needs, boolean)
	if bottle.state == "Full" then
		local newThirst = math.min(needs.thirst + THIRST_RESTORE, NEEDS_MAX)
		local newNeeds: Needs = {
			warmth = needs.warmth,
			hunger = needs.hunger,
			thirst = newThirst,
			health = needs.health,
		}
		local newBottle: Bottle = { state = "Empty" }
		return newBottle, newNeeds, true
	end

	-- Botella vacía: nada cambia. Se devuelven copias nuevas para no exponer las entradas.
	local unchangedBottle: Bottle = { state = bottle.state }
	local unchangedNeeds: Needs = {
		warmth = needs.warmth,
		hunger = needs.hunger,
		thirst = needs.thirst,
		health = needs.health,
	}
	return unchangedBottle, unchangedNeeds, false
end

-- Rellena la Botella dejándola en estado "Full". Devuelve una tabla nueva. (Req. 11.3)
function BottleModel.refill(_bottle: Bottle): Bottle
	local newBottle: Bottle = { state = "Full" }
	return newBottle
end

return BottleModel
