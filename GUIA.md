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
6. **Jellyseerr** — conectá con Jellyfin y con Radarr/Sonarr. Es el front donde
   pedís contenido.

> El detalle contraintuitivo: como qBittorrent comparte la pila de red de
> gluetun, el resto de los servicios lo alcanzan como **`gluetun:8080`**, no
> como `qbittorrent:8080`.

---

## Paso 5 — Recyclarr (calidad automática)

Recyclarr aplica los custom formats de TRaSH Guides a Radarr/Sonarr.

1. Generá una config base:
   ```bash
   docker exec recyclarr recyclarr config create
   ```
2. Editá `/srv/config/recyclarr/recyclarr.yml`: pegá las API keys de Radarr y
   Sonarr (las sacás de *Settings → General* en cada uno) y elegí los perfiles
   de calidad que quieras (ej: HD Bluray + WEB).
3. Corré una sync manual para probar:
   ```bash
   docker exec recyclarr recyclarr sync
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
| Jellyseerr  | 5055   |
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

## Paso 6.5 — Jellyfin detrás del proxy: `known proxies`

**Esto no es opcional si querés que fail2ban sirva de algo.**

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
