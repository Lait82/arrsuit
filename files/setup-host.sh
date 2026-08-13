#!/usr/bin/env bash
# =========================================================================
#  setup-host.sh - Configura la capa de host del media stack
#  nginx (reverse proxy Jellyfin) + GeoIP2 (bloqueo AR) + fail2ban + UFW
#
#  Idempotente: se puede correr varias veces.
#  Correr con sudo desde la carpeta que contiene ./nginx y ./fail2ban.
#
#  >>> ANTES DE CORRER, editar las variables en la seccion CONFIG <<<
# =========================================================================
set -euo pipefail

# ----------------------------- CONFIG ------------------------------------
# IP de Tailscale de esta VPS (tailscale ip -4). Se usa para las reglas UFW.
TAILSCALE_IP="100.x.y.z"

# License key de MaxMind GeoLite2 (cuenta gratis en maxmind.com).
# Necesaria para bajar la base de datos de paises.
MAXMIND_ACCOUNT_ID="TU_ACCOUNT_ID"
MAXMIND_LICENSE_KEY="TU_LICENSE_KEY"

# Puerto SSH (cambiar si no es el 22). Se abre en UFW para no lockearte.
SSH_PORT="22"

# Ruta a los archivos de config (por defecto, junto a este script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# -------------------------------------------------------------------------

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Corré con sudo."

# --- Guarda: no seguir con placeholders sin tocar ---
[[ "$TAILSCALE_IP" != "100.x.y.z" ]] || die "Editá TAILSCALE_IP en la seccion CONFIG."
[[ "$MAXMIND_LICENSE_KEY" != "TU_LICENSE_KEY" ]] || warn "MAXMIND_LICENSE_KEY sin setear: se saltea el geo-bloqueo."

# =========================================================================
log "1/6 Instalando paquetes"
# =========================================================================
apt-get update -qq
apt-get install -y -qq \
    nginx \
    libnginx-mod-http-geoip2 \
    geoipupdate \
    fail2ban \
    ufw

# =========================================================================
log "2/6 GeoIP2: bajando base de datos de MaxMind"
# =========================================================================
if [[ "$MAXMIND_LICENSE_KEY" != "TU_LICENSE_KEY" ]]; then
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
log "3/6 nginx: colocando configs"
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
log "4/6 fail2ban: filtro y jail de Jellyfin"
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
log "5/6 UFW: firewall"
# =========================================================================
# ORDEN IMPORTANTE: permitir SSH y Tailscale ANTES de enable, o te lockeas.
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'Tailscale interface'
ufw allow "$SSH_PORT"/tcp   comment 'SSH'
ufw allow 41641/udp         comment 'Tailscale'
ufw allow 80/tcp            comment 'Jellyfin via nginx'
ufw --force enable

# =========================================================================
log "6/6 Listo. Verificaciones pendientes:"
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
