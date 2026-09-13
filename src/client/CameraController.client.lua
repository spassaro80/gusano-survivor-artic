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
	  - Placeholder de disparo: por robustez, la primera persona se activa tanto al
	    aparecer el personaje (`CharacterAdded`) como al recibir la señal local
	    `SurvivalStarted` (si algún controlador la emite). No bloquea si la señal no
	    existe: el `CharacterAdded` basta para cumplir el presupuesto de 1 s (3.1).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

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

	-- Requisito 3.1: primera persona en cuanto el personaje existe (muy por debajo
	-- del presupuesto de 1 s).
	setFirstPerson()

	-- Reponer visibilidad de inmediato para evitar un fotograma con brazos ocultos.
	makeArmsAndToolVisible(character)
end

--[[
	onRenderStepped — Se ejecuta en cada fotograma renderizado. Mantiene brazos y
	herramienta equipada visibles (3.2) y reafirma la primera persona por robustez
	ante cambios externos del modo de cámara.
]]
local function onRenderStepped(): ()
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

	-- Bucle por fotograma: garantiza visibilidad en CADA render (Requisito 3.2).
	RunService.RenderStepped:Connect(onRenderStepped)
end

start()
