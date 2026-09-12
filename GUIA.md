# Guía de puesta en marcha — media stack

Todo asume que ya tenés Docker + Docker Compose en la VPS.
Los paneles NO se exponen a internet: se acceden por la IP de tu tailnet.

**Casi todo vive en el compose**, incluidos el reverse proxy (nginx), el
geo-bloqueo y fail2ban. Del host solo quedan afuera de Docker dos cosas, porque
no pueden estar adentro: **Tailscale** (crea una interfaz de red del host) y
**UFW** (son las reglas del host). Pero ya no se configuran aparte: son el
**paso 1** del orquestador.

Son dos comandos, y el segundo hace todo:

```bash
cp env.example .env && nano .env   # secretos
sudo ./configure-stack.py          # host + compose + configuración de servicios
```

Es idempotente de punta a punta: se puede correr las veces que haga falta. Cada
paso chequea antes de actuar, así que una segunda pasada no reinstala paquetes
ni reconstruye el firewall.

> **La primera vez frena en el paso 1** si Tailscale todavía no está
> autenticado: eso abre una URL en el navegador y no se automatiza. Corré
> `sudo tailscale up --ssh`, autenticá, y volvé a correr el mismo comando.

> ⚠️ Antes de la primera corrida, revisá que `SSH_PORT` en el `.env` sea tu
> puerto SSH real. El paso 1 configura UFW y abre **solo** ese puerto; si no
> coincide, te quedás afuera del server.

---

## Paso 0 — Estructura de carpetas

**Esto lo hace solo el orquestador** (paso 2, `media-tree.sh`): crea las carpetas
con el dueño correcto y verifica desde adentro de cada contenedor que pueda
escribir. Queda documentado acá para que entiendas el layout, no para que lo
corras a mano.

Estructura resultante:

```
/srv
├── config/          # config de cada servicio (persistente)
└── media/
    ├── downloads/   # qBittorrent baja acá
    ├── movies/      # Radarr organiza acá  -> biblioteca "Películas" de Jellyfin
    └── series/      # Sonarr organiza acá  -> biblioteca "Series" de Jellyfin
```

Ojo: dentro de los contenedores esas rutas son `/data/movies` y `/data/series`.
Los servicios no ven el filesystem del host, así que en cualquier config de
Radarr, Sonarr o Jellyfin va la ruta `/data/...`, nunca `/srv/media/...`.

**Importante (hardlinks):** todos los servicios montan `/srv/media` como `/data`.
Esto permite que Radarr/Sonarr muevan de `downloads/` a `movies/`/`series/` con
**hardlink** (instantáneo, sin duplicar espacio) en vez de copiar. Si montaras
`/downloads` y `/movies` por separado, perderías el hardlink y duplicarías disco.

---

## Paso 1 — Credenciales de ProtonVPN (WireGuard)

1. Entrá a https://account.protonvpn.com/downloads
2. Sección **WireGuard configuration**.
3. Activá:
   - **NAT-PMP (Port Forwarding)** — ON
   - **VPN Accelerator** — ON (opcional, da velocidad)
4. Elegí una plataforma (GNU/Linux) y un **servidor que soporte P2P**
   (Suiza y Países Bajos suelen tenerlos).
5. Generá y abrí el archivo `.conf`. Copiá el valor de `PrivateKey`.
6. En la carpeta del compose:
   ```bash
   cp env.example .env
   nano .env   # pegá la private key en WIREGUARD_PRIVATE_KEY
   ```

> Si elegiste otro país, cambiá `SERVER_COUNTRIES=Switzerland` en el compose.

---

## Paso 2 — Levantar el stack

**Esto también lo hace el orquestador** (paso 4). Lo de abajo sirve para
levantarlo a mano si estás debuggeando:

```bash
cd /ruta/al/media-stack
docker compose up -d
```

Mirá que gluetun conecte bien:

```bash
docker logs -f gluetun
```

Buscás una línea tipo `You are running the latest ...` y que la conexión al
servidor de Proton quede establecida, sin loops de reconexión.

---

