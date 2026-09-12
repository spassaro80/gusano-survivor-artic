# Requirements Document

## Introduction

"7 Días en el Ártico" es un videojuego de supervivencia en primera persona ambientado en un entorno ártico hostil. El jugador debe sobrevivir durante 7 días reales gestionando tres necesidades vitales (Calor, Hambre y Sed), recolectando recursos del entorno (madera, piedra y pescado), construyendo refugios y hogueras, y protegiéndose de ventiscas periódicas. El objetivo principal es resistir hasta que llegue un helicóptero de rescate en el Día 7, momento en el que el jugador puede escapar (ganar) o continuar jugando indefinidamente en un modo libre. El juego guarda el progreso automáticamente para permitir sesiones en distintos días.

Este documento captura los requisitos funcionales del juego en patrones EARS. No incluye decisiones de implementación (motor de juego, scripts o código), que se abordarán en las fases de diseño e implementación. El motor de juego objetivo se asume compatible con mecánicas de físicas, primera persona e inventario (por ejemplo, un motor tipo Roblox/Luau), pero la elección definitiva se confirmará en la fase de diseño.

## Glossary

- **Juego**: El sistema de software completo "7 Días en el Ártico" que gestiona la partida, el estado del jugador y el mundo.
- **Menu_Principal**: Componente que muestra la pantalla de inicio y el botón para comenzar la partida.
- **Tutorial**: Componente que muestra la tarjeta de instrucciones iniciales al comenzar.
- **Camara**: Componente que controla la vista en primera persona del jugador.
- **Jugador**: La entidad controlada por el usuario dentro del mundo del juego.
- **Inventario**: Almacén de herramientas y recursos que porta el Jugador (mochila).
- **Neverita**: Contenedor especializado (Neverita Portátil) que almacena exclusivamente peces, con capacidad máxima de 30 peces.
- **Botella**: La Botella de Agua que el Jugador usa para beber y que puede rellenarse en un agujero de agua.
- **HUD**: Interfaz en pantalla que muestra las barras de estado de Calor, Hambre y Sed.
- **Barra_Calor**: Indicador de la necesidad vital Calor (Warmth).
- **Barra_Hambre**: Indicador de la necesidad vital Hambre (Hunger).
- **Barra_Sed**: Indicador de la necesidad vital Sed (Thirst).
- **Salud**: Puntos de vida del Jugador; su agotamiento provoca la muerte.
- **Mundo**: El mapa jugable de bloques cubierto de nieve, con montañas, colinas y lagos helados.
- **Lago_Helado**: Zona baja del Mundo cubierta de hielo azul transparente sobre agua.
- **Agujero_Agua**: Abertura creada al romper el hielo de un Lago_Helado, usada para pescar y rellenar la Botella.
- **Sistema_Clima**: Componente que gestiona los cambios de clima y las ventiscas.
- **Ventisca**: Evento climático de tormenta con niebla densa, viento fuerte y frío intensificado.
- **Arbol**: Objeto interactivo talable que produce troncos y, tras cortarlos, madera.
- **Roca**: Objeto interactivo minable que produce fragmentos y, tras minarlos, piedra.
- **Tronco**: Objeto físico resultante de talar un Arbol; al cortarse produce madera.
- **Madera**: Recurso obtenido de cortar un Tronco.
- **Piedra**: Recurso obtenido de minar fragmentos de Roca.
- **Cueva**: Refugio subterráneo excavado en la nieve con la Pala.
- **Pez**: Recurso alimenticio obtenido pescando en un Agujero_Agua.
- **Pez_Cocinado**: Pez que ha sido cocinado en una hoguera encendida y que restaura Hambre.
- **Pez_Quemado**: Pez que ha permanecido demasiado tiempo en el fuego y que reduce Salud al consumirse.
- **Hoguera_Emergencia**: Fuego temporal creado con un único Tronco y el Mechero.
- **Hoguera_Base**: Fuego permanente construido con piedras y madera en el campamento.
- **Mechero**: Herramienta usada para encender troncos y hogueras.
- **Cama**: Objeto que, al interactuar, fija el punto de reaparición y permite dormir para avanzar el tiempo.
- **Helicoptero_Rescate**: Vehículo que aparece en el Día 7 para ofrecer el rescate.
- **Dia**: Unidad de tiempo de la partida; el objetivo es sobrevivir 7 Días reales.
- **Modo_Libre**: Modo de juego infinito que continúa tras el Día 7 sin condición de victoria.
- **Sistema_Guardado**: Componente que persiste y restaura el estado de la partida.
- **Herramienta**: Cualquiera de los útiles portados por el Jugador (Pala, Hacha, Pico, Caña de Pescar, Neverita Portátil, Cama, Botella de Agua, Mechero).

