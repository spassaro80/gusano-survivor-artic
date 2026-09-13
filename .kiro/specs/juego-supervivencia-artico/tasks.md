# Implementation Plan: 7 Días en el Ártico

## Overview

Este plan convierte el diseño en una serie de pasos de codificación incrementales para un juego de supervivencia sobre **Roblox / Luau**, estructurado para sincronizarse con **Rojo** hacia Roblox Studio. Cada paso construye sobre el anterior y termina integrándose con el resto, sin dejar código huérfano.

El orden respeta la arquitectura de tres capas del diseño:

1. **Andamiaje Rojo + herramientas** (para poder sincronizar y ejecutar pruebas).
2. **Capa de lógica pura** (`ReplicatedStorage/Shared`) con sus pruebas basadas en propiedades — una prueba por cada una de las 12 propiedades de correctitud del diseño, mínimo 100 iteraciones.
3. **Definiciones de Remotes** (contrato cliente-servidor).
4. **Sistemas de servidor autoritativos** que consumen la lógica pura.
5. **Orquestador del ciclo de partida** y **guardado con DataStore**.
6. **Controladores de cliente** (cámara, HUD, menú, tutorial, input).

Todas las tareas son ediciones de archivos en este repositorio (scripts `.lua`/`.luau` en disco). Los pasos que solo pueden hacerse dentro de Roblox Studio (playtest visual, físicas percibidas, DataStore real) se recogen como **notas**, no como tareas.

Cada prueba de propiedad se etiqueta con el comentario:
`Feature: juego-supervivencia-artico, Property {n}: {texto}`

## Tasks

- [x] 1. Preparar el andamiaje de Rojo y las herramientas del proyecto
  - Crear `default.project.json` que mapee el árbol de Roblox: `ReplicatedStorage/Shared` → `src/shared`, `ReplicatedStorage/Remotes` → `src/shared/Remotes` (o carpeta dedicada), `ServerScriptService` → `src/server`, `StarterPlayer/StarterPlayerScripts` → `src/client`, y una carpeta de pruebas cargable
  - Crear el layout de carpetas en disco: `src/shared`, `src/server`, `src/server/Systems`, `src/client`, `tests`
  - Añadir configuración de toolchain con Rokit/Aftman (`rokit.toml` o `aftman.toml`) declarando `rojo`, `wally` y un runner de pruebas (`lune` o `run-in-roblox`)
  - Añadir `wally.toml` con la dependencia de desarrollo `TestEZ` y el `[dev-dependencies]` correspondiente
  - Añadir `.gitignore` de artefactos de build (`*.rbxlx`, `*.rbxl`, `Packages/`, `DevPackages/`)
  - Documentar en `README.md` el flujo: instalar toolchain, `wally install`, `rojo serve`, y cómo abrir/sincronizar en Studio en otro PC
  - _Requisitos: soporte de infraestructura para todos los requisitos (base de sincronización y pruebas)_

- [x] 2. Definir tipos y constantes de balance (fundamento de la lógica pura)
  - [x] 2.1 Crear `src/shared/Types.lua` con `--!strict`
    - Definir los tipos `Needs`, `Env`, `Cooler`, `Bottle`, `FishState`, `CookingFish`, `Weather`, `Placement`, `Region`, `World`, `SaveData`, `Inventory`, `PlayerState`
    - _Requisitos: 3.3, 4.1, 10.2, 13.8, 16.3_
  - [x] 2.2 Crear `src/shared/Constants.lua` con los valores de balance del diseño
    - Consumo Hambre/Sed (1%/s), multiplicador Calor ×2, caída de Salud (5%/s), golpes para talar/minar (5), madera por tronco (3), respawn (60 s), capacidad Neverita (30), +40 al beber, hoguera emergencia (45 s, +10/s, radio 5 m), piedra/madera hoguera base (5/3), tope madera (20), peces simultáneos (5), cocinado (10 s / +8 s), +40 al comer, −15 pez quemado, cambio de clima (600 s), ventisca (60 s), guardado (120 s), día de rescate (7)
    - _Requisitos: 4.3, 4.5, 4.6, 4.7, 6.1, 6.3, 7.1, 7.3, 7.6, 7.7, 10.2, 11.1, 12.5, 12.6, 13.1, 13.3, 13.6, 13.7, 13.8, 13.9, 13.10, 13.11, 15.1, 16.1_
  - [x]* 2.3 Escribir pruebas unitarias de las constantes de balance
    - Verificar los valores exactos declarados en `Constants.lua`
    - _Requisitos: 7.1, 7.3, 11.1, 13.9_

