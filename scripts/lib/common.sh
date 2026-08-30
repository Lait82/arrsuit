#!/usr/bin/env bash
# =========================================================================
#  scripts/lib/common.sh - Helpers compartidos por los scripts de servicio
#
#  Se SOURCEA, no se ejecuta. El orquestador (configure-stack.sh) lo carga y
#  despues sourcea cada modulo de servicio, que usa estas funciones.
#
#  REGLA DE ORO DE ESTE ARCHIVO:
#    No define ningun nombre que ya exista en configure-stack.sh, salvo bajo
#    guarda 'declare -F'. Motivo: configure-stack.sh define su api_call() con
#    la API key HARDCODEADA en el header ("X-Api-Key: $RADARR_API_KEY"). Si
#    aca definieramos otra api_call, una pisaria a la otra segun el orden de
#    sourcing y Sonarr terminaria autenticando con la key de Radarr -> 401.
#    Por eso el helper HTTP se llama servarr_api, no api_call.
#
#  El prefijo 'servarr_' es porque Radarr, Sonarr y Prowlarr comparten base de
#  codigo (Servarr): mismo header X-Api-Key, mismo /api/v3, mismo config.xml.
# =========================================================================

# --- Guardas de compatibilidad -------------------------------------------
# Si ya existen (caso normal: sourceado desde configure-stack.sh), se respetan
# las del orquestador. Si no (lib usada sola), se definen iguales.
declare -F log     >/dev/null || log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
declare -F info    >/dev/null || info() { echo -e "  \033[1;36m->\033[0m $*"; }
declare -F warn    >/dev/null || warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
declare -F die     >/dev/null || die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }
declare -F logfile >/dev/null || logfile() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE:-/dev/null}"
}
declare -F conf    >/dev/null || conf() { jq -r "$1" "$CONF_FILE"; }
declare -F ctr_to_host_path >/dev/null || ctr_to_host_path() {
    echo "${MEDIA_HOST_DIR}${1#$MEDIA_CTR_DIR}"
}

# =========================================================================
#  servarr_api METHOD URL API_KEY [DATA]
#
#  Mismo contrato que el api_call del orquestador, pero con la key como
#  parametro en vez de leerla de una global fija:
#    - setea HTTP_CODE y HTTP_BODY (globales, es el canal de retorno del repo)
#    - loguea request y response completos a $LOG_FILE
#    - devuelve 0 SOLO si el codigo es 2xx (para usarlo en if/&&)
# =========================================================================
servarr_api() {
    local method="$1" url="$2" key="$3" data="${4:-}"
    local tmp_body; tmp_body="$(mktemp)"
    local curl_args=(-sSg -X "$method"
        -H "X-Api-Key: $key"
        -H "Content-Type: application/json"
        -o "$tmp_body" -w '%{http_code}')
    [[ -n "$data" ]] && curl_args+=(-d "$data")
    logfile "--- REQUEST: $method $url"
    [[ -n "$data" ]] && logfile "    PAYLOAD: $data"
    HTTP_CODE="$(curl "${curl_args[@]}" "$url" 2>>"${LOG_FILE:-/dev/null}")" || HTTP_CODE="000"
    HTTP_BODY="$(cat "$tmp_body")"; rm -f "$tmp_body"
    logfile "    HTTP_CODE: $HTTP_CODE"
    logfile "    RESPONSE: ${HTTP_BODY:-<vacio>}"
    [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]
}

# Imprime los errores de validacion de una respuesta 400 de Servarr, que vienen
# como array de objetos con propertyName/errorMessage. Si no parsea, imprime crudo.
servarr_print_errors() {
    echo "$HTTP_BODY" | jq -r \
        '.[]? | "  - \(.propertyName): \(.errorMessage) (\(.detailedDescription // ""))"' \
        2>/dev/null || echo "  $HTTP_BODY"
}

# =========================================================================
#  servarr_api_key <config.xml>
#  Extrae <ApiKey> del config.xml del servicio. La key se genera sola en el
#  primer arranque, asi que el contenedor tiene que haber corrido al menos una vez.
# =========================================================================
servarr_api_key() {
    local xml="$1" key
    [[ -f "$xml" ]] || die "No encuentro $xml. ¿El contenedor arranco al menos una vez?"
    key="$(grep -oP '(?<=<ApiKey>)[^<]+' "$xml" || true)"
    [[ -n "$key" ]] || die "No pude extraer la ApiKey de $xml"
    echo "$key"
}