## Paso 3 — VERIFICAR que qBittorrent sale por la VPN (crítico)

Antes de bajar NADA, confirmá que no hay leak de la IP de la VPS:

```bash
# la IP que ve qBittorrent debe ser la de Proton, NO la de tu VPS
docker exec qbittorrent curl -s https://ipinfo.io/ip
```

Comparalo con la IP real de la VPS:

```bash
curl -s https://ipinfo.io/ip
```

**Tienen que ser DISTINTAS.** Si son iguales, PARÁ: qBittorrent está filtrando.
No sigas hasta resolverlo (revisá logs de gluetun y la private key).

Contraseña inicial de qBittorrent: mirá los logs, la genera temporal:
```bash
docker logs qbittorrent | grep -i password
```
Entrá a la WebUI (ver Paso 6) y cambiala en Options → WebUI.

---

## Paso 4 — Orden de configuración de la suite

Configurá en este orden (cada uno depende del anterior):

1. **qBittorrent** — creá categorías `radarr` y `sonarr`. Seteá la carpeta de
   descargas a `/downloads`.
2. **Prowlarr** — agregá tus indexers. Después, en *Settings → Apps*, conectá
   Radarr y Sonarr (Prowlarr les empuja los indexers solo).
   - URL de Radarr: `http://radarr:7878`
   - URL de Sonarr: `http://sonarr:8989`
3. **Radarr** — en *Settings → Download Clients* agregá qBittorrent:
   - Host: `gluetun`  (NO `qbittorrent`, porque qbit vive en la red de gluetun)
   - Port: `8080`
   - Category: `radarr`
   - Root folder: `/data/movies`
4. **Sonarr** — igual que Radarr:
   - Host: `gluetun`, Port `8080`, Category `sonarr`
   - Root folder: `/data/series`
5. **Bazarr** — conectá con Radarr (`http://radarr:7878`) y Sonarr
   (`http://sonarr:8989`). Agregá proveedores de subs (OpenSubtitles, Subdivx)
   y poné español como idioma deseado.
6. **Seerr** — el front donde pedís contenido. **Ya lo configura el orquestador**
   (paso 12): lo enlaza con Jellyfin y con Radarr/Sonarr solo (ver Paso 6.7).

> El detalle contraintuitivo: como qBittorrent comparte la pila de red de
> gluetun, el resto de los servicios lo alcanzan como **`gluetun:8080`**, no
> como `qbittorrent:8080`.

---

## Paso 5 — Recyclarr (calidad automática)

**Ya lo configura el orquestador** (paso 10). Aplica las TRaSH Guides a Radarr y
Sonarr: los tamaños por calidad, el quality profile y los custom formats con sus
puntajes.

Qué perfil se aplica sale de `configs/services_setup.conf`, en `.recyclarr`:

| Servicio | Perfil por defecto |
|----------|--------------------|
| Radarr   | HD Bluray + WEB    |
| Sonarr   | WEB-1080p          |

Para cambiarlo necesitás el `trash_id` del perfil que quieras. La lista sale de
los templates oficiales que el propio contenedor cachea:

```bash
grep -m1 -H "trash_id" /srv/config/recyclarr/resources/config-templates/git/official/radarr/templates/*.yml
```

Pegás el `trash_id` y el nombre en `services_setup.conf` y volvés a correr
`sudo ./configure-stack.py`.

> ⚠️ **Cambiar el quality profile mueve tu biblioteca.** Radarr y Sonarr
> re-evalúan lo que ya tenés contra el cutoff nuevo y encolan upgrades de todo lo
> que quede por debajo. En una biblioteca grande eso son muchas descargas.

El contenedor además corre un sync solo una vez por día (`CRON_SCHEDULE=@daily`),
así que los cambios del guide llegan sin que hagas nada. El paso del orquestador
existe para aplicarlo en el momento y no esperar hasta 24 hs.

Para ver qué haría sin aplicar nada:

```bash
docker exec recyclarr recyclarr sync --preview
```

---

## Paso 6 — Acceso a los paneles (por Tailscale)

