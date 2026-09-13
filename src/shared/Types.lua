--!strict
--[[
	Types.lua — Tipos Luau compartidos por la capa de lógica pura.

	Feature: juego-supervivencia-artico

	Este ModuleScript solo declara tipos (`export type`) para que otros módulos
	puedan referenciarlos con:
		local Types = require(ReplicatedStorage.Shared.Types)
		type Needs = Types.Needs

	No contiene lógica ni estado en tiempo de ejecución: devuelve una tabla vacía.
	Las formas de los tipos se corresponden con la sección "Data Models" y
	"Components and Interfaces" del documento de diseño.

	Requisitos cubiertos: 3.3, 4.1, 10.2, 13.8, 16.3
]]

-- Necesidades vitales del Jugador. Todos los valores viven en el rango [0, 100].
-- (Requisito 4.1)
export type Needs = {
	warmth: number,
	hunger: number,
	thirst: number,
	health: number,
}

-- Entorno del Jugador que condiciona el paso de tiempo de las necesidades.
-- underSnow / blizzardExposed activan el doble consumo de Calor; nearFire lo restaura.
export type Env = {
	underSnow: boolean,
	blizzardExposed: boolean,
	nearFire: boolean,
}

-- Neverita Portátil: contador de peces en el rango [0, 30]. (Requisito 10.2)
export type Cooler = {
	count: number,
}

-- Botella de Agua: estados discretos.
export type Bottle = {
	state: "Full" | "Empty",
}

-- Estado del pescado sobre el fuego. (Requisito 13.8)
export type FishState = "Raw" | "Cooked" | "Burned"

-- Pez en proceso de cocinado, con el tiempo acumulado sobre el fuego.
export type CookingFish = {
	state: FishState,
	timeOnFire: number,
}

-- Estado del clima: temporizador de cambio y ciclo de ventisca. (Requisito 6)
export type Weather = {
	timer: number,
	blizzardActive: boolean,
	blizzardRemaining: number,
}

-- Colocación de un recurso en el mapa (piedra o árbol). (Requisito 5)
export type Placement = {
	x: number,
	y: number,
	kind: "stone" | "tree",
}

-- Región rectangular del mapa; usada para los lagos helados. (Requisito 5.3)
export type Region = {
	x: number,
	y: number,
	width: number,
	height: number,
}

-- Descripción de la distribución del mundo generado. (Requisito 5)
export type World = {
	size: number,
	lakes: { Region },
	perimeter: number,
	placements: { Placement },
	seed: number?,
}

-- Subconjunto de datos persistidos en DataStore. (Requisito 16.3)
export type SaveData = {
	version: number,
	pos: { x: number, y: number, z: number },
	day: number,
	wood: number,
	stone: number,
	coolerFish: number,
	freeMode: boolean,
}

-- Inventario del Jugador: 7 herramientas + recursos apilables.
export type Inventory = {
	tools: { [string]: boolean },
	wood: number,
	stone: number,
	capacity: number,
}

-- Estado autoritativo del Jugador mantenido en el servidor. (Requisito 3.3)
export type PlayerState = {
	userId: number,
	needs: Needs,
	inventory: Inventory,
	cooler: Cooler,
	bottle: Bottle,
	day: number,
	freeMode: boolean,
	respawnBedId: string?,
	lastSaveClock: number,
}

return {}
