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
#  LOG: cada llamada a la API queda registrada en ./configure-stack.log
#       (codigo HTTP + payload enviado + respuesta del server).
#
#  >>> Requiere: jq, curl. El script instala jq si falta.
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/configs/services_setup.conf"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/configure-stack.log"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# --- Log a archivo (con timestamp), sin colores ---
logfile() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Arranca un log limpio por corrida
: > "$LOG_FILE"
logfile "=== configure-stack.sh iniciado ==="

# =========================================================================
#  api_call METHOD URL [DATA]
#  Hace una llamada a la API de Radarr y loguea TODO (codigo, body, payload).
#  - NO usa -f: asi captura el body aunque el server devuelva 4xx/5xx.
#  - Setea las globales HTTP_CODE y HTTP_BODY para que el caller las use.
#  Devuelve 0 si el codigo es 2xx, 1 si no (pero nunca aborta por si solo).
# =========================================================================
api_call() {
    local method="$1" url="$2" data="${3:-}"
    local tmp_body; tmp_body="$(mktemp)"
    local curl_args=(-sS -X "$method"
        -H "X-Api-Key: $RADARR_API_KEY"
        -H "Content-Type: application/json"
        -o "$tmp_body"
        -w '%{http_code}')
    [[ -n "$data" ]] && curl_args+=(-d "$data")

    logfile "--- REQUEST: $method $url"
    [[ -n "$data" ]] && logfile "    PAYLOAD: $data"

    # -w imprime el codigo; si curl falla de red (no hay respuesta HTTP),
    # el codigo ya es 000, no hace falta el fallback duplicado.
    HTTP_CODE="$(curl "${curl_args[@]}" "$url" 2>>"$LOG_FILE")" || HTTP_CODE="000"
    HTTP_BODY="$(cat "$tmp_body")"
    rm -f "$tmp_body"

    logfile "    HTTP_CODE: $HTTP_CODE"
    logfile "    RESPONSE: ${HTTP_BODY:-<vacio>}"

    # 2xx => exito
    [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]
}

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
#                        (gluetun tiene que estar en la red 'media' tambien.)
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
RADARR_CATEGORY="$(conf '.radarr.downloadClientCategory')"
DOWNLOAD_DIR="$(conf '.torrentClient.downloadDir')"

RADARR_URL="http://${TAILSCALE_IP}:${RADARR_PORT}"

echo "  Torrent client : $TC_NAME @ $TC_HOST:$TC_PORT (constante del stack)"
echo "  Categoria      : $RADARR_CATEGORY (editable)"
echo "  Download dir   : $DOWNLOAD_DIR (editable)"
echo "  Radarr         : $RADARR_URL"
echo "  Log            : $LOG_FILE"
logfile "Radarr URL: $RADARR_URL | client: $TC_HOST:$TC_PORT | cat: $RADARR_CATEGORY"

# --- Extraer la API key de Radarr del config.xml -------------------------
[[ -f "$RADARR_CONFIG_XML" ]] || die "No encuentro $RADARR_CONFIG_XML. ¿Arranco Radarr al menos una vez?"
RADARR_API_KEY="$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG_XML" || true)"
[[ -n "$RADARR_API_KEY" ]] || die "No pude extraer la ApiKey de $RADARR_CONFIG_XML"
logfile "API key extraida de $RADARR_CONFIG_XML (longitud: ${#RADARR_API_KEY})"

# =========================================================================
log "Esperando a que Radarr responda"
# =========================================================================
for i in {1..30}; do
    if api_call GET "$RADARR_URL/api/v3/system/status"; then
        log "Radarr OK"
        break
    fi
    [[ $i -eq 30 ]] && die "Radarr no respondio tras 30 intentos. Ver $LOG_FILE"
    sleep 2
done

# =========================================================================
log "Verificando si el download client ya existe (idempotencia)"
# =========================================================================
if api_call GET "$RADARR_URL/api/v3/downloadclient"; then
    EXISTING="$(echo "$HTTP_BODY" | jq -r --arg n "$TC_NAME" \
        '.[] | select(.name == $n) | .id' | head -n1 || true)"
    if [[ -n "$EXISTING" ]]; then
        warn "Ya existe un download client '$TC_NAME' (id $EXISTING). No se duplica."
        logfile "Download client ya existe (id $EXISTING). Saliendo."
        exit 0
    fi
else
    die "No pude listar download clients (HTTP $HTTP_CODE). Ver $LOG_FILE"
fi

# =========================================================================
log "Construyendo payload del download client"
# =========================================================================
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

# =========================================================================
log "Probando la conexion ANTES de guardar (endpoint /test)"
# =========================================================================
# Testeamos primero: si Radarr no puede hablar con qBittorrent, no tiene
# sentido guardar. El /test devuelve [] o {} si esta OK, o un array con
# errores si algo falla (host inalcanzable, auth, etc.).
if api_call POST "$RADARR_URL/api/v3/downloadclient/test" "$PAYLOAD"; then
    log "Test OK: Radarr alcanza a qBittorrent en $TC_HOST:$TC_PORT"
else
    warn "El test fallo (HTTP $HTTP_CODE). Detalle:"
    echo "$HTTP_BODY" | jq -r '.[]? | "  - \(.propertyName): \(.errorMessage) (\(.detailedDescription // ""))"' 2>/dev/null || echo "  $HTTP_BODY"
    echo ""
    warn "Pistas segun el error:"
    warn "  'Unable to connect' -> gluetun tiene que estar en 'networks: [media]'"
    warn "  'authentication'    -> bug de qBittorrent >5.1.4 (deberias tener 5.1.4)"
    warn "Log completo en: $LOG_FILE"
    die "Abortando: no guardo un download client que no conecta."
fi

# =========================================================================
log "Agregando qBittorrent como download client"
# =========================================================================
if api_call POST "$RADARR_URL/api/v3/downloadclient" "$PAYLOAD"; then
    NEW_ID="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
    log "Download client '$TC_NAME' agregado (id ${NEW_ID:-?})"
else
    warn "Fallo al agregar (HTTP $HTTP_CODE):"
    echo "$HTTP_BODY" | jq -r '.[]? | "  - \(.propertyName): \(.errorMessage)"' 2>/dev/null || echo "  $HTTP_BODY"
    die "No se pudo agregar el download client. Ver $LOG_FILE"
fi

logfile "=== configure-stack.sh finalizado OK ==="
log "configure-stack.sh finalizado. Log en $LOG_FILE"