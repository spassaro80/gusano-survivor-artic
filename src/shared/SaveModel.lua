--!strict
--[[
	SaveModel.lua — Serialización, deserialización y validación del guardado.

	Feature: juego-supervivencia-artico

	ModuleScript de lógica PURA ubicado en ReplicatedStorage/Shared. Transforma
	datos únicamente: NO accede a `DataStoreService` ni realiza ninguna operación
	de I/O. El `SaveSystem` (capa de servidor) es la única capa con efectos contra
	el DataStore y se apoya en este módulo para toda la transformación de datos.

	Modela el subconjunto persistido del Requisito 16.3:
		{ version, pos={x,y,z}, day, wood, stone, coolerFish, freeMode }

	Funciones (Requisito 16):
	  - serialize(state)   -> string       : JSON del subconjunto persistido.
	  - deserialize(raw)   -> (SaveData?, ok): parsea y valida integridad.
	  - isValid(data)      -> boolean       : validación PURA de campos y rangos.

	------------------------------------------------------------------------------
	Nota sobre pureza y testeabilidad (importante para las pruebas de propiedad):

	`isValid` es COMPLETAMENTE PURA: no requiere ningún servicio del motor y valida
	toda la forma y rangos de los datos. La detección de corrupción (Property 12)
	sobre tablas ya parseadas se puede comprobar de forma aislada mediante `isValid`.

	`serialize`/`deserialize` necesitan codificar/decodificar JSON. Para ello usan
	`HttpService:JSONEncode`/`JSONDecode`, que solo está disponible dentro del motor
	de Roblox. Por eso el `HttpService` se requiere de forma PEREZOSA (lazy) dentro
	de cada función: así, importar este módulo y ejecutar `isValid` no obliga a
	tener el motor disponible. La prueba de round-trip serializar → deserializar
	(Property 11) se ejecuta dentro de Roblox/TestEZ, donde `HttpService` existe.

	Requisitos cubiertos: 16.3, 16.4, 16.7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

type SaveData = Types.SaveData

-- Versión de formato conocida y capacidad de la Neverita (reusadas de Constants).
local FORMAT_VERSION: number = Constants.SAVE.FORMAT_VERSION
local COOLER_CAPACITY: number = Constants.COOLER.CAPACITY

local SaveModel = {}

--[[
	getHttpService — Requiere HttpService de forma perezosa.

	Se aísla en una función para dejar claro que solo `serialize`/`deserialize`
	dependen del motor; `isValid` permanece pura y no invoca esto.
]]
local function getHttpService(): HttpService
	return game:GetService("HttpService")
end

--[[
	isFiniteNumber — Verifica que un valor es un número real finito (no NaN/inf).

	PURA. La aritmética de comparación descarta NaN (NaN ~= NaN) e infinitos.
]]
local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	isInteger — Verifica que un valor es un número entero finito.

	PURA. Usada para los campos que solo admiten enteros (day, wood, stone,
	coolerFish, version).
]]
local function isInteger(value: any): boolean
	return isFiniteNumber(value) and math.floor(value) == value
end

--[[
	isValid — Validación PURA de un SaveData ya parseado.

	Devuelve `true` si y solo si TODOS los campos persistidos están presentes,
	tienen el tipo correcto y caen dentro de rango:
	  - version   : entero == FORMAT_VERSION (versión conocida).
	  - pos        : tabla con x, y, z numéricos finitos.
	  - day        : entero >= 1.
	  - wood       : entero >= 0.
	  - stone      : entero >= 0.
	  - coolerFish : entero en [0, COOLER_CAPACITY] (0..30).
	  - freeMode   : booleano.

	No requiere el motor de Roblox: es testeable en aislamiento. (Req. 16.7)
]]
function SaveModel.isValid(data: any): boolean
	if type(data) ~= "table" then
		return false
	end

	-- Versión conocida (habilita detección de formatos incompatibles).
	if not isInteger(data.version) or data.version ~= FORMAT_VERSION then
		return false
	end

	-- Posición: tabla con x, y, z numéricos finitos.
	local pos = data.pos
	if type(pos) ~= "table" then
		return false
	end
	if not isFiniteNumber(pos.x) or not isFiniteNumber(pos.y) or not isFiniteNumber(pos.z) then
		return false
	end

	-- Día: entero >= 1.
	if not isInteger(data.day) or data.day < 1 then
		return false
	end

	-- Madera: entero >= 0.
	if not isInteger(data.wood) or data.wood < 0 then
		return false
	end

	-- Piedra: entero >= 0.
	if not isInteger(data.stone) or data.stone < 0 then
		return false
	end

	-- Peces de la Neverita: entero en [0, CAPACITY].
	if not isInteger(data.coolerFish) or data.coolerFish < 0 or data.coolerFish > COOLER_CAPACITY then
		return false
	end

	-- Modo libre: booleano.
	if type(data.freeMode) ~= "boolean" then
		return false
	end

	return true
end

--[[
	serialize — Convierte un SaveData en su cadena JSON persistida.

	Emite EXACTAMENTE el subconjunto persistido (version, pos, day, wood, stone,
	coolerFish, freeMode), normalizando `pos` a { x, y, z } para no arrastrar
	campos ajenos. Requiere HttpService (lazy). (Req. 16.3, 16.4)
]]
function SaveModel.serialize(state: SaveData): string
	local persisted = {
		version = state.version,
		pos = { x = state.pos.x, y = state.pos.y, z = state.pos.z },
		day = state.day,
		wood = state.wood,
		stone = state.stone,
		coolerFish = state.coolerFish,
		freeMode = state.freeMode,
	}
	return getHttpService():JSONEncode(persisted)
end

--[[
	deserialize — Parsea y valida una cadena JSON de guardado.

	Devuelve `(data, true)` cuando el JSON es válido y `isValid(data)` es `true`.
	Devuelve `(nil, false)` ante:
	  - `raw` que no sea una cadena.
	  - JSON mal formado (fallo de parseo).
	  - campos faltantes, de tipo incorrecto, versión desconocida o fuera de rango
	    (p. ej. coolerFish > 30, wood/stone negativos).

	La normalización a un SaveData "limpio" se realiza solo tras validar, para no
	devolver nunca un objeto parcialmente válido. (Req. 16.4, 16.7)
]]
function SaveModel.deserialize(raw: any): (SaveData?, boolean)
	if type(raw) ~= "string" then
		return nil, false
	end

	local ok, decoded = pcall(function()
		return getHttpService():JSONDecode(raw)
	end)

	if not ok or not SaveModel.isValid(decoded) then
		return nil, false
	end

	-- Reconstruir un SaveData limpio con solo los campos persistidos.
	local data: SaveData = {
		version = decoded.version,
		pos = { x = decoded.pos.x, y = decoded.pos.y, z = decoded.pos.z },
		day = decoded.day,
		wood = decoded.wood,
		stone = decoded.stone,
		coolerFish = decoded.coolerFish,
		freeMode = decoded.freeMode,
	}

	return data, true
end

return SaveModel