- [x] 3. Crear el ayudante de generación aleatoria para property-based testing
  - [x] 3.1 Implementar `tests/support/PropCheck.lua`
    - Función `forAll(generator, predicate, iterations)` con mínimo 100 iteraciones por defecto
    - Generadores deterministas sembrados; registrar y reportar la semilla del contraejemplo al fallar
    - Generadores base: `genNumber(min,max)`, `genInt`, `genBool`, y helper para secuencias de operaciones
    - _Requisitos: soporte de pruebas para las Propiedades 1–12_

- [x] 4. Implementar NeedsModel (necesidades vitales)
  - [x] 4.1 Implementar `src/shared/NeedsModel.lua` (funciones puras)
    - `step(needs, env, dt)`: consumo de Hambre/Sed 1%/s, doble consumo de Calor bajo nieve/ventisca, caída de Salud 5%/s cuando una necesidad está a 0, clamp [0,100]
    - `applyDrink`, `applyEat` (clamp a 100), `applyBurnedFish` (clamp a ≥0), `isDead`
    - _Requisitos: 4.1, 4.3, 4.5, 4.6, 4.7, 4.8, 6.6, 11.1, 11.2, 13.9, 13.11_
  - [x]* 4.2 Prueba de propiedad: rango acotado de necesidades
    - **Property 1: Las necesidades permanecen acotadas en [0, 100]**
    - **Validates: Requirements 4.1**
  - [x]* 4.3 Prueba de propiedad: doble consumo de Calor
    - **Property 2: El Calor se consume al doble bajo nieve o ventisca**
    - **Validates: Requirements 4.3, 6.6**
  - [x]* 4.4 Prueba de propiedad: disminución proporcional de Hambre y Sed
    - **Property 3: Hambre y Sed disminuyen de forma proporcional al tiempo**
    - **Validates: Requirements 4.5, 4.6**
  - [x]* 4.5 Prueba de propiedad: decaimiento de Salud con necesidad agotada
    - **Property 4: La Salud decae mientras una necesidad está agotada**
    - **Validates: Requirements 4.7**
  - [x]* 4.6 Prueba de propiedad: restauración aditiva sin desbordar 100
    - **Property 5: La restauración aditiva de necesidades nunca desborda 100**
    - **Validates: Requirements 11.1, 11.2, 13.9**
  - [x]* 4.7 Prueba de propiedad: penalización de pez quemado sin bajar de 0
    - **Property 6: La penalización por pez quemado nunca baja de 0**
    - **Validates: Requirements 13.11**

- [x] 5. Implementar CoolerModel (neverita) y BottleModel (botella)
  - [x] 5.1 Implementar `src/shared/CoolerModel.lua` (funciones puras)
    - `add` (ok=false si count=30), `remove` (ok=false si count=0), `isFull`; contador siempre en [0,30]
    - _Requisitos: 10.1, 10.2, 10.3, 10.4, 10.5_
  - [x]* 5.2 Prueba de propiedad: capacidad e indicadores de la neverita
    - **Property 7: La Neverita respeta su capacidad y señala lleno/vacío correctamente**
    - **Validates: Requirements 10.2, 10.3, 10.4**
  - [x] 5.3 Implementar `src/shared/BottleModel.lua` (funciones puras)
    - `drink(bottle, needs)`: si Full → +40 Sed (clamp 100) y pasa a Empty, ok=true; si Empty → sin cambios, ok=false. `refill` → Full
    - _Requisitos: 11.1, 11.2, 11.3, 11.4, 11.7_
  - [x]* 5.4 Prueba unitaria de transiciones de la botella
    - Ciclo Llena → beber → Vacía → rellenar → Llena y su efecto en la Sed
    - _Requisitos: 11.3, 11.4, 11.7_