## Requirements

### Requisito 1: Pantalla de inicio y menú principal

**Historia de Usuario:** Como jugador, quiero una pantalla de inicio inmersiva con un botón para comenzar, para sumergirme en la ambientación ártica antes de jugar.

#### Criterios de Aceptación

1. WHEN el Juego arranca, THE Menu_Principal SHALL mostrar, en un máximo de 3 segundos, una escena con un fondo de bosque nevado y el título "7 DÍAS EN EL ÁRTICO".
2. WHILE el Menu_Principal está visible, THE Menu_Principal SHALL reproducir en bucle continuo un sonido de viento aullando.
3. WHEN el Menu_Principal termina de mostrar la escena de inicio, THE Menu_Principal SHALL mostrar un botón etiquetado "SOBREVIVIR".
4. WHEN el Jugador pulsa el botón "SOBREVIVIR", THE Juego SHALL iniciar la secuencia de tutorial inicial.
5. IF el sonido de viento no puede reproducirse, THEN THE Menu_Principal SHALL continuar mostrando la escena de inicio y el botón "SOBREVIVIR" sin bloquear el arranque del Juego.

### Requisito 2: Tutorial inicial

**Historia de Usuario:** Como jugador nuevo, quiero unas instrucciones iniciales claras, para entender qué necesidades vigilar y cuál es mi objetivo antes de empezar a jugar.

#### Criterios de Aceptación

1. WHEN el Jugador pulsa el botón "SOBREVIVIR", THE Tutorial SHALL atenuar la pantalla a un máximo del 50% de opacidad y mostrar la tarjeta de instrucciones iniciales en un máximo de 500 milisegundos.
2. THE Tutorial SHALL mostrar en la tarjeta de instrucciones que el Jugador debe vigilar exactamente tres necesidades: Calor, Hambre y Sed.
3. THE Tutorial SHALL mostrar en la tarjeta de instrucciones las indicaciones para minar rocas, talar árboles y crear hogueras de emergencia.
4. THE Tutorial SHALL indicar en la tarjeta de instrucciones que el objetivo es sobrevivir 7 Días reales hasta que llegue un helicóptero de rescate.
5. THE Tutorial SHALL mostrar en la tarjeta de instrucciones un botón etiquetado "ENTENDIDO".
6. WHILE la tarjeta de instrucciones iniciales esté visible, THE Juego SHALL mantener la partida en pausa, sin avanzar el tiempo ni consumir las necesidades Calor, Hambre y Sed.
7. WHEN el Jugador pulsa el botón "ENTENDIDO", THE Tutorial SHALL ocultar la tarjeta de instrucciones y restaurar la opacidad de la pantalla al 100% en un máximo de 500 milisegundos.
8. WHEN el Tutorial oculta la tarjeta de instrucciones, THE Juego SHALL comenzar la partida activa e iniciar el consumo de las necesidades Calor, Hambre y Sed.

### Requisito 3: Cámara en primera persona y kit inicial

**Historia de Usuario:** Como jugador, quiero ver el juego en primera persona con mis brazos y herramientas visibles, y empezar con un kit completo, para sentir inmersión y disponer de lo necesario para sobrevivir.

