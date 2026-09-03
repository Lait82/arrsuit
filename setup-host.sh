#!/usr/bin/env bash
# =========================================================================
#  setup-host.sh - Configura la capa de host del media stack
#  Tailscale (tailnet + IP en el .env) + UFW (firewall)
#
#  Esto es TODO lo que queda fuera de Docker, y queda fuera porque no puede
#  estar adentro: Tailscale crea una interfaz de red del host y UFW son las
#  reglas del host. nginx, el geo-bloqueo y fail2ban se mudaron al compose
#  (los configura configure-stack.py).
#
#  Idempotente: se puede correr varias veces.
#
#  ORDEN: este script primero, configure-stack.py despues. El compose necesita
#  la TAILSCALE_IP que este script escribe en el .env.
#
#  >>> ANTES DE CORRER: copiar env.example a .env y completarlo <<<
#      cp env.example .env && nano .env
# =========================================================================
set -euo pipefail

# Ruta a los archivos de config (por defecto, junto a este script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# spin "Mensaje" comando args...
# Corre el comando en background con un spinner al lado. Preserva el exit code
# y captura la salida; si el comando falla, la muestra antes de abortar.
# Si no hay TTY (log a archivo, CI), corre el comando directo sin animacion.
spin() {
    local msg="$1"; shift
    if [[ ! -t 1 ]]; then
        echo "  $msg..."
        "$@"
        return $?
    fi
    local tmp; tmp="$(mktemp)"
    "$@" >"$tmp" 2>&1 &
    local pid=$!
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    # tput civis/cnorm: ocultar/mostrar cursor (si tput existe)
    command -v tput >/dev/null && tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#frames} ))
        printf '\r  \033[1;36m%s\033[0m %s' "${frames:$i:1}" "$msg"
        sleep 0.1
    done
    wait "$pid"; local rc=$?
    command -v tput >/dev/null && tput cnorm 2>/dev/null || true
    if [[ $rc -eq 0 ]]; then
        printf '\r  \033[1;32m✓\033[0m %s\n' "$msg"
    else
        printf '\r  \033[1;31m✗\033[0m %s\n' "$msg"
        cat "$tmp"
    fi
    rm -f "$tmp"
    return $rc
}

[[ $EUID -eq 0 ]] || die "Corré con sudo."

# =========================================================================
#  Cargar variables desde .env
# =========================================================================
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE. Copiá .env.example a .env y completalo:  cp .env.example .env"

# set -a: exporta automaticamente todo lo que se define al sourcear el .env
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ----------------------------- CONFIG ------------------------------------
# Valores por defecto si el .env no los define (SSH_PORT es opcional).
# La IP de Tailscale NO se pone a mano; el script la deriva sola.
# Las credenciales de MaxMind ya no se leen aca: las consume el compose
# (contenedor geoipupdate) y configure-stack.py.
SSH_PORT="${SSH_PORT:-22}"
# -------------------------------------------------------------------------

# =========================================================================
log "1/4 Instalando paquetes"
# =========================================================================
# Solo ufw: nginx, geoipupdate y fail2ban ahora son contenedores.
export DEBIAN_FRONTEND=noninteractive
spin "Actualizando indice de paquetes (apt update)" \
    apt-get update -qq
spin "Instalando ufw" \
    apt-get install -y -qq ufw

# =========================================================================
log "2/4 Migracion: apagando nginx y fail2ban del host"
# =========================================================================
# Si venis de la version vieja de este script, nginx esta instalado en el host
# y tiene tomado el puerto 80. El contenedor nginx no va a poder bindearlo y el
# compose falla con "address already in use". fail2ban no choca puerto, pero
# tenerlo duplicado significa dos daemons leyendo el mismo log y peleandose las
# reglas de iptables.
#
# Se desactivan, NO se desinstalan: si algo sale mal, un 'systemctl enable
# --now nginx' te devuelve lo que tenias.
for svc in nginx fail2ban; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1 || systemctl is-active "$svc" >/dev/null 2>&1; then
        warn "$svc corre en el host: lo apago para que lo tome el contenedor."
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
        log "  $svc desactivado (para revertir: systemctl enable --now $svc)"
    fi
done

# El cron de geoipupdate del host tampoco tiene sentido ya: la base la baja el
# contenedor geoipupdate a su propio volumen.
rm -f /etc/cron.weekly/geoipupdate

# =========================================================================
log "3/4 Tailscale: instalacion y autenticacion"
# =========================================================================
if ! command -v tailscale >/dev/null 2>&1; then
    spin "Instalando Tailscale" \
        bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
