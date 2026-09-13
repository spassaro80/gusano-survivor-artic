--!strict
--[[
	Bootstrap.server.lua — Punto de arranque del SERVIDOR.

	Feature: juego-supervivencia-artico

	Rojo convierte los `*.server.lua` en `Script` (a diferencia de los `*.lua`,
	que son ModuleScripts y no se ejecutan solos). Este Script vive en la raíz de
	ServerScriptService (src/server -> ServerScriptService) y su única labor es
	REQUERIR el orquestador `GameServer`, que se auto-inicializa de forma
	idempotente al cargarse en el servidor.

	Mantener el arranque en un archivo aparte permite que `GameServer.lua` siga
	siendo un ModuleScript reutilizable/testeable, sin acoplar su carga a que sea
	un Script.
]]

require(script.Parent.GameServer)
