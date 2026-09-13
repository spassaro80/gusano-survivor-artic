--!strict
--[[
	CoolerModel.lua — Reglas puras de la Neverita Portátil.

	Feature: juego-supervivencia-artico

	ModuleScript de lógica PURA ubicado en ReplicatedStorage/Shared. No depende
	del motor de Roblox: recibe estado y devuelve estado nuevo, sin efectos
	secundarios ni mutación de las tablas de entrada.

	Modela la Neverita con capacidad máxima `Constants.COOLER.CAPACITY` (30 peces).
	El contador `count` se mantiene siempre dentro del rango cerrado [0, 30].

	Requisitos cubiertos: 10.1, 10.2, 10.3, 10.4, 10.5
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

type Cooler = Types.Cooler

-- Capacidad máxima de peces de la Neverita (Req. 10.2).
local CAPACITY: number = Constants.COOLER.CAPACITY

local CoolerModel = {}

--[[
	add — Intenta añadir un pez a la Neverita.

	Si `count < CAPACITY`, devuelve una Neverita NUEVA con `count + 1` y `ok = true`.
	Si `count == CAPACITY` (llena), devuelve una copia intacta y `ok = false`.
	El contador resultante nunca supera CAPACITY. (Req. 10.1, 10.2, 10.4)
]]
function CoolerModel.add(cooler: Cooler): (Cooler, boolean)
	if cooler.count < CAPACITY then
		return { count = cooler.count + 1 }, true
	end
	return { count = cooler.count }, false
end

--[[
	remove — Intenta retirar un pez de la Neverita.

	Si `count > 0`, devuelve una Neverita NUEVA con `count - 1` y `ok = true`.
	Si `count == 0` (vacía), devuelve una copia intacta y `ok = false`.
	El contador resultante nunca baja de 0. (Req. 10.3, 10.5)
]]
function CoolerModel.remove(cooler: Cooler): (Cooler, boolean)
	if cooler.count > 0 then
		return { count = cooler.count - 1 }, true
	end
	return { count = cooler.count }, false
end

--[[
	isFull — Indica si la Neverita ha alcanzado su capacidad máxima.

	Devuelve `true` si y solo si `count >= CAPACITY`. (Req. 10.4)
]]
function CoolerModel.isFull(cooler: Cooler): boolean
	return cooler.count >= CAPACITY
end

return CoolerModel
