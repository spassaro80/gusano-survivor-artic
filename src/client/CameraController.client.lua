--!strict
--[[
	CameraController (LocalScript) — Vista en primera persona con brazos y
	herramienta visibles.

	Feature: juego-supervivencia-artico
	Ubicación Rojo: StarterPlayer/StarterPlayerScripts (default.project.json -> src/client).

	Capa: CLIENTE (presentación). Este controlador se encarga exclusivamente de la
	cámara del jugador local. No decide resultados de juego (la autoridad es el
	servidor); solo gestiona la presentación en primera persona.

	NOTA DE SINCRONIZACIÓN (Rojo):
	  Por defecto Rojo interpreta un `*.lua` bajo `src/client` como ModuleScript.
	  Para que este controlador se ejecute como LocalScript, el proyecto debe tratar
	  `src/client/*` como LocalScripts (p. ej. renombrando a `*.client.lua`, o con un
	  bootstrapper de cliente que haga `require` de estos controladores). Se mantiene
	  el nombre `CameraController.lua` pedido por la tarea; el arranque va al final.

	Requisitos cubiertos:
	  3.1  Activar la vista en primera persona para el Jugador dentro de 1 s desde
	       que comienza la partida activa. Se fuerza con
	       `player.CameraMode = Enum.CameraMode.LockFirstPerson`.
	  3.2  Garantizar que los brazos del propio Jugador y la herramienta equipada
	       sean visibles en primera persona en CADA fotograma renderizado. En Roblox,
	       `LockFirstPerson` oculta el personaje por defecto (el motor sube el
	       `LocalTransparencyModifier` de las partes en primera persona); por eso, en
	       cada `RenderStepped` reponemos `LocalTransparencyModifier = 0` en las partes
	       de brazo relevantes y en la herramienta equipada.

	ASUNCIONES / PLACEHOLDERS sobre el rig:
	  - Se soportan tanto rigs R15 como R6 mediante búsqueda por nombre de parte.
	    * R15 brazos: "LeftHand", "RightHand", "LeftLowerArm", "RightLowerArm",
	      "LeftUpperArm", "RightUpperArm".
	    * R6 brazos:  "Left Arm", "Right Arm".
	  - La herramienta equipada es un `Tool` hijo del `Character` (Roblox mueve el
	    Tool al Character al equiparlo). Se hacen visibles todos los `BasePart` del
	    Tool (Handle incluido) cada fotograma.
	  - Disparo de la primera persona: se activa SOLO cuando el servidor confirma el
	    inicio de la PARTIDA ACTIVA mediante `Remotes.StateUpdate { kind = "started" }`
	    (emitido tras cerrar el tutorial). Antes de eso la cámara queda en modo normal
	    con el cursor LIBRE, para que el Jugador pueda usar el ratón en el
	    Menu_Principal (1.x) y en la tarjeta del tutorial (2.x). Activarla antes
	    (p. ej. en `CharacterAdded`) capturaría el cursor al centro y haría que el
	    ratón pareciera no responder en esas pantallas. El personaje se vincula en
	    `CharacterAdded` para el bucle de visibilidad, pero la primera persona no se
	    fuerza hasta recibir "started" (Requisito 3.1).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player: Player = Players.LocalPlayer

-- Nombres de partes de brazo que deben permanecer visibles en primera persona.
-- Cubre R15 (manos/antebrazos/brazos superiores) y R6 ("Left Arm"/"Right Arm").
local ARM_PART_NAMES: { [string]: boolean } = {
	-- R15
	["LeftHand"] = true,
	["RightHand"] = true,
	["LeftLowerArm"] = true,
	["RightLowerArm"] = true,
	["LeftUpperArm"] = true,
	["RightUpperArm"] = true,
	-- R6
	["Left Arm"] = true,
	["Right Arm"] = true,
}

-- Estado del personaje actualmente gestionado. Se re-vincula en cada respawn.
local currentCharacter: Model? = nil

-- ¿Ha comenzado ya la PARTIDA ACTIVA? La primera persona (y el bloqueo del ratón
-- que conlleva) NO debe activarse hasta que el servidor confirme el inicio con
-- `StateUpdate { kind = "started" }`. Mientras esto sea false, la cámara queda en
-- modo normal (tercera persona, cursor libre) para que el Jugador pueda usar el
-- ratón en el Menu_Principal (1.x) y en la tarjeta del tutorial (2.x). Activar la
-- primera persona antes de tiempo captura el cursor al centro y hace que "el ratón
-- no funcione" en esas pantallas. (Requisito 3.1: activar al comenzar la partida.)
local firstPersonEnabled: boolean = false

--[[
	setFirstPerson — Fuerza el modo de cámara en primera persona bloqueada (3.1).
	Idempotente: puede llamarse varias veces sin efectos adversos.
]]
local function setFirstPerson(): ()
	-- LockFirstPerson bloquea la cámara en primera persona de inmediato.
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

--[[
	makeArmsAndToolVisible — Repone `LocalTransparencyModifier = 0` en las partes de
	brazo relevantes y en la herramienta equipada del personaje dado (3.2).

	Debe ejecutarse en cada fotograma (RenderStepped) porque, bajo LockFirstPerson,
	el motor vuelve a subir la transparencia local de las partes en primera persona
	tras cada render. Reponerla a 0 mantiene brazos y herramienta visibles siempre.
]]
local function makeArmsAndToolVisible(character: Model): ()
	for _, descendant in ipairs(character:GetChildren()) do
		if descendant:IsA("BasePart") and ARM_PART_NAMES[descendant.Name] then
			-- Brazo (R15 o R6): visible en primera persona.
			descendant.LocalTransparencyModifier = 0
		elseif descendant:IsA("Tool") then
			-- Herramienta equipada (Roblox la reparenta al Character al equipar).
			-- Hacer visibles todas sus partes, incluido el Handle.
			for _, toolPart in ipairs(descendant:GetDescendants()) do
				if toolPart:IsA("BasePart") then
					toolPart.LocalTransparencyModifier = 0
				end
			end
		end
	end
end

--[[
	bindCharacter — Vincula un personaje: activa la primera persona (3.1) y conecta
	el mantenimiento de visibilidad por fotograma (3.2). Robusto a respawns: cada
	nuevo personaje se re-vincula y sustituye al anterior como objetivo.
]]
local function bindCharacter(character: Model): ()
	currentCharacter = character

	-- Solo forzar la primera persona (y reponer visibilidad) si la partida activa
	-- ya comenzó. Antes de eso, dejar el modo de cámara normal para no capturar el
	-- cursor durante el menú/tutorial (Requisito 3.1). En respawns durante la
	-- partida, `firstPersonEnabled` seguirá siendo true y se re-vincula igual.
	if firstPersonEnabled then
		setFirstPerson()
		-- Reponer visibilidad de inmediato para evitar un fotograma con brazos ocultos.
		makeArmsAndToolVisible(character)
	end
end

--[[
	enableFirstPerson — Activa la vista en primera persona al comenzar la PARTIDA
	ACTIVA (Requisito 3.1). Es el ÚNICO punto que habilita el bloqueo del cursor:
	se invoca al recibir del servidor `StateUpdate { kind = "started" }`, es decir,
	tras cerrar el tutorial. Idempotente: llamadas repetidas no tienen efecto extra.
]]
local function enableFirstPerson(): ()
	if firstPersonEnabled then
		return
	end
	firstPersonEnabled = true

	setFirstPerson()
	local character = currentCharacter
	if character and character.Parent then
		makeArmsAndToolVisible(character)
	end
end

--[[
	onRenderStepped — Se ejecuta en cada fotograma renderizado. Mantiene brazos y
	herramienta equipada visibles (3.2) y reafirma la primera persona por robustez
	ante cambios externos del modo de cámara.
]]
local function onRenderStepped(): ()
	-- Mientras la partida activa no haya comenzado, no tocar la cámara ni la
	-- visibilidad: el cursor debe quedar libre para el menú/tutorial (Req. 3.1).
	if not firstPersonEnabled then
		return
	end

	local character = currentCharacter
	if not character or not character.Parent then
		return
	end

	-- Reafirmar primera persona de forma defensiva (barato e idempotente).
	if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		setFirstPerson()
	end

	makeArmsAndToolVisible(character)
end

--[[
	start — Punto de entrada. Vincula el personaje actual (si ya existe), se suscribe
	a `CharacterAdded` para reconectar en cada respawn (robustez), y arranca el bucle
	`RenderStepped` que mantiene la visibilidad de brazos y herramienta.
]]
local function start(): ()
	print("[Gusano] CameraController v3: raton libre en menu/tutorial, 1a persona al iniciar.")

	-- Si el personaje ya existe al arrancar (hot-reload / carga tardía), vincularlo.
	if player.Character then
		bindCharacter(player.Character)
	end

	-- Reconexión robusta ante respawns (Requisito de robustez del enunciado).
	player.CharacterAdded:Connect(function(character: Model)
		bindCharacter(character)
	end)

	-- Limpieza al morir/desaparecer el personaje: dejar de apuntar a un modelo muerto.
	player.CharacterRemoving:Connect(function(character: Model)
		if currentCharacter == character then
			currentCharacter = nil
		end
	end)

	-- Activar la primera persona SOLO cuando el servidor confirme el inicio de la
	-- partida activa (`kind == "started"`), tras cerrar el tutorial. Así el cursor
	-- permanece libre en el menú y el tutorial (Requisito 3.1).
	Remotes.StateUpdate.OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and payload.kind == "started" then
			enableFirstPerson()
		end
	end)

	-- Bucle por fotograma: garantiza visibilidad en CADA render (Requisito 3.2).
	RunService.RenderStepped:Connect(onRenderStepped)
end

start()
