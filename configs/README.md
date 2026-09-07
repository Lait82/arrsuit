# Media stack — la capa que da a internet

Este directorio tiene la config de **nginx** (reverse proxy + geo-bloqueo +
rate limit) y de **fail2ban** (baneo de IPs). Los dos corren **en el compose**,
no instalados en el host: los archivos de acá se copian a `/srv/config`, que es
lo que los contenedores montan.

Quién hace qué:

| Pieza | Dónde corre | Paso del orquestador |
|-------|-------------|----------------------|
| Tailscale, UFW | host | 1 — `pylib/apps/host.py` |
| nginx, fail2ban, geoipupdate | contenedores | 3 — `pylib/apps/proxy.py` |
| Jellyfin y el resto del stack | contenedores | 4 en adelante |

Todo lo configura **`configure-stack.py`**, un solo comando. Tailscale y UFW
quedan afuera de Docker porque no pueden estar adentro (uno crea una interfaz de
red del host, el otro son las reglas del host), pero igual están orquestados
como el primer paso: es ahí donde se descubre la IP del tailnet que el compose
necesita para bindear los paneles.

## Modelo de amenaza

La decisión de diseño detrás de todo esto:

- **Jellyfin** es el **único** servicio expuesto a internet, porque la tele
  (Samsung Tizen) no puede entrar por Tailscale. Y sale siempre **a través de
  nginx**: su propio puerto solo escucha en la IP de Tailscale.
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
  subdominio a la IP y usar la variante SWAG de la imagen de nginx, que trae
  certbot.

## Las tres capas de defensa

1. **Geo-bloqueo (nginx + GeoIP2):** solo pasan las IPs de los países de
   `.nginx.geoBlock.countries` (`services_setup.conf`). Saca de encima el grueso
   del escaneo automatizado, que viene de datacenters en otros países. Un 403
   antes de que la request llegue a Jellyfin.
2. **Rate limit del login (nginx):** limita los intentos contra el endpoint de
   autenticación (10/min por IP). Solo el login — el streaming machaca otros
   endpoints y no debe limitarse.
3. **fail2ban:** lee los logs de Jellyfin y banea a nivel de firewall del host las
   IPs que fallan el login repetidamente (4 fallos en 1h → ban de 24h). Es un
   rate-limiter inteligente: banea por *fallo de auth*, no por volumen.

Y por debajo de todo, **UFW** cierra el host: solo entra SSH y la interfaz de
Tailscale.

## Archivos

```
configs/
├── services_setup.conf        # config editable del stack (incl. países del geo)
├── nginx/
│   ├── site-confs/
│   │   └── default.conf       # server block: reverse proxy + geo + rate limit
│   ├── proxy_jellyfin.conf    # headers de proxy compartidos (incl. WebSockets)
│   ├── geoip-on.conf.tmpl     # bloque geoip2 + map  (geo ACTIVADO)
│   └── geoip-off.conf         # map que deja pasar todo (geo DESACTIVADO)
└── fail2ban/
    ├── filter.d/jellyfin.conf # filtro (regex de login fallido)
    └── jail.d/jellyfin.local  # jail (umbrales de baneo + cadena de iptables)
```

`configure-stack.py` los copia a `/srv/config` en cada corrida y, si cambiaron,
recarga nginx y reinicia fail2ban. Editar acá y volver a correr el script es el
flujo normal; no hay que tocar `/srv/config` a mano.

## Los dos detalles que hay que entender

### 1. fail2ban banea en `DOCKER-USER`, no en `INPUT`

Con nginx corriendo en un contenedor, el tráfico de internet **no termina en el
host**: Docker lo hace DNAT y lo reenvía al contenedor, así que atraviesa
`FORWARD` y nunca toca `INPUT`. Un ban en `INPUT` (el default de fail2ban) se
aplicaría a una cadena por la que el atacante no pasa: no banea nada.

`DOCKER-USER` es la cadena que Docker deja libre justo en ese camino. Está
seteada en `fail2ban/jail.d/jellyfin.local`. **Si alguna vez movés nginx de
vuelta al host, hay que volver a `INPUT`.**

Por lo mismo el `banaction` es `iptables-allports` y no `iptables-multiport`: en
`DOCKER-USER` el paquete ya viene con el puerto traducido al del contenedor, así
que filtrar por `http` sería frágil.

### 2. Sin `known proxy` en Jellyfin, fail2ban es inútil

Jellyfin loguea la IP de quien le pega, que ahora es el contenedor de nginx. Hay
que decirle que confíe en el `X-Forwarded-For`:

> Jellyfin → Dashboard → Networking → **Known proxies**: `172.20.0.0/16`

Sin eso, fail2ban ve siempre la IP de nginx y termina baneando al proxy.

## Cómo se decide si el geo-bloqueo se activa

`configure-stack.py` mira el `.env`:

- **Con** `MAXMIND_ACCOUNT_ID` + `MAXMIND_LICENSE_KEY` → renderiza
  `geoip-on.conf.tmpl` con los países del `services_setup.conf`, baja la base
  GeoLite2 al volumen `geoip` y levanta el contenedor `geoipupdate` (perfil
  `geo` del compose) para mantenerla al día una vez por semana.
- **Sin** credenciales → copia `geoip-off.conf`, que define `$allowed_country`
  fijo en `yes`. El stack levanta igual, sin geo, y avisa.

Son dos archivos y no un `sed` sobre uno solo porque el server block usa
`$allowed_country` siempre, y nginx **no arranca** con una variable que nadie
define: aún con el geo apagado hace falta un `map` que la fije.

Cuenta gratis para las credenciales:
[MaxMind GeoLite2](https://www.maxmind.com/en/geolite2/signup).

## Verificaciones post-instalación

- [ ] Desde **datos móviles** (fuera de tu red), `http://<IP-VPS>/` entra a
      Jellyfin; los puertos de los *arr (9696, 7878, 8989…) y el 8096 de
      Jellyfin **no** responden.
- [ ] Si alguno responde pese a UFW: es el problema conocido de **Docker
      saltándose UFW**. Se resuelve con los binds explícitos a la IP de Tailscale
      en el compose (ya están puestos), que son inmunes a eso.
- [ ] Known proxies en Jellyfin (ver arriba).
- [ ] Validar el regex de fail2ban contra tus logs:
      ```bash
      docker exec fail2ban fail2ban-regex \
          /remotelogs/jellyfin/<archivo>.log \
          /config/fail2ban/filter.d/jellyfin.conf
      ```
      El formato del mensaje de login fallido cambia entre versiones de Jellyfin;
      si no matchea, ajustá el `failregex`.
- [ ] Probar el baneo: 4 logins fallidos a propósito y
      `docker exec fail2ban fail2ban-client status jellyfin`.

## Notas

- **El regex de fail2ban es lo más frágil.** Depende de la versión de Jellyfin.
  Es lo primero a revisar si los baneos no ocurren.
- **La imagen de nginx es la de LinuxServer y no la oficial** porque trae
  compilado `ngx_http_geoip2`, que la oficial no tiene. Sin ese módulo no hay
  geo-bloqueo posible.
- **Actualizar Jellyfin** con cierta frecuencia (`docker compose pull &&
  docker compose up -d`) es lo único que te cubre de CVEs conocidos, que a
  diferencia de un 0-day sí son evitables.