- [x] 6. Implementar CookingModel (máquina de estados de cocinado)
  - [x] 6.1 Implementar `src/shared/CookingModel.lua` (funciones puras)
    - `step(fish, dt)`: Raw→Cooked a los 10 s, Cooked→Burned a los +8 s (18 s totales); `hungerRestored` (40 si Cooked), `healthPenalty` (15 si Burned)
    - _Requisitos: 13.8, 13.9, 13.10, 13.11_
  - [x]* 6.2 Prueba de propiedad: transiciones ordenadas y confluencia temporal
    - **Property 8: La máquina de estados de cocinado transita en orden y es confluente en el tiempo**
    - **Validates: Requirements 13.8, 13.10**

- [x] 7. Implementar WeatherModel (clima y ventiscas)
  - [x] 7.1 Implementar `src/shared/WeatherModel.lua` (funciones puras)
    - `step(weather, dt, rng)`: al llegar el temporizador a 0 activa ventisca, reinicia timer a 600 y fija `blizzardRemaining=60`; desactiva ventisca cuando `blizzardRemaining` llega a 0; `visibilityFactor` (0.3 en ventisca, 1.0 si no)
    - _Requisitos: 6.1, 6.2, 6.3, 6.4, 6.7_
  - [x]* 7.2 Prueba de propiedad: reinicio del temporizador y duración de ventisca
    - **Property 9: El temporizador de clima se reinicia a 600 y la ventisca dura 60 s**
    - **Validates: Requirements 6.1, 6.2, 6.3**

- [x] 8. Implementar WorldGenModel (generación y validación del mundo)
  - [x] 8.1 Implementar `src/shared/WorldGenModel.lua` (funciones puras)
    - `generate(seed)`: mapa 500x500, banda perimetral ≥20, 3–8 lagos en celdas bajas, 40 piedras y 60 árboles con separación mínima 2 y sin solape; `validate(world)` que comprueba todas las restricciones y devuelve `(ok, reason)`
    - _Requisitos: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_
  - [x]* 8.2 Prueba de propiedad: restricciones de distribución del mundo
    - **Property 10: La generación del mundo cumple las restricciones de distribución**
    - **Validates: Requirements 5.2, 5.3, 5.4, 5.5**

- [x] 9. Implementar SaveModel (serialización del guardado)
  - [x] 9.1 Implementar `src/shared/SaveModel.lua` (funciones puras)
    - `serialize(state)` → JSON del subconjunto persistido (pos, day, wood, stone, coolerFish, freeMode, version); `deserialize(raw)` → `(SaveData?, ok)` validando integridad; `isValid(data)` (campos presentes, rangos, `coolerFish` ≤ 30, version conocida)
    - _Requisitos: 16.3, 16.4, 16.7_
  - [x]* 9.2 Prueba de propiedad: round-trip de serialización
    - **Property 11: El guardado preserva los datos en un ciclo serializar → deserializar**
    - **Validates: Requirements 16.3, 16.4**
  - [x]* 9.3 Prueba de propiedad: detección de guardados corruptos/incompletos
    - **Property 12: Los guardados corruptos o incompletos se detectan**
    - **Validates: Requirements 16.7**

- [ ] 10. Checkpoint — Verificar la capa de lógica pura
  - Ejecutar toda la suite de TestEZ (unitarias + 12 propiedades). Asegurarse de que todas las pruebas pasan; preguntar al usuario si surgen dudas.

- [x] 11. Definir el contrato de Remotes cliente-servidor
  - [x] 11.1 Crear el script/carpeta de Remotes en `src/shared/Remotes`
    - Declarar los RemoteEvents: `StartSurvival`, `HarvestAction`, `DigAction`, `FishingAction`, `ConsumeAction`, `FireAction`, `BedAction`, `RescueChoice`, `StateUpdate`; y la RemoteFunction `GetSaveState`
    - Garantizar creación idempotente al arrancar el servidor
    - _Requisitos: 2.4, 7.1, 8.1, 9.2, 11.1, 12.3, 14.3, 15.3, 16.4_

