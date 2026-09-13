# 7 Días en el Ártico (Gusano Survivor Artic)

Juego de supervivencia en primera persona para **Roblox / Luau**. El jugador debe
sobrevivir 7 días reales gestionando Calor, Hambre y Sed, recolectando recursos,
construyendo refugios y hogueras, y resistiendo ventiscas, hasta que llega un
helicóptero de rescate en el Día 7.

## Estado del proyecto

En fase de especificación y desarrollo incremental. La especificación completa
(requisitos, diseño y plan de tareas) vive en `.kiro/specs/juego-supervivencia-artico/`.

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

## Desarrollo con Rojo

Este proyecto se sincroniza con Roblox Studio mediante [Rojo](https://rojo.space):

1. En un PC con Roblox Studio instalado, instala la toolchain (ver sección
   anterior) y el plugin de Rojo para Studio.
2. Clona este repositorio y ejecuta `wally install` una vez.
3. Ejecuta `rojo serve` en la raíz del proyecto.
4. En Studio, abre el plugin de Rojo y pulsa **Connect**.
5. El código de `src/` y `tests/` se monta en el árbol del juego. Pulsa **Play**
   para probar.

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