#### Criterios de Aceptación

1. WHEN la partida activa comienza, THE Camara SHALL activar la vista en primera persona del Jugador en un máximo de 1 segundo.
2. WHILE la partida activa está en curso, THE Camara SHALL mostrar, en cada fotograma renderizado, los brazos del Jugador y la Herramienta que tiene equipada.
3. WHEN la partida activa comienza, THE Inventario SHALL contener exactamente las 7 Herramientas iniciales, una unidad de cada una: Pala, Hacha, Pico, Caña de Pescar, Neverita Portátil, Cama y Botella de Agua.
4. WHEN la partida activa comienza, THE Botella de Agua SHALL estar llena al 100% de su capacidad máxima.
5. IF al comenzar la partida activa el Inventario no queda con las 7 Herramientas iniciales completas, THEN THE Juego SHALL impedir el inicio de la partida y mostrar al Jugador un mensaje que indique el fallo en la creación del kit inicial, sin dejar la partida en un estado jugable parcial.

### Requisito 4: Barras de estado del HUD

**Historia de Usuario:** Como jugador, quiero ver barras claras de mis necesidades vitales que cambian según mi estado, para tomar decisiones de supervivencia a tiempo.

#### Criterios de Aceptación

1. WHILE la partida activa está en curso, THE HUD SHALL mostrar tres barras que representan Barra_Calor, Barra_Hambre y Barra_Sed, cada una con un valor comprendido entre 0% y 100%.
2. WHEN el valor de una barra cambia, THE HUD SHALL redimensionar la barra correspondiente hasta el nuevo valor mediante una transición con una duración de entre 200 y 400 milisegundos.
3. WHILE el Jugador está bajo nieve, THE Barra_Calor SHALL disminuir a una velocidad equivalente al doble (200%) de la velocidad de disminución en condiciones normales.
4. WHILE la Barra_Calor está por debajo del 20%, THE HUD SHALL parpadear en rojo a una frecuencia de entre 1 y 2 parpadeos por segundo y mostrar un efecto de congelación en los bordes de la pantalla.
5. WHILE la partida activa está en curso, THE Barra_Hambre SHALL disminuir a una velocidad constante de 1% por segundo.
6. WHILE la partida activa está en curso, THE Barra_Sed SHALL disminuir a una velocidad constante de 1% por segundo.
7. WHILE cualquiera de Barra_Calor, Barra_Hambre o Barra_Sed está en 0%, THE Juego SHALL reducir la Salud del Jugador a una velocidad constante de 5% por segundo.
8. WHEN la Salud del Jugador llega a 0%, THE Juego SHALL provocar la muerte del Jugador dentro de 1 segundo.

### Requisito 5: Terreno y recursos del mundo

**Historia de Usuario:** Como jugador, quiero un mapa amplio y coherente con recursos distribuidos, para explorar y recolectar lo necesario para sobrevivir.

#### Criterios de Aceptación

1. WHEN la partida activa comienza, THE Mundo SHALL generar un mapa de 500x500 bloques (250.000 celdas) con el 100% de sus celdas transitables cubiertas de nieve blanca.
2. THE Mundo SHALL disponer en su perímetro una banda continua e infranqueable de montañas y colinas de al menos 20 bloques de ancho que impida al Jugador salir del mapa.
3. THE Mundo SHALL contener entre 3 y 8 lagos helados de hielo azul transparente situados en las celdas de menor elevación, sin solapar la banda perimetral.
4. WHEN la partida activa comienza, THE Mundo SHALL distribuir 40 bloques de piedra dentro de los límites del mapa, sin solaparse entre sí y con una separación mínima de 2 bloques.
5. WHEN la partida activa comienza, THE Mundo SHALL distribuir 60 árboles interactivos (talables para recolectar recursos) dentro de los límites del mapa, sin solaparse entre sí y con una separación mínima de 2 bloques.
6. IF la generación del Mundo no cumple las restricciones de distribución tras 3 reintentos, THEN THE Juego SHALL impedir el inicio de la partida y mostrar un mensaje de error indicando el fallo de generación del mapa.

