#!/usr/bin/env bash
# =========================================================================
#  configure-stack.sh - Orquesta y configura el media stack de punta a punta
#
#  Pensado para alguien que apenas se maneja: un solo comando deja todo listo.
#  Hace, en orden:
#    1. Levanta el stack (docker compose up -d) si no esta arriba.
#    2. Configura el bypass de auth de qBittorrent para la red 'media'
#       (edita qBittorrent.conf; para y arranca el contenedor para hacerlo).
#    3. Setea la auth de Radarr en External (Tailscale es la capa de acceso;
#       no pide login por web, la API key sigue funcionando).
#    4. Conecta Radarr -> qBittorrent (download client) via API REST.
#    5. Crea el root folder de Radarr (biblioteca de peliculas) via API REST.
#
#  Idempotente: se puede correr varias veces sin romper ni duplicar nada.
#
#  Config editable   -> configs/services_setup.conf (JSON, se parsea con jq)
#  Secretos/IP        -> .env  (TAILSCALE_IP la escribe setup-host.sh)
#  LOG                -> ./configure-stack.log  (cada request/response API)
#
#  >>> Requiere: docker, jq, curl. Corre con sudo (toca /srv/config y docker).
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/configs/services_setup.conf"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/configure-stack.log"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }
logfile() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

: > "$LOG_FILE"
logfile "=== configure-stack.sh iniciado ==="

# =========================================================================
#  CONSTANTES DEL STACK (definidas por el compose, NO son "config")
# =========================================================================
#   TC_HOST=gluetun   -> qBittorrent usa network_mode: service:gluetun.
#                        gluetun DEBE estar en 'networks: [media]'.
#   TC_PORT=8080      -> WEBUI_PORT de qBittorrent en el compose.
#   RADARR_PORT=7878  -> bind de Radarr en el compose.
#   MEDIA_SUBNET      -> subnet de la red 'media' (para el bypass de auth).
#   QBIT_CONF         -> qBittorrent.conf en el host (via volumen del compose).
TC_NAME="qBittorrent"
TC_HOST="gluetun"
TC_PORT=8080
RADARR_PORT=7878
RADARR_CONFIG_XML="/srv/config/radarr/config.xml"
MEDIA_SUBNET="172.20.0.0/16"
QBIT_CONF="/srv/config/qbittorrent/qBittorrent/qBittorrent.conf"
QBIT_CONTAINER="qbittorrent"

# =========================================================================
#  Prerrequisitos
# =========================================================================
[[ $EUID -eq 0 ]] || die "Corré con sudo (toca /srv/config y docker)."
[[ -f "$CONF_FILE" ]] || die "No existe $CONF_FILE"
[[ -f "$ENV_FILE" ]]  || die "No existe $ENV_FILE (lo escribe setup-host.sh)"
command -v curl >/dev/null || die "Falta curl."
command -v docker >/dev/null || die "Falta docker."
if ! command -v jq >/dev/null; then
    log "Instalando jq..."
    apt-get install -y -qq jq || die "No pude instalar jq. Instalalo: apt install jq"
fi

# docker compose v2 (plugin) o v1 (binario)
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    die "No encuentro 'docker compose' ni 'docker-compose'."
fi

# --- Cargar .env ---------------------------------------------------------
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
TAILSCALE_IP="${TAILSCALE_IP:-}"
[[ -n "$TAILSCALE_IP" ]] || die "TAILSCALE_IP vacio en .env. ¿Corriste setup-host.sh?"

# --- Config editable -----------------------------------------------------
conf() { jq -r "$1" "$CONF_FILE"; }
RADARR_CATEGORY="$(conf '.radarr.downloadClientCategory')"
DOWNLOAD_DIR="$(conf '.torrentClient.downloadDir')"
RADARR_URL="http://${TAILSCALE_IP}:${RADARR_PORT}"

