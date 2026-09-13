--!strict
--[[
	TutorialController (LocalScript) — Tarjeta de instrucciones iniciales.

	Feature: juego-supervivencia-artico
	Ubicación Rojo: StarterPlayer/StarterPlayerScripts (default.project.json -> src/client).

	Responsabilidad (Requisito 2): al pulsar "SOBREVIVIR" en el Menu_Principal,
	atenuar la pantalla (<=50% de opacidad) y mostrar una tarjeta de instrucciones
	en <=500 ms. La tarjeta explica las 3 necesidades (Calor, Hambre, Sed), cómo
	minar rocas / talar árboles / crear hogueras de emergencia, y el objetivo de
	sobrevivir 7 días reales hasta el helicóptero de rescate. Muestra un botón
	"ENTENDIDO" que, al pulsarse, oculta la tarjeta y restaura la opacidad al 100%
	en <=500 ms, y avisa al servidor de que el tutorial terminó para que comience
	la partida activa y el consumo de necesidades.

	--------------------------------------------------------------------------
	CONTRATO DE COORDINACIÓN CLIENTE (con MenuController, tarea 18.1)
	--------------------------------------------------------------------------
	Como MenuController y TutorialController son LocalScripts independientes en
	el mismo cliente, se coordinan mediante un BindableEvent local (no cruza la
	red, solo dispara listeners dentro del mismo cliente):

	  ReplicatedStorage/ClientEvents/SurvivalRequested : BindableEvent

	- MenuController: cuando el Jugador pulsa "SOBREVIVIR" (Requisito 1.4), en
	  vez de iniciar la partida directamente, hace:
	      local ev = ReplicatedStorage.ClientEvents.SurvivalRequested
	      ev:Fire()
	  y oculta su propia UI de menú.
	- TutorialController (este script): escucha ese BindableEvent y, al recibirlo,
	  muestra la tarjeta (Requisito 2.1). Este script CREA el BindableEvent de
	  forma idempotente si aún no existe, de modo que no depende del orden de
	  arranque entre ambos controladores.

	Este BindableEvent es puramente de cliente: se usa Fire/:Event (in-process),
	nunca FireServer. Si en el futuro MenuController prefiere invocar directamente,
	este módulo también expone el mismo BindableEvent como punto de encuentro.

	--------------------------------------------------------------------------
	CONTRATO CLIENTE -> SERVIDOR (con GameServer, tarea 16)
	--------------------------------------------------------------------------
	Al pulsar "ENTENDIDO" (Requisitos 2.7, 2.8) este script dispara:

	    Remotes.StartSurvival:FireServer({ phase = "tutorialDone" })

	GameServer (tarea 16.1) debe, al recibir StartSurvival con un payload cuyo
	campo `phase == "tutorialDone"`, comenzar la partida activa e iniciar el
	consumo de necesidades (Calor, Hambre, Sed). Mientras la tarjeta está visible,
	el cliente no habilita input/HUD de juego y la pausa de necesidades la impone
	el servidor (Requisito 2.6 es autoritativo en servidor: el servidor no inicia
	el consumo hasta recibir `phase == "tutorialDone"`).

	Nota de alcance: la construcción de la UI se hace en código (ScreenGui/Frame/
	TextLabel/TextButton) parentada al PlayerGui, según el diseño (Testing Strategy
	trata este controlador con pruebas de ejemplo/playtest, no PBT).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Remotes)

local player: Player = Players.LocalPlayer
local playerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

-- Duración de las transiciones de atenuar/restaurar. Debe quedar por debajo del
-- límite de 500 ms de los Requisitos 2.1 y 2.7; usamos 0.3 s por holgura y suavidad.
local TRANSITION_TIME: number = 0.3

-- Opacidad máxima de la atenuación: 50% de opacidad => overlay al 50% opaco =>
-- BackgroundTransparency = 0.5 (Requisito 2.1).
local DIM_TRANSPARENCY: number = 0.5

-- Estado interno del flujo del tutorial.
local tutorialActive: boolean = false
local tutorialDone: boolean = false

--------------------------------------------------------------------------------
-- Coordinación de cliente: BindableEvent SurvivalRequested (idempotente).
--------------------------------------------------------------------------------
local function ensureSurvivalRequested(): BindableEvent
	local folder = ReplicatedStorage:FindFirstChild("ClientEvents")
	if not folder then
		-- Puede que MenuController aún no lo haya creado; lo creamos nosotros.
		local existing = ReplicatedStorage:FindFirstChild("ClientEvents")
		if existing then
			folder = existing
		else
			local newFolder = Instance.new("Folder")
			newFolder.Name = "ClientEvents"
			newFolder.Parent = ReplicatedStorage
			folder = newFolder
		end
	end

	local signal = folder:FindFirstChild("SurvivalRequested")
	if not signal then
		local newSignal = Instance.new("BindableEvent")
		newSignal.Name = "SurvivalRequested"
		newSignal.Parent = folder
		signal = newSignal
	end

	return signal :: BindableEvent
end

--------------------------------------------------------------------------------
-- Construcción de la UI (en código).
--------------------------------------------------------------------------------
type TutorialUi = {
	gui: ScreenGui,
	dim: Frame,
	card: Frame,
	button: TextButton,
}

-- Textos de la tarjeta (Requisitos 2.2, 2.3, 2.4, 2.5).
local NEEDS_TEXT: string =
	"Vigila tus TRES necesidades vitales:\n• CALOR\n• HAMBRE\n• SED"
local HOWTO_TEXT: string =
	"Cómo sobrevivir:\n• Mina ROCAS con el Pico para obtener Piedra.\n"
	.. "• Tala ÁRBOLES con el Hacha y corta la leña para obtener Madera.\n"
	.. "• Suelta un tronco y enciéndelo con el Mechero para crear una HOGUERA DE EMERGENCIA."
local OBJECTIVE_TEXT: string =
	"Objetivo: SOBREVIVE 7 DÍAS REALES hasta que llegue el helicóptero de rescate."

local function buildUi(): TutorialUi
	local gui = Instance.new("ScreenGui")
	gui.Name = "TutorialGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Capa de atenuación a pantalla completa (arranca invisible: opacidad 100%).
	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.Position = UDim2.fromScale(0, 0)
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = 1 -- 100% de opacidad de pantalla = overlay transparente
	dim.BorderSizePixel = 0
	dim.ZIndex = 1
	dim.Parent = gui

	-- Tarjeta de instrucciones.
	local card = Instance.new("Frame")
	card.Name = "InstructionsCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.6, 0.72)
	card.BackgroundColor3 = Color3.fromRGB(24, 34, 46)
	card.BackgroundTransparency = 0
	card.BorderSizePixel = 0
	card.ZIndex = 2
	card.Visible = false
	card.Parent = gui

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 12)
	cardCorner.Parent = card

	local cardPadding = Instance.new("UIPadding")
	cardPadding.PaddingTop = UDim.new(0, 24)
	cardPadding.PaddingBottom = UDim.new(0, 24)
	cardPadding.PaddingLeft = UDim.new(0, 24)
	cardPadding.PaddingRight = UDim.new(0, 24)
	cardPadding.Parent = card

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = card

	local function makeLabel(name: string, text: string, order: number, size: number, bold: boolean): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.LayoutOrder = order
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(235, 240, 245)
		label.TextScaled = false
		label.TextSize = size
		label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.ZIndex = 2
		label.Parent = card
		return label
	end

	makeLabel("Title", "INSTRUCCIONES", 1, 28, true)
	makeLabel("Needs", NEEDS_TEXT, 2, 20, false)
	makeLabel("HowTo", HOWTO_TEXT, 3, 20, false)
	makeLabel("Objective", OBJECTIVE_TEXT, 4, 20, false)

	-- Botón "ENTENDIDO" (Requisito 2.5).
	local button = Instance.new("TextButton")
	button.Name = "EntendidoButton"
	button.LayoutOrder = 5
	button.Size = UDim2.new(0, 220, 0, 48)
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.fromRGB(46, 120, 88)
	button.Text = "ENTENDIDO"
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 22
	button.Font = Enum.Font.GothamBold
	button.ZIndex = 2
	button.Parent = card

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = button

	gui.Parent = playerGui

	return {
		gui = gui,
		dim = dim,
		card = card,
		button = button,
	}