### Requisito 6: Clima y ventiscas

**Historia de Usuario:** Como jugador, quiero que el clima cambie y que aparezcan ventiscas peligrosas, para que la supervivencia sea dinámica y desafiante.

#### Criterios de Aceptación

1. WHEN transcurren 600 segundos (10 minutos) desde el último cambio de clima, THE Sistema_Clima SHALL seleccionar un nuevo estado de clima de forma aleatoria con probabilidad uniforme entre los estados de clima disponibles.
2. WHEN el Sistema_Clima selecciona un nuevo estado de clima, THE Sistema_Clima SHALL activar una Ventisca y reiniciar el temporizador de cambio de clima a 600 segundos.
3. WHEN una Ventisca se activa, THE Sistema_Clima SHALL mantener la Ventisca activa durante 60 segundos (1 minuto) y desactivarla automáticamente al finalizar ese intervalo.
4. WHILE una Ventisca está activa, THE Sistema_Clima SHALL mostrar niebla que reduzca la distancia de visibilidad del Jugador al 30% de la distancia de visibilidad en clima despejado.
5. WHILE una Ventisca está activa, THE Sistema_Clima SHALL reproducir un sonido de viento rugiente a un volumen igual o superior al 80% del volumen máximo del canal de efectos ambientales.
6. WHILE una Ventisca está activa AND el Jugador está a la intemperie (no situado bajo un refugio o techo), THE Barra_Calor SHALL disminuir al doble de la velocidad de disminución en clima despejado.
7. WHEN una Ventisca se desactiva, THE Sistema_Clima SHALL restaurar la distancia de visibilidad, el volumen del sonido de viento y la velocidad de disminución de la Barra_Calor a sus valores de clima despejado.

### Requisito 7: Talado de árboles y minería de rocas

**Historia de Usuario:** Como jugador, quiero talar árboles y minar rocas con físicas realistas, para obtener madera y piedra como recursos.

#### Criterios de Aceptación

1. WHEN el Jugador golpea un Arbol con el Hacha 5 veces, THE Arbol SHALL desanclar el Tronco y hacerlo caer al suelo por gravedad.
2. WHILE un Tronco está en el suelo AND el Jugador está dentro de un radio de 2 metros del Tronco, THE Juego SHALL mostrar una acción etiquetada "Cortar Leña".
3. WHEN el Jugador ejecuta la acción "Cortar Leña" sobre un Tronco en el suelo, THE Juego SHALL romper el Tronco y liberar 3 piezas de Madera en el suelo.
4. WHEN el Jugador golpea una Roca con el Pico 5 veces, THE Roca SHALL desmoronarse en 3 fragmentos físicos en el suelo.
5. WHEN el Jugador mina un fragmento de Roca en el suelo, THE Juego SHALL otorgar 1 unidad de Piedra al Jugador por cada fragmento minado.
6. WHEN transcurre 1 minuto desde que un Arbol fue talado, THE Mundo SHALL reaparecer el Arbol en su ubicación original.
7. WHEN transcurre 1 minuto desde que una Roca fue destruida, THE Mundo SHALL reaparecer la Roca en su ubicación original.
8. IF el Jugador golpea un Arbol con una herramienta distinta al Hacha OR golpea una Roca con una herramienta distinta al Pico, THEN THE Juego SHALL no incrementar el contador de golpes del objeto y mantener el objeto intacto.
9. IF el Inventario del Jugador está lleno cuando se debería otorgar Madera o Piedra, THEN THE Juego SHALL dejar el recurso en el suelo y mostrar una indicación visible de inventario lleno.

### Requisito 8: Excavación de cuevas en la nieve

**Historia de Usuario:** Como jugador atrapado por una ventisca lejos del campamento, quiero excavar una cueva en la nieve, para refugiarme del viento y el frío extremo.

