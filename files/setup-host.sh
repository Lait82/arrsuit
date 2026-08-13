#!/usr/bin/env bash
# =========================================================================
#  setup-host.sh - Configura la capa de host del media stack
#  nginx (reverse proxy Jellyfin) + GeoIP2 (bloqueo AR) + fail2ban + UFW
#
#  Idempotente: se puede correr varias veces.
#  Correr con sudo desde la carpeta que contiene ./nginx y ./fail2ban.
#
#  >>> ANTES DE CORRER: copiar .env.example a .env y completarlo <<<
#      cp .env.example .env && nano .env
# =========================================================================
set -euo pipefail

# Ruta a los archivos de config (por defecto, junto a este script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

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
SSH_PORT="${SSH_PORT:-22}"
MAXMIND_ACCOUNT_ID="${MAXMIND_ACCOUNT_ID:-}"
MAXMIND_LICENSE_KEY="${MAXMIND_LICENSE_KEY:-}"
# -------------------------------------------------------------------------

# --- Guarda: avisar si las creds de MaxMind quedaron sin setear ---
if [[ -z "$MAXMIND_LICENSE_KEY" || "$MAXMIND_LICENSE_KEY" == "TU_LICENSE_KEY" ]]; then
    warn "MAXMIND_LICENSE_KEY sin setear en .env: se saltea el geo-bloqueo."
    MAXMIND_LICENSE_KEY=""
fi

# =========================================================================
log "1/7 Instalando paquetes"
# =========================================================================
apt-get update -qq
apt-get install -y -qq \
    nginx \
    libnginx-mod-http-geoip2 \
    geoipupdate \
    fail2ban \
    ufw

# =========================================================================
log "2/7 Tailscale: instalacion y autenticacion"
# =========================================================================
if ! command -v tailscale >/dev/null 2>&1; then
    log "Instalando Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
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

# Chequeo de coherencia: avisar si el compose todavia tiene el placeholder
if grep -rq "100.x.y.z" /srv 2>/dev/null; then
    warn "Ojo: encontré '100.x.y.z' en /srv. Reemplazá el placeholder en el compose por $TAILSCALE_IP."
fi

# =========================================================================
log "3/7 GeoIP2: bajando base de datos de MaxMind"
# =========================================================================
if [[ -n "$MAXMIND_LICENSE_KEY" ]]; then
    cat > /etc/GeoIP.conf <<EOF
AccountID $MAXMIND_ACCOUNT_ID
LicenseKey $MAXMIND_LICENSE_KEY
EditionIDs GeoLite2-Country
EOF
    geoipupdate || warn "geoipupdate fallo. Revisar credenciales de MaxMind."

    # Cron semanal para mantener la DB al dia
    cat > /etc/cron.weekly/geoipupdate <<'EOF'
#!/bin/sh
/usr/bin/geoipupdate
EOF
    chmod +x /etc/cron.weekly/geoipupdate
    GEO_ENABLED=1
else
    warn "Sin license key: nginx se configura SIN geo-bloqueo (comentado)."
    GEO_ENABLED=0
fi

# =========================================================================
log "4/7 nginx: colocando configs"
# =========================================================================
# Server block y headers de proxy
install -m 0644 "$SCRIPT_DIR/nginx/jellyfin"            /etc/nginx/sites-available/jellyfin
install -m 0644 "$SCRIPT_DIR/nginx/proxy_jellyfin.conf" /etc/nginx/proxy_jellyfin.conf

# Habilitar el sitio y sacar el default
ln -sf /etc/nginx/sites-available/jellyfin /etc/nginx/sites-enabled/jellyfin
rm -f /etc/nginx/sites-enabled/default

# Insertar el bloque geoip2 dentro de http { } si no esta ya
if [[ "$GEO_ENABLED" -eq 1 ]]; then
    if ! grep -q "geoip2 /usr/share/GeoIP" /etc/nginx/nginx.conf; then
        # Inserta el snippet justo despues de la linea 'http {'
        GEO_SNIPPET="$(sed 's/^/\t/' "$SCRIPT_DIR/nginx/geoip2-snippet.conf")"
        awk -v snip="$GEO_SNIPPET" '
            /^http[[:space:]]*{/ && !done { print; print snip; done=1; next }
            { print }
        ' /etc/nginx/nginx.conf > /etc/nginx/nginx.conf.tmp
        mv /etc/nginx/nginx.conf.tmp /etc/nginx/nginx.conf
        log "Bloque geoip2 insertado en nginx.conf"
    else
        log "Bloque geoip2 ya presente, se saltea"
    fi
else
    # Sin geo: comentar el 'if ($allowed_country = no)' para que nginx valide
    sed -i 's/^\(\s*\)\(if (\$allowed_country = no) {\)/\1# \2/' /etc/nginx/sites-available/jellyfin
    sed -i 's/^\(\s*\)\(return 403;\)\s*$/\1# \2/'               /etc/nginx/sites-available/jellyfin
    sed -i 's/^\(\s*\)\(}\s*# geo-close\)/\1# \2/'               /etc/nginx/sites-available/jellyfin || true
fi

# Validar sintaxis ANTES de recargar
if nginx -t; then
    systemctl reload nginx
    log "nginx recargado OK"
else
    die "nginx -t fallo. Revisar config antes de continuar. NO se recargo."
fi

# =========================================================================
log "5/7 fail2ban: filtro y jail de Jellyfin"
# =========================================================================
install -m 0644 "$SCRIPT_DIR/fail2ban/jellyfin.conf"  /etc/fail2ban/filter.d/jellyfin.conf
install -m 0644 "$SCRIPT_DIR/fail2ban/jellyfin.local" /etc/fail2ban/jail.d/jellyfin.local

# Validar el regex contra logs reales si existen
JELLY_LOG="$(find /srv/config/jellyfin/log -maxdepth 1 -name '*.log' 2>/dev/null | head -n1 || true)"
if [[ -n "$JELLY_LOG" ]]; then
    log "Validando regex contra $JELLY_LOG"
    fail2ban-regex "$JELLY_LOG" /etc/fail2ban/filter.d/jellyfin.conf || \
        warn "El regex no matcheo. Ajustar failregex segun tu version de Jellyfin."
else
    warn "No hay logs de Jellyfin todavia. Validar el regex despues de que arranque."
fi

systemctl enable fail2ban
systemctl restart fail2ban

# =========================================================================
log "6/7 UFW: firewall"
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

# =========================================================================
log "7/7 Listo. Verificaciones pendientes:"
# =========================================================================
cat <<EOF

  [ ] Desde el celu con DATOS MOVILES (fuera de tu red), probar:
        - http://<IP-VPS>/         -> deberia entrar Jellyfin (o 403 si estas fuera de AR)
        - http://<IP-VPS>:9696/    -> NO deberia responder (Prowlarr, solo Tailscale)
        - http://<IP-VPS>:7878/    -> NO deberia responder (Radarr, solo Tailscale)
      Si los puertos de los *arr responden, Docker se salteo UFW: confirmar
      que los binds a $TAILSCALE_IP esten en el compose.

  [ ] En Jellyfin: Dashboard > Networking > agregar 127.0.0.1 como known proxy
      (para que loguee la IP real del cliente y fail2ban banee bien).

  [ ] Probar 4 logins fallidos a proposito y verificar el ban:
        sudo fail2ban-client status jellyfin

  [ ] Confirmar que segui entrando desde AR tras activar el geo-bloqueo.

EOF
log "setup-host.sh finalizado."
