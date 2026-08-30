# Guía de puesta en marcha — media stack

Todo asume que ya tenés Docker + Docker Compose en la VPS y Tailscale corriendo.
Los paneles NO se exponen a internet: se acceden por la IP de tu tailnet.

---

## Paso 0 — Estructura de carpetas

Creá las carpetas de datos antes de levantar nada:

```bash
sudo mkdir -p /srv/config
sudo mkdir -p /srv/media/{downloads,movies,tv}
# que tu usuario (PUID/PGID 1000) sea dueño:
sudo chown -R 1000:1000 /srv
```

Estructura resultante:

```
/srv
├── config/          # config de cada servicio (persistente)
└── media/
    ├── downloads/   # qBittorrent baja acá
    ├── movies/      # Radarr organiza acá  -> biblioteca "Películas" de Jellyfin
    └── tv/          # Sonarr organiza acá  -> biblioteca "Series" de Jellyfin
```

**Importante (hardlinks):** todos los servicios montan `/srv/media` como `/data`.
Esto permite que Radarr/Sonarr muevan de `downloads/` a `movies/`/`tv/` con
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
   cp .env.example .env
   nano .env   # pegá la private key en WIREGUARD_PRIVATE_KEY
   ```

> Si elegiste otro país, cambiá `SERVER_COUNTRIES=Switzerland` en el compose.

---

## Paso 2 — Levantar el stack

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

Ej: `http://100.x.x.x:7878` para Radarr.

**Firewall:** asegurate de que la VPS NO tenga estos puertos abiertos al mundo.
Con ufw, algo como:
```bash
sudo ufw allow in on tailscale0   # todo lo que entre por Tailscale, OK
sudo ufw allow 22/tcp             # SSH (o cerralo también si entrás por Tailscale)
sudo ufw enable
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
- **Downloads y biblioteca en el mismo filesystem:** no muevas `downloads/`
  fuera de `/srv/media` o perdés los hardlinks.
- **Jellyfin:** apuntá sus bibliotecas a `/srv/media/movies` y `/srv/media/tv`
  (ajustá el path según cómo tengas montado Jellyfin en su propio contenedor).
