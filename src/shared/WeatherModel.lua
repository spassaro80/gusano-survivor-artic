--!strict
--[[
	WeatherModel.lua — Lógica pura del clima y ciclo de ventisca.

	Feature: juego-supervivencia-artico

	ModuleScript de lógica PURA ubicado en ReplicatedStorage/Shared. No tiene
	dependencias del motor Roblox: recibe estado y devuelve estado NUEVO, sin
	mutar la entrada ni producir efectos secundarios. Esto lo hace testeable de
	forma determinista con property-based testing (ver Propiedad 9 del diseño).

	Modelo (ver "Components and Interfaces" del diseño):
		type Weather = { timer:number, blizzardActive:boolean, blizzardRemaining:number }

	Reglas (Requisitos 6.1, 6.2, 6.3, 6.4, 6.7):
		- El temporizador `timer` cuenta atrás hacia 0 con cada `dt`.
		- Cuando `timer` llega a 0 (o menos), se activa una ventisca: `blizzardActive=true`,
		  se reinicia `timer` a CHANGE_INTERVAL_S (600 s) y `blizzardRemaining=BLIZZARD_DURATION_S` (60 s).
		- Mientras la ventisca está activa, `blizzardRemaining` decrece con cada `dt`;
		  cuando llega a 0 (o menos), se desactiva la ventisca (`blizzardActive=false`).
		- `visibilityFactor` devuelve 0.3 durante la ventisca y 1.0 con clima despejado.

	La selección aleatoria del nuevo clima usa `rng`, una función `() -> number`
	en el rango [0, 1), inyectada por el llamador para permitir pruebas deterministas.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

type Weather = Types.Weather

local WeatherModel = {}

local CHANGE_INTERVAL_S: number = Constants.WEATHER.CHANGE_INTERVAL_S -- 600 s (Req. 6.1)
local BLIZZARD_DURATION_S: number = Constants.WEATHER.BLIZZARD_DURATION_S -- 60 s (Req. 6.3)
local BLIZZARD_VISIBILITY: number = Constants.WEATHER.BLIZZARD_VISIBILITY_FACTOR -- 0.3 (Req. 6.4)
local CLEAR_VISIBILITY: number = Constants.WEATHER.CLEAR_VISIBILITY_FACTOR -- 1.0 (Req. 6.4)

--[[
	step — Avanza el estado del clima `dt` segundos.

	Devuelve SIEMPRE una tabla nueva; no muta `weather`.

	Maneja `dt` que puede cruzar varios límites (por ejemplo, un `dt` grande que
	agotaría el temporizador y además consumiría toda la ventisca) mediante un
	bucle acotado que procesa un tramo de tiempo a la vez.

	@param weather Estado actual del clima.
	@param dt      Tiempo transcurrido en segundos (se asume dt >= 0).
	@param rng     Función () -> number en [0, 1) para la selección uniforme del clima.
	@return Weather Nuevo estado del clima.
]]
function WeatherModel.step(weather: Weather, dt: number, rng: () -> number): Weather
	-- Copia local mutable de trabajo; la entrada nunca se modifica.
	local timer = weather.timer
	local blizzardActive = weather.blizzardActive
	local blizzardRemaining = weather.blizzardRemaining

	local remaining = if dt > 0 then dt else 0

	-- Procesa el paso de tiempo en tramos, de modo que un `dt` grande pueda
	-- cruzar el fin de un temporizador y/o el fin de una ventisca sin perder
	-- el tiempo sobrante. El bucle avanza siempre (consume tiempo o cruza un
	-- límite exacto), por lo que termina.
	while remaining > 0 do
		if blizzardActive then
			-- Durante la ventisca: consumir su tiempo restante.
			if blizzardRemaining > remaining then
				blizzardRemaining -= remaining
				remaining = 0
			else
				-- La ventisca termina dentro de este tramo.
				remaining -= blizzardRemaining
				blizzardRemaining = 0
				blizzardActive = false
			end
		else
			-- Clima despejado: contar atrás hacia el próximo cambio.
			if timer > remaining then
				timer -= remaining
				remaining = 0
			else
				-- El temporizador se agota dentro de este tramo: cambia el clima.
				remaining -= timer
				-- Selección uniforme del nuevo clima (mantiene rng en el contrato
				-- aunque el resultado active siempre la ventisca por diseño).
				local _roll = rng()
				blizzardActive = true
				timer = CHANGE_INTERVAL_S
				blizzardRemaining = BLIZZARD_DURATION_S
			end
		end
	end

	return {
		timer = timer,
		blizzardActive = blizzardActive,
		blizzardRemaining = blizzardRemaining,
	}
end

--[[
	visibilityFactor — Factor de visibilidad según el clima (Req. 6.4).
	@return number 0.3 si hay ventisca activa, 1.0 si el clima está despejado.
]]
function WeatherModel.visibilityFactor(weather: Weather): number
	if weather.blizzardActive then
		return BLIZZARD_VISIBILITY
	end
	return CLEAR_VISIBILITY
end

return WeatherModel