# =========================================================================
#  servarr_wait_ready <nombre> <url> <key> [api_version]
#  Espera hasta 60s (30 intentos x 2s) a que /system/status responda 2xx.
#
#  api_version por defecto es v3 (Radarr y Sonarr). PROWLARR USA v1: no comparte
#  el versionado de API con el resto aunque comparta la base de codigo.
# =========================================================================
servarr_wait_ready() {
    local name="$1" url="$2" key="$3" api="${4:-v3}" i
    info "Esperando a que $name responda..."
    for i in {1..30}; do
        servarr_api GET "$url/api/$api/system/status" "$key" && { info "$name OK"; return 0; }
        sleep 2
    done
    die "$name no respondio despues de 60s. Ver $LOG_FILE"
}

# =========================================================================
#  servarr_apply_external_auth <contenedor> <config.xml>
#
#  Pone AuthenticationMethod=External: el servicio no pide login y delega la
#  autenticacion a la capa de acceso (Tailscale). La API key sigue funcionando.
#
#  Por que External y no DisabledForLocalAddresses: los *arr consideran "local"
#  solo loopback y los rangos RFC1918. Tailscale usa 100.64.0.0/10 (CGNAT), que
#  NO entra en esa lista -> con DisabledForLocalAddresses te pide login igual.
#
#  Patron stop/edit/start: el servicio reescribe su XML al apagarse, asi que hay
#  que editarlo con el contenedor detenido o se pierde el cambio.
# =========================================================================
servarr_apply_external_auth() {
    local container="$1" xml="$2"
    [[ -f "$xml" ]] || die "No encuentro $xml"

    if grep -qF '<AuthenticationMethod>External</AuthenticationMethod>' "$xml"; then
        info "Auth de $container ya esta en External. No se toca."
        return 0
    fi

    info "Parando $container para editar su config..."
    $DC stop "$container" >/dev/null
    logfile "$container detenido para editar $xml"
    cp -a "$xml" "${xml}.bak.$(date +%s)"

    # Bug conocido (#9353): editar mal deja <AuthenticationMethod> duplicados.
    # Estrategia robusta: borrar TODAS las lineas de AuthenticationMethod y
    # AuthenticationRequired, y reescribir una sola de cada una.
    grep -vE '<Authentication(Method|Required)>' "$xml" > "${xml}.tmp" \
        && mv "${xml}.tmp" "$xml"

    export _SA_M='  <AuthenticationMethod>External</AuthenticationMethod>'
    export _SA_R='  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>'
    awk '
        { print }
        /<Config>/ && !done { print ENVIRON["_SA_M"]; print ENVIRON["_SA_R"]; done=1 }
    ' "$xml" > "${xml}.tmp" && mv "${xml}.tmp" "$xml"
    unset _SA_M _SA_R

    logfile "AuthenticationMethod=External escrito en $xml"
    info "Arrancando $container..."
    $DC start "$container" >/dev/null
    sleep 5
    info "Auth de $container en External (sin login; Tailscale es la capa de acceso)."
}

# =========================================================================
#  servarr_assert_dir_writable <contenedor> <ctr_path>
#
#  Verificacion, NO reparacion. Es el unico chequeo hecho DESDE ADENTRO del
#  contenedor, que es donde la respuesta cuenta. Un chequeo en el host no puede
#  ver: un bind montado :ro, un mount que fallo y dejo /data vacio, SELinux sin
#  labels :z, o userns-remap (donde el uid $PUID del contenedor NO es el $PUID
#  del host y ningun chown en el host sirve).
#
#  Ojo con el -u $PUID: 'docker exec' sin eso corre como root, y root escribe
#  siempre -> el test daria un falso OK.
# =========================================================================
servarr_assert_dir_writable() {
    local container="$1" ctr_path="$2" host_path
    host_path="$(ctr_to_host_path "$ctr_path")"

    if docker exec -u "$PUID" "$container" test -w "$ctr_path" 2>/dev/null; then
        info "Permisos OK: $container puede escribir en $ctr_path"
        return 0
    fi

    warn "$container (uid $PUID / 'abc') no puede escribir en $ctr_path"
    warn "El host tiene $host_path como ${PUID}:${PGID}, asi que no es el dueño."
    warn "Revisá, en este orden:"
    warn "  1) que el bind este montado y no sea read-only:"
    warn "       docker exec $container mount | grep /data"
    warn "  2) que dockerd no tenga userns-remap (remapea los uid del contenedor):"
    warn "       docker info | grep -i userns"
    warn "  3) SELinux: si esta activo, el compose necesita ':z' en el volumen."
    die "Abortando: no configuro una carpeta donde $container no puede escribir."
}

