# Media stack — capa de host

Este directorio configura **lo que corre en el host** (fuera de Docker) para el
media stack: el reverse proxy que expone Jellyfin a internet, el geo-bloqueo, el
baneo de IPs y el firewall. El `docker-compose.yml` (los contenedores) va aparte.

## Modelo de amenaza

La decisión de diseño detrás de todo esto:

- **Jellyfin** es el **único** servicio expuesto a internet, porque la tele
  (Samsung Tizen) no puede entrar por Tailscale.
- **Todo lo demás** (Prowlarr, Radarr, Sonarr, Bazarr, Jellyseerr, Tdarr,
  qBittorrent) queda **solo accesible por Tailscale**. Son los paneles que, si se
  filtran, comprometen el server; no tienen por qué salir a internet.
- El objetivo NO es defenderse de un atacante en la misma red ni de un 0-day de
  Jellyfin, sino del **ruido de fondo de internet**: bots que barren rangos de IP
  buscando logins y exploits genéricos. Contra eso, las tres capas de abajo cubren
  la enorme mayoría del riesgo real. Contra un 0-day, la única defensa es mantener
  Jellyfin actualizado (`docker compose pull`).
- **No hay TLS** (no hay dominio, es IP pelada). Consecuencia asumida: las
  credenciales viajan sin cifrar. Si algún día querés TLS, alcanza con apuntar un
  subdominio a la IP y correr `certbot --nginx`.

## Las tres capas de defensa

1. **Geo-bloqueo (nginx + GeoIP2):** solo pasan las IPs de Argentina. Saca de
   encima el grueso del escaneo automatizado, que viene de datacenters en otros
   países. Un 403 antes de que la request llegue a Jellyfin.
2. **Rate limit del login (nginx):** limita los intentos contra el endpoint de
   autenticación (10/min por IP). Solo el login — el streaming machaca otros
   endpoints y no debe limitarse.
3. **fail2ban:** lee los logs de Jellyfin y banea a nivel de firewall del host las
   IPs que fallan el login repetidamente (4 fallos en 1h → ban de 24h). Es un
   rate-limiter inteligente: banea por *fallo de auth*, no por volumen.

Y por debajo de todo, **UFW** cierra el host: solo entra SSH, la interfaz de
Tailscale y el puerto 80 (Jellyfin vía nginx).

## Archivos

```
host-setup/
├── setup-host.sh              # script idempotente que instala y configura todo
├── nginx/
│   ├── jellyfin               # server block: reverse proxy + geo + rate limit
│   ├── proxy_jellyfin.conf    # headers de proxy compartidos (incl. WebSockets)
│   └── geoip2-snippet.conf    # bloque geoip2+map (se inserta en nginx.conf)
├── fail2ban/
│   ├── jellyfin.conf          # filtro (regex de login fallido)
│   └── jellyfin.local         # jail (umbrales de baneo)
└── README.md
```

## Uso

### 1. Prerequisitos

- Tailscale ya instalado y andando en la VPS. Sacá tu IP con `tailscale ip -4`.
- Cuenta gratis en [MaxMind](https://www.maxmind.com/en/geolite2/signup) para la
  base GeoLite2 (necesitás Account ID + License Key). Sin esto, el script se
  configura **sin** geo-bloqueo y avisa.
- El `docker-compose.yml` con los binds correctos (Jellyfin en `127.0.0.1:8096`,
  el resto en tu IP de Tailscale).

### 2. Editar la config del script

Abrí `setup-host.sh` y completá la sección `CONFIG`:

```bash
TAILSCALE_IP="100.x.y.z"          # tu IP de Tailscale (tailscale ip -4)
MAXMIND_ACCOUNT_ID="..."          # de tu cuenta MaxMind
MAXMIND_LICENSE_KEY="..."         # de tu cuenta MaxMind
SSH_PORT="22"                     # cambialo si usás otro
```

### 3. Correr

```bash
cd host-setup
sudo ./setup-host.sh
```

El script es **idempotente**: podés correrlo de nuevo sin duplicar reglas ni
romper nada. Qué hace, en orden:

1. Instala nginx, geoipupdate, fail2ban, ufw.
2. Baja la base de MaxMind y arma un cron semanal para mantenerla al día.
3. Coloca las configs de nginx, inserta el bloque geoip2 en `nginx.conf`, valida
   con `nginx -t` y recién ahí recarga. **Si `nginx -t` falla, no recarga.**
4. Instala el filtro y jail de fail2ban, y valida el regex contra los logs reales
   si ya existen.
5. Configura UFW **abriendo SSH y Tailscale ANTES** de activarlo (para no
   lockearte), y lo activa.
6. Imprime un checklist de verificaciones manuales.

### 4. Orden recomendado la primera vez

Para no debuggear diez cosas a la vez, conviene ir por partes:

1. Levantá el `docker compose up -d` primero (con los binds ya puestos).
2. Corré el script **sin** license key de MaxMind → nginx queda sin geo. Probá
   que la tele entra y reproduce por `http://<IP-VPS>/`.
3. Agregá la license key y volvé a correr el script → activa el geo-bloqueo.
   Confirmá que seguís entrando desde Argentina.
4. Probá el baneo: 4 logins fallidos a propósito y `sudo fail2ban-client status
   jellyfin`.

## Verificaciones post-instalación

- [ ] Desde **datos móviles** (fuera de tu red), `http://<IP-VPS>/` entra a
      Jellyfin; los puertos de los *arr (9696, 7878, 8989…) **no** responden.
- [ ] Si los *arr responden pese a UFW: es el problema conocido de **Docker
      saltándose UFW**. Se resuelve con los binds explícitos a la IP de Tailscale
      en el compose (ya están puestos), que son inmunes a eso.
- [ ] En Jellyfin → Dashboard → Networking → agregar `127.0.0.1` como known proxy,
      para que loguee la IP real del cliente (si no, fail2ban banea a `127.0.0.1`).
- [ ] Validar el regex de fail2ban contra tus logs:
      `sudo fail2ban-regex /srv/config/jellyfin/log/<archivo>.log /etc/fail2ban/filter.d/jellyfin.conf`
      El formato del mensaje de login fallido cambia entre versiones de Jellyfin;
      si no matchea, ajustá el `failregex`.

## Notas

- **El regex de fail2ban es lo más frágil.** Depende de la versión de Jellyfin.
  Es lo primero a revisar si los baneos no ocurren.
- **Sin known proxy en Jellyfin, fail2ban es inútil:** verá siempre la IP de
  nginx (`127.0.0.1`) en vez de la del atacante.
- **Actualizar Jellyfin** con cierta frecuencia (`docker compose pull &&
  docker compose up -d`) es lo único que te cubre de CVEs conocidos, que a
  diferencia de un 0-day sí son evitables.
- Si algún día agregás un dominio, corré `sudo certbot --nginx -d tudominio` y
  tenés TLS sin tocar el resto.