Desde cualquier dispositivo en tu tailnet, usá la IP Tailscale de la VPS
(`100.x.x.x`) con cada puerto:

| Servicio    | Puerto |
|-------------|--------|
| qBittorrent | 8080   |
| SABnzbd     | 8081   |
| Prowlarr    | 9696   |
| Radarr      | 7878   |
| Sonarr      | 8989   |
| Bazarr      | 6767   |
| Seerr       | 5055   |
| Tdarr       | 8265   |
| Jellyfin    | 8096   |

Ej: `http://100.x.x.x:7878` para Radarr.

Lo único que sale a internet es el **puerto 80**, donde escucha nginx y proxea
Jellyfin. El `8096` de la tabla es un atajo para vos por el tailnet (entrás al
dashboard sin pasar por el geo-bloqueo); desde internet ese puerto no existe.

**Firewall:** lo configura el paso 1 del orquestador (UFW: solo SSH, Tailscale
y el 80). Pero el que realmente tapa los paneles **no es UFW**: son los binds a
`${TAILSCALE_IP}` del compose. Docker publica los puertos escribiendo sus
propias reglas de DNAT, que se evalúan **antes** que las cadenas de UFW, así que
un servicio publicado en `0.0.0.0` quedaría expuesto aunque UFW diga `deny`.

---

## Paso 6.5 — Jellyfin: lo que configura el orquestador y lo que no

El **paso 11** deja puestos el asistente inicial, las bibliotecas, los plugins,
el borrado de segmentos y el aviso de Radarr/Sonarr al importar. Lo único que
tenés que cargar en el `.env` son **`JELLYFIN_USER` y `JELLYFIN_PASSWORD`** (tu
cuenta admin):

```bash
JELLYFIN_USER=manu
JELLYFIN_PASSWORD=...
JELLYFIN_API_KEY=          # se escribe sola, dejala vacía
```

La API key **no se puede sacar de ningún archivo**: Jellyfin las crea a pedido y
las guarda hasheadas, y crear una requiere estar autenticado (`POST /Auth/Keys`
pide elevación). Así que el script se loguea, crea la key, y la escribe en el
`.env` — igual que hace el paso 1 con `TAILSCALE_IP`.

De la segunda corrida en adelante entra por la key y ni se autentica. Si la
borrás del Dashboard, detecta que no sirve y genera otra. En el Dashboard
aparece como **`arrsuit-orchestrator`**.

> El `.env` pasa a tener tu contraseña de admin, así que el script le pone
> permisos **600** al escribir la key. Venía en 644, o sea legible por cualquier
> usuario del host.

Sin esas credenciales el paso se saltea con un aviso y el resto del stack
funciona igual.

### Las bibliotecas

**El asistente inicial no crea ninguna**: termina con el servidor vacío, y
Jellyfin tampoco las descubre solo por más que Radarr y Sonarr estén importando
en `/data`. Las crea el paso 11 desde `.jellyfin.libraries`:

```json
"libraries": [
    { "name": "Movies", "type": "movies",  "path": "/data/movies" },
    { "name": "Series", "type": "tvshows", "path": "/data/series" }
]
```

`path` es la ruta **que ve Jellyfin** (el mismo bind que usan Radarr y Sonarr),
así que se escribe igual que los `rootFolder` de ellos. El `type` es el de
Jellyfin: `movies`, `tvshows`, `music`, `boxsets`. Es idempotente por nombre:
si ya existe, no la duplica ni la toca.

> Van **antes** que Seerr (paso 12), que sincroniza justamente estas bibliotecas
> para saber qué hay descargado.

### Los plugins (Moonfin)

El paso 11 los instala desde `.jellyfin.plugins`. Cada entrada trae su
repositorio, porque Jellyfin solo instala desde un manifest que tenga cargado:

```json
"plugins": [
    {
        "name": "Moonbase",
        "repositoryName": "Moonfin",
        "repository": "https://raw.githubusercontent.com/Moonfin-Client/Plugin/refs/heads/master/manifest.json"
    }
]
```

