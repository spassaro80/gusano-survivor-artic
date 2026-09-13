--!strict
--[[
	InputRouter (LocalScript) — Traductor de INPUT a INTENCIONES del servidor.

	Feature: juego-supervivencia-artico
	Ubicación Rojo: StarterPlayer/StarterPlayerScripts (default.project.json -> src/client).

	Capa: CLIENTE (presentación e input). Este controlador es el ÚNICO punto del
	cliente que traduce clics, toques y teclas del Jugador en INTENCIONES y las
	envía al servidor por los RemoteEvents del contrato (`ReplicatedStorage.Remotes`).

	REGLA ARQUITECTÓNICA CRÍTICA (servidor autoritativo, ver design.md):
	  El cliente NUNCA decide el resultado de una acción (talar, excavar, pescar,
	  beber, encender, cocinar, dormir, escapar...). Este módulo SOLO:
	    1. Detecta qué Herramienta tiene equipada el Jugador (Tool hija del Character).
	    2. Calcula un rayo de mira desde la cámara y, si hace falta, el objetivo
	       (Instance/posición) que ese rayo impacta.
	    3. Empaqueta la intención con la FORMA DE PAYLOAD que espera cada sistema de
	       servidor y la envía por su RemoteEvent.
	  La validación (herramienta correcta, distancia, material, recursos, estado) y
	  toda decisión de resultado ocurren EN EL SERVIDOR. Si el servidor rechaza, lo
	  comunica por `StateUpdate` (que renderiza HudController); aquí no se comprueba
	  el éxito.

	NOTA DE SINCRONIZACIÓN (Rojo):
	  Por defecto Rojo interpreta un `*.lua` bajo `src/client` como ModuleScript.
	  Para que este controlador se ejecute como LocalScript, el proyecto debe tratar
	  `src/client/*` como LocalScripts (p. ej. renombrando a `*.client.lua`, o con un
	  bootstrapper de cliente que haga `require` de estos controladores). Se mantiene
	  el nombre `InputRouter.lua` pedido por la tarea; el arranque (`start()`) va al
	  final tras las funciones, como en MenuController/CameraController.

	CONTRATO DE PAYLOADS POR REMOTE (fuente de verdad: los sistemas de servidor):
	  Remotes.HarvestAction:FireServer({ kind = "hit"|"chop"|"mine", target = <Instance|Vector3> })
	      - "hit":  golpear Árbol (Hacha) o Roca (Pico). El servidor resuelve el nodo
	                por el atributo "id" de la Instance o por posición (7.1, 7.4, 7.8).
	      - "chop": "Cortar Leña" sobre un Tronco en el suelo (7.2, 7.3).
	      - "mine": minar un Fragmento_Roca (7.5).
	  Remotes.DigAction:FireServer(origin: Vector3, direction: Vector3)
	      - Excavar nieve con la Pala. El servidor lanza su propio rayo acotado a 3 m
	        desde `origin` en `direction` (8.1). Se envían DOS argumentos, no una tabla.
	  Remotes.FishingAction:FireServer({ kind = "cast"|"reel"|"breakIce", target = Vector3 })
	      - "cast":     lanzar la Caña de Pescar sobre el agua de un Agujero_Agua (9.2).
	      - "reel":     "¡Sacar Pez!" (9.4). No requiere target.
	      - "breakIce": romper hielo de lago con el Pico -> Agujero_Agua (9.1).
	  Remotes.ConsumeAction:FireServer({ kind = "drink"|"refillBottle" })
	      - "drink":        beber de la Botella de Agua (11.1).
	      - "refillBottle": rellenar junto a un Agujero_Agua (11.5..11.7).
	  Remotes.FireAction:FireServer({ kind = ..., ... })
	      - "dropWood"                                   -> soltar Madera como Tronco (12.1).
	      - "igniteEmergency", logId?/target = Vector3   -> encender Tronco con Mechero (12.3).
	      - "placeBaseBlueprint", target = Vector3       -> plano de Hoguera_Base (13.1).
	      - "addBaseWoodCenter",  fireId                 -> 3 Madera al centro (13.3).
	      - "igniteBase",         fireId                 -> encender base con Mechero (13.4).
	      - "feedBaseWood",       fireId, amount?        -> alimentar base (13.6).
	      - "dropRawFish",        target = Vector3       -> poner Pez a cocinar (13.7).
	      - "eatFish",            fireId, fishId          -> comer Pez cocinado/quemado (13.9/13.11).
	  Remotes.BedAction:FireServer({ kind = "place"|"setRespawn"|"sleep", position? })
	      - "place":      colocar la Cama (14.1/14.2).
	      - "setRespawn": fijar el punto de reaparición (14.3).
	      - "sleep":      dormir de noche (14.6/14.7).
	  Remotes.RescueChoice:FireServer({ choice = "escape"|"keepSurviving" })
	      - Elección del panel de rescate del Día 7 (15.3/15.4/15.5).

	MAPEO DE ENTRADA (asunciones documentadas — reconfigurable en las constantes):
	  Acción PRIMARIA (clic izquierdo del ratón / toque en pantalla): depende de la
	  Herramienta equipada, usando un rayo desde la cámara:
	    Hacha          -> HarvestAction { kind = "hit" }  (sobre un Árbol)
	    Pico           -> si el objetivo es hielo de lago: FishingAction { kind = "breakIce" }
	                      en caso contrario:               HarvestAction { kind = "hit" } (Roca)
	    Pala           -> DigAction(origin, direction)
	    Caña de Pescar -> FishingAction { kind = "cast" }
	    Botella de Agua-> ConsumeAction { kind = "drink" }
	    Mechero        -> FireAction { kind = "igniteEmergency", target }
	    Cama           -> BedAction { kind = "place", position }

	  Acciones sin clic natural (teclas; documentadas y reconfigurables en KEY_ACTIONS):
	    E -> INTERACTUAR (contextual según la Herramienta equipada):
	           Hacha           -> HarvestAction { kind = "chop" }   (Cortar Leña)
	           Pico            -> HarvestAction { kind = "mine" }   (minar Fragmento)
	           Caña de Pescar  -> FishingAction { kind = "reel" }   (¡Sacar Pez!)
	           Botella de Agua -> ConsumeAction { kind = "refillBottle" }
	           Cama            -> BedAction     { kind = "setRespawn" }
	    Q -> FireAction { kind = "dropWood" }
	    B -> FireAction { kind = "placeBaseBlueprint", target }
	    V -> FireAction { kind = "addBaseWoodCenter", fireId }   (usa la última Hoguera_Base conocida)
	    Y -> FireAction { kind = "igniteBase",        fireId }
	    H -> FireAction { kind = "feedBaseWood",       fireId, amount = 1 }
	    C -> FireAction { kind = "dropRawFish",        target }
	    X -> FireAction { kind = "eatFish", fireId, fishId }     (último Pez en cocción conocido)
	    Z -> BedAction  { kind = "sleep" }
	    1 -> RescueChoice { choice = "escape" }
	    2 -> RescueChoice { choice = "keepSurviving" }

	CACHÉ DE CONTEXTO DE CLIENTE (no autoritativa):
	  Algunas intenciones de fuego/cocina necesitan un `fireId`/`fishId` que el
	  servidor asigna y comunica por `StateUpdate` (p. ej. al colocar el plano de la
	  Hoguera_Base o al empezar a cocinar un Pez). Este módulo escucha `StateUpdate`
	  SOLO para recordar el último `fireId`/`fishId` recibidos y así poder referirlos
	  en acciones de teclado. Es una comodidad de presentación: el servidor sigue
	  validando todo. Si el cliente aún no conoce un id, la tecla no envía nada.

	GUARDAS DE ROBUSTEZ:
	  - Sin Character, sin Tool equipada o sin cámara, las acciones no fallan: se
	    ignoran de forma segura (nunca lanzan error).
	  - Se ignoran los eventos de input ya consumidos por la GUI (gameProcessedEvent).

	Requisitos cubiertos: 7.1, 8.1, 9.2, 11.1, 12.3, 14.3, 15.3
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player: Player = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Constantes de configuración
--------------------------------------------------------------------------------

-- Nombres EXACTOS de las Herramientas del kit inicial (deben coincidir con los que
-- valida el servidor: ver GameServer.KIT_TOOLS y los sistemas). "Mechero" no forma
-- parte del kit de 7, pero se soporta por si el flujo de juego lo entrega luego.
local TOOL_AXE: string = "Hacha"
local TOOL_PICKAXE: string = "Pico"
local TOOL_SHOVEL: string = "Pala"
local TOOL_ROD: string = "Caña de Pescar"
local TOOL_BOTTLE: string = "Botella de Agua"
local TOOL_BED: string = "Cama"
local TOOL_LIGHTER: string = "Mechero"

-- Alcance del rayo de mira (studs). Generoso a propósito: el servidor acota las
-- distancias reales de cada acción (excavar 3 m, encender 3 m, cortar leña 2 m,
-- etc.), de modo que aquí solo hace falta un objetivo razonable bajo el retículo.
local AIM_REACH: number = 60

-- Cantidad de Madera por defecto al alimentar la Hoguera_Base (Req. 13.6).
local FEED_WOOD_AMOUNT: number = 1

--------------------------------------------------------------------------------
-- Caché de contexto de cliente (NO autoritativa) alimentada por StateUpdate
--------------------------------------------------------------------------------

-- Último id de Hoguera_Base conocido por el cliente (para addBaseWoodCenter,
-- igniteBase, feedBaseWood, eatFish). El servidor lo comunica por StateUpdate.
local lastBaseFireId: string? = nil
-- Último Pez en cocción conocido (fireId + fishId) para eatFish.
local lastCookFireId: string? = nil
local lastCookFishId: string? = nil

--------------------------------------------------------------------------------
-- Utilidades de personaje / herramienta / cámara
--------------------------------------------------------------------------------

-- getCharacter — Character actual del Jugador si existe y está en el Workspace.
local function getCharacter(): Model?
	local character = player.Character
	if character and character.Parent then
		return character
	end
	return nil
end

-- getEquippedToolName — Nombre de la Tool equipada (Tool hija del Character), o
-- nil si no hay ninguna equipada. Roblox reparenta la Tool al Character al equipar.
local function getEquippedToolName(): string?
	local character = getCharacter()
	if character == nil then
		return nil
	end
	local tool = character:FindFirstChildOfClass("Tool")
	return tool and tool.Name or nil
end

-- getAimRay — Rayo de mira desde la cámara a través de la posición del ratón
-- (en primera persona bloqueada el ratón está centrado, por lo que equivale a
-- mirar al frente). Devuelve origen y dirección UNITARIA, o nil si no hay cámara.
local function getAimRay(): (Vector3?, Vector3?)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return nil, nil
	end
	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return ray.Origin, ray.Direction
end

-- raycastFromAim — Lanza un rayo de mira acotado a AIM_REACH excluyendo al propio
-- Character. Devuelve el RaycastResult (Instance + posición de impacto) o nil.
local function raycastFromAim(): RaycastResult?
	local origin, direction = getAimRay()
	if origin == nil or direction == nil then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = getCharacter()
	if character then
		params.FilterDescendantsInstances = { character }
	end

	return Workspace:Raycast(origin, direction * AIM_REACH, params)
end

-- resolveHitTarget — Devuelve un objetivo para HarvestAction "hit": la Instance
-- impactada si el rayo golpeó algo (el servidor resuelve el nodo por su atributo
-- "id"), o su posición de impacto como respaldo. nil si el rayo no impacta nada.
local function resolveHitTarget(): (Instance | Vector3)?
	local result = raycastFromAim()
	if result == nil then
		return nil
	end
	if result.Instance then
		return result.Instance
	end
	return result.Position
end

-- aimPosition — Posición del mundo bajo el retículo (impacto del rayo), o nil.
local function aimPosition(): Vector3?
	local result = raycastFromAim()
	if result == nil then
		return nil
	end
	return result.Position
end

-- looksLikeLakeIce — Heurística de CLIENTE para decidir, con el Pico equipado, si
-- el objetivo es hielo de lago (romper hielo) o roca (golpear). Se apoya en el
-- atributo "kind" que usan los sistemas de terreno ("ice"/"lakeIce") y, como
-- respaldo, en el nombre de la Instance. El servidor valida el material de todos
-- modos, así que un fallo de heurística solo produce un rechazo inofensivo.
local function looksLikeLakeIce(instance: Instance): boolean
	local kind = instance:GetAttribute("kind")
	if kind == "ice" or kind == "lakeIce" then
		return true
	end
	local name = string.lower(instance.Name)
	return string.find(name, "hielo") ~= nil
		or string.find(name, "ice") ~= nil
		or string.find(name, "lago") ~= nil
end

--------------------------------------------------------------------------------
-- Emisores de intención (envoltorios finos sobre los RemoteEvents)
--------------------------------------------------------------------------------

-- Cada emisor solo empaqueta y dispara: NINGUNO decide resultados (autoridad del
-- servidor). Se protegen con pcall para que un fallo puntual de red no rompa el
-- bucle de input del cliente.

local function fireHarvest(kind: string, target: (Instance | Vector3)?)
	if target == nil then
		return
	end
	pcall(function()
		Remotes.HarvestAction:FireServer({ kind = kind, target = target })
	end)
end

local function fireDig(origin: Vector3, direction: Vector3)
	pcall(function()
		Remotes.DigAction:FireServer(origin, direction)
	end)
end

local function fireFishing(kind: string, target: Vector3?)
	pcall(function()
		Remotes.FishingAction:FireServer({ kind = kind, target = target })
	end)
end

local function fireConsume(kind: string)
	pcall(function()
		Remotes.ConsumeAction:FireServer({ kind = kind })
	end)
end

local function fireFire(payload: { [string]: any })
	pcall(function()
		Remotes.FireAction:FireServer(payload)
	end)
end

local function fireBed(payload: { [string]: any })
	pcall(function()
		Remotes.BedAction:FireServer(payload)
	end)
end

local function fireRescue(choice: string)
	pcall(function()
		Remotes.RescueChoice:FireServer({ choice = choice })
	end)
end

--------------------------------------------------------------------------------
-- Acción PRIMARIA (clic izquierdo / toque): mapeo por Herramienta equipada
--------------------------------------------------------------------------------

--[[
	handlePrimaryAction — Traduce el clic/toque primario a la intención adecuada
	según la Herramienta equipada. Sin Herramienta o sin objetivo válido, no hace
	nada (guarda de robustez). Requisitos: 7.1, 8.1, 9.2, 11.1, 12.3, 14.3(place).
]]
local function handlePrimaryAction()
	local toolName = getEquippedToolName()
	if toolName == nil then
		return -- sin Herramienta equipada: nada que enrutar.
	end

	if toolName == TOOL_AXE then
		-- Golpear un Árbol con el Hacha (7.1). El servidor valida herramienta/nodo.
		fireHarvest("hit", resolveHitTarget())
	elseif toolName == TOOL_PICKAXE then
		-- Pico: sobre hielo de lago -> romper hielo (9.1); sobre roca -> golpear (7.4).
		local result = raycastFromAim()
		if result == nil then
			return
		end
		if result.Instance and looksLikeLakeIce(result.Instance) then
			fireFishing("breakIce", result.Position)
		else
			fireHarvest("hit", result.Instance or result.Position)
		end
	elseif toolName == TOOL_SHOVEL then
		-- Excavar nieve (8.1): se envían origen y dirección de la mira; el servidor
		-- lanza su propio rayo acotado a 3 m.
		local origin, direction = getAimRay()
		if origin ~= nil and direction ~= nil then
			fireDig(origin, direction)
		end
	elseif toolName == TOOL_ROD then
		-- Lanzar la Caña sobre el agua de un Agujero_Agua (9.2).
		local pos = aimPosition()
		if pos ~= nil then
			fireFishing("cast", pos)
		end
	elseif toolName == TOOL_BOTTLE then
		-- Beber de la Botella (11.1). No requiere objetivo.
		fireConsume("drink")
	elseif toolName == TOOL_LIGHTER then
		-- Encender un Tronco como Hoguera_Emergencia con el Mechero (12.3).
		local pos = aimPosition()
		if pos ~= nil then
			fireFire({ kind = "igniteEmergency", target = pos })
		end
	elseif toolName == TOOL_BED then
		-- Colocar la Cama en la posición apuntada (14.1/14.2).
		local pos = aimPosition()
		if pos ~= nil then
			fireBed({ kind = "place", position = pos })
		end
	end
end

--------------------------------------------------------------------------------
-- Acción de INTERACTUAR (tecla E): contextual según la Herramienta equipada
--------------------------------------------------------------------------------

--[[
	handleInteract — Acción secundaria contextual (Cortar Leña, minar, sacar Pez,
	rellenar Botella, fijar reaparición) según la Herramienta equipada.
	Requisitos: 7.2/7.3 (chop), 7.5 (mine), 9.4 (reel), 11.5..11.7 (refill), 14.3.
]]
local function handleInteract()
	local toolName = getEquippedToolName()
	if toolName == nil then
		return
	end

	if toolName == TOOL_AXE then
		fireHarvest("chop", resolveHitTarget()) -- Cortar Leña sobre un Tronco (7.3).
	elseif toolName == TOOL_PICKAXE then
		fireHarvest("mine", resolveHitTarget()) -- Minar un Fragmento_Roca (7.5).
	elseif toolName == TOOL_ROD then
		fireFishing("reel", nil) -- "¡Sacar Pez!" (9.4).
	elseif toolName == TOOL_BOTTLE then
		fireConsume("refillBottle") -- Rellenar junto a un Agujero_Agua (11.7).
	elseif toolName == TOOL_BED then
		fireBed({ kind = "setRespawn" }) -- Fijar punto de reaparición (14.3).
	end
end

--------------------------------------------------------------------------------
-- Acciones de teclado directas (fuego, cocina, dormir, rescate)
--------------------------------------------------------------------------------

local function handleDropWood()
	fireFire({ kind = "dropWood" }) -- 12.1
end

local function handlePlaceBaseBlueprint()
	local pos = aimPosition()
	if pos ~= nil then
		fireFire({ kind = "placeBaseBlueprint", target = pos }) -- 13.1
	end
end

local function handleAddBaseWood()
	if lastBaseFireId ~= nil then
		fireFire({ kind = "addBaseWoodCenter", fireId = lastBaseFireId }) -- 13.3
	end
end

local function handleIgniteBase()
	if lastBaseFireId ~= nil then
		fireFire({ kind = "igniteBase", fireId = lastBaseFireId }) -- 13.4
	end
end

local function handleFeedBaseWood()
	if lastBaseFireId ~= nil then
		fireFire({ kind = "feedBaseWood", fireId = lastBaseFireId, amount = FEED_WOOD_AMOUNT }) -- 13.6
	end
end

local function handleDropRawFish()
	local pos = aimPosition()
	if pos ~= nil then
		fireFire({ kind = "dropRawFish", target = pos }) -- 13.7
	end
end

local function handleEatFish()
	if lastCookFireId ~= nil and lastCookFishId ~= nil then
		fireFire({ kind = "eatFish", fireId = lastCookFireId, fishId = lastCookFishId }) -- 13.9/13.11
	end
end

local function handleSleep()
	fireBed({ kind = "sleep" }) -- 14.6/14.7
end

local function handleRescueEscape()
	fireRescue("escape") -- 15.4
end

local function handleRescueKeepSurviving()
	fireRescue("keepSurviving") -- 15.5
end

-- Tabla de despacho de teclas -> manejador. Reconfigurable en un solo sitio.
local KEY_ACTIONS: { [Enum.KeyCode]: () -> () } = {
	[Enum.KeyCode.E] = handleInteract,
	[Enum.KeyCode.Q] = handleDropWood,
	[Enum.KeyCode.B] = handlePlaceBaseBlueprint,
	[Enum.KeyCode.V] = handleAddBaseWood,
	[Enum.KeyCode.Y] = handleIgniteBase,
	[Enum.KeyCode.H] = handleFeedBaseWood,
	[Enum.KeyCode.C] = handleDropRawFish,
	[Enum.KeyCode.X] = handleEatFish,
	[Enum.KeyCode.Z] = handleSleep,
	[Enum.KeyCode.One] = handleRescueEscape,
	[Enum.KeyCode.Two] = handleRescueKeepSurviving,
}

--------------------------------------------------------------------------------
-- Escucha de StateUpdate: solo para cachear ids de contexto (NO autoritativo)
--------------------------------------------------------------------------------

--[[
	onStateUpdate — Extrae del estado replicado por el servidor los ids que las
	acciones de teclado necesitan referir (fireId de la Hoguera_Base, fishId del
	Pez en cocción). No renderiza HUD (eso es de HudController); solo recuerda el
	último contexto para que teclas como V/Y/H/X puedan enviar la intención correcta.
]]
local function onStateUpdate(payload: any)
	if type(payload) ~= "table" then
		return
	end

	if payload.kind == "fire" then
		-- Cualquier fase de fuego con un fireId actualiza la última Hoguera_Base.
		if type(payload.fireId) == "string" then
			lastBaseFireId = payload.fireId
		end
		-- Al empezar a cocinar, recuerda el par (fireId, fishId) para eatFish.
		if payload.phase == "cookingStarted" and type(payload.fishId) == "string" then
			lastCookFireId = payload.fireId
			lastCookFishId = payload.fishId
		end
	end
end

--------------------------------------------------------------------------------
-- Conexiones de input
--------------------------------------------------------------------------------

--[[
	onInputBegan — Enruta clics/toques a la acción primaria y teclas a la tabla de
	despacho. Ignora eventos ya consumidos por la GUI (gameProcessed) para no
	disparar acciones al pulsar botones del menú/tutorial/HUD.
]]
local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
		handlePrimaryAction()
		return
	end

	if inputType == Enum.UserInputType.Keyboard then
		local action = KEY_ACTIONS[input.KeyCode]
		if action then
			action()
		end
	end
end

--------------------------------------------------------------------------------
-- Arranque
--------------------------------------------------------------------------------

--[[
	start — Punto de entrada. Conecta el input del Jugador y la escucha de contexto
	de `StateUpdate`. Es seguro llamarlo aunque aún no exista el Character: las
	acciones se guardan a sí mismas contra estados incompletos.
]]
local function start()
	UserInputService.InputBegan:Connect(onInputBegan)
	Remotes.StateUpdate.OnClientEvent:Connect(onStateUpdate)
end

start()
