# 7 Días en el Ártico (Gusano Survivor Artic)

Juego de supervivencia en primera persona para **Roblox / Luau**. El jugador debe
sobrevivir 7 días reales gestionando Calor, Hambre y Sed, recolectando recursos,
construyendo refugios y hogueras, y resistiendo ventiscas, hasta que llega un
helicóptero de rescate en el Día 7.

## Estado del proyecto

**Implementación de código completa** y sin errores de análisis estático: lógica
pura, contrato de Remotes, 12 sistemas de servidor autoritativos, orquestador
`GameServer` con bucle de simulación, y 5 controladores de cliente. Documentación
del producto en `product.md` y del diseño técnico en `design.md`.

**Pendiente (requiere Roblox Studio / Lune):** ejecutar la suite de pruebas
(TestEZ) y los playtests de físicas, UI y persistencia real con DataStore. El arte
y el audio son placeholders (`rbxassetid://0`) intercambiables.

La especificación completa (requisitos, diseño y plan de tareas) vive en
`.kiro/specs/juego-supervivencia-artico/`.

## Documentación

- `product.md` — visión del producto y descripción funcional de las 16 mecánicas.
- `design.md` — arquitectura técnica, mapa de módulos y estrategia de pruebas.
- `.kiro/specs/juego-supervivencia-artico/` — requisitos (EARS), diseño formal con
  propiedades de correctitud, y plan de tareas.

## Arquitectura

Servidor autoritativo con tres capas:

- **Lógica pura (`ReplicatedStorage/Shared`)**: módulos sin dependencias del motor,
  verificables con property-based testing.
- **Servidor (`ServerScriptService`)**: posee el estado real y valida toda acción.
- **Cliente (`StarterPlayer`)**: cámara en primera persona, HUD, menús e input.

## Estructura del repositorio

```
default.project.json     -- Mapeo del arbol de Roblox (Rojo 7)
rokit.toml               -- Toolchain con versiones fijadas (rojo, wally, lune)
wally.toml               -- Dependencias (dev: TestEZ)
src/
  shared/                -> ReplicatedStorage/Shared  (logica pura)
  remotes/               -> ReplicatedStorage/Remotes (contrato cliente-servidor)
  server/                -> ServerScriptService        (sistemas autoritativos)
    Systems/
  client/                -> StarterPlayer/StarterPlayerScripts (cliente)
tests/                   -> ReplicatedStorage/Tests    (TestEZ: unitarias + propiedades)
```

## Toolchain