> **El plugin se llama `Moonbase`, no `Moonfin`.** Moonfin es el cliente;
> Moonbase es su plugin *companion* del lado del servidor. El `name` tiene que
> ser **el del catálogo** (`Moonbase`), porque es lo que el script le pide a
> Jellyfin: con el nombre del proyecto la instalación devuelve 404.

Aparte del sync de ajustes y el theming, Moonbase hospeda la web de Moonfin en
`/Moonfin/Web/` y trae un **proxy de Seerr con single sign-on**. Eso es lo que
permite pedir contenido desde la tele o el celular **sin exponer Seerr**: entrás
por Jellyfin, que ya sale a internet por nginx.

### La integración con Seerr (la prende el paso 12)

Viene apagada de fábrica (`SeerrEnabled: false`); el paso 12 la prende sola, con
las dos URLs **internas** de la red `media` — las dos puntas son conversaciones
entre contenedores, ninguna la abre un navegador:

| Clave | Valor | Para qué |
|-------|-------|----------|
| `SeerrEnabled` | `true` | prende el proxy |
| `SeerrUrl` | `http://seerr:5055` | Jellyfin le pega a Seerr |
| `PublicServerUrl` | `http://jellyfin:8096` | Seerr le pega de vuelta al webhook |

`PublicServerUrl` se pone explícito porque si se deja vacío Moonbase **adivina**:
prueba la URL publicada de Jellyfin, después una IP de LAN, y al final loopback
— que desde el contenedor de Seerr no resuelve a nada.

La config del plugin se lee y se reescribe **entera**: ese endpoint deserializa
el body en el objeto de configuración, así que mandar sólo nuestras claves
volvería todo lo demás a su default (incluido el secreto del webhook, que
Moonbase genera solo la primera vez).

> **Queda un paso manual, y es por diseño:** el single sign-on guarda una sesión
> de Seerr **por usuario**, así que cada uno entra una vez desde la app de
> Moonfin. Hasta que eso pasa, `/Moonfin/Seerr/Status` dice
> `authenticated: false`. El registro automático del webhook de Seerr también
> espera a que haya una sesión de admin.

Detalles que el script maneja y conviene saber:

- **El repo se agrega sin pisar el oficial.** El `POST /Repositories` de Jellyfin
  **reemplaza** la lista entera en vez de agregar: mandar solo el repo nuevo te
  deja sin el catálogo oficial, que es de donde sale todo lo demás. El script lee
  la lista y la manda completa.
- **Reinicia Jellyfin al terminar.** Un plugin recién instalado queda inerte
  hasta que eso pasa. Reinicia el **proceso**, no el contenedor: en la imagen de
  LinuxServer lo vuelve a levantar s6 en el lugar (vuelve en unos segundos). Por
  eso los plugins van al final del paso.
- **La espera es por disco, no por la API.** Un plugin recién bajado aparece en
  `/Plugins` sólo si el servidor pudo cargarlo en caliente; Moonbase no puede
  (su `targetAbi` es de una versión anterior) y queda invisible ahí hasta el
  reinicio, aunque la instalación haya salido perfecta. El script espera el
  `meta.json` que Jellyfin escribe al final del desempaquetado.
- **Verificá el estado final.** Jellyfin instala un plugin aunque su `targetAbi`
  sea viejo, y el problema recién aparece al cargarlo. El script imprime el
  estado de cada uno: **`Active`** es el único que significa que anduvo
  (`Malfunctioned` o `NotSupported` = instalado y muerto). Moonbase 2.2.0.0
  declara `targetAbi` 10.10 y aun así queda `Active` en Jellyfin 12.

### Aviso de Radarr/Sonarr al importar

Jellyfin descubre archivos nuevos mirando el filesystem, y ese monitor puede
agarrar la carpeta **a mitad de una importación**. El resultado es una serie que
aparece con episodios sin archivo asociado y un *"unable to find a valid media
source to play"* al darle play.

Con el aviso puesto, el que avisa es el que sabe que terminó de escribir. Se
registra en Radarr y Sonarr como conector *Emby / Jellyfin* con **Update
Library**, y dispara en import, upgrade, rename y borrado.

