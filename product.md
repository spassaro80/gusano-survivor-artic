# Producto — 7 Días en el Ártico

## Visión

"7 Días en el Ártico" es un juego de **supervivencia en primera persona** para
**Roblox**. El jugador aparece solo en un vasto mapa ártico nevado y debe
resistir **7 días reales** gestionando tres necesidades vitales —**Calor,
Hambre y Sed**— mientras recolecta recursos, construye refugios y hogueras, pesca
para alimentarse y sobrevive a ventiscas periódicas. El objetivo es aguantar
hasta que un **helicóptero de rescate** llegue el Día 7. Al llegar, el jugador
elige entre **escapar (ganar)** o **seguir sobreviviendo** en un modo libre
infinito.

## Plataforma y cómo se juega

- El juego se ejecuta **dentro de la plataforma Roblox** (app de Roblox en PC,
  móvil o consola, o Roblox a través del navegador). **No** es una web
  independiente ni un ejecutable.
- Perspectiva: **primera persona**, con los brazos del personaje y la herramienta
  equipada visibles en todo momento.
- Sesiones persistentes: el progreso se **guarda automáticamente**, de modo que
  se puede continuar la partida en otra sesión.

## Mecánicas (resumen funcional)

1. **Menú principal inmersivo**: escena de bosque nevado, título "7 DÍAS EN EL
   ÁRTICO", viento aullando en bucle y botón "SOBREVIVIR".
2. **Tutorial inicial**: tarjeta con instrucciones (vigilar Calor/Hambre/Sed;
   cómo minar, talar y hacer hogueras; el objetivo de 7 días) y botón "ENTENDIDO".
   La partida permanece en pausa mientras la tarjeta está visible.
3. **Cámara en primera persona + kit inicial**: al empezar, el jugador tiene 7
   herramientas: Pala, Hacha, Pico, Caña de Pescar, Neverita Portátil, Cama y
   Botella de Agua (llena al 100%).
4. **HUD de supervivencia**: tres barras (Calor, Hambre, Sed) con transiciones
   suaves. Bajo el 20% de Calor la pantalla parpadea en rojo y los bordes se
   congelan. Si cualquier barra llega a 0, el jugador pierde salud hasta morir.
5. **Terreno y recursos**: mapa de 500×500 bloques nevado, rodeado de montañas,
   con lagos helados en zonas bajas. Se distribuyen 40 rocas y 60 árboles.
6. **Clima y ventiscas**: cada 10 minutos se activa una ventisca de 1 minuto con
   niebla densa, viento rugiente y frío que consume el doble de Calor a la
   intemperie.
7. **Talado y minería con físicas**: 5 golpes de Hacha derriban un árbol (el
   tronco cae por gravedad); "Cortar Leña" produce 3 maderas. 5 golpes de Pico
   desmoronan una roca en fragmentos; minarlos da piedra. Árboles y rocas
   reaparecen tras 1 minuto.
8. **Excavar cuevas**: con la Pala se retiran cubos de nieve para cavar una cueva
   que protege del viento y el frío durante la ventisca. No se puede excavar roca
   ni hielo.
9. **Pesca en el hielo**: se rompe el hielo con el Pico (crea un agujero de agua),
   se lanza la Caña, se esperan 5 segundos y con un clic en "¡Sacar Pez!" cae un
   pez al suelo.
10. **Neverita portátil**: almacena hasta 30 peces. Al intentar meter el nº 31
    avisa de que está llena. Se pueden sacar de uno en uno.
11. **Beber y rellenar la botella**: beber recupera 40 de Sed y vacía la botella;
    se rellena junto a un agujero de agua.
12. **Mechero y hogueras de emergencia**: se suelta una madera, se enciende con el
    Mechero y da calor durante 45 segundos.
13. **Hoguera base y cocinado**: con 5 piedras se coloca el círculo, con 3 maderas
    el centro, y se enciende con el Mechero (permanente, admite hasta 20 maderas).
    Un pez crudo cerca del fuego se cocina en 10 s (+40 Hambre); si se deja 8 s más
    se quema (−15 Salud al comerlo).
14. **Cama y reaparición**: se coloca en la base o en una cueva; al interactuar,
    fija el punto de reaparición. De noche, dormir avanza rápido hasta el amanecer.
15. **Rescate o modo libre**: el Día 7 aterriza el helicóptero. Al acercarse,
    el jugador elige "Escapar" (victoria y vuelta al menú) o "Seguir Sobreviviendo"
    (modo infinito: Día 8, 9, 10...).
16. **Guardado automático**: cada 2 minutos y al salir. Guarda día, madera, piedra,
    peces de la neverita, posición y si estaba en modo libre.

## Estado del producto

- **Implementación de código: completa.** Toda la lógica del juego (reglas puras,
  sistemas de servidor autoritativos, orquestador y controladores de cliente) está
  escrita y sin errores de análisis estático.
- **Pendiente (requiere Roblox Studio / Lune):** ejecutar la suite de pruebas
  (TestEZ) y los playtests visuales de físicas, UI y persistencia real con
  DataStore. El arte y el audio son placeholders intercambiables.

## Público objetivo

Jugadores de Roblox que disfrutan de la supervivencia con gestión de recursos y
tensión ambiental (clima hostil, escasez, refugio). Partidas de sesión larga con
progreso persistente.
