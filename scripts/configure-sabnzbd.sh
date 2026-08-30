#!/usr/bin/env bash
# =========================================================================
#  scripts/configure-sabnzbd.sh - Cliente de descargas USENET
#
#  Se SOURCEA desde configure-stack.sh. Solo DEFINE funciones.
#
#  SABnzbd es a Usenet lo que qBittorrent es a torrent. Radarr y Sonarr
#  manejan los dos protocolos a la vez, asi que este cliente CONVIVE con
#  qBittorrent, no lo reemplaza.
#
#  SABNZBD NO ES UNA APP SERVARR. Las diferencias que importan:
#    - La API key no esta en un config.xml sino en /config/sabnzbd.ini
#    - Autentica por query param (?apikey=X), NO por header X-Api-Key
#    - La API es /api?mode=<accion>, no /api/v3/<recurso>
#  Por eso este modulo tiene su propio sab_api() y no usa servarr_api().
#
#  Hace, en orden (las llama configure-stack.sh):
#    sabnzbd_wait_ready     -> saca la API key del .ini y espera a que responda
#    sabnzbd_configure      -> host_whitelist, carpetas y categorias
#    sabnzbd_connect_apps   -> lo agrega como download client a Radarr y Sonarr
#
#  LO QUE NO HACE: cargar tu proveedor de Usenet (servidor de news, usuario y
#  contrasenia). Eso es una credencial paga y personal -> se carga a mano en
#  la UI, en Config -> Servers. Sin eso SABnzbd no baja nada.
# =========================================================================

# --- Constantes propias del servicio (salen del compose) -----------------
SAB_CONTAINER="sabnzbd"
SAB_NAME="SABnzbd"
SAB_INI="/srv/config/sabnzbd/sabnzbd.ini"

# Puerto INTERNO: el que usan Radarr y Sonarr para alcanzarlo por la red
# 'media'. Es 8080 adentro del contenedor aunque afuera se publique en 8081.
SAB_INTERNAL_HOST="sabnzbd"
SAB_INTERNAL_PORT=8080

# =========================================================================
#  sab_api <mode> [params_extra]
#  SABnzbd autentica por query param y responde JSON con output=json.
#  Setea HTTP_CODE y HTTP_BODY igual que servarr_api, para mantener el contrato.
# =========================================================================
sab_api() {
    local mode="$1" extra="${2:-}"
    local url="${SAB_URL}/api?mode=${mode}&output=json&apikey=${SAB_API_KEY}${extra:+&$extra}"
    local tmp_body; tmp_body="$(mktemp)"

    # La key va en la URL: se enmascara en el log para no dejarla en claro.
    logfile "--- REQUEST: GET ${url//$SAB_API_KEY/<APIKEY>}"
    HTTP_CODE="$(curl -sS -G -o "$tmp_body" -w '%{http_code}' "$url" 2>>"$LOG_FILE")" \
        || HTTP_CODE="000"
    HTTP_BODY="$(cat "$tmp_body")"; rm -f "$tmp_body"
    logfile "    HTTP_CODE: $HTTP_CODE"
    logfile "    RESPONSE: ${HTTP_BODY:-<vacio>}"

    # OJO: SABnzbd devuelve 200 aunque la operacion falle; el error viene en el
    # body como {"status": false, "error": "..."}. Chequear solo el codigo HTTP
    # daria un falso OK.
    [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]] || return 1
    if echo "$HTTP_BODY" | jq -e '.status == false' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

sab_error() {
    echo "$HTTP_BODY" | jq -r '.error // .' 2>/dev/null || echo "$HTTP_BODY"
}