> El **Real Time Monitoring** de Jellyfin queda encendido igual: son
> complementarios. El aviso cubre las importaciones; el monitor, los archivos que
> aparecen por fuera de Radarr/Sonarr (algo que copiaste a mano).

### Borrado de segmentos de transcode

Jellyfin escribe los `.ts` del transcode en su cache y por defecto los deja
hasta terminar. Si el cliente corta a la mitad, quedan huérfanos acumulándose.

Se configura en `.jellyfin.transcoding` de `services_setup.conf`:

| Clave | Default | Qué hace |
|-------|---------|----------|
| `deleteSegments` | `true` | borra cada segmento apenas el cliente lo bajó |
| `keepSegmentsSeconds` | `3600` | retención máxima (Jellyfin usa 720 por defecto) |

Es la limpieza nativa de Jellyfin: sabe qué sesiones están activas, así que no
hay riesgo de que borre algo que se está reproduciendo. Por eso no hace falta un
cron aparte.

> Necesita Jellyfin **10.10 o superior**. En versiones anteriores esas opciones
> no existen y el paso avisa y sigue.

---

## Paso 6.6 — `known proxies` (esto sí es manual)

**No es opcional si querés que fail2ban sirva de algo.**

Jellyfin loguea la IP de quien le pega, que ahora es el contenedor de nginx. Hay
que decirle que confíe en el header `X-Forwarded-For`:

> Jellyfin → Dashboard → Networking → **Known proxies**: `172.20.0.0/16`

Sin eso, los logs muestran siempre la IP de nginx y fail2ban termina baneando al
proxy en vez de al atacante.

Para verificar el baneo, con 4 logins fallidos a propósito:

```bash
docker exec fail2ban fail2ban-client status jellyfin
```

Y si no matchea nada, lo primero a revisar es el regex — cambia entre versiones
de Jellyfin (detalle en [configs/README.md](configs/README.md)):

```bash
docker exec fail2ban fail2ban-regex \
    /remotelogs/jellyfin/<archivo>.log /config/fail2ban/filter.d/jellyfin.conf
```

---

## Paso 6.7 — Seerr: el front de pedidos

**Ya lo configura el orquestador** (paso 12). No hay nada que cargar en el
`.env`: usa las **mismas credenciales de Jellyfin** que el paso 11.

> **Se llama Seerr, no Jellyseerr.** Overseerr y Jellyseerr se fusionaron en un
> solo proyecto (`ghcr.io/seerr-team/seerr`) y las imágenes viejas quedaron sin
> mantenimiento. La API sigue siendo `/api/v1/*`, así que la documentación vieja
> *parece* válida y no lo es.

Qué deja hecho:

| Qué | Cómo |
|-----|------|
| Usuario admin | El mismo de Jellyfin: entrás con esas credenciales |
| Enlace con Jellyfin | `http://jellyfin:8096`, por la red interna |
| Librerías | Las sincroniza y las prende todas |
| Radarr / Sonarr | Como destino de los pedidos, con el quality profile de Recyclarr |

### Por qué el admin se crea logueándose contra Jellyfin

Seerr genera una API key sola en el primer arranque y la deja en su
`settings.json`, pero **esa key no alcanza para configurarlo de cero**: el
middleware que la valida la traduce al *usuario 1*, y en una instalación nueva
ese usuario todavía no existe. Resultado: la key resuelve a nadie y todos los
endpoints de settings contestan **403**.

El único endpoint abierto es `POST /auth/jellyfin`, y está abierto justo para
esto: si la base no tiene usuarios, crea al primero como admin. De paso deja
enlazado Jellyfin, porque para loguearte necesita saber a qué servidor pegarle.
Una sola llamada resuelve las dos cosas; de ahí en adelante va todo por la API
key. Seerr además se crea su propia key **del lado de Jellyfin**, que aparece en
el Dashboard como `Seerr`.

Por eso, sin `JELLYFIN_USER` y `JELLYFIN_PASSWORD` el paso se saltea con un
aviso. El usuario tiene que ser **administrador en Jellyfin**: si no lo es, la
creación falla con 403.