#### Criterios de Aceptación

1. WHILE la Pala está equipada AND el Jugador apunta a un bloque de suelo de nieve situado a 3 metros o menos del Jugador, WHEN el Jugador hace clic, THE Juego SHALL retirar exactamente un cubo de nieve del suelo en 500 milisegundos o menos.
2. WHEN el Jugador retira 8 o más cubos de nieve consecutivos que conforman un espacio hueco de al menos 2 cubos de alto, 2 de ancho y 2 de profundidad, THE Juego SHALL registrar ese espacio como una Cueva subterránea accesible mediante un túnel.
3. WHILE el Jugador está completamente dentro de una Cueva durante una Ventisca, THE Juego SHALL reducir a cero el daño por frío extremo y el efecto del viento de la Ventisca sobre el Jugador.
4. IF el Jugador apunta a roca o a hielo de lago con la Pala equipada AND hace clic, THEN THE Juego SHALL impedir la excavación, no retirar ningún cubo y mostrar una indicación de que ese material no puede excavarse.
5. IF el Jugador intenta excavar en un punto cuya profundidad de nieve es menor de 1 cubo, THEN THE Juego SHALL impedir la excavación, conservar el terreno sin cambios y mostrar una indicación de que no hay nieve suficiente.

### Requisito 9: Pesca en el hielo

**Historia de Usuario:** Como jugador, quiero pescar en un lago helado, para obtener alimento y evitar morir de hambre.

#### Criterios de Aceptación

1. WHEN el Jugador golpea con el Pico equipado un bloque de hielo perteneciente a un Lago_Helado, THE Juego SHALL romper ese bloque de hielo y crear un Agujero_Agua en la posición del bloque roto en un plazo máximo de 1 segundo.
2. WHILE la Caña de Pescar está equipada, WHEN el Jugador hace clic sobre el agua de un Agujero_Agua, THE Juego SHALL iniciar una cuenta de espera de exactamente 5 segundos y mostrar un indicador visual de que la Caña de Pescar ha sido lanzada.
3. WHEN transcurren exactamente 5 segundos desde el lanzamiento de la Caña de Pescar sin que el Jugador haya cancelado la acción, THE Juego SHALL mostrar un Pez colgando del anzuelo y una acción etiquetada "¡Sacar Pez!".
4. WHEN el Jugador ejecuta la acción "¡Sacar Pez!" con un solo clic, THE Juego SHALL retirar el Pez del anzuelo y depositar 1 unidad de Pez en el suelo en la casilla adyacente al Jugador.
5. IF transcurren 10 segundos desde que se muestra la acción "¡Sacar Pez!" sin que el Jugador la ejecute, THEN THE Juego SHALL retirar el Pez del anzuelo sin entregarlo al Jugador y finalizar la sesión de pesca, dejando el Agujero_Agua disponible para un nuevo lanzamiento.
6. IF el Jugador equipa la Caña de Pescar y hace clic sobre una casilla que no contiene el agua de un Agujero_Agua, THEN THE Juego SHALL no iniciar la cuenta de espera de pesca y mantener la Caña de Pescar sin lanzar.

### Requisito 10: Neverita portátil

**Historia de Usuario:** Como jugador, quiero almacenar los peces en una neverita portátil separada del inventario, para conservarlos hasta cocinarlos.

#### Criterios de Aceptación