# =========================================================================
#  Lee la config, saca la API key del .ini y espera a que SABnzbd responda.
# =========================================================================
sabnzbd_wait_ready() {
    SAB_PORT="$(conf '.sabnzbd.port')"
    [[ -n "$SAB_PORT" && "$SAB_PORT" != "null" ]] \
        || die "Falta .sabnzbd.port en $CONF_FILE (ej: 8081)"

    SAB_COMPLETE_DIR="$(conf '.sabnzbd.completeDir')"
    SAB_INCOMPLETE_DIR="$(conf '.sabnzbd.incompleteDir')"
    for _d in "$SAB_COMPLETE_DIR" "$SAB_INCOMPLETE_DIR"; do
        [[ -n "$_d" && "$_d" != "null" ]] \
            || die "Faltan .sabnzbd.completeDir / .sabnzbd.incompleteDir en $CONF_FILE"
        # Misma regla que los root folders: son rutas del CONTENEDOR.
        case "$_d" in
            /data/*) ;;
            *) die "Las carpetas de SABnzbd deben ser rutas internas del contenedor (/data/...). Valor actual: $_d" ;;
        esac
    done
    unset _d

    [[ -f "$SAB_INI" ]] || die "No encuentro $SAB_INI. ¿SABnzbd arranco al menos una vez?"
    SAB_API_KEY="$(grep -oP '^api_key\s*=\s*\K\S+' "$SAB_INI" | head -n1 || true)"
    [[ -n "$SAB_API_KEY" ]] || die "No pude extraer api_key de $SAB_INI"

    # POR LOOPBACK Y NO POR LA IP DE TAILSCALE:
    # SABnzbd rechaza con 403 "External internet access denied" todo lo que no
    # venga de sus rangos locales (loopback + RFC1918). Pegandole a
    # http://<TAILSCALE_IP>:8081 el paquete da la vuelta por la interfaz de
    # Tailscale y SABnzbd ve como origen 100.64.x.x, que es CGNAT y NO es
    # RFC1918 -> 403, aunque la request salga de la misma maquina.
    # Por 127.0.0.1 el origen es local y no hay nada que configurar.
    # El compose publica el puerto en las dos IPs justamente para esto.
    SAB_URL="http://127.0.0.1:${SAB_PORT}"

    echo "  SABnzbd (API): $SAB_URL"
    echo "  SABnzbd (UI) : http://${TAILSCALE_IP}:${SAB_PORT}"
    echo "  Completos    : $SAB_COMPLETE_DIR"
    echo "  Incompletos  : $SAB_INCOMPLETE_DIR"

    info "Esperando a que SABnzbd responda..."
    local i
    for i in {1..30}; do
        sab_api version && { info "SABnzbd OK"; return 0; }
        sleep 2
    done
    die "SABnzbd no respondio despues de 60s. Ver $LOG_FILE"
}

# =========================================================================
#  sab_set_config <section> <keyword> <extra_params>
# =========================================================================
sab_set_config() {
    local section="$1" keyword="$2" extra="$3"
    if sab_api set_config "section=${section}&keyword=${keyword}&${extra}"; then
        return 0
    fi
    warn "Fallo set_config ${section}/${keyword}: $(sab_error)"
    die "No pude configurar SABnzbd. Ver $LOG_FILE"
}

# =========================================================================
#  Configura SABnzbd: whitelist de host, carpetas y categorias. Todo por API:
#  yendo por loopback el origen es local y SABnzbd no bloquea nada, asi que no
#  hace falta tocar el .ini ni parar el contenedor.
# =========================================================================
sabnzbd_configure() {
    # --- host_whitelist ---------------------------------------------------
    # OJO: esto es un chequeo DISTINTO del de local_ranges. local_ranges mira
    # la IP de origen; host_whitelist mira el header Host. Son dos filtros
    # independientes y este sigue haciendo falta:
    #
    #   script  -> http://127.0.0.1:8081   Host es una IP    -> no se verifica
    #   Radarr  -> http://sabnzbd:8080     Host es 'sabnzbd' -> SI se verifica
    #
    # Sin esto, Radarr y Sonarr reciben "Hostname verification failed" y el
    # download client no conecta nunca.
    local current
    if sab_api get_config "section=misc&keyword=host_whitelist"; then
        current="$(echo "$HTTP_BODY" | jq -r '.config.misc.host_whitelist // ""')"
    else
        current=""
    fi

    if [[ ",$current," == *",${SAB_INTERNAL_HOST},"* ]]; then
        info "host_whitelist ya incluye '$SAB_INTERNAL_HOST'. No se toca."
    else
        local nuevo="${current:+$current,}${SAB_INTERNAL_HOST}"
        info "Agregando '$SAB_INTERNAL_HOST' al host_whitelist..."
        sab_set_config misc host_whitelist "value=${nuevo}"
    fi

    # --- carpetas ---------------------------------------------------------
    # Ambas dentro de /data para que el hardlink downloads/ -> movies/ funcione:
    # tienen que estar en el MISMO filesystem que la biblioteca.
    # Se crean con dueño $PUID desde el host antes de pasarselas a SABnzbd, por
    # el mismo motivo que el resto del arbol: si las crea Docker o quedan de
    # root, SABnzbd (uid $PUID) no puede escribir ahi.
    servarr_ensure_host_dir "$SAB_COMPLETE_DIR"
    servarr_ensure_host_dir "$SAB_INCOMPLETE_DIR"
    servarr_assert_dir_writable "$SAB_CONTAINER" "$SAB_COMPLETE_DIR"

    info "Configurando carpetas de descarga..."
    sab_set_config misc download_dir  "value=${SAB_INCOMPLETE_DIR}"
    sab_set_config misc complete_dir  "value=${SAB_COMPLETE_DIR}"

    # --- categorias -------------------------------------------------------
    # Reusan los mismos nombres que las categorias de qBittorrent
    # (.radarr/.sonarr.downloadClientCategory), asi Radarr y Sonarr usan la
    # misma etiqueta para torrent y para usenet.
    local cat
    for cat in "$RADARR_CATEGORY" "$SONARR_CATEGORY"; do
        info "Creando categoria '$cat' en SABnzbd..."
        sab_set_config categories "$cat" "name=${cat}&dir=${cat}"
    done
}

# =========================================================================
#  Lo agrega como download client a Radarr y a Sonarr.
#
#  host/port son los INTERNOS (sabnzbd:8080): el que hace la request es el
#  contenedor de Radarr/Sonarr por la red 'media', no vos por Tailscale.
#
#  Igual que con qBittorrent, los campos de categoria difieren:
#  Radarr usa movieCategory, Sonarr usa tvCategory.
# =========================================================================
sab_client_payload() {
    local category_field="$1" category="$2"
    jq -n \
        --arg name "$SAB_NAME" --arg host "$SAB_INTERNAL_HOST" \
        --argjson port "$SAB_INTERNAL_PORT" --arg key "$SAB_API_KEY" \
        --arg catfield "$category_field" --arg cat "$category" \
        '{
            enable: true, protocol: "usenet", priority: 1, name: $name,
            implementation: "Sabnzbd", implementationName: "SABnzbd",
            configContract: "SabnzbdSettings",
            fields: [
                { name: "host", value: $host },
                { name: "port", value: $port },
                { name: "apiKey", value: $key },
                { name: "useSsl", value: false },
                { name: "urlBase", value: "" },
                { name: ($catfield), value: $cat }
            ], tags: []
        }'
}

sabnzbd_connect_apps() {
    servarr_upsert_download_client "Radarr" "$RADARR_URL" "$RADARR_API_KEY" "$SAB_NAME" \
        "$(sab_client_payload movieCategory "$RADARR_CATEGORY")"

    servarr_upsert_download_client "Sonarr" "$SONARR_URL" "$SONARR_API_KEY" "$SAB_NAME" \
        "$(sab_client_payload tvCategory "$SONARR_CATEGORY")"
}