else
    log "Tailscale ya instalado, se saltea."
fi

# Levantar el servicio (idempotente)
systemctl enable --now tailscaled

# Verificar si ya esta autenticado. Si no, frenar aca: 'tailscale up' necesita
# que abras una URL en el navegador, no se puede automatizar sin auth key.
if ! tailscale status >/dev/null 2>&1; then
    warn "Tailscale instalado pero SIN autenticar."
    echo ""
    echo "  Corré esto en otra terminal y autenticá en el navegador:"
    echo "      sudo tailscale up"
    echo ""
    echo "  (o con SSH por Tailscale, recomendado):"
    echo "      sudo tailscale up --ssh"
    echo ""
    echo "  Cuando termines, volvé a correr este script."
    die "Autenticá Tailscale y reintentá."
fi

# Derivar la IP de Tailscale automaticamente
TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[[ -n "$TAILSCALE_IP" ]] || die "No pude obtener la IP de Tailscale. ¿Autenticaste con 'tailscale up'?"
log "IP de Tailscale detectada: $TAILSCALE_IP"

# Persistir la IP en el .env para que docker-compose la lea como ${TAILSCALE_IP}.
# Idempotente: reemplaza la linea si ya existe, la agrega si no.
if grep -q '^TAILSCALE_IP=' "$ENV_FILE"; then
    sed -i "s|^TAILSCALE_IP=.*|TAILSCALE_IP=$TAILSCALE_IP|" "$ENV_FILE"
else
    printf '\n# IP de Tailscale (escrita automaticamente por setup-host.sh)\nTAILSCALE_IP=%s\n' "$TAILSCALE_IP" >> "$ENV_FILE"
fi
log "IP escrita en $ENV_FILE (TAILSCALE_IP=$TAILSCALE_IP)"

# El docker-compose.yml debe usar ${TAILSCALE_IP} en los binds de los *arr.
# Recorda hacer 'docker compose up -d' desde la carpeta que tiene este .env,
# o pasarle --env-file, para que la variable se resuelva.

# =========================================================================
log "4/4 UFW: firewall"
# =========================================================================
# ORDEN IMPORTANTE: permitir SSH y Tailscale ANTES de enable, o te lockeas.
# Guarda: la interfaz tailscale0 tiene que existir (Tailscale ya levantado).
if ! ip link show tailscale0 >/dev/null 2>&1; then
    die "No existe la interfaz tailscale0. Tailscale no esta levantado; abortando ANTES de tocar el firewall para no lockearte."
fi
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'Tailscale interface'
ufw allow "$SSH_PORT"/tcp   comment 'SSH'
ufw allow 41641/udp         comment 'Tailscale'
ufw allow 80/tcp            comment 'Jellyfin via nginx'
ufw --force enable

# El 80/tcp de arriba es mas declarativo que efectivo: Docker publica el puerto
# escribiendo sus propias reglas de DNAT, que se evaluan ANTES que las cadenas
# de UFW. O sea que el 80 del contenedor nginx queda abierto lo pongas o no.
# La regla queda igual para que 'ufw status' cuente la verdad de que puertos se
# supone que estan abiertos.
#
# El corolario es el de siempre en este stack: lo que protege a los paneles NO
# es UFW sino el bind a ${TAILSCALE_IP} en el compose. Un servicio publicado en
# 0.0.0.0 estaria expuesto aunque UFW diga deny.

# =========================================================================
log "Listo. Ahora corré configure-stack.py:"
# =========================================================================
cat <<EOF

      sudo ./configure-stack.py

  Ese script levanta el compose (incluido nginx, fail2ban y el geo-bloqueo)
  y configura los servicios. Este de aca solo dejo el host listo.

  Verificaciones para despues, desde el celu con DATOS MOVILES:

  [ ] http://<IP-VPS>/         -> entra Jellyfin (o 403 si el geo esta activo
                                  y estas fuera de los paises permitidos)
  [ ] http://<IP-VPS>:9696/    -> NO responde (Prowlarr, solo Tailscale)
  [ ] http://<IP-VPS>:7878/    -> NO responde (Radarr, solo Tailscale)
  [ ] http://<IP-VPS>:8096/    -> NO responde (Jellyfin directo, solo Tailscale)

      Si alguno responde, revisá que los binds a $TAILSCALE_IP esten en el
      compose: es lo unico que los tapa, UFW no alcanza contra Docker.

EOF
log "setup-host.sh finalizado."
