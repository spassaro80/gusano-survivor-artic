--!strict
--[[
	Constants.lua — Constantes de balance de "7 Días en el Ártico"

	ModuleScript de lógica pura ubicado en ReplicatedStorage/Shared.
	Contiene EXACTAMENTE los valores de la tabla "Constantes de balance" del
	documento de diseño. La tabla resultante (y sus subtablas) se congela con
	`table.freeze` para garantizar que los valores de balance son inmutables en
	tiempo de ejecución.

	Todas las tasas expresadas "por segundo" (per second) se aplican multiplicadas
	por el `dt` del bucle de simulación en los modelos puros.

	Referencias de requisito indicadas junto a cada grupo/valor.
]]

-- NEEDS — Necesidades vitales (Calor, Hambre, Sed, Salud), rango [0, 100].
local NEEDS = table.freeze({
	MAX = 100, -- Máximo de las barras de necesidad (Req. 4.1)
	MIN = 0, -- Mínimo de las barras de necesidad (Req. 4.1)
	-- Tasas de consumo (%/s). Ajustadas a un ritmo jugable: una barra llena tarda
	-- ~8 min en agotarse por descuido, y beber/comer (+40) da un buen respiro.
	-- (Balance de juego; ver design.md "Constantes de balance").
	WARMTH_DECAY_PER_S = 0.2, -- Consumo base de Calor en %/s (×2 bajo nieve/ventisca)
	HUNGER_DECAY_PER_S = 0.2, -- Consumo de Hambre en %/s (Req. 4.5)
	THIRST_DECAY_PER_S = 0.2, -- Consumo de Sed en %/s (Req. 4.6)
	COLD_EXPOSURE_MULTIPLIER = 2, -- Multiplicador de consumo de Calor bajo nieve/ventisca ×2 (Req. 4.3, 6.6)
	HEALTH_DECAY_PER_S_WHEN_DEPLETED = 5, -- Caída de Salud en %/s si una necesidad está a 0 (Req. 4.7)
	DRINK_THIRST_RESTORE = 40, -- Recuperación de Sed al beber (Req. 11.1)
	EAT_HUNGER_RESTORE = 40, -- Recuperación de Hambre al comer pez cocinado (Req. 13.9)
	BURNED_FISH_HEALTH_PENALTY = 15, -- Penalización de Salud al comer pez quemado (Req. 13.11)
})

-- HARVEST — Talado, minería y respawn de recursos.
local HARVEST = table.freeze({
	HITS_TO_FELL = 5, -- Golpes para talar un árbol o desmoronar una roca (Req. 7.1, 7.4)
	WOOD_PER_LOG = 3, -- Madera obtenida por tronco al cortar leña (Req. 7.3)
	STONE_PER_FRAGMENT = 1, -- Piedra obtenida por fragmento minado (Req. 7.5)
	RESPAWN_S = 60, -- Respawn de árbol/roca en segundos (Req. 7.6, 7.7)
})

-- COOLER — Neverita.
local COOLER = table.freeze({
	CAPACITY = 30, -- Capacidad máxima de peces (Req. 10.2)
})

-- BOTTLE — Botella de agua.
local BOTTLE = table.freeze({
	DRINK_THIRST_RESTORE = 40, -- Recuperación de Sed al beber (Req. 11.1)
})

-- FIRE — Hoguera de emergencia y hoguera de base.
local FIRE = table.freeze({
	-- Hoguera de emergencia
	EMERGENCY_DURATION_S = 45, -- Duración de la hoguera de emergencia en segundos (Req. 12.6)
	EMERGENCY_WARMTH_PER_S = 10, -- Calor aportado por segundo por la hoguera de emergencia (Req. 12.5)
	EMERGENCY_RADIUS_M = 5, -- Radio de efecto de la hoguera de emergencia en metros (Req. 12.5)

	-- Hoguera de base
	BASE_STONE_COST = 5, -- Piedra necesaria para colocar la hoguera de base (Req. 13.1)
	BASE_WOOD_COST = 3, -- Madera necesaria para la hoguera de base (Req. 13.3)
	BASE_WOOD_CAP = 20, -- Tope de madera almacenable en la hoguera de base (Req. 13.6)
	MAX_COOKING_FISH = 5, -- Peces cocinándose a la vez (Req. 13.7)
})