- [x] 12. Implementar los sistemas de servidor de recolección e interacción con el mundo
  - [x] 12.1 Implementar `src/server/Systems/WorldSystem.lua`
    - Consumir `WorldGenModel.generate`/`validate` con hasta 3 reintentos; construir el mundo en `Workspace`; respawn de árboles/rocas a los 60 s; impedir inicio si la validación falla tras 3 reintentos
    - _Requisitos: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 7.6, 7.7_
  - [x] 12.2 Implementar `src/server/Systems/HarvestSystem.lua`
    - Validar herramienta (Hacha para árbol, Pico para roca); 5 golpes para desanclar tronco / desmoronar roca; acción "Cortar Leña" (3 maderas), minar fragmentos (1 piedra c/u); rechazar herramienta incorrecta; dejar recurso en suelo si inventario lleno
    - _Requisitos: 7.1, 7.2, 7.3, 7.4, 7.5, 7.8, 7.9_
  - [ ]* 12.3 Pruebas unitarias de los guardianes de validación de recolección
    - Herramienta incorrecta no incrementa golpes (7.8); inventario lleno deja el recurso en el suelo (7.9)
    - _Requisitos: 7.8, 7.9_
  - [x] 12.4 Implementar `src/server/Systems/DiggingSystem.lua`
    - Retirar cubo de nieve (≤3 m, clic, ≤500 ms); registrar cueva al retirar ≥8 cubos formando hueco 2x2x2; anular daño de frío/viento dentro de cueva; rechazar roca/hielo y nieve insuficiente
    - _Requisitos: 8.1, 8.2, 8.3, 8.4, 8.5_
  - [x] 12.5 Implementar `src/server/Systems/FishingSystem.lua`
    - Romper hielo con Pico → Agujero_Agua (≤1 s); lanzar caña sobre agua → espera 5 s; mostrar "¡Sacar Pez!"; sacar pez → 1 Pez en suelo; timeout de 10 s; rechazar clic fuera de agua
    - _Requisitos: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6_
  - [ ]* 12.6 Pruebas unitarias de rechazos de excavación y pesca
    - Excavar sobre roca/hielo o sin nieve (8.4, 8.5); lanzar caña fuera de agua (9.6)
    - _Requisitos: 8.4, 8.5, 9.6_

- [x] 13. Implementar los sistemas de servidor de consumo, neverita y fuego
  - [x] 13.1 Implementar `src/server/Systems/CoolerSystem.lua`
    - Usar `CoolerModel` para almacenar/retirar peces (máx 30); rechazar recogida con neverita llena (mensaje ≥3 s); exponer contador 0–30
    - _Requisitos: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6_
  - [x] 13.2 Implementar `src/server/Systems/BottleSystem.lua`
    - Usar `BottleModel` para beber (+40 Sed, pasa a Vacía) y rellenar junto a Agujero_Agua (≤2 m); mostrar/ocultar acción "Rellenar Botella"; señal de botella vacía
    - _Requisitos: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7_
  - [x] 13.3 Implementar `src/server/Systems/FireSystem.lua`
    - Soltar madera → tronco (−1 madera); encender con Mechero (≤3 m) → Hoguera_Emergencia (+10 Calor/s radio 5 m, dura 45 s); Hoguera_Base (5 piedra + 3 madera, encender con Mechero, tope 20 madera); cocinado con `CookingModel` (máx 5 peces); consumir cocinado (+40 Hambre) / quemado (−15 Salud); rechazos correspondientes
    - _Requisitos: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 13.1, 13.2, 13.3, 13.4, 13.5, 13.6, 13.7, 13.8, 13.9, 13.10, 13.11_
  - [ ]* 13.4 Pruebas unitarias de rechazos de consumo y fuego
    - Neverita llena (10.4), botella vacía (11.4), soltar madera sin madera (12.2), encender sin mechero/lejos (12.4), hoguera base con <5 piedra (13.2), encender base sin mechero (13.5)
    - _Requisitos: 10.4, 11.4, 12.2, 12.4, 13.2, 13.5_