RADARR_ROOT_FOLDER="$(conf '.radarr.rootFolder')"
[[ -n "$RADARR_ROOT_FOLDER" && "$RADARR_ROOT_FOLDER" != "null" ]] \
    || die "Falta .radarr.rootFolder en $CONF_FILE (ej: \"/data/movies\")"
case "$RADARR_ROOT_FOLDER" in
    /data/*) ;;
    *) die "rootFolder debe ser una ruta interna del contenedor (/data/...), no del host. Valor actual: $RADARR_ROOT_FOLDER" ;;
esac

# =========================================================================
#  Helper API (loguea todo; setea HTTP_CODE y HTTP_BODY; no aborta solo)
# =========================================================================
api_call() {
    local method="$1" url="$2" data="${3:-}"
    local tmp_body; tmp_body="$(mktemp)"
    local curl_args=(-sS -X "$method"
        -H "X-Api-Key: $RADARR_API_KEY"
        -H "Content-Type: application/json"
        -o "$tmp_body" -w '%{http_code}')
    [[ -n "$data" ]] && curl_args+=(-d "$data")
    logfile "--- REQUEST: $method $url"
    [[ -n "$data" ]] && logfile "    PAYLOAD: $data"
    HTTP_CODE="$(curl "${curl_args[@]}" "$url" 2>>"$LOG_FILE")" || HTTP_CODE="000"
    HTTP_BODY="$(cat "$tmp_body")"; rm -f "$tmp_body"
    logfile "    HTTP_CODE: $HTTP_CODE"
    logfile "    RESPONSE: ${HTTP_BODY:-<vacio>}"
    [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]
}

# =========================================================================
log "1/5 Levantando el stack (si hace falta)"
# =========================================================================
cd "$SCRIPT_DIR"
if $DC ps --status running 2>/dev/null | grep -q "$QBIT_CONTAINER"; then
    log "El stack ya esta arriba."
else
    log "Levantando contenedores..."
    $DC up -d
    log "Esperando 10s a que los servicios arranquen..."
    sleep 10
fi

# =========================================================================
log "2/5 Configurando bypass de auth de qBittorrent (red $MEDIA_SUBNET)"
# =========================================================================
# qBittorrent reescribe su .conf al apagarse, asi que hay que:
#   parar el contenedor -> editar el archivo -> arrancarlo.
# Idempotente: si ya esta el bypass con la subnet correcta, no toca nada.

apply_qbit_bypass() {
    [[ -f "$QBIT_CONF" ]] || die "No existe $QBIT_CONF. ¿Arranco qBittorrent al menos una vez?"

    # ¿Ya esta aplicado? (grep -F: match literal, no interpreta el backslash)
    if grep -qF 'WebUI\AuthSubnetWhitelistEnabled=true' "$QBIT_CONF" \
       && grep -qF "WebUI\\AuthSubnetWhitelist=$MEDIA_SUBNET" "$QBIT_CONF"; then
        log "El bypass ya esta aplicado ($MEDIA_SUBNET). No se toca qBittorrent."
        return 0
    fi

    log "Parando qBittorrent para editar su config..."
    $DC stop "$QBIT_CONTAINER" >/dev/null
    logfile "qbittorrent detenido para editar $QBIT_CONF"

    # Backup por las dudas
    cp -a "$QBIT_CONF" "${QBIT_CONF}.bak.$(date +%s)"

    # Limpieza previa: borrar CUALQUIER linea de estas claves, bien o mal
    # escrita (con barra, sin barra por el bug del -v, con otra subnet, o
    # duplicadas). Asi el archivo converge a lo correcto sin importar como
    # quedo de corridas anteriores. Matcheamos 'AuthSubnetWhitelist' que es
    # comun a la version correcta y a la rota (WebUIAuthSubnet sin barra).
    if grep -qF 'AuthSubnetWhitelist' "$QBIT_CONF"; then
        logfile "Limpiando lineas AuthSubnet previas (bien o mal escritas)"
        grep -vF 'AuthSubnetWhitelist' "$QBIT_CONF" > "${QBIT_CONF}.tmp" \
            && mv "${QBIT_CONF}.tmp" "$QBIT_CONF"
    fi

    # Asegurar seccion [Preferences]
    grep -qF '[Preferences]' "$QBIT_CONF" || echo '[Preferences]' >> "$QBIT_CONF"

    # set_conf_key con awk usando ENVIRON: pasar el valor por -v hace que awk
    # interprete '\A' como escape y se coma la barra. Via ENVIRON[] el string
    # es literal, asi 'WebUI\AuthSubnet...' se preserva con la barra.
    # (Como recien limpiamos, las claves NO existen -> caen al branch 'else'
    #  que las agrega bajo [Preferences]. El branch de reemplazo queda igual
    #  por robustez ante otras claves que se agreguen en el futuro.)
    set_conf_key() {
        local key="$1" val="$2"
        export _CK_KEY="$key" _CK_LINE="${key}=${val}"
        if grep -qF "${key}=" "$QBIT_CONF"; then
            awk '
                index($0, ENVIRON["_CK_KEY"] "=") == 1 { print ENVIRON["_CK_LINE"]; next }
                { print }
            ' "$QBIT_CONF" > "${QBIT_CONF}.tmp" && mv "${QBIT_CONF}.tmp" "$QBIT_CONF"
        else
            awk '
                { print }
                /^\[Preferences\]/ && !done { print ENVIRON["_CK_LINE"]; done=1 }
            ' "$QBIT_CONF" > "${QBIT_CONF}.tmp" && mv "${QBIT_CONF}.tmp" "$QBIT_CONF"
        fi
        unset _CK_KEY _CK_LINE
    }
    set_conf_key 'WebUI\AuthSubnetWhitelistEnabled' 'true'
    set_conf_key 'WebUI\AuthSubnetWhitelist' "$MEDIA_SUBNET"
    # Si aparece un 403 desde otros contenedores, descomentar:
    # set_conf_key 'WebUI\HostHeaderValidation' 'false'

    logfile "Bypass escrito en $QBIT_CONF"
    log "Arrancando qBittorrent..."
    $DC start "$QBIT_CONTAINER" >/dev/null
    sleep 5
    log "Bypass aplicado para $MEDIA_SUBNET."
}
apply_qbit_bypass

# =========================================================================
log "3/5 Configurando auth de Radarr (External: la maneja Tailscale)"
# =========================================================================
# Radarr no considera la IP de Tailscale como "local", asi que
# "Disabled for Local Addresses" NO sirve (te pide login igual).
# Solucion: AuthenticationMethod=External -> Radarr delega la auth a la
# capa de acceso (Tailscale) y no pide login. Nadie llega sin estar en el
# tailnet, asi que la auth ya la hizo Tailscale.
# La API key sigue funcionando para Prowlarr/Sonarr/este script.
#
# Patron stop/edit/start (como qBittorrent): Radarr reescribe el XML al
# apagarse, hay que editarlo con el contenedor detenido.
apply_radarr_auth() {
    [[ -f "$RADARR_CONFIG_XML" ]] || die "No encuentro $RADARR_CONFIG_XML"

    # ¿Ya esta en External? (idempotencia)
    if grep -qF '<AuthenticationMethod>External</AuthenticationMethod>' "$RADARR_CONFIG_XML"; then
        log "Auth de Radarr ya esta en External. No se toca."
        return 0
    fi

    log "Parando Radarr para editar su config..."
    $DC stop radarr >/dev/null
    logfile "radarr detenido para editar $RADARR_CONFIG_XML"
    cp -a "$RADARR_CONFIG_XML" "${RADARR_CONFIG_XML}.bak.$(date +%s)"

    # Bug conocido (#9353): editar mal deja <AuthenticationMethod> duplicados.
    # Estrategia robusta: borrar TODAS las lineas de AuthenticationMethod y
    # AuthenticationRequired, y reescribir una sola de cada una.
    grep -vE '<Authentication(Method|Required)>' "$RADARR_CONFIG_XML" \
        > "${RADARR_CONFIG_XML}.tmp" && mv "${RADARR_CONFIG_XML}.tmp" "$RADARR_CONFIG_XML"

    # Insertar las dos lineas correctas justo despues de <Config>
    # (usa awk+ENVIRON por consistencia; aca no hay backslash pero da igual)
    export _RA_M='  <AuthenticationMethod>External</AuthenticationMethod>'
    export _RA_R='  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>'
    awk '
        { print }
        /<Config>/ && !done { print ENVIRON["_RA_M"]; print ENVIRON["_RA_R"]; done=1 }
    ' "$RADARR_CONFIG_XML" > "${RADARR_CONFIG_XML}.tmp" && mv "${RADARR_CONFIG_XML}.tmp" "$RADARR_CONFIG_XML"
    unset _RA_M _RA_R

    logfile "AuthenticationMethod=External escrito en $RADARR_CONFIG_XML"
    log "Arrancando Radarr..."
    $DC start radarr >/dev/null
    sleep 5
    log "Auth de Radarr en External (sin login; Tailscale es la capa de acceso)."
}
apply_radarr_auth

# =========================================================================
log "4/5 Conectando Radarr -> qBittorrent"
# =========================================================================
[[ -f "$RADARR_CONFIG_XML" ]] || die "No encuentro $RADARR_CONFIG_XML"
RADARR_API_KEY="$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG_XML" || true)"
[[ -n "$RADARR_API_KEY" ]] || die "No pude extraer la ApiKey de $RADARR_CONFIG_XML"

echo "  Torrent client : $TC_NAME @ $TC_HOST:$TC_PORT"
echo "  Categoria      : $RADARR_CATEGORY"
echo "  Download dir   : $DOWNLOAD_DIR"
echo "  Root folder    : $RADARR_ROOT_FOLDER (dentro del contenedor)"
echo "  Radarr         : $RADARR_URL"
echo "  Log            : $LOG_FILE"

# Esperar a Radarr
log "Esperando a que Radarr responda..."
for i in {1..30}; do
    api_call GET "$RADARR_URL/api/v3/system/status" && { log "Radarr OK"; break; }
    [[ $i -eq 30 ]] && die "Radarr no respondio. Ver $LOG_FILE"
    sleep 2
done

add_download_client() {
# Idempotencia: ¿ya existe el download client?
if api_call GET "$RADARR_URL/api/v3/downloadclient"; then
    EXISTING="$(echo "$HTTP_BODY" | jq -r --arg n "$TC_NAME" \
        '.[] | select(.name == $n) | .id' | head -n1 || true)"
    if [[ -n "$EXISTING" ]]; then
        warn "Ya existe el download client '$TC_NAME' (id $EXISTING). No se duplica."
        logfile "Download client ya existe (id $EXISTING)."
        return 0
    fi
else
    die "No pude listar download clients (HTTP $HTTP_CODE). Ver $LOG_FILE"
fi

# Payload
PAYLOAD="$(jq -n \
    --arg name "$TC_NAME" --arg host "$TC_HOST" \
    --argjson port "$TC_PORT" --arg category "$RADARR_CATEGORY" \
    '{
        enable: true, protocol: "torrent", priority: 1, name: $name,
        implementation: "QBittorrent", implementationName: "qBittorrent",
        configContract: "QBittorrentSettings",
        fields: [
            { name: "host", value: $host },
            { name: "port", value: $port },
            { name: "useSsl", value: false },
            { name: "movieCategory", value: $category },
            { name: "recentMoviePriority", value: 0 },
            { name: "olderMoviePriority", value: 0 },
            { name: "initialState", value: 0 },
            { name: "sequentialOrder", value: false },
            { name: "firstAndLast", value: false }
        ], tags: []
    }')"

# Test antes de guardar
log "Probando la conexion (endpoint /test)..."
if api_call POST "$RADARR_URL/api/v3/downloadclient/test" "$PAYLOAD"; then
    log "Test OK: Radarr alcanza a qBittorrent."
else
    warn "El test fallo (HTTP $HTTP_CODE):"
    echo "$HTTP_BODY" | jq -r '.[]? | "  - \(.propertyName): \(.errorMessage) (\(.detailedDescription // ""))"' 2>/dev/null || echo "  $HTTP_BODY"
    warn "Log completo en: $LOG_FILE"
    die "Abortando: no guardo un download client que no conecta."
fi

# Guardar
log "Agregando el download client..."
if api_call POST "$RADARR_URL/api/v3/downloadclient" "$PAYLOAD"; then
    NEW_ID="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
    log "Download client '$TC_NAME' agregado (id ${NEW_ID:-?})"
else
    warn "Fallo al agregar (HTTP $HTTP_CODE):"
    echo "$HTTP_BODY" | jq -r '.[]? | "  - \(.propertyName): \(.errorMessage)"' 2>/dev/null || echo "  $HTTP_BODY"
    die "No se pudo agregar. Ver $LOG_FILE"
fi
}
add_download_client

# =========================================================================
log "5/5 Configurando root folder de Radarr ($RADARR_ROOT_FOLDER)"
# =========================================================================
# Sin root folder, Radarr no puede agregar ni una pelicula: es donde organiza
# la biblioteca. Tiene que estar DENTRO del mismo filesystem que /data/downloads
# para que el move de qBittorrent -> biblioteca sea hardlink y no copia.
add_root_folder() {
    # Chequeo previo: que la carpeta exista dentro del contenedor. Da un error
    # mucho mas claro que el 400 generico de la API.
    if ! docker exec radarr test -d "$RADARR_ROOT_FOLDER" 2>/dev/null; then
        warn "Radarr no ve la carpeta $RADARR_ROOT_FOLDER."
        warn "Creala en el host (el compose monta /srv/media como /data):"
        warn "    sudo mkdir -p /srv/media/movies && sudo chown -R 1000:1000 /srv/media"
        die "Abortando: no agrego un root folder que no existe."
    fi

    # Idempotencia: ¿ya esta cargado ese path?
    if api_call GET "$RADARR_URL/api/v3/rootfolder"; then
        local existing
        existing="$(echo "$HTTP_BODY" | jq -r --arg p "$RADARR_ROOT_FOLDER" \
            '.[] | select(.path == $p) | .id' | head -n1 || true)"
        if [[ -n "$existing" ]]; then
            warn "El root folder '$RADARR_ROOT_FOLDER' ya existe (id $existing). No se duplica."
            logfile "Root folder ya existe (id $existing)."
            return 0
        fi
    else
        die "No pude listar root folders (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi

    local payload
    payload="$(jq -n --arg path "$RADARR_ROOT_FOLDER" '{ path: $path }')"

    log "Agregando el root folder..."
    if api_call POST "$RADARR_URL/api/v3/rootfolder" "$payload"; then
        local new_id free
        new_id="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
        free="$(echo "$HTTP_BODY" | jq -r '.freeSpace // empty')"
        log "Root folder '$RADARR_ROOT_FOLDER' agregado (id ${new_id:-?})"
        [[ -n "$free" ]] && echo "  Espacio libre: $(( free / 1024 / 1024 / 1024 )) GB"
    else
        warn "Fallo al agregar el root folder (HTTP $HTTP_CODE):"
        echo "$HTTP_BODY" | jq -r '.[]? | "  - \(.propertyName): \(.errorMessage)"' 2>/dev/null || echo "  $HTTP_BODY"
        die "No se pudo agregar el root folder. Ver $LOG_FILE"
    fi
}
add_root_folder

logfile "=== configure-stack.sh finalizado OK ==="
log "Listo. Radarr conectado a qBittorrent y con biblioteca en $RADARR_ROOT_FOLDER."
log "Log en $LOG_FILE"