-- COOKING — Máquina de estados del pescado (Raw → Cooked → Burned).
local COOKING = table.freeze({
	RAW_TO_COOKED_S = 10, -- Tiempo Crudo → Cocinado en segundos (Req. 13.8)
	COOKED_TO_BURNED_S = 8, -- Tiempo adicional Cocinado → Quemado en segundos (Req. 13.10)
	TOTAL_TO_BURNED_S = 18, -- Tiempo total acumulado hasta Quemado (10 + 8) (Req. 13.8, 13.10)
	COOKED_HUNGER_RESTORE = 40, -- Recuperación de Hambre al comer pez cocinado (Req. 13.9)
	BURNED_HEALTH_PENALTY = 15, -- Penalización de Salud por pez quemado (Req. 13.11)
})

-- WEATHER — Ciclo de clima y ventiscas.
local WEATHER = table.freeze({
	CHANGE_INTERVAL_S = 600, -- Intervalo de cambio de clima en segundos (Req. 6.1)
	BLIZZARD_DURATION_S = 60, -- Duración de una ventisca en segundos (Req. 6.3)
	BLIZZARD_VISIBILITY_FACTOR = 0.3, -- Factor de visibilidad durante ventisca (Req. 6.4)
	CLEAR_VISIBILITY_FACTOR = 1.0, -- Factor de visibilidad con clima despejado (Req. 6.4)
})

-- SAVE — Guardado automático y versión del formato persistido.
local SAVE = table.freeze({
	INTERVAL_S = 120, -- Intervalo de guardado automático en segundos (Req. 16.1)
	FORMAT_VERSION = 1, -- Versión del formato de guardado (Req. 16.3, 16.7)
})

-- RESCUE — Rescate y modo libre.
local RESCUE = table.freeze({
	DAY = 7, -- Día en que llega el helicóptero de rescate (Req. 15.1)
})

-- INTERACTION — Distancias de interacción usadas en el diseño (en metros).
local INTERACTION = table.freeze({
	CHOP_WOOD_M = 2, -- Distancia para "Cortar Leña" sobre un tronco (Req. 12.x)
	REFILL_BOTTLE_M = 2, -- Distancia para rellenar la botella junto a un agujero de agua (Req. 11.6)
	IGNITE_LOG_M = 3, -- Distancia para encender un tronco con el Mechero (Req. 12.4)
	DIG_M = 3, -- Distancia para excavar nieve (Req. 8.1)
	HELICOPTER_APPROACH_M = 5, -- Distancia de aproximación al helicóptero (Req. 15.3)
	BED_RESPAWN_M = 2, -- Distancia de reaparición junto a la cama (Req. 14.5)
})

-- WORLD — Generación y distribución del mundo.
local WORLD = table.freeze({
	MAP_SIZE = 500, -- Tamaño del mapa en bloques (Req. 5.1)
	PERIMETER_BAND = 20, -- Ancho de la banda perimetral en bloques (Req. 5.5)
	MIN_LAKES = 3, -- Número mínimo de lagos (Req. 5.x)
	MAX_LAKES = 8, -- Número máximo de lagos (Req. 5.x)
	MIN_RESOURCE_SEPARATION = 2, -- Separación mínima entre recursos en bloques (Req. 5.4)
	STONE_COUNT = 100, -- Número de piedras a generar (más densidad de recursos)
	TREE_COUNT = 160, -- Número de árboles a generar (más densidad de recursos)
})

local Constants = table.freeze({
	NEEDS = NEEDS,
	HARVEST = HARVEST,
	COOLER = COOLER,
	BOTTLE = BOTTLE,
	FIRE = FIRE,
	COOKING = COOKING,
	WEATHER = WEATHER,
	SAVE = SAVE,
	RESCUE = RESCUE,
	INTERACTION = INTERACTION,
	WORLD = WORLD,
})

return Constants