- [x] 14. Implementar los sistemas de servidor de necesidades, clima, cama y rescate
  - [x] 14.1 Implementar `src/server/Systems/NeedsSystem.lua`
    - Aplicar `NeedsModel.step` por tick con el entorno del jugador (nieve, ventisca, cerca de fuego); disparar muerte cuando Salud llega a 0 (≤1 s)
    - _Requisitos: 4.3, 4.5, 4.6, 4.7, 4.8, 6.6_
  - [x] 14.2 Implementar `src/server/Systems/WeatherSystem.lua`
    - Ejecutar `WeatherModel.step`; aplicar efectos (niebla al 30%, sonido de viento ≥80%, doble consumo de Calor a la intemperie) y restaurarlos al desactivar
    - _Requisitos: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7_
  - [x] 14.3 Implementar `src/server/Systems/BedSystem.lua`
    - Colocar cama en base/cueva (rechazar ubicación no válida); fijar punto de reaparición; reaparecer ≤2 m de la cama o en punto por defecto; dormir de noche (avance al amanecer), rechazar de día
    - _Requisitos: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6, 14.7_
  - [x] 14.4 Implementar `src/server/Systems/RescueSystem.lua`
    - En Día 7: sonido de aspas y aterrizaje del helicóptero; pantalla "Escapar"/"Seguir Sobreviviendo" al acercarse (≤5 m); victoria y vuelta al menú, o despegue y Modo_Libre (incremento indefinido de días); ocultar opciones al alejarse
    - _Requisitos: 15.1, 15.2, 15.3, 15.4, 15.5, 15.6, 15.7_
  - [ ]* 14.5 Pruebas unitarias de rechazos de cama y transiciones de rescate
    - Colocar cama fuera de base/cueva (14.2), dormir de día (14.7), elección de modo libre incrementa días (15.6)
    - _Requisitos: 14.2, 14.7, 15.6_

- [x] 15. Implementar el guardado con DataStore
  - [x] 15.1 Implementar `src/server/Systems/SaveSystem.lua`
    - Única capa de I/O contra `DataStoreService` dentro de `pcall`; guardado cada 120 s y al salir usando `SaveModel.serialize`; al entrar, leer y pasar por `SaveModel.deserialize`: sin partida → Día 1, corrupta → aviso + Día 1, fallo de escritura → conservar guardado previo + aviso
    - _Requisitos: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6, 16.7_
  - [ ]* 15.2 Pruebas unitarias de las ramas del SaveSystem
    - Sin partida guardada (Día 1), guardado corrupto (Día 1), fallo de escritura (conservación del guardado anterior)
    - _Requisitos: 16.5, 16.6, 16.7_

- [x] 16. Implementar el orquestador del ciclo de partida
  - [x] 16.1 Implementar `src/server/GameServer.lua`
    - Al entrar el jugador: consultar `SaveSystem` (`GetSaveState`), crear kit inicial de 7 herramientas con Botella al 100% (impedir inicio si el kit es incompleto), iniciar el mundo vía `WorldSystem`
    - Manejar `StartSurvival` (comenzar partida activa tras el tutorial) e iniciar el consumo de necesidades
    - Bucle `Heartbeat`/`RunService`: aportar `dt` a NeedsSystem, WeatherSystem, FireSystem (cocinado), respawn de recursos y disparar el guardado automático
    - Enrutar cada RemoteEvent al sistema correspondiente con validación autoritativa; replicar estado con `StateUpdate`
    - _Requisitos: 2.6, 2.8, 3.3, 3.4, 3.5, 4.1, 5.1_
  - [ ]* 16.2 Pruebas unitarias de creación del kit inicial
    - Kit incompleto impide iniciar la partida (3.5); Botella llena al 100% (3.4)
    - _Requisitos: 3.4, 3.5_

- [ ] 17. Checkpoint — Verificar la capa de servidor
  - Ejecutar toda la suite de pruebas (lógica pura + unitarias de servidor). Asegurarse de que todas pasan; preguntar al usuario si surgen dudas.

