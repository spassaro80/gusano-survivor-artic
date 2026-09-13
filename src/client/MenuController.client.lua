--!strict
--[[
	MenuController — Menú principal inmersivo del cliente.

	Feature: juego-supervivencia-artico

	Capa: CLIENTE (presentación e input). Este es un LocalScript pensado para
	vivir bajo `StarterPlayer/StarterPlayerScripts` (Rojo: `src/client`). Ejecuta
	código de nivel superior al arrancar el cliente para construir y mostrar el
	Menu_Principal.

	NOTA DE SINCRONIZACIÓN (Rojo):
	  Por defecto Rojo interpreta un archivo `*.lua` como ModuleScript. Para que
	  este controlador se ejecute automáticamente como LocalScript, el proyecto
	  debe tratar `src/client/*` como LocalScripts (por ejemplo renombrando a
	  `MenuController.client.lua`, o mediante un bootstrapper de cliente que haga
	  `require` de estos controladores). Se mantiene el nombre `MenuController.lua`
	  pedido por la tarea; el código de arranque va al final tras las funciones.

	Requisitos cubiertos:
	  1.1  Al arrancar, mostrar (≤3 s) una escena de bosque nevado + título
	       "7 DÍAS EN EL ÁRTICO".
	  1.2  Mientras el menú es visible, reproducir en bucle un sonido de viento.
	  1.3  Al terminar la escena de intro, mostrar el botón "SOBREVIVIR".
	  1.4  Al pulsar "SOBREVIVIR", iniciar la secuencia de tutorial disparando
	       `Remotes.StartSurvival` (el TutorialController — tarea 18.2 — escucha
	       el hand-off local). El servidor comienza el flujo activo/tutorial.
	  1.5  Si el sonido de viento no puede reproducirse, seguir mostrando la
	       escena + botón sin bloquear el arranque (carga/reproducción en pcall).

	ASUNCIONES / PLACEHOLDERS:
	  - Los `rbxassetid` de imagen y sonido son PLACEHOLDERS. El arte y el audio
	    definitivos pueden intercambiarse cambiando las constantes ASSETS de abajo,
	    sin tocar la lógica del menú.
	  - El hand-off al tutorial se realiza por DOS vías complementarias:
	      1. El RemoteEvent `StartSurvival` (C→S, contrato del diseño): informa al
	         servidor de la intención de empezar. Firing sin argumentos es
	         intencional; el servidor arranca su flujo.
	      2. Una señal local cliente→cliente `ReplicatedStorage/ClientEvents/
	         SurvivalRequested` (BindableEvent) para que el TutorialController
	         (tarea 18.2) muestre su tarjeta SIN depender del rebote del servidor.
	    Este nombre/ubicación de señal es EXACTAMENTE el que espera
	    TutorialController (ver su docstring "CONTRATO DE COORDINACIÓN CLIENTE"),
	    de modo que ambos controladores se encuentran aunque arranquen en cualquier
	    orden: quien llega primero crea la carpeta/señal de forma idempotente.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player: Player = Players.LocalPlayer
local playerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

-- Placeholders de arte/audio. Intercambiables sin tocar la lógica del menú.
local ASSETS = {
	-- Escena de bosque nevado (fondo del menú). Sustituir por el arte final.
	SNOWY_FOREST_IMAGE = "rbxassetid://0", -- TODO(arte): imagen del bosque nevado
	-- Viento aullando en bucle. Sustituir por el SFX final.
	HOWLING_WIND_SOUND = "rbxassetid://0", -- TODO(audio): viento aullando
}

-- Duración de la "escena de intro" antes de revelar el botón (1.3). Se mantiene
-- muy por debajo del presupuesto de 3 s del criterio 1.1.
local INTRO_SCENE_SECONDS: number = 1.5

-- Ubicación de la señal local de hand-off al TutorialController (tarea 18.2).
-- DEBE coincidir con lo que escucha TutorialController: una carpeta `ClientEvents`
-- bajo ReplicatedStorage que contiene un BindableEvent `SurvivalRequested`.
local CLIENT_EVENTS_FOLDER_NAME: string = "ClientEvents"
local SURVIVAL_REQUESTED_SIGNAL_NAME: string = "SurvivalRequested"

--[[
	getOrCreateSurvivalRequested — Devuelve (creando de forma idempotente si hace
	falta) el BindableEvent `ReplicatedStorage/ClientEvents/SurvivalRequested`.

	Este es el punto de encuentro cliente→cliente con TutorialController: al pulsar
	"SOBREVIVIR" el menú hace `signal:Fire()` y el tutorial (que escucha
	`signal.Event`) muestra su tarjeta. Como ambos controladores crean la carpeta y
	la señal comprobando su existencia antes, el hand-off funciona sin importar cuál
	de los dos LocalScripts arranque primero.
]]
local function getOrCreateSurvivalRequested(): BindableEvent
	local folder = ReplicatedStorage:FindFirstChild(CLIENT_EVENTS_FOLDER_NAME)
	if not (folder and folder:IsA("Folder")) then
		local newFolder = Instance.new("Folder")
		newFolder.Name = CLIENT_EVENTS_FOLDER_NAME
		newFolder.Parent = ReplicatedStorage
		folder = newFolder
	end

	local existing = folder:FindFirstChild(SURVIVAL_REQUESTED_SIGNAL_NAME)
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	local signal = Instance.new("BindableEvent")
	signal.Name = SURVIVAL_REQUESTED_SIGNAL_NAME
	signal.Parent = folder
	return signal
end

--[[
	buildMenuGui — Construye la jerarquía de UI del menú en código y la parenta a
	PlayerGui. Devuelve la ScreenGui y el TextButton "SOBREVIVIR" (inicialmente
	oculto hasta que termine la escena de intro).

	Estructura:
	  ScreenGui "MenuPrincipal"
	    Frame "Root" (pantalla completa, fondo negro por si falla la imagen)
	      ImageLabel "SnowyForest" (escena de bosque nevado, 1.1)
	      TextLabel  "Title" ("7 DÍAS EN EL ÁRTICO", 1.1)
	      TextButton "SurviveButton" ("SOBREVIVIR", 1.3) — oculto al inicio
]]
local function buildMenuGui(): (ScreenGui, TextButton)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MenuPrincipal"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 100
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.fromRGB(10, 14, 20) -- respaldo si la imagen falla
	root.BorderSizePixel = 0
	root.Parent = screenGui

	-- Escena de bosque nevado (fondo). Placeholder de arte intercambiable (1.1).
	local scene = Instance.new("ImageLabel")
	scene.Name = "SnowyForest"
	scene.Size = UDim2.fromScale(1, 1)
	scene.BackgroundTransparency = 1
	scene.Image = ASSETS.SNOWY_FOREST_IMAGE
	scene.ScaleType = Enum.ScaleType.Crop
	scene.Parent = root

	-- Velo sutil para legibilidad del título sobre la imagen.
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	scrim.BackgroundTransparency = 0.45
	scrim.BorderSizePixel = 0
	scrim.Parent = scene

	-- Título "7 DÍAS EN EL ÁRTICO" (1.1).
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.32)
	title.Size = UDim2.fromScale(0.9, 0.2)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = "7 DÍAS EN EL ÁRTICO"
	title.TextColor3 = Color3.fromRGB(238, 246, 255)
	title.TextScaled = true
	title.TextStrokeTransparency = 0.4
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.Parent = root

	-- Botón "SOBREVIVIR" (1.3). Oculto hasta que la escena de intro termine.
	local surviveButton = Instance.new("TextButton")
	surviveButton.Name = "SurviveButton"
	surviveButton.AnchorPoint = Vector2.new(0.5, 0.5)
	surviveButton.Position = UDim2.fromScale(0.5, 0.72)
	surviveButton.Size = UDim2.fromScale(0.28, 0.11)
	surviveButton.BackgroundColor3 = Color3.fromRGB(28, 120, 176)
	surviveButton.AutoButtonColor = true
	surviveButton.Font = Enum.Font.GothamBold
	surviveButton.Text = "SOBREVIVIR"
	surviveButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	surviveButton.TextScaled = true
	surviveButton.Visible = false -- se revela tras la intro (1.3)
	surviveButton.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = surviveButton

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.Parent = surviveButton

	screenGui.Parent = playerGui

	return screenGui, surviveButton
end

--[[
	startWindLoop — Carga y reproduce en bucle el viento aullando (1.2), de forma
	NO BLOQUEANTE (1.5): cualquier fallo de carga/reproducción se captura con
	pcall y se registra, pero nunca interrumpe el menú. Devuelve el Sound creado
	(o nil si no se pudo crear) para poder detenerlo al salir del menú.
]]
local function startWindLoop(): Sound?
	local created: Sound? = nil
	local ok, err = pcall(function()
		local sound = Instance.new("Sound")
		sound.Name = "HowlingWind"
		sound.SoundId = ASSETS.HOWLING_WIND_SOUND
		sound.Looped = true -- bucle continuo mientras el menú es visible (1.2)
		sound.Volume = 0.6
		sound.Parent = playerGui
		created = sound
		sound:Play()
	end)
	if not ok then
		-- Fallo de audio: no crítico. El menú sigue mostrándose (1.5).
		warn("[MenuController] No se pudo reproducir el viento del menú: " .. tostring(err))
	end
	return created
end

--[[
	handOffToTutorial — Ejecuta el hand-off al pulsar "SOBREVIVIR" (1.4):
	  1. Dispara `Remotes.StartSurvival` al servidor (sin argumentos; el servidor
	     comienza el tutorial/flujo activo).
	  2. Dispara la señal local `MenuStart` para que el TutorialController arranque.
	  3. Oculta y destruye el menú, deteniendo el sonido del viento.
	Todo protegido para que un fallo puntual del Remote no deje el menú colgado.
]]
local function handOffToTutorial(screenGui: ScreenGui, windSound: Sound?)
	-- Disparo al servidor (contrato del diseño). No bloqueante ante fallos.
	pcall(function()
		Remotes.StartSurvival:FireServer()
	end)

	-- Señal local de arranque del tutorial (hand-off cliente→cliente, tarea 18.2).
	-- Fire() dispara `SurvivalRequested.Event`, que TutorialController escucha para
	-- atenuar la pantalla y mostrar su tarjeta de instrucciones.
	pcall(function()
		local signal = getOrCreateSurvivalRequested()
		signal:Fire()
	end)

	-- Detener el viento (deja de sonar al ocultar el menú, 1.2).
	if windSound then
		pcall(function()
			windSound:Stop()
			windSound:Destroy()
		end)
	end

	-- Ocultar y limpiar el menú.
	screenGui.Enabled = false
	screenGui:Destroy()
end

--[[
	start — Punto de entrada del controlador del menú. Construye la escena, lanza
	el viento en bucle, revela el botón tras la intro y conecta el hand-off.
]]
local function start()
	local screenGui, surviveButton = buildMenuGui()
	local windSound = startWindLoop()

	-- Evita hand-offs dobles si el jugador pulsa varias veces.
	local handedOff = false
	surviveButton.Activated:Connect(function()
		if handedOff then
			return
		end
		handedOff = true
		handOffToTutorial(screenGui, windSound)
	end)

	-- Revelar "SOBREVIVIR" cuando la escena de intro termina (1.3). Se hace en un
	-- hilo aparte para no bloquear el arranque del menú.
	task.delay(INTRO_SCENE_SECONDS, function()
		-- El menú pudo cerrarse antes (defensivo si el usuario es muy rápido).
		if surviveButton and surviveButton.Parent then
			surviveButton.Visible = true
		end
	end)
end

start()