1. WHEN el Jugador recoge un Pez y la Neverita contiene menos de 30 peces, THE Juego SHALL almacenar el Pez únicamente en la Neverita y no en el Inventario normal.
2. THE Neverita SHALL tener una capacidad máxima de 30 peces.
3. WHILE la Neverita contiene menos de 30 peces, WHEN el Jugador añade un Pez a la Neverita, THE Neverita SHALL almacenar el Pez e incrementar en 1 el contador de peces almacenados.
4. IF el Jugador intenta añadir o recoger un Pez cuando la Neverita ya contiene 30 peces, THEN THE Juego SHALL rechazar la operación, mantener el contador de la Neverita en 30, dejar el Pez sin recoger en el mundo y mostrar un mensaje de error indicando que la Neverita está llena durante al menos 3 segundos.
5. WHEN el Jugador retira un Pez de la Neverita, THE Juego SHALL extraer exactamente 1 Pez por operación y decrementar en 1 el contador de peces almacenados.
6. WHILE la Neverita está abierta, THE Juego SHALL mostrar el número actual de peces almacenados de 0 a 30.

### Requisito 11: Beber y rellenar la botella de agua

**Historia de Usuario:** Como jugador, quiero beber agua y rellenar mi botella, para mantener la barra de Sed y no deshidratarme.

#### Criterios de Aceptación

1. WHILE la Botella está equipada AND la Botella no está vacía, WHEN el Jugador hace clic para beber, THE Juego SHALL aumentar la Barra_Sed en 40 puntos sin superar su valor máximo de 100 puntos, en un tiempo máximo de 500 milisegundos.
2. IF la suma de la Barra_Sed actual más 40 puntos supera el valor máximo de 100 puntos, THEN THE Juego SHALL fijar la Barra_Sed en 100 puntos.
3. WHEN el Jugador bebe de la Botella, THE Botella SHALL pasar al estado "Vacía".
4. IF la Botella está equipada AND la Botella está vacía, WHEN el Jugador hace clic para beber, THEN THE Juego SHALL mantener la Barra_Sed sin cambios y mostrar una indicación visible de que la Botella está vacía.
5. WHILE la Botella está vacía AND el Jugador está a una distancia igual o inferior a 2 unidades de un Agujero_Agua, THE Juego SHALL mostrar una acción etiquetada "Rellenar Botella".
6. WHILE la Botella está vacía AND el Jugador está a una distancia superior a 2 unidades de todo Agujero_Agua, THE Juego SHALL ocultar la acción etiquetada "Rellenar Botella".
7. WHEN el Jugador ejecuta la acción "Rellenar Botella", THE Botella SHALL pasar al estado "Llena" en un tiempo máximo de 1 segundo, quedando habilitada para restaurar 40 puntos de Barra_Sed al beber.

### Requisito 12: Mechero y hogueras de emergencia

**Historia de Usuario:** Como jugador lejos de la base y congelándome, quiero encender una hoguera de emergencia con un tronco, para recuperar calor y salvar mi vida temporalmente.

#### Criterios de Aceptación

1. WHEN el Jugador selecciona una pieza de Madera en el Inventario y ejecuta la acción "Soltar Madera", THE Juego SHALL soltar un Tronco en el suelo a 1 metro frente al Jugador en un plazo máximo de 1 segundo y reducir en 1 la cantidad de Madera del Inventario.
2. IF el Jugador ejecuta la acción "Soltar Madera" sin ninguna pieza de Madera disponible en el Inventario, THEN THE Juego SHALL rechazar la acción, no crear ningún Tronco y mostrar una indicación de error señalando que no dispone de Madera.
3. WHILE el Mechero está equipado, WHEN el Jugador hace clic sobre un Tronco soltado situado a 3 metros o menos del Jugador, THE Juego SHALL encender el Tronco como Hoguera_Emergencia en un plazo máximo de 1 segundo.
4. IF el Jugador hace clic sobre un Tronco soltado sin el Mechero equipado o situado a más de 3 metros del Jugador, THEN THE Juego SHALL no encender el Tronco y mantenerlo en su estado sin encender.
5. WHILE una Hoguera_Emergencia está encendida, THE Juego SHALL aumentar la Barra_Calor de cada Jugador situado a 5 metros o menos de la Hoguera_Emergencia a un ritmo de 10 puntos por segundo, hasta un valor máximo de 100 puntos.
6. WHEN transcurren 45 segundos desde que se enciende una Hoguera_Emergencia, THE Juego SHALL apagar la Hoguera_Emergencia y hacerla desaparecer.