Las herramientas de línea de comandos se gestionan con
[Rokit](https://github.com/rojo-rbx/rokit) (compatible con manifiestos de
[Aftman](https://github.com/LPGhatguy/aftman)). Las versiones están fijadas en
`rokit.toml`, de modo que cualquier PC obtiene exactamente las mismas versiones.

1. Instala Rokit (o Aftman) siguiendo su README.
2. En la raíz del repositorio, instala las herramientas declaradas:

   ```bash
   rokit install
   ```

   Esto deja disponibles `rojo`, `wally` y `lune`.

3. Instala las dependencias de Luau declaradas en `wally.toml` (crea `DevPackages/`
   con TestEZ):

   ```bash
   wally install
   ```

## Puesta en marcha en un PC con Roblox Studio (paso a paso)

Guía completa desde un equipo nuevo (con acceso libre a `roblox.com`) hasta jugar
la versión publicada. Requiere una red **sin bloqueos a Roblox** (no funciona en
redes corporativas que filtran `roblox.com`/`rbxcdn.com`).

### Fase 1 — Preparar el equipo (una sola vez)
1. **Instala Roblox Studio**: entra en `roblox.com`, inicia sesión y descarga
   Studio. Ábrelo y autentícate.
2. **Instala Git** desde `git-scm.com` (si no lo tienes).
3. **Instala la toolchain** (ver sección "Toolchain"): Rokit + `rokit install`.
   Alternativa mínima: instala **Rojo** y su **plugin de Roblox Studio** (búscalo
   como "Rojo" en Plugins/Toolbox de Studio).

### Fase 2 — Traer el proyecto
4. Clona el repositorio e instala dependencias:

   ```bash
   git clone https://github.com/spassaro80/gusano-survivor-artic.git
   cd gusano-survivor-artic
   rokit install     # rojo, wally, lune (segun rokit.toml)
   wally install     # descarga TestEZ a DevPackages/
   ```

   Si te pide credenciales de GitHub, inicia sesión como **spassaro80**.

### Fase 3 — Sincronizar con Studio (Rojo)
5. En la raíz del repo, arranca el servidor de Rojo:

   ```bash
   rojo serve
   ```

6. Abre Roblox Studio con un **lugar nuevo (Baseplate)**. En el plugin de **Rojo**
   pulsa **Connect** (`localhost`, puerto 34872 por defecto).
7. Rojo monta el árbol del juego. En el Explorer verás `ReplicatedStorage/Shared`,
   `ReplicatedStorage/Remotes`, `ReplicatedStorage/Tests`, `ServerScriptService`
   (con `GameServer`, `Bootstrap` y `Systems/`) y `StarterPlayerScripts` (con los
   controladores). Cualquier cambio en la carpeta se refleja al instante.

   > Arranque: el servidor se inicia mediante `ServerScriptService/Bootstrap`
   > (Script generado desde `Bootstrap.server.lua`), que requiere `GameServer`. El
   > cliente arranca por los `*.client.lua`, que Rojo crea como LocalScripts
   > autoejecutables en `StarterPlayerScripts`.

### Fase 4 — Habilitar el guardado (DataStore)
8. En Studio: **Game Settings → Security → activa "Enable Studio Access to API
   Services"**. Sin esto, el guardado automático no funciona en pruebas locales
   (en el juego publicado sí funciona por defecto).

### Fase 5 — Probar el juego
9. Pulsa **Play** (F5): menú → tutorial → primera persona con HUD. Prueba las
   mecánicas (talar, minar, pescar, hogueras, cama, etc.).
10. El **arte y el audio son placeholders** (`rbxassetid://0`): se verán/oirán
    vacíos hasta que los sustituyas; la lógica funciona igual.

### Fase 6 — Ejecutar los tests (recomendado)
11. Con `wally install` hecho, ejecuta la suite TestEZ (unitarias + 12 propiedades)
    dentro de Studio o con Lune (ver sección "Ejecutar las pruebas"). Aquí se
    completan los checkpoints del plan (tareas 10, 17 y 19).

### Fase 7 — Pulir (opcional)
12. Sustituye los placeholders de arte/sonido (sube tus assets a Roblox y cambia
    los `rbxassetid://0` en `MenuController`, `HudController`, etc.) y mejora los
    modelos 3D en `WorldSystem`/`GameServer` si quieres más fidelidad.

### Fase 8 — Publicar y jugar
13. **File → Publish to Roblox As...**, crea la experiencia y publícala.
14. En **Game Settings → Permissions**, ponla **Public** si quieres que otros
    entren.
15. A partir de ahí se juega **desde Roblox**: app de Roblox (PC/móvil/consola) o
    `roblox.com` en el navegador, abriendo la página del juego. El DataStore ya
    funciona de forma nativa.

### Fase 9 — Iterar
16. Para traer cambios del repo: `git pull` (Rojo resincroniza). Para subir cambios
    hechos en este PC: `git add -A && git commit -m "..." && git push`.

> Nota: el guardado con `DataStoreService` requiere el juego publicado o
> "Enable Studio Access to API Services" activado en Studio.

## Ejecutar las pruebas

La suite (pruebas unitarias + las 12 pruebas de propiedad) usa **TestEZ** y puede
ejecutarse de dos formas:

- **Fuera de Studio (local/CI):** con [Lune](https://github.com/lune-org/lune),
  cargando `tests/` y arrancando TestEZ desde un script runner.
- **Dentro de Studio:** con Rojo sincronizado, ejecutando TestEZ sobre
  `ReplicatedStorage/Tests`.

Requisito previo en ambos casos: haber ejecutado `wally install` para que TestEZ
esté presente en `DevPackages/`.

## Requisitos para jugar

El juego se ejecuta dentro de la plataforma Roblox (app de Roblox o
Roblox en el navegador), no como aplicación web independiente.