### El quality profile sale de Recyclarr

Seerr guarda el perfil por **ID**, no por nombre, y esos IDs son de cada
instancia de Radarr/Sonarr: hay que preguntárselos. El script usa el endpoint
`/test` (que además de validar la conexión devuelve perfiles y root folders) y
elige **el mismo perfil que aplica Recyclarr** — el de `.recyclarr` en
`services_setup.conf`. Sin eso, Seerr pediría con un perfil que nadie afina.

Si el perfil no está (típicamente porque el paso de Recyclarr no corrió), avisa
y cae al primero de la lista.

### Lo configurable

En `.seerr` de `services_setup.conf`:

| Clave | Default | Qué hace |
|-------|---------|----------|
| `adminEmail` | `""` | Email del admin. Vacío = usa el usuario de Jellyfin |
| `radarr.minimumAvailability` | `released` | Cuándo Radarr empieza a buscar una peli pedida |
| `sonarr.seasonFolders` | `true` | Carpeta por temporada en las series pedidas |

### Lo que no hace

- **No lo expone a internet.** Queda solo en el tailnet, como el resto de los
  paneles: lo único que sale por el puerto 80 es Jellyfin. Si querés que tus
  usuarios pidan contenido sin entrar a la tailnet, hay que agregarle un
  `server` en nginx — es una decisión de exposición, no un olvido.
- **No toca las librerías si ya elegiste vos.** Si prendiste o apagaste alguna a
  mano, las corridas siguientes respetan esa elección.

---

## Paso 7 — Tdarr: SOLO audio DTS -> AC3/EAC3

Tu Samsung Tizen (BED7000) reproduce HEVC y H.264 4K nativo, así que **no
reencodees video**. Lo único que te fuerza transcode en vivo es el audio DTS
(Samsung sacó el decodificador DTS) y los subtítulos bitmap.

En Tdarr:
1. Creá una **Library** apuntando a `/data/movies` y otra a `/data/series`.
2. En los **plugins de esa library**, NO uses plugins de transcode de video.
   Usá un flujo tipo:
   - Plugin de audio: *"Migz - Convert audio to AC3/EAC3 if source is DTS"*
     (o el equivalente en Tdarr flows). Dejá el video en **copy/passthrough**.
3. Con eso, Tdarr recorre la biblioteca y sólo toca el audio problemático.
   Liviano de CPU (transcodear audio no cuesta casi nada).

> Los subtítulos bitmap (PGS/DVD) NO se arreglan con Tdarr: se manejan en el
> cliente. En la app de Jellyfin de la tele, no actives subs bitmap por
> defecto — si necesitás español, que Bazarr te baje subs de texto (SRT).

---

## Notas finales

- **Backups:** todo el estado vive en `/srv/config`. Un backup periódico de esa
  carpeta te salva de rehacer todo.
- **Actualizar imágenes:**
  ```bash
  docker compose pull && docker compose up -d
  ```
- **Editar la config de nginx o fail2ban:** se toca en `configs/` y se vuelve a
  correr `sudo ./configure-stack.py`, que las copia a `/srv/config` y recarga
  los contenedores si cambiaron. No editar `/srv/config` a mano: la próxima
  corrida lo pisa.
- **Levantar el compose a mano** (sin el orquestador) deja afuera el contenedor
  `geoipupdate`, que vive detrás del perfil `geo`:
  ```bash
  docker compose --profile geo up -d     # si tenés credenciales de MaxMind
  ```
  Está así a propósito: sin credenciales esa imagen sale con error y quedaría
  reiniciándose para siempre.
- **Downloads y biblioteca en el mismo filesystem:** no muevas `downloads/`
  fuera de `/srv/media` o perdés los hardlinks.
- **Jellyfin:** apuntá sus bibliotecas a `/data/movies` y `/data/series`, que
  son las rutas **dentro del contenedor**. El compose monta `/srv/media` como
  `/data`, así que Jellyfin no ve las rutas del host. Si le ponés
  `/srv/media/...` la biblioteca escanea cero archivos y no reporta ningún
  error: simplemente no aparece nada.
