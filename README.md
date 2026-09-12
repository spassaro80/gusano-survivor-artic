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

## Desarrollo con Rojo

Este proyecto está pensado para sincronizarse con Roblox Studio mediante
[Rojo](https://rojo.space):

1. En un PC con Roblox Studio instalado, instala Rojo y el plugin de Studio.
2. Clona este repositorio.
3. Ejecuta `rojo serve` en la raíz del proyecto.
4. En Studio, abre el plugin de Rojo y pulsa **Connect**.
5. El código se monta en el árbol del juego. Pulsa **Play** para probar.

> Nota: el guardado con `DataStoreService` requiere el juego publicado o
> "Enable Studio Access to API Services" activado en Studio.

## Requisitos para jugar

El juego se ejecuta dentro de la plataforma Roblox (app de Roblox o
Roblox en el navegador), no como aplicación web independiente.