### Requisito 13: Hoguera de base y cocinado de peces

**Historia de Usuario:** Como jugador, quiero construir una hoguera permanente en mi base y cocinar peces, para tener calor estable y comida que restaure el hambre.

#### Criterios de Aceptación

1. WHEN el Jugador coloca el plano de la Hoguera_Base disponiendo de 5 unidades de Piedra, THE Juego SHALL consumir 5 unidades de Piedra y disponer las piedras en el suelo formando un círculo.
2. IF el Jugador intenta colocar el plano de la Hoguera_Base con menos de 5 unidades de Piedra, THEN THE Juego SHALL rechazar la colocación, conservar el Inventario sin cambios y mostrar una indicación de que se necesitan 5 unidades de Piedra.
3. WHEN el círculo de piedras está formado, THE Juego SHALL solicitar 3 unidades de Madera y colocarlas en el centro consumiéndolas del Inventario.
4. WHILE el Mechero está equipado AND la Madera está colocada en el centro, WHEN el Jugador hace clic para encender, THE Juego SHALL crear una Hoguera_Base permanente encendida.
5. IF el Jugador intenta encender la Hoguera_Base sin el Mechero equipado, THEN THE Juego SHALL no crear la Hoguera_Base y conservar la Madera colocada en el centro.
6. WHEN el Jugador añade Madera a una Hoguera_Base encendida, THE Juego SHALL mantener la Hoguera_Base encendida sin apagarse, hasta un máximo de 20 unidades de Madera acumuladas.
7. WHEN el Jugador suelta un Pez crudo a 3 unidades o menos de una Hoguera_Base encendida, THE Juego SHALL iniciar el cocinado del Pez, admitiendo un máximo de 5 Peces cocinándose simultáneamente.
8. WHEN transcurren 10 segundos de cocinado de un Pez, THE Juego SHALL convertir el Pez en Pez_Cocinado con aspecto dorado.
9. WHEN el Jugador consume un Pez_Cocinado, THE Juego SHALL aumentar la Barra_Hambre en 40 puntos sin superar su valor máximo de 100 puntos.
10. IF un Pez_Cocinado permanece 8 segundos adicionales sobre el fuego, THEN THE Juego SHALL convertirlo en Pez_Quemado de color negro carbón que emite humo.
11. WHEN el Jugador consume un Pez_Quemado, THE Juego SHALL reducir la Salud del Jugador en 15 puntos sin bajar de 0 puntos.

### Requisito 14: Cama y punto de reaparición

**Historia de Usuario:** Como jugador, quiero colocar una cama en mi refugio y usarla como punto de reaparición y para dormir, para reaparecer a salvo y hacer pasar las noches frías rápidamente.

#### Criterios de Aceptación

1. WHEN el Jugador coloca la Cama sobre una superficie válida dentro de la base o dentro de una Cueva, THE Juego SHALL fijar la Cama en esa ubicación y mantenerla fija hasta que el Jugador la retire.
2. IF el Jugador intenta colocar la Cama fuera de la base y fuera de una Cueva, o sobre una superficie no válida, THEN THE Juego SHALL rechazar la colocación, no fijar la Cama e indicar mediante retroalimentación visual que la ubicación no es válida.
3. WHEN el Jugador interactúa con una Cama fijada, THE Juego SHALL establecer esa Cama como único punto de reaparición del Jugador, reemplazando cualquier punto de reaparición previamente establecido.
4. WHEN el Jugador muere en el Mundo y existe una Cama establecida como punto de reaparición, THE Juego SHALL reaparecer al Jugador en una posición transitable adyacente a esa Cama, a una distancia máxima de 2 metros.
5. IF el Jugador muere en el Mundo y no existe ninguna Cama establecida como punto de reaparición, o la Cama establecida ha sido retirada o destruida, THEN THE Juego SHALL reaparecer al Jugador en el punto de reaparición inicial por defecto del Mundo.
6. WHILE es de noche, WHEN el Jugador se acuesta en la Cama, THE Juego SHALL oscurecer la pantalla por completo en un máximo de 1 segundo, avanzar el tiempo del juego hasta el amanecer en un máximo de 3 segundos reales y restaurar la visibilidad de la pantalla al finalizar el avance.
7. IF el Jugador intenta acostarse en la Cama cuando no es de noche, THEN THE Juego SHALL impedir el avance acelerado del tiempo e indicar mediante retroalimentación visual que solo puede dormir de noche.

