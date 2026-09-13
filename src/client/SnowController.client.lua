--!strict
--[[
	SnowController (LocalScript) — Nieve cayendo (ambiente ártico).

	Feature: juego-supervivencia-artico
	Ubicación Rojo: StarterPlayer/StarterPlayerScripts (default.project.json -> src/client).

	Capa: CLIENTE (presentación). Añade un efecto de nieve cayendo alrededor de la
	cámara del Jugador para reforzar el bioma nevado. Es puramente cosmético: no
	decide nada del juego (la autoridad sigue siendo el servidor) y es robusto a la
	ausencia de cámara/personaje (no lanza errores).

	Implementación: un emisor de partículas (`ParticleEmitter`) sobre una parte
	invisible y sin colisión que sigue a la cámara por encima del Jugador, de modo
	que la nieve cae siempre en su entorno visible sin poblar todo el mapa.

	NOTA DE SINCRONIZACIÓN (Rojo): como los demás `*.client.lua`, se ejecuta como
	LocalScript. El arranque va al final.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player: Player = Players.LocalPlayer

-- Altura sobre la cámara a la que se emite la nieve (studs) y tamaño del área.
local EMIT_HEIGHT: number = 40
local AREA_SIZE: number = 90

-- source — Parte invisible portadora del emisor; sigue a la cámara cada frame.
local source: Part? = nil

--[[
	buildSource — Crea (una vez) la parte emisora con un ParticleEmitter de nieve.
	Usa la textura por defecto del emisor (un copo suave blanco), por lo que no
	depende de ningún asset externo. Devuelve la parte creada o nil si falla.
]]
local function buildSource(): Part?
	local created: Part? = nil
	pcall(function()
		local part = Instance.new("Part")
		part.Name = "SnowSource"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.Size = Vector3.new(AREA_SIZE, 1, AREA_SIZE)
		part.CastShadow = false

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Snow"
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		emitter.Transparency = NumberSequence.new(0.1)
		emitter.Size = NumberSequence.new(0.35)
		emitter.Lifetime = NumberRange.new(3.5, 5.5)
		emitter.Rate = 220
		emitter.Speed = NumberRange.new(10, 16)
		emitter.SpreadAngle = Vector2.new(25, 25)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-40, 40)
		emitter.Drag = 3
		emitter.LockedToPart = false
		-- Emite hacia abajo: la cara superior de la parte mira +Y, así que
		-- orientamos la aceleración para que los copos caigan.
		emitter.Acceleration = Vector3.new(0.5, -6, 0)
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.Parent = part

		part.Parent = Workspace
		created = part
	end)
	return created
end

--[[
	onRenderStepped — Reposiciona la parte emisora por encima de la cámara cada
	frame para que la nieve caiga siempre en el entorno visible del Jugador.
]]
local function onRenderStepped(): ()
	local part = source
	if not part or not part.Parent then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local p = camera.CFrame.Position
	part.CFrame = CFrame.new(p.X, p.Y + EMIT_HEIGHT, p.Z)
end

--[[
	start — Punto de entrada. Crea el emisor y arranca el bucle de seguimiento.
]]
local function start(): ()
	source = buildSource()
	RunService.RenderStepped:Connect(onRenderStepped)
end

start()
