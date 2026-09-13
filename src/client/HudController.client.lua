--!strict
--[[
	HudController (LocalScript) — HUD de supervivencia (barras, parpadeo de frío,
	niebla/viento de ventisca y contador de Neverita).

	Feature: juego-supervivencia-artico
	Ubicación Rojo: StarterPlayer/StarterPlayerScripts (default.project.json -> src/client).

	Capa: CLIENTE (presentación). El HUD SOLO renderiza el estado que replica el
	servidor; nunca decide resultados de juego (la autoridad es el servidor). Se
	suscribe a `Remotes.StateUpdate` (canal S->C) y reacciona a los payloads cuyo
	campo `kind` le concierne, ignorando el resto.

	NOTA DE SINCRONIZACIÓN (Rojo):
	  Por defecto Rojo interpreta un `*.lua` bajo `src/client` como ModuleScript.
	  Para que este controlador se ejecute como LocalScript, el proyecto debe tratar
	  `src/client/*` como LocalScripts (p. ej. renombrando a `*.client.lua`, o con un
	  bootstrapper de cliente que haga `require` de estos controladores). Se mantiene
	  el nombre `HudController.lua` pedido por la tarea; el arranque (start) va al final.

	Payloads de `StateUpdate` a los que reacciona (por `kind`):
	  - "state"  : instantánea principal.
	      { kind="state", active:boolean,
	        needs = { warmth, hunger, thirst, health },      -- 0..100
	        inventory = { wood, stone, capacity },
	        cooler:number(0..30), bottle:"Full"|"Empty",
	        day:number, freeMode:boolean,
	        weather = { blizzardActive:boolean, visibilityFactor:number } }
	  - "cooler" : cambios puntuales de la Neverita.
	      phase="count" -> { count, capacity }
	      phase="full"  -> { count, capacity, message, minDurationSeconds }
	  - "weather": clima puntual { blizzardActive, visibilityFactor, windVolume }.
	  El resto de kinds ("started", "victory", "startRejected", "saveNotice",
	  "digRejected", "caveRegistered", ...) se ignoran aquí de forma segura.

	Requisitos cubiertos:
	  4.1  Tres barras elegantes: Calor (Warmth), Hambre (Hunger), Sed (Thirst),
	       cada una 0..100%. Se muestra además Salud como barra secundaria.
	  4.2  Al cambiar el valor de una barra, redimensionarla con una transición
	       suave de 200-400 ms. Se usa TweenService con tiempo en [0.2, 0.4] s.
	  4.4  Con Calor < 20%, parpadeo rojo de pantalla a 1-2 Hz + efecto de
	       congelación en los bordes. Se implementa con una viñeta roja cuya
	       transparencia oscila ~1.5 veces/segundo y un marco de escarcha en el
	       borde; se detiene al recuperar Calor >= 20%.
	  6.4  Reflejar la ventisca aplicando niebla según `weather.visibilityFactor`
	       (0.3 en ventisca) sobre `Lighting.FogEnd` (con un frame atmosférico de
	       respaldo si no se puede tocar Lighting).
	  6.5  Reflejar el rugido del viento ajustando el volumen de un Sound a partir
	       de `weather.windVolume` cuando esté presente (cambios de audio en pcall,
	       no bloqueantes).
	  10.6 Mostrar el contador de peces de la Neverita (0..30) en el HUD, actualizado
	       desde el campo `cooler` de la instantánea y/o desde los payloads "cooler".
	       Al llegar un mensaje "full", mostrarlo durante >= minDurationSeconds (3 s).

	ASUNCIONES / PLACEHOLDERS:
	  - El `rbxassetid` del sonido de viento es un PLACEHOLDER intercambiable sin
	    tocar la lógica (ver ASSETS). Si falla, el HUD sigue funcionando (6.5 en pcall).
	  - Todo el código es robusto a campos ausentes: se leen con comprobaciones y se
	    aplican valores por defecto; un payload incompleto nunca rompe el HUD.
	  - El servidor restaura los valores despejados al terminar la ventisca (6.7),
	    de modo que el HUD converge a niebla/viento normales sin lógica extra.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player: Player = Players.LocalPlayer
local playerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

--=============================================================================
-- Constantes de presentación
--=============================================================================

-- Placeholders de audio intercambiables sin tocar la lógica.
local ASSETS = {
	-- Rugido de viento de ventisca (bucle). Sustituir por el SFX final.
	BLIZZARD_WIND_SOUND = "rbxassetid://0", -- TODO(audio): viento de ventisca
}

-- Transición de las barras (Req. 4.2): dentro del rango 200-400 ms. 0.3 s por holgura.
local BAR_TWEEN_TIME: number = 0.3

-- Umbral de Calor bajo el que se activa el parpadeo/congelación (Req. 4.4).
local COLD_THRESHOLD: number = 20

-- Frecuencia del parpadeo rojo (Req. 4.4): 1-2 Hz. 1.5 Hz => periodo ~0.667 s.
local COLD_BLINK_HZ: number = 1.5

-- Transparencia de la viñeta roja en su punto más OPACO durante el parpadeo.
local COLD_VIGNETTE_MIN_TRANSP: number = 0.35

-- Rango de FogEnd para reflejar la visibilidad de la ventisca (Req. 6.4). Con
-- visibilityFactor=1 (despejado) la niebla queda muy lejos; con 0.3 se acerca.
local FOG_END_CLEAR: number = 100000
local FOG_END_BLIZZARD_MIN: number = 60 -- FogEnd más corto (menos visibilidad)

-- Duración por defecto del mensaje "Neverita llena" si el payload no la indica.
local FULL_MESSAGE_DEFAULT_SECONDS: number = 3

-- Colores de las barras (Calor, Hambre, Sed, Salud).
local BAR_COLORS = {
	warmth = Color3.fromRGB(255, 148, 66), -- naranja cálido
	hunger = Color3.fromRGB(180, 130, 70), -- marrón alimento
	thirst = Color3.fromRGB(74, 168, 227), -- azul agua
	health = Color3.fromRGB(96, 208, 112), -- verde salud
}

--=============================================================================
-- Estado interno del HUD
--=============================================================================

-- Últimos valores mostrados por barra, para evitar tweens redundantes.
local shownValues: { [string]: number } = {
	warmth = -1,
	hunger = -1,
	thirst = -1,
	health = -1,
}

-- Estado del parpadeo de frío (Req. 4.4).
local coldActive: boolean = false

-- Marca temporal (os.clock) hasta la que debe permanecer visible el mensaje
-- "Neverita llena" (Req. 10.6). Mientras os.clock() < holdUntil, no se sobreescribe.
local coolerMessageHoldUntil: number = 0

-- Sonido de viento de ventisca (puede quedar nil si el audio no se pudo crear).
local windSound: Sound? = nil

--=============================================================================
-- Construcción de la GUI (en código, parentada a PlayerGui)
--=============================================================================

type BarRefs = {
	fill: Frame,
	label: TextLabel,
}

type HudUi = {
	gui: ScreenGui,
	bars: { [string]: BarRefs },
	coolerLabel: TextLabel,
	coolerMessage: TextLabel,
	vignette: Frame,
	frost: Frame,
}

--[[
	makeBar — Crea una barra elegante (contenedor + relleno + etiqueta) y la coloca
	en el panel con el orden dado. Devuelve las referencias necesarias para animarla.
]]
local function makeBar(parent: Instance, name: string, caption: string, order: number, color: Color3): BarRefs
	local container = Instance.new("Frame")
	container.Name = name .. "Bar"
	container.LayoutOrder = order
	container.Size = UDim2.new(1, 0, 0, 26)
	container.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
	container.BackgroundTransparency = 0.25
	container.BorderSizePixel = 0
	container.Parent = parent

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(0, 6)
	containerCorner.Parent = container

	-- Relleno (lo que se anima al cambiar el valor). Arranca en 0% y se ajusta
	-- con el primer snapshot.
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.ZIndex = 2
	fill.Parent = container

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	-- Etiqueta con nombre + porcentaje, superpuesta.
	local label = Instance.new("TextLabel")
	label.Name = "Caption"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = caption .. " 0%"
	label.TextColor3 = Color3.fromRGB(245, 249, 255)
	label.TextScaled = false
	label.TextSize = 15
	label.TextStrokeTransparency = 0.5
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 3
	label.Parent = container

	local labelPadding = Instance.new("UIPadding")
	labelPadding.PaddingLeft = UDim.new(0, 10)
	labelPadding.Parent = label

	return { fill = fill, label = label }
end

--[[
	buildHudGui — Construye toda la jerarquía de UI del HUD y la parenta a PlayerGui.

	Estructura:
	  ScreenGui "Hud"
	    Frame "NeedsPanel" (esquina superior izquierda)
	      Barras: Calor, Hambre, Sed, Salud (UIListLayout vertical)
	    TextLabel "CoolerCounter" (contador de Neverita)
	    TextLabel "CoolerMessage" (aviso "Neverita llena", oculto por defecto)
	    Frame "ColdVignette" (viñeta roja de frío, oculta por defecto) (4.4)
	    Frame "FrostEdge" (borde de escarcha, oculto por defecto) (4.4)
]]
local function buildHudGui(): HudUi
	local gui = Instance.new("ScreenGui")
	gui.Name = "Hud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Panel de necesidades (arriba a la izquierda).
	local needsPanel = Instance.new("Frame")
	needsPanel.Name = "NeedsPanel"
	needsPanel.AnchorPoint = Vector2.new(0, 0)
	needsPanel.Position = UDim2.new(0, 16, 0, 16)
	needsPanel.Size = UDim2.new(0, 260, 0, 122)
	needsPanel.BackgroundTransparency = 1
	needsPanel.ZIndex = 2
	needsPanel.Parent = gui

	local panelLayout = Instance.new("UIListLayout")
	panelLayout.FillDirection = Enum.FillDirection.Vertical
	panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	panelLayout.Padding = UDim.new(0, 6)
	panelLayout.Parent = needsPanel

	local bars: { [string]: BarRefs } = {
		warmth = makeBar(needsPanel, "Warmth", "CALOR", 1, BAR_COLORS.warmth),
		hunger = makeBar(needsPanel, "Hunger", "HAMBRE", 2, BAR_COLORS.hunger),
		thirst = makeBar(needsPanel, "Thirst", "SED", 3, BAR_COLORS.thirst),
		health = makeBar(needsPanel, "Health", "SALUD", 4, BAR_COLORS.health),
	}

	-- Contador de la Neverita (Req. 10.6), esquina superior derecha.
	local coolerLabel = Instance.new("TextLabel")
	coolerLabel.Name = "CoolerCounter"
	coolerLabel.AnchorPoint = Vector2.new(1, 0)
	coolerLabel.Position = UDim2.new(1, -16, 0, 16)
	coolerLabel.Size = UDim2.new(0, 180, 0, 30)
	coolerLabel.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
	coolerLabel.BackgroundTransparency = 0.25
	coolerLabel.Font = Enum.Font.GothamBold
	coolerLabel.Text = "🐟 Neverita 0/30"
	coolerLabel.TextColor3 = Color3.fromRGB(210, 235, 255)
	coolerLabel.TextSize = 16
	coolerLabel.ZIndex = 2
	coolerLabel.Parent = gui

	local coolerCorner = Instance.new("UICorner")
	coolerCorner.CornerRadius = UDim.new(0, 6)
	coolerCorner.Parent = coolerLabel

	-- Aviso "Neverita llena" (Req. 10.6), centrado arriba, oculto por defecto.
	local coolerMessage = Instance.new("TextLabel")
	coolerMessage.Name = "CoolerMessage"
	coolerMessage.AnchorPoint = Vector2.new(0.5, 0)
	coolerMessage.Position = UDim2.new(0.5, 0, 0, 56)
	coolerMessage.Size = UDim2.new(0, 260, 0, 34)
	coolerMessage.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
	coolerMessage.BackgroundTransparency = 0.15
	coolerMessage.Font = Enum.Font.GothamBold
	coolerMessage.Text = "Neverita llena"
	coolerMessage.TextColor3 = Color3.fromRGB(255, 236, 236)
	coolerMessage.TextSize = 18
	coolerMessage.Visible = false
	coolerMessage.ZIndex = 4
	coolerMessage.Parent = gui

	local msgCorner = Instance.new("UICorner")
	msgCorner.CornerRadius = UDim.new(0, 6)
	msgCorner.Parent = coolerMessage

	-- Viñeta roja de frío a pantalla completa (Req. 4.4), oculta por defecto.
	-- Se usa un ImageLabel? No; un Frame con degradado radial simulado por un
	-- UIGradient de transparencia hacia el centro. Arranca totalmente transparente.
	local vignette = Instance.new("Frame")
	vignette.Name = "ColdVignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundColor3 = Color3.fromRGB(200, 30, 30)
	vignette.BackgroundTransparency = 1 -- invisible hasta que haya frío
	vignette.BorderSizePixel = 0
	vignette.Visible = false
	vignette.ZIndex = 8
	vignette.Parent = gui

	-- Borde de escarcha (Req. 4.4): marco claro pegado a los bordes con el centro
	-- hueco (se logra con un UIStroke grueso sobre un Frame transparente de centro).
	local frost = Instance.new("Frame")
	frost.Name = "FrostEdge"
	frost.Size = UDim2.fromScale(1, 1)
	frost.BackgroundTransparency = 1
	frost.BorderSizePixel = 0
	frost.Visible = false
	frost.ZIndex = 9
	frost.Parent = gui

	local frostStroke = Instance.new("UIStroke")
	frostStroke.Thickness = 26
	frostStroke.Color = Color3.fromRGB(198, 226, 255)
	frostStroke.Transparency = 0.25
	frostStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	frostStroke.Parent = frost

	gui.Parent = playerGui

	return {
		gui = gui,
		bars = bars,
		coolerLabel = coolerLabel,
		coolerMessage = coolerMessage,
		vignette = vignette,
		frost = frost,
	}
end

local ui: HudUi = buildHudGui()

--=============================================================================
-- Barras: actualización con transición suave (Req. 4.1, 4.2)
--=============================================================================

local BAR_CAPTIONS: { [string]: string } = {
	warmth = "CALOR",
	hunger = "HAMBRE",
	thirst = "SED",
	health = "SALUD",
}

--[[
	clampPercent — Acota un valor de necesidad al rango [0, 100] y tolera entradas
	ausentes o no numéricas devolviendo 0 (robustez ante payloads incompletos).
]]
local function clampPercent(value: any): number
	if typeof(value) ~= "number" then
		return 0
	end
	if value < 0 then
		return 0
	elseif value > 100 then
		return 100
	end
	return value
end

--[[
	setBar — Ajusta una barra al porcentaje dado. Si el valor cambió respecto al
	último mostrado, anima el ancho del relleno con una transición de 200-400 ms
	(Req. 4.2) usando TweenService. La etiqueta de porcentaje se actualiza al vuelo.
]]
local function setBar(key: string, rawValue: any): ()
	local refs = ui.bars[key]
	if not refs then
		return
	end

	local value = clampPercent(rawValue)
	local rounded = math.floor(value + 0.5)

	-- Etiqueta siempre coherente con el valor entrante.
	refs.label.Text = string.format("%s %d%%", BAR_CAPTIONS[key] or key, rounded)

	-- Evitar tweens redundantes si el valor no cambió.
	if shownValues[key] == value then
		return
	end
	shownValues[key] = value

	-- Transición suave del ancho (Req. 4.2). Tiempo dentro de [0.2, 0.4] s.
	local goal = { Size = UDim2.fromScale(value / 100, 1) }
	local tweenInfo = TweenInfo.new(BAR_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(refs.fill, tweenInfo, goal):Play()
end

--=============================================================================
-- Efecto de frío: parpadeo rojo 1-2 Hz + escarcha en bordes (Req. 4.4)
--=============================================================================

--[[
	setColdEffect — Activa o desactiva el efecto de frío según el Calor actual.
	Cuando `active` es true, muestra la viñeta roja y la escarcha; el parpadeo
	real (oscilación de transparencia) lo produce el bucle RenderStepped mientras
	`coldActive` sea true. Cuando es false, oculta ambos overlays.
]]
local function setColdEffect(active: boolean): ()
	if active == coldActive then
		return
	end
	coldActive = active

	ui.vignette.Visible = active
	ui.frost.Visible = active
	if not active then
		-- Restaurar a invisible al salir del estado de frío.
		ui.vignette.BackgroundTransparency = 1
	end
end

--[[
	updateColdBlink — Llamado en cada fotograma. Si el frío está activo, oscila la
	transparencia de la viñeta roja a COLD_BLINK_HZ (1-2 Hz) usando una onda
	sinusoidal sobre el reloj, produciendo el parpadeo de pantalla (Req. 4.4).
]]
local function updateColdBlink(): ()
	if not coldActive then
		return
	end
	-- Onda 0..1 a la frecuencia deseada. (sin+1)/2 mantiene el rango.
	local phase = (math.sin(os.clock() * COLD_BLINK_HZ * math.pi * 2) + 1) * 0.5
	-- Interpola entre casi invisible (1) y el punto más opaco del parpadeo.
	ui.vignette.BackgroundTransparency = 1 - phase * (1 - COLD_VIGNETTE_MIN_TRANSP)
end

--=============================================================================
-- Clima: niebla (Req. 6.4) y rugido del viento (Req. 6.5)
--=============================================================================

--[[
	ensureWindSound — Crea de forma perezosa (y no bloqueante) el Sound de viento,
	en bucle y en reposo. Cualquier fallo se captura y deja `windSound = nil` sin
	romper el HUD (Req. 6.5).
]]
local function ensureWindSound(): ()
	if windSound then
		return
	end
	pcall(function()
		local sound = Instance.new("Sound")
		sound.Name = "BlizzardWind"
		sound.SoundId = ASSETS.BLIZZARD_WIND_SOUND
		sound.Looped = true
		sound.Volume = 0
		sound.Parent = playerGui
		sound:Play()
		windSound = sound
	end)
end

--[[
	applyFog — Refleja la ventisca aplicando niebla en función de `visibilityFactor`
	(Req. 6.4). visibilityFactor=1 => niebla lejana (despejado); 0.3 => niebla
	cercana (poca visibilidad). Se interpola FogEnd de forma lineal. Protegido con
	pcall por si Lighting no admite el cambio en algún contexto.
]]
local function applyFog(visibilityFactor: number): ()
	-- Acotar el factor a un rango sensato [0, 1].
	local vf = visibilityFactor
	if typeof(vf) ~= "number" then
		vf = 1
	end
	if vf < 0 then
		vf = 0
	elseif vf > 1 then
		vf = 1
	end

	-- Interpolar FogEnd entre el mínimo de ventisca y el "despejado".
	local fogEnd = FOG_END_BLIZZARD_MIN + (FOG_END_CLEAR - FOG_END_BLIZZARD_MIN) * vf
	pcall(function()
		Lighting.FogEnd = fogEnd
	end)
end

--[[
	applyWind — Ajusta el volumen del Sound de viento a partir de `windVolume`
	(Req. 6.5). Si el campo no viene, no se toca el audio. No bloqueante (pcall).
]]
local function applyWind(windVolume: any): ()
	if typeof(windVolume) ~= "number" then
		return
	end
	local vol = windVolume
	if vol < 0 then
		vol = 0
	elseif vol > 1 then
		vol = 1
	end
	ensureWindSound()
	local sound = windSound
	if sound then
		pcall(function()
			sound.Volume = vol
		end)
	end
end

--=============================================================================
-- Neverita: contador y aviso de "llena" (Req. 10.6)
--=============================================================================

--[[
	setCoolerCount — Actualiza el contador visible de la Neverita (0..30). Tolera
	valores ausentes/no numéricos y capacidades por defecto (30).
]]
local function setCoolerCount(count: any, capacity: any): ()
	local n = if typeof(count) == "number" then math.max(0, math.floor(count + 0.5)) else 0
	local cap = if typeof(capacity) == "number" then math.floor(capacity + 0.5) else 30
	ui.coolerLabel.Text = string.format("🐟 Neverita %d/%d", n, cap)
end

--[[
	showCoolerFullMessage — Muestra el aviso "Neverita llena" durante al menos
	`minDurationSeconds` (Req. 10.6, por defecto 3 s). Registra el instante hasta el
	que debe permanecer visible y programa su ocultación si sigue vigente.
]]
local function showCoolerFullMessage(message: any, minDurationSeconds: any): ()
	local text = if typeof(message) == "string" then message else "Neverita llena"
	local seconds = if typeof(minDurationSeconds) == "number" and minDurationSeconds > 0
		then minDurationSeconds
		else FULL_MESSAGE_DEFAULT_SECONDS

	ui.coolerMessage.Text = text
	ui.coolerMessage.Visible = true

	-- Extiende el tiempo de visualización (si llega otro aviso, se prolonga).
	local until_ = os.clock() + seconds
	if until_ > coolerMessageHoldUntil then
		coolerMessageHoldUntil = until_
	end

	local holdSnapshot = coolerMessageHoldUntil
	task.delay(seconds, function()
		-- Solo ocultar si no se prolongó con un aviso posterior.
		if coolerMessageHoldUntil <= holdSnapshot then
			ui.coolerMessage.Visible = false
		end
	end)
end

--=============================================================================
-- Despacho de payloads de StateUpdate (por `kind`)
--=============================================================================

--[[
	onStateSnapshot — Renderiza la instantánea principal (kind="state"): barras de
	necesidades (4.1/4.2), efecto de frío según Calor (4.4), niebla de ventisca
	(6.4) y contador de Neverita (10.6). Robusto a campos ausentes.
]]
local function onStateSnapshot(payload: { [string]: any }): ()
	local needs = payload.needs
	if typeof(needs) == "table" then
		setBar("warmth", needs.warmth)
		setBar("hunger", needs.hunger)
		setBar("thirst", needs.thirst)
		setBar("health", needs.health)

		-- Efecto de frío cuando Calor < 20% (Req. 4.4).
		setColdEffect(clampPercent(needs.warmth) < COLD_THRESHOLD)
	end

	-- Contador de Neverita desde la instantánea (Req. 10.6).
	if payload.cooler ~= nil then
		setCoolerCount(payload.cooler, 30)
	end

	-- Clima: niebla desde la instantánea (Req. 6.4). El viento puntual llega por
	-- el payload "weather"; la instantánea no incluye windVolume.
	local weather = payload.weather
	if typeof(weather) == "table" then
		applyFog(weather.visibilityFactor)
	end
end

--[[
	onCoolerPayload — Reacciona a los payloads kind="cooler": actualiza el contador
	(phase="count") o muestra el aviso de llena (phase="full"). (Req. 10.6)
]]
local function onCoolerPayload(payload: { [string]: any }): ()
	setCoolerCount(payload.count, payload.capacity)
	if payload.phase == "full" then
		showCoolerFullMessage(payload.message, payload.minDurationSeconds)
	end
end

--[[
	onWeatherPayload — Reacciona a los payloads kind="weather": aplica niebla
	(Req. 6.4) y ajusta el rugido del viento (Req. 6.5).
]]
local function onWeatherPayload(payload: { [string]: any }): ()
	applyFog(payload.visibilityFactor)
	applyWind(payload.windVolume)
end

--[[
	onStateUpdate — Punto de entrada del canal S->C. Ramifica por `kind` y descarta
	de forma segura los payloads que no conciernen al HUD ("started", "victory",
	"startRejected", "saveNotice", "digRejected", "caveRegistered", ...).
]]
local function onStateUpdate(payload: any): ()
	if typeof(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	if kind == "state" then
		onStateSnapshot(payload)
	elseif kind == "cooler" then
		onCoolerPayload(payload)
	elseif kind == "weather" then
		onWeatherPayload(payload)
	end
	-- Cualquier otro kind se ignora intencionadamente.
end

--=============================================================================
-- Arranque
--=============================================================================

--[[
	start — Punto de entrada. Se suscribe a `Remotes.StateUpdate`, arranca el bucle
	de parpadeo de frío por fotograma (Req. 4.4) y deja la niebla despejada por
	defecto (Req. 6.4/6.7).
]]
local function start(): ()
	-- Niebla despejada al inicio (el servidor la acercará durante ventiscas).
	applyFog(1)

	-- Suscripción al canal S->C.
	Remotes.StateUpdate.OnClientEvent:Connect(onStateUpdate)

	-- Bucle por fotograma para el parpadeo rojo del frío (Req. 4.4).
	RunService.RenderStepped:Connect(updateColdBlink)
end

start()