### Requisito 15: Rescate o modo libre infinito

**Historia de Usuario:** Como jugador que ha sobrevivido 7 días, quiero elegir entre escapar en helicóptero o seguir jugando, para decidir si gano la partida o continúo en modo infinito.

#### Criterios de Aceptación

1. WHEN comienza el Día 7, THE Juego SHALL reproducir el sonido de aspas de un helicóptero gigante durante un máximo de 5 segundos.
2. WHEN comienza el Día 7, THE Juego SHALL hacer aterrizar el Helicoptero_Rescate en una zona del Mundo con luces y sonidos en un plazo máximo de 10 segundos.
3. WHEN el Jugador se aproxima a 5 metros o menos del Helicoptero_Rescate, THE Juego SHALL mostrar una pantalla con exactamente dos opciones seleccionables: "Escapar" y "Seguir Sobreviviendo".
4. WHEN el Jugador elige "Escapar" y confirma, THE Juego SHALL mostrar una pantalla de victoria por sobrevivir y, tras la confirmación del Jugador, regresar al Menu_Principal.
5. WHEN el Jugador elige "Seguir Sobreviviendo", THE Juego SHALL hacer despegar el Helicoptero_Rescate y activar el Modo_Libre en un plazo máximo de 10 segundos.
6. WHILE el Modo_Libre está activo, THE Juego SHALL continuar la partida de forma indefinida incrementando el contador de Días en una unidad al final de cada Día (8, 9, 10, ...) sin condición de victoria.
7. IF el Jugador se aleja del Helicoptero_Rescate sin elegir ninguna opción, THEN THE Juego SHALL ocultar la pantalla de opciones y mantener el Helicoptero_Rescate disponible para una nueva aproximación.

### Requisito 16: Guardado automático de datos

**Historia de Usuario:** Como jugador, quiero que el juego guarde mi progreso automáticamente, para retomar la partida exactamente donde la dejé en otra sesión.

#### Criterios de Aceptación

1. WHEN transcurren 120 segundos (2 minutos) desde que finalizó el último guardado, THE Sistema_Guardado SHALL guardar el estado actual de la partida en un plazo máximo de 3 segundos.
2. WHEN el Jugador decide salir del Juego, THE Sistema_Guardado SHALL guardar el estado actual de la partida antes de cerrar la sesión.
3. WHEN el Sistema_Guardado guarda la partida, THE Sistema_Guardado SHALL registrar la posición del Jugador, el Día actual, la cantidad de Madera, la cantidad de Piedra, el número de peces restantes en la Neverita y si el Modo_Libre estaba activo.
4. WHEN el Jugador vuelve a entrar en el Juego con una partida guardada válida, THE Juego SHALL restaurar exactamente los mismos valores registrados en el último guardado: posición del Jugador, Día, Madera, Piedra, peces de la Neverita y estado del Modo_Libre.
5. IF el guardado de la partida falla, THEN THE Sistema_Guardado SHALL conservar los datos del guardado anterior y mostrar un mensaje indicando que el guardado no se completó.
6. IF el Jugador entra en el Juego y no existe ninguna partida guardada, THEN THE Juego SHALL iniciar una partida nueva desde el Día 1.
7. IF la partida guardada está corrupta o incompleta, THEN THE Juego SHALL mostrar un mensaje indicándolo e iniciar una partida nueva desde el Día 1.
