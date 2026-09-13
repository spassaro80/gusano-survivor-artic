--!strict
--[[
	TutorialController (LocalScript) — Instrucciones accesibles desde un botón de
	esquina (no bloqueante).

	Feature: juego-supervivencia-artico
	Ubicación Rojo: StarterPlayer/StarterPlayerScripts (default.project.json -> src/client).

	Cambio de diseño (a petición): al pulsar "SOBREVIVIR" el Jugador entra YA en el
	juego (la partida se activa en el servidor desde MenuController). Las
	instrucciones dejan de ser una tarjeta a pantalla completa que hay que cerrar;
	ahora son un pequeño BOTÓN en una esquina de la derecha que abre/cierra un panel
	con las instrucciones, sin pausar ni tapar el juego.

	Coordinación cliente (con MenuController): un BindableEvent local
	`ReplicatedStorage/ClientEvents/SurvivalRequested` que MenuController dispara al
	pulsar "SOBREVIVIR". Al recibirlo, este controlador muestra el botón de
	instrucciones. Se crea de forma idempotente por si arranca antes que MenuController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player: Player = Players.LocalPlayer
local playerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

-- Estado del panel (abierto/cerrado).
local panelOpen: boolean = false

--------------------------------------------------------------------------------
-- Coordinación de cliente: BindableEvent SurvivalRequested (idempotente).
--------------------------------------------------------------------------------
local function ensureSurvivalRequested(): BindableEvent
	local folder = ReplicatedStorage:FindFirstChild("ClientEvents")
	if not folder then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "ClientEvents"
		newFolder.Parent = ReplicatedStorage
		folder = newFolder
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
-- Textos de las instrucciones.
--------------------------------------------------------------------------------
local NEEDS_TEXT: string = "Vigila tus TRES necesidades: CALOR, HAMBRE y SED."
local HOWTO_TEXT: string = "• Mina ROCAS con el Pico para Piedra.\n"
	.. "• Tala ÁRBOLES con el Hacha y corta la leña para Madera.\n"
	.. "• Suelta un tronco y enciéndelo con el Mechero para una HOGUERA.\n"
	.. "• Excava las MONTAÑAS DE NIEVE con la Pala para hacer una CUEVA."
local OBJECTIVE_TEXT: string = "Objetivo: SOBREVIVE 7 DÍAS hasta el helicóptero de rescate."

--------------------------------------------------------------------------------
-- Construcción de la UI: botón de esquina + panel desplegable.
--------------------------------------------------------------------------------
type TutorialUi = {
	gui: ScreenGui,
	toggleButton: TextButton,
	panel: Frame,
}

local function makeLabel(parent: Instance, name: string, text: string, order: number, size: number, bold: boolean)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(235, 240, 245)
	label.TextSize = size
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Parent = parent
end

local function buildUi(): TutorialUi
	local gui = Instance.new("ScreenGui")
	gui.Name = "TutorialGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 60
	gui.Enabled = false -- se habilita al pulsar SOBREVIVIR
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Botón pequeño en la esquina derecha (a media altura) para abrir/cerrar.
	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "InstruccionesToggle"
	toggleButton.AnchorPoint = Vector2.new(1, 0.5)
	toggleButton.Position = UDim2.new(1, -12, 0.5, 0)
	toggleButton.Size = UDim2.new(0, 46, 0, 46)
	toggleButton.BackgroundColor3 = Color3.fromRGB(28, 120, 176)
	toggleButton.AutoButtonColor = true
	toggleButton.Text = "❔"
	toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleButton.TextSize = 26
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.ZIndex = 3
	toggleButton.Parent = gui

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(1, 0)
	toggleCorner.Parent = toggleButton

	-- Panel de instrucciones (oculto por defecto), anclado a la derecha.
	local panel = Instance.new("Frame")
	panel.Name = "InstruccionesPanel"
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -66, 0.5, 0)
	panel.Size = UDim2.new(0, 320, 0, 240)
	panel.BackgroundColor3 = Color3.fromRGB(24, 34, 46)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 2
	panel.Parent = gui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 12)
	panelCorner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 14)
	padding.PaddingBottom = UDim.new(0, 14)
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	makeLabel(panel, "Title", "INSTRUCCIONES", 1, 20, true)
	makeLabel(panel, "Needs", NEEDS_TEXT, 2, 15, false)
	makeLabel(panel, "HowTo", HOWTO_TEXT, 3, 15, false)
	makeLabel(panel, "Objective", OBJECTIVE_TEXT, 4, 15, false)

	gui.Parent = playerGui

	return { gui = gui, toggleButton = toggleButton, panel = panel }
end

local ui: TutorialUi = buildUi()

--------------------------------------------------------------------------------
-- Mostrar botón / alternar panel.
--------------------------------------------------------------------------------

-- showToggle — Habilita el botón de instrucciones al entrar en el juego.
local function showToggle(): ()
	ui.gui.Enabled = true
end

-- togglePanel — Abre o cierra el panel de instrucciones.
local function togglePanel(): ()
	panelOpen = not panelOpen
	ui.panel.Visible = panelOpen
	ui.toggleButton.Text = if panelOpen then "✕" else "❔"
end

--------------------------------------------------------------------------------
-- Conexiones.
--------------------------------------------------------------------------------
ui.toggleButton.Activated:Connect(togglePanel)

local survivalRequested = ensureSurvivalRequested()
survivalRequested.Event:Connect(showToggle)