# =========================================================================
#  servarr_ensure_host_dir <ctr_path>
#  Crea la carpeta en el host (traduciendo la ruta del contenedor) con el dueño
#  correcto. Existe para que cada modulo de servicio se encargue de SU carpeta
#  sin depender de que prepare_media_tree conozca todos los paths posibles.
# =========================================================================
servarr_ensure_host_dir() {
    local ctr_path="$1" host_path
    host_path="$(ctr_to_host_path "$ctr_path")"

    if [[ ! -d "$host_path" ]]; then
        info "Creando $host_path en el host..."
        mkdir -p "$host_path" || die "No pude crear $host_path"
        logfile "mkdir -p $host_path"
    fi
    chown "${PUID}:${PGID}" "$host_path" || die "Fallo el chown de $host_path"
}

# =========================================================================
#  servarr_upsert_download_client <app> <url> <key> <nombre_cliente> <payload>
#
#  Agrega un download client a una app Servarr. Sirve para cualquier cliente
#  (qBittorrent, SABnzbd, lo que venga): el payload lo arma quien llama, esto
#  se encarga del ciclo idempotencia -> test -> guardar.
#
#  Siempre prueba con /test ANTES de guardar: no dejamos configurado un cliente
#  que no conecta, porque despues falla en silencio a la hora de descargar.
# =========================================================================
servarr_upsert_download_client() {
    local app="$1" url="$2" key="$3" client="$4" payload="$5"
    local existing new_id

    if servarr_api GET "$url/api/v3/downloadclient" "$key"; then
        existing="$(echo "$HTTP_BODY" | jq -r --arg n "$client" \
            '.[] | select(.name == $n) | .id' | head -n1 || true)"
        if [[ -n "$existing" ]]; then
            warn "'$client' ya existe en $app (id $existing). No se duplica."
            logfile "$app: download client '$client' ya existe (id $existing)."
            return 0
        fi
    else
        die "No pude listar download clients de $app (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi

    info "Probando $app -> $client (endpoint /test)..."
    if servarr_api POST "$url/api/v3/downloadclient/test" "$key" "$payload"; then
        info "Test OK: $app alcanza a $client."
    else
        warn "El test de $client contra $app fallo (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "Abortando: no guardo un download client que no conecta."
    fi

    info "Agregando $client a $app..."
    if servarr_api POST "$url/api/v3/downloadclient" "$key" "$payload"; then
        new_id="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
        info "'$client' agregado a $app (id ${new_id:-?})"
    else
        warn "Fallo al agregar $client a $app (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "No se pudo agregar $client a $app. Ver $LOG_FILE"
    fi
}

# =========================================================================
#  servarr_register_root_folder <nombre> <url> <key> <ctr_path>
#  Idempotente: si el path ya esta cargado, no lo duplica.
#
#  Se llama 'register' y no 'add' a proposito: los modulos de servicio exponen
#  funciones tipo sonarr_add_root_folder, y dos nombres a una letra de distancia
#  (servarr_ / sonarr_) son un typo esperando a pasar -> recursion infinita.
# =========================================================================
servarr_register_root_folder() {
    local name="$1" url="$2" key="$3" ctr_path="$4"
    local existing payload new_id free

    if servarr_api GET "$url/api/v3/rootfolder" "$key"; then
        existing="$(echo "$HTTP_BODY" | jq -r --arg p "$ctr_path" \
            '.[] | select(.path == $p) | .id' | head -n1 || true)"
        if [[ -n "$existing" ]]; then
            warn "El root folder '$ctr_path' ya existe en $name (id $existing). No se duplica."
            logfile "$name: root folder ya existe (id $existing)."
            return 0
        fi
    else
        die "No pude listar root folders de $name (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi

    payload="$(jq -n --arg path "$ctr_path" '{ path: $path }')"

    info "Agregando el root folder a $name..."
    if servarr_api POST "$url/api/v3/rootfolder" "$key" "$payload"; then
        new_id="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
        free="$(echo "$HTTP_BODY" | jq -r '.freeSpace // empty')"
        info "Root folder '$ctr_path' agregado a $name (id ${new_id:-?})"
        [[ -n "$free" ]] && echo "  Espacio libre: $(( free / 1024 / 1024 / 1024 )) GB"
    else
        warn "Fallo al agregar el root folder en $name (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "No se pudo agregar el root folder. Ver $LOG_FILE"
    fi
}