- [x] 18. Implementar los controladores de cliente (presentación e input)
  - [x] 18.1 Implementar `src/client/MenuController.lua`
    - Escena de bosque nevado + título (≤3 s), viento en bucle (fallo de audio no bloqueante), botón "SOBREVIVIR" que dispara `StartSurvival`
    - _Requisitos: 1.1, 1.2, 1.3, 1.4, 1.5_
  - [x] 18.2 Implementar `src/client/TutorialController.lua`
    - Atenuar pantalla ≤50% y mostrar tarjeta (≤500 ms) con las 3 necesidades, indicaciones y objetivo; botón "ENTENDIDO"; mantener pausa; al cerrar restaurar opacidad e iniciar partida activa
    - _Requisitos: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8_
  - [x] 18.3 Implementar `src/client/CameraController.lua`
    - Vista en primera persona (≤1 s) con brazos y herramienta equipada visibles en cada fotograma
    - _Requisitos: 3.1, 3.2_
  - [x] 18.4 Implementar `src/client/HudController.lua`
    - Tres barras 0–100% con transición 200–400 ms al cambiar; parpadeo rojo 1–2 Hz y efecto de congelación con Calor <20%; renderizar el estado recibido por `StateUpdate` (incluye niebla/sonido de ventisca y contador de neverita)
    - _Requisitos: 4.1, 4.2, 4.4, 6.4, 6.5, 10.6_
  - [x] 18.5 Implementar `src/client/InputRouter.lua`
    - Traducir clics/teclas a intenciones y enviarlas por los RemoteEvents (`HarvestAction`, `DigAction`, `FishingAction`, `ConsumeAction`, `FireAction`, `BedAction`, `RescueChoice`); no decidir resultados en cliente
    - _Requisitos: 7.1, 8.1, 9.2, 11.1, 12.3, 14.3, 15.3_

- [ ] 19. Checkpoint final — Verificar la integración completa
  - Ejecutar toda la suite de pruebas y confirmar el arranque del servidor (Remotes creados, mundo generado, bucle activo). Asegurarse de que todas las pruebas pasan; preguntar al usuario si surgen dudas.

## Notes

- Las tareas marcadas con `*` son opcionales (pruebas) y pueden omitirse para un MVP más rápido; las de implementación nunca lo son.
- Cada tarea referencia requisitos concretos para trazabilidad, y las pruebas de propiedad referencian su Propiedad del diseño.
- La capa de lógica pura (`src/shared`) se implementa y prueba **antes** que los sistemas de servidor que la usan; el cliente/presentación va al final.
- Las 12 propiedades de correctitud se implementan como pruebas de propiedad con TestEZ + el ayudante `PropCheck`, mínimo 100 iteraciones, etiquetadas `Feature: juego-supervivencia-artico, Property {n}: {texto}`.
- **Pasos solo de Studio (no son tareas de código, se realizan manualmente tras sincronizar con Rojo):** validación visual de físicas (caída de troncos, fragmentación de rocas, radio de calor), percepción de niebla/sonido de ventisca, y pruebas de guardado real contra `DataStoreService` de Studio. Requieren `game.ScriptContext`/DataStore habilitados en Studio.
- El proyecto se sincroniza con `rojo serve` en el PC con Studio; TestEZ se ejecuta con `lune`/`run-in-roblox` en local o dentro de Studio.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["2.1", "2.2", "3.1"] },
    { "id": 2, "tasks": ["2.3", "4.1", "5.1", "5.3", "6.1", "7.1", "8.1", "9.1"] },
    { "id": 3, "tasks": ["4.2", "4.3", "4.4", "4.5", "4.6", "4.7", "5.2", "5.4", "6.2", "7.2", "8.2", "9.2", "9.3"] },
    { "id": 4, "tasks": ["11.1"] },
    { "id": 5, "tasks": ["12.1", "12.2", "12.4", "12.5", "13.1", "13.2", "13.3", "14.1", "14.2", "14.3", "14.4", "15.1"] },
    { "id": 6, "tasks": ["12.3", "12.6", "13.4", "14.5", "15.2"] },
    { "id": 7, "tasks": ["16.1"] },
    { "id": 8, "tasks": ["16.2", "18.1", "18.2", "18.3", "18.4", "18.5"] }
  ]
}
```
