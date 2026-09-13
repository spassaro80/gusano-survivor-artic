--!strict
--[[
	Remotes (init.lua) — Contrato de comunicación cliente-servidor.

	Feature: juego-supervivencia-artico

	Este ModuleScript se sincroniza con Rojo como `ReplicatedStorage.Remotes`
	(ver default.project.json: `src/remotes` -> ReplicatedStorage.Remotes). Al
	ser `init.lua`, el `require(ReplicatedStorage.Remotes)` resuelve directamente
	a este módulo, y `script` ES la instancia `ReplicatedStorage.Remotes`, de modo
	que los RemoteEvent/RemoteFunction creados como hijos de `script` quedan bajo
	`ReplicatedStorage.Remotes`.

	Propósito: un único punto que crea (en el servidor) y localiza (en el cliente)
	los RemoteEvents y la RemoteFunction, de forma IDEMPOTENTE, para que tanto el
	servidor como el cliente obtengan LAS MISMAS instancias.

	Patrón:
	  - Servidor: crea cualquier Remote que falte (comprobando `FindFirstChild`
	    antes de crear, de modo que llamarlo varias veces NO duplica instancias).
	  - Cliente: espera cada Remote con `WaitForChild` (el servidor ya los creó).
	  - Se ramifica con `RunService:IsServer()`.

	Esto es "pegamento" del motor Roblox (no lógica pura): requerir
	ReplicatedStorage y RunService es esperado y necesario aquí.

	Tabla de Remotes (de la sección "Interfaces cliente-servidor" del diseño):

	| Remote        | Tipo           | Dirección | Propósito                                          |
	|---------------|----------------|-----------|----------------------------------------------------|
	| StartSurvival | RemoteEvent    | C->S      | Pulsar SOBREVIVIR / cerrar tutorial                |
	| HarvestAction | RemoteEvent    | C->S      | Golpear árbol/roca, cortar leña, minar fragmento   |
	| DigAction     | RemoteEvent    | C->S      | Excavar cubo de nieve                              |
	| FishingAction | RemoteEvent    | C->S      | Lanzar caña, sacar pez                             |
	| ConsumeAction | RemoteEvent    | C->S      | Beber, comer pez, rellenar botella                 |
	| FireAction    | RemoteEvent    | C->S      | Soltar madera, encender, alimentar hoguera         |
	| BedAction     | RemoteEvent    | C->S      | Colocar cama, fijar respawn, dormir                |
	| RescueChoice  | RemoteEvent    | C->S      | Escapar / Seguir sobreviviendo                     |
	| StateUpdate   | RemoteEvent    | S->C      | Replicar necesidades, inventario, clima al HUD     |
	| GetSaveState  | RemoteFunction | C->S      | Consultar el estado inicial al entrar              |

	Uso:
	  local Remotes = require(ReplicatedStorage.Remotes)
	  Remotes.HarvestAction:FireServer(...)          -- cliente
	  Remotes.StateUpdate:FireClient(player, state)  -- servidor
	  local state = Remotes.GetSaveState:InvokeServer()  -- cliente

	Requisitos cubiertos: 2.4, 7.1, 8.1, 9.2, 11.1, 12.3, 14.3, 15.3, 16.4
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Tipo del accesor tipado devuelto por este módulo. Documenta la dirección de
-- cada Remote en el nombre del campo mediante los comentarios de arriba.
export type RemotesTable = {
	-- RemoteEvents Cliente -> Servidor
	StartSurvival: RemoteEvent,
	HarvestAction: RemoteEvent,
	DigAction: RemoteEvent,
	FishingAction: RemoteEvent,
	ConsumeAction: RemoteEvent,
	FireAction: RemoteEvent,
	BedAction: RemoteEvent,
	RescueChoice: RemoteEvent,
	-- RemoteEvent Servidor -> Cliente
	StateUpdate: RemoteEvent,
	-- RemoteFunction Cliente -> Servidor
	GetSaveState: RemoteFunction,
}

-- Nombres de los RemoteEvents que se declaran bajo ReplicatedStorage.Remotes.
-- Incluye los C->S y el único S->C (`StateUpdate`); la clase de instancia es la
-- misma (RemoteEvent), la dirección es una convención de uso, no de tipo.
local REMOTE_EVENT_NAMES: { string } = {
	"StartSurvival",
	"HarvestAction",
	"DigAction",
	"FishingAction",
	"ConsumeAction",
	"FireAction",
	"BedAction",
	"RescueChoice",
	"StateUpdate",
}

-- Nombres de las RemoteFunctions bajo ReplicatedStorage.Remotes.
local REMOTE_FUNCTION_NAMES: { string } = {
	"GetSaveState",
}

-- Tiempo máximo de espera (segundos) del cliente por cada Remote. Un valor
-- acotado evita que un cliente quede colgado indefinidamente si el servidor
-- no llegó a inicializar los Remotes por algún fallo de arranque.
local CLIENT_WAIT_TIMEOUT: number = 30

--[[
	ensureRemote — Crea de forma IDEMPOTENTE un Remote de la clase indicada como
	hijo de `parent`, o devuelve el existente.

	Solo debe llamarse en el servidor. Comprueba `FindFirstChild` antes de crear,
	por lo que invocarlo múltiples veces nunca produce duplicados.
]]
local function ensureRemote(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = parent
	return remote
end

--[[
	buildOnServer — Crea (si faltan) todos los Remotes bajo `script`
	(= ReplicatedStorage.Remotes) y devuelve el accesor tipado.
]]
local function buildOnServer(): RemotesTable
	local remotes: { [string]: Instance } = {}

	for _, name in REMOTE_EVENT_NAMES do
		remotes[name] = ensureRemote(script, "RemoteEvent", name)
	end
	for _, name in REMOTE_FUNCTION_NAMES do
		remotes[name] = ensureRemote(script, "RemoteFunction", name)
	end

	return (remotes :: any) :: RemotesTable
end

--[[
	buildOnClient — Espera a que el servidor haya creado cada Remote y devuelve
	el accesor tipado. Usa `WaitForChild` con un timeout acotado.
]]
local function buildOnClient(): RemotesTable
	local remotes: { [string]: Instance } = {}

	for _, name in REMOTE_EVENT_NAMES do
		local remote = script:WaitForChild(name, CLIENT_WAIT_TIMEOUT)
		assert(remote, string.format("Remote '%s' no disponible tras %d s", name, CLIENT_WAIT_TIMEOUT))
		remotes[name] = remote
	end
	for _, name in REMOTE_FUNCTION_NAMES do
		local remote = script:WaitForChild(name, CLIENT_WAIT_TIMEOUT)
		assert(remote, string.format("Remote '%s' no disponible tras %d s", name, CLIENT_WAIT_TIMEOUT))
		remotes[name] = remote
	end

	return (remotes :: any) :: RemotesTable
end

-- Se resuelve una sola vez al requerir el módulo. En el servidor crea los
-- Remotes; en el cliente los espera. Como los módulos se cachean por contexto,
-- todos los `require` posteriores reciben el mismo accesor con las mismas
-- instancias (idempotencia efectiva a nivel de proceso).
local Remotes: RemotesTable
if RunService:IsServer() then
	Remotes = buildOnServer()
else
	Remotes = buildOnClient()
end

return Remotes
