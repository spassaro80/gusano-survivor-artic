# Diseño técnico — 7 Días en el Ártico

> Este documento resume la arquitectura de implementación del proyecto. El
> documento de diseño formal de la especificación (con propiedades de correctitud
> y estrategia de pruebas detalladas) vive en
> `.kiro/specs/juego-supervivencia-artico/design.md`.

## Motor y lenguaje

- **Motor:** Roblox.
- **Lenguaje:** Luau (`--!strict` en todos los módulos).
- **Sincronización con Studio:** [Rojo](https://rojo.space) mapea la carpeta
  `src/` (y `tests/`) al árbol de Roblox mediante `default.project.json`.

## Principio arquitectónico: servidor autoritativo

El **servidor posee el estado real** de la partida y valida toda acción del
cliente (herramienta equipada, distancia, precondiciones, recursos) antes de
aplicar cualquier cambio. El **cliente solo envía intenciones** (por RemoteEvents)
y **renderiza** el estado que el servidor confirma. Esto evita trampas y mantiene
coherente el estado que se persiste.

## Tres capas

1. **Lógica pura** (`ReplicatedStorage/Shared`, en `src/shared/`): módulos sin
   dependencias del motor que modelan las reglas del juego. Reciben estado y
   devuelven estado nuevo, sin efectos secundarios. Es la capa verificable con
   *property-based testing*.
2. **Servidor autoritativo** (`ServerScriptService`, en `src/server/`): posee el
   `PlayerState`, aplica la lógica pura, resuelve físicas y valida intenciones.
3. **Cliente / presentación** (`StarterPlayer/StarterPlayerScripts`, en
   `src/client/`): cámara en primera persona, HUD, menús e input.

## Mapa del árbol de Roblox (default.project.json)

```
ReplicatedStorage/
  Shared/            <- src/shared      (lógica pura + Types + Constants)
  Remotes/           <- src/remotes     (contrato cliente-servidor, init.lua)
  Tests/             <- tests           (specs TestEZ + support/PropCheck)
ServerScriptService/ <- src/server      (GameServer + Systems/)
StarterPlayer/
  StarterPlayerScripts/ <- src/client   (controladores del cliente)
Workspace/           (FilteringEnabled = true)
SoundService/        (RespectFilteringEnabled = true)
```

## Módulos de lógica pura (`src/shared/`)

| Módulo | Responsabilidad |
|--------|-----------------|
| `Types.lua` | Definiciones de tipos Luau compartidos. |
| `Constants.lua` | Constantes de balance (tasas, capacidades, tiempos), congeladas. |
| `NeedsModel.lua` | Consumo de Calor/Hambre/Sed, caída de Salud, beber/comer, muerte. |
| `CoolerModel.lua` | Neverita: capacidad 30, add/remove, lleno/vacío. |
| `BottleModel.lua` | Botella: estados Full/Empty, beber (+40 Sed), rellenar. |
| `CookingModel.lua` | Máquina de estados del pescado: Crudo→Cocinado (10 s)→Quemado (18 s). |
| `WeatherModel.lua` | Temporizador de clima (600 s) y ciclo de ventisca (60 s). |
| `WorldGenModel.lua` | Generación determinista y validación del mundo (40 rocas, 60 árboles). |
| `SaveModel.lua` | Serialización/deserialización y validación de integridad del guardado. |

## Contrato de Remotes (`src/remotes/init.lua`)

Módulo idempotente que crea (servidor) y localiza (cliente) los Remotes:

- **RemoteEvents C→S:** `StartSurvival`, `HarvestAction`, `DigAction`,
  `FishingAction`, `ConsumeAction`, `FireAction`, `BedAction`, `RescueChoice`.
- **RemoteEvent S→C:** `StateUpdate` (replica estado al HUD; los payloads llevan
  un campo `kind`).
- **RemoteFunction C→S:** `GetSaveState`.

## Sistemas de servidor (`src/server/Systems/`)

Cada sistema envuelve la lógica pura correspondiente, valida las intenciones y
expone dependencias inyectables (para desacoplar y testear). No arrancan su propio
bucle: el orquestador los conduce con un `dt` común.

| Sistema | Función |
|---------|---------|
| `WorldSystem` | Genera/valida y construye el mundo; respawn de árboles/rocas; agujeros de agua; clima compartido. |
| `HarvestSystem` | Talado y minería con físicas; conversión a madera/piedra; inventario lleno. |
| `DiggingSystem` | Excavación de nieve; detección geométrica de cueva 2×2×2; protección en cueva. |
| `FishingSystem` | Romper hielo; ciclo de pesca (5 s + "¡Sacar Pez!" + timeout 10 s). |
| `CoolerSystem` | Neverita autoritativa por jugador; avisos de lleno; contador HUD. |
| `BottleSystem` | Beber/rellenar; prompt de rellenado por distancia. |
| `FireSystem` | Hoguera de emergencia (45 s) y base; cocinado de peces por `dt`. |
| `NeedsSystem` | Aplica `NeedsModel.step` por tick; dispara muerte al llegar a 0 de Salud. |
| `WeatherSystem` | Conduce `WeatherModel`; difunde niebla/viento; compone `Env` para necesidades. |
| `BedSystem` | Colocación de cama; punto de reaparición; dormir de noche. |
| `RescueSystem` | Escena del Día 7; panel de opciones; victoria o modo libre. |
| `SaveSystem` | Única capa de I/O con DataStore (en `pcall`); guardado cada 120 s y al salir. |

## Orquestador (`src/server/GameServer.lua`)

Hub de integración del servidor. **Posee el `PlayerState`** (única fuente de
verdad), cablea todos los sistemas inyectándoles los accesores al estado, crea el
kit inicial de 7 herramientas, gestiona el ciclo de vida del jugador
(entrada/salida, carga del guardado, reaparición) y ejecuta el **único bucle
`RunService.Heartbeat`** que aporta `dt` a NeedsSystem, WeatherSystem, FireSystem,
RescueSystem y SaveSystem. Replica el estado al HUD por `StateUpdate`. Se
auto-inicializa de forma idempotente en el servidor.

## Controladores de cliente (`src/client/`)

| Controlador | Función |
|-------------|---------|
| `MenuController` | Menú principal, viento en bucle, botón SOBREVIVIR, hand-off al tutorial. |
| `TutorialController` | Tarjeta de instrucciones, pausa, botón ENTENDIDO. |
| `CameraController` | Primera persona bloqueada; brazos y herramienta visibles cada fotograma. |
| `HudController` | Barras Calor/Hambre/Sed/Salud con tweens; parpadeo/escarcha por frío; niebla/viento de ventisca; contador de neverita. |
| `InputRouter` | Traduce clics/teclas a intenciones y las envía por los RemoteEvents; nunca decide resultados. |

## Modelos de datos clave

- **PlayerState** (servidor): `needs`, `inventory` (herramientas + madera/piedra),
  `cooler`, `bottle`, `day`, `freeMode`, punto de reaparición.
- **SaveData** (persistido): `version`, `pos {x,y,z}`, `day`, `wood`, `stone`,
  `coolerFish`, `freeMode`.

## Pruebas

- **Property-based testing** sobre la capa pura con **TestEZ** + un ayudante
  ligero de generación (`tests/support/PropCheck.lua`), mínimo 100 iteraciones por
  propiedad. Cada test se etiqueta con
  `Feature: juego-supervivencia-artico, Property {n}: {texto}`.
- **Tests de ejemplo** (Constants, BottleModel) para valores concretos.
- **Integración / playtest** (en Studio): físicas de talado/pesca/hogueras, UI,
  y persistencia real con `DataStoreService`.

> Nota sobre determinismo: como la aritmética temporal vive en módulos puros que
> reciben `dt` y una semilla de RNG inyectable, las pruebas son 100% reproducibles
> sin depender del reloj real ni de servicios del motor.

## Ejecutar las pruebas

Requiere un entorno con runtime de Luau/Roblox:

- **Roblox Studio**: sincronizar con Rojo y usar un runner de TestEZ dentro de
  Studio.
- **Lune / run-in-roblox** (CI/local): ejecutar TestEZ sobre `tests/`.

Las pruebas **no** pueden ejecutarse en un entorno sin acceso a Roblox/Lune.

## Notas operativas

- `DataStoreService` (guardado) solo funciona en el juego **publicado** o en
  Studio con **"Enable Studio Access to API Services"** activado.
- Arte (imágenes) y audio (sonidos) son **placeholders** (`rbxassetid://0`)
  intercambiables sin tocar la lógica.
- Los archivos bajo `src/client/*` son controladores pensados como **LocalScripts**;
  si Rojo los trata como ModuleScripts, renombrar a `*.client.lua` o requerirlos
  desde un bootstrapper de cliente (ver notas en cada archivo).
