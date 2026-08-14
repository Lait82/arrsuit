#!/usr/bin/env bash
# =========================================================================
#  configure-stack.sh - Configura las conexiones entre servicios del stack
#  v1: conecta Radarr -> qBittorrent (download client) via API REST.
#
#  Corre DESPUES de 'docker compose up -d' (necesita los contenedores vivos).
#  Idempotente: si el download client ya existe, no lo duplica.
#
#  Config no sensible -> services_setup.conf (JSON, se parsea con jq)
#  Secretos/IP        -> .env  (TAILSCALE_IP la escribe setup-host.sh)
#
#  >>> Requiere: jq, curl. El script instala jq si falta.
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/services_setup.conf"
ENV_FILE="$SCRIPT_DIR/.env"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# --- Prerrequisitos ------------------------------------------------------
[[ -f "$CONF_FILE" ]] || die "No existe $CONF_FILE"
[[ -f "$ENV_FILE" ]]  || die "No existe $ENV_FILE (lo escribe setup-host.sh)"

command -v curl >/dev/null || die "Falta curl."
if ! command -v jq >/dev/null; then
    log "Instalando jq..."
    apt-get install -y -qq jq || die "No pude instalar jq. Instalalo a mano: apt install jq"
fi

# --- Cargar .env (para TAILSCALE_IP) ------------------------------------
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
TAILSCALE_IP="${TAILSCALE_IP:-}"
[[ -n "$TAILSCALE_IP" ]] || die "TAILSCALE_IP vacio en .env. ¿Corriste setup-host.sh?"

# --- Helper: leer una clave del JSON de config --------------------------
conf() { jq -r "$1" "$CONF_FILE"; }

# =========================================================================
#  CONSTANTES DEL STACK (definidas por el compose, NO son "config")
# =========================================================================
# Estos valores estan fijados por docker-compose.yml. NO los edites aca:
# si cambian, cambialos en el compose Y aca a la vez. No van en el .conf
# porque no son decisiones ajustables, son consecuencia de la topologia.
#
#   TC_HOST=gluetun   -> qBittorrent corre con network_mode: service:gluetun,
#                        asi que Radarr lo alcanza por el hostname 'gluetun'.
#   TC_PORT=8080      -> WEBUI_PORT de qBittorrent en el compose.
#   RADARR_PORT=7878  -> bind de Radarr en el compose.
#   RADARR_CONFIG_XML -> volumen /srv/config/radarr del compose.
TC_NAME="qBittorrent"
TC_HOST="gluetun"
TC_PORT=8080
RADARR_PORT=7878
RADARR_CONFIG_XML="/srv/config/radarr/config.xml"

# =========================================================================
log "Leyendo configuracion editable"
# =========================================================================
# Solo esto es config real (editable en services_setup.conf):
RADARR_CATEGORY="$(conf '.radarr.downloadClientCategory')"
DOWNLOAD_DIR="$(conf '.torrentClient.downloadDir')"

# URL de Radarr desde el HOST: Radarr esta bindeado a TAILSCALE_IP
RADARR_URL="http://${TAILSCALE_IP}:${RADARR_PORT}"

echo "  Torrent client : $TC_NAME @ $TC_HOST:$TC_PORT (constante del stack)"
echo "  Categoria      : $RADARR_CATEGORY (editable)"
echo "  Download dir   : $DOWNLOAD_DIR (editable)"
echo "  Radarr         : $RADARR_URL"

# --- Extraer la API key de Radarr del config.xml -------------------------
[[ -f "$RADARR_CONFIG_XML" ]] || die "No encuentro $RADARR_CONFIG_XML. ¿Arranco Radarr al menos una vez?"
RADARR_API_KEY="$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG_XML" || true)"
[[ -n "$RADARR_API_KEY" ]] || die "No pude extraer la ApiKey de $RADARR_CONFIG_XML"

# =========================================================================
log "Esperando a que Radarr responda"
# =========================================================================
for i in {1..30}; do
    if curl -fsS -H "X-Api-Key: $RADARR_API_KEY" "$RADARR_URL/api/v3/system/status" >/dev/null 2>&1; then
        log "Radarr OK"
        break
    fi
    [[ $i -eq 30 ]] && die "Radarr no respondio tras 30 intentos en $RADARR_URL"
    sleep 2
done

# =========================================================================
log "Verificando si el download client ya existe (idempotencia)"
# =========================================================================
EXISTING="$(curl -fsS -H "X-Api-Key: $RADARR_API_KEY" \
    "$RADARR_URL/api/v3/downloadclient" | jq -r --arg n "$TC_NAME" \
    '.[] | select(.name == $n) | .id' | head -n1 || true)"

if [[ -n "$EXISTING" ]]; then
    warn "Ya existe un download client '$TC_NAME' (id $EXISTING). No se duplica."
    exit 0
fi

# =========================================================================
log "Agregando qBittorrent como download client en Radarr"
# =========================================================================
# Payload para la API v3 de Radarr. Los 'fields' son los del schema de
# qBittorrent (host, port, category, etc.). Password default -> no se setea
# username/password (qBittorrent en default admin/adminadmin, LAN+tailnet).
PAYLOAD="$(jq -n \
    --arg name "$TC_NAME" \
    --arg host "$TC_HOST" \
    --argjson port "$TC_PORT" \
    --arg category "$RADARR_CATEGORY" \
    '{
        enable: true,
        protocol: "torrent",
        priority: 1,
        name: $name,
        implementation: "QBittorrent",
        implementationName: "qBittorrent",
        configContract: "QBittorrentSettings",
        fields: [
            { name: "host",            value: $host },
            { name: "port",            value: $port },
            { name: "useSsl",          value: false },
            { name: "movieCategory",   value: $category },
            { name: "recentMoviePriority", value: 0 },
            { name: "olderMoviePriority",  value: 0 },
            { name: "initialState",    value: 0 },
            { name: "sequentialOrder", value: false },
            { name: "firstAndLast",    value: false }
        ],
        tags: []
    }')"

RESPONSE="$(curl -fsS -X POST \
    -H "X-Api-Key: $RADARR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$RADARR_URL/api/v3/downloadclient" 2>&1)" || die "Fallo el POST: $RESPONSE"

NEW_ID="$(echo "$RESPONSE" | jq -r '.id // empty')"
if [[ -n "$NEW_ID" ]]; then
    log "Download client '$TC_NAME' agregado (id $NEW_ID)"
else
    die "Radarr no devolvio un id. Respuesta: $RESPONSE"
fi

# =========================================================================
log "Probando la conexion Radarr -> qBittorrent"
# =========================================================================
# El endpoint /test valida que Radarr realmente pueda hablar con qBittorrent.
TEST="$(curl -fsS -X POST \
    -H "X-Api-Key: $RADARR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$RADARR_URL/api/v3/downloadclient/test" 2>&1 || true)"

if [[ -z "$TEST" || "$TEST" == "{}" ]]; then
    log "Test OK: Radarr se conecta a qBittorrent en $TC_HOST:$TC_PORT"
else
    warn "El test devolvio observaciones (revisar):"
    echo "$TEST" | jq -r '.[]?.errorMessage // empty' 2>/dev/null || echo "$TEST"
    warn "Si es error de auth, puede ser el bug de qBittorrent >5.1.4 (ya pineaste 5.1.4)."
    warn "Si es 'Unable to connect', revisa que el host sea 'gluetun' y no 'qbittorrent'."
fi

log "configure-stack.sh finalizado."