end

local ui: TutorialUi = buildUi()

--------------------------------------------------------------------------------
-- Mostrar / ocultar la tarjeta.
--------------------------------------------------------------------------------

-- showTutorial — Atenúa la pantalla y muestra la tarjeta (<=500 ms). Requisito 2.1.
local function showTutorial(): ()
	if tutorialActive or tutorialDone then
		return
	end
	tutorialActive = true

	ui.gui.Enabled = true
	ui.card.Visible = true
	ui.dim.BackgroundTransparency = 1

	local tweenInfo = TweenInfo.new(TRANSITION_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ui.dim, tweenInfo, { BackgroundTransparency = DIM_TRANSPARENCY }):Play()
end

-- hideTutorial — Oculta la tarjeta, restaura la opacidad al 100% (<=500 ms,
-- Requisito 2.7) y avisa al servidor de que el tutorial terminó (Requisito 2.8).
local function hideTutorial(): ()
	if not tutorialActive or tutorialDone then
		return
	end
	tutorialActive = false
	tutorialDone = true

	-- Ocultar la tarjeta de inmediato; atenuación se disuelve con transición.
	ui.card.Visible = false

	local tweenInfo = TweenInfo.new(TRANSITION_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(ui.dim, tweenInfo, { BackgroundTransparency = 1 })
	tween.Completed:Connect(function()
		ui.gui.Enabled = false
	end)
	tween:Play()

	-- Señalar al servidor que el tutorial terminó para iniciar la partida activa
	-- y el consumo de necesidades (Requisito 2.8 / contrato con GameServer).
	Remotes.StartSurvival:FireServer({ phase = "tutorialDone" })
end

--------------------------------------------------------------------------------
-- Conexiones.
--------------------------------------------------------------------------------
ui.button.Activated:Connect(function()
	hideTutorial()
end)

local survivalRequested = ensureSurvivalRequested()
survivalRequested.Event:Connect(function()
	showTutorial()
end)
