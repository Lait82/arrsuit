#!/usr/bin/env bash
# =========================================================================
#  scripts/configure-sonarr.sh - Configura Sonarr (series)
#
#  Se SOURCEA desde configure-stack.sh. Solo DEFINE funciones: no ejecuta nada
#  al cargarse, para que el orquestador siga decidiendo cuando corre cada cosa.
#
#  Depende de scripts/lib/common.sh (servarr_*) y de globales que pone el
#  orquestador: DC, PUID, PGID, TAILSCALE_IP, CONF_FILE, LOG_FILE,
#  MEDIA_HOST_DIR, MEDIA_CTR_DIR, TC_NAME, TC_HOST, TC_PORT.
#
#  Hace, en orden (las llama configure-stack.sh):
#    sonarr_apply_auth           -> AuthenticationMethod=External (sin login)
#    sonarr_wait_ready           -> lee config, saca la API key, espera a Sonarr
#    sonarr_add_download_client  -> conecta Sonarr -> qBittorrent
#    sonarr_add_root_folder      -> biblioteca de series
# =========================================================================

# --- Constantes propias del servicio (salen del compose) -----------------
SONARR_PORT=8989                                    # compose.yml: bind de Sonarr
SONARR_CONFIG_XML="/srv/config/sonarr/config.xml"
SONARR_CONTAINER="sonarr"
SONARR_NAME="Sonarr"

# =========================================================================
#  Auth en External. Mismo motivo que Radarr: la IP de Tailscale es CGNAT
#  (100.64.0.0/10) y los *arr solo consideran "local" loopback y RFC1918, asi
#  que DisabledForLocalAddresses no alcanza y te pide login igual.
# =========================================================================
sonarr_apply_auth() {
    servarr_apply_external_auth "$SONARR_CONTAINER" "$SONARR_CONFIG_XML"
}

# =========================================================================
#  Lee la config de Sonarr, valida, extrae la API key y espera a que responda.
#  Setea las globales que usan las funciones siguientes.
# =========================================================================
sonarr_wait_ready() {
    SONARR_CATEGORY="$(conf '.sonarr.downloadClientCategory')"
    [[ -n "$SONARR_CATEGORY" && "$SONARR_CATEGORY" != "null" ]] \
        || die "Falta .sonarr.downloadClientCategory en $CONF_FILE (ej: \"sonarr\")"

    SONARR_ROOT_FOLDER="$(conf '.sonarr.rootFolder')"
    [[ -n "$SONARR_ROOT_FOLDER" && "$SONARR_ROOT_FOLDER" != "null" ]] \
        || die "Falta .sonarr.rootFolder en $CONF_FILE (ej: \"/data/series\")"

    # Igual que Radarr: la ruta es la que ve el CONTENEDOR. El compose monta
    # /srv/media:/data, asi que la biblioteca es /data/series, NO /srv/media/series.
    case "$SONARR_ROOT_FOLDER" in
        /data/*) ;;
        *) die "sonarr.rootFolder debe ser una ruta interna del contenedor (/data/...), no del host. Valor actual: $SONARR_ROOT_FOLDER" ;;
    esac

    SONARR_URL="http://${TAILSCALE_IP}:${SONARR_PORT}"
    SONARR_API_KEY="$(servarr_api_key "$SONARR_CONFIG_XML")"

    echo "  Torrent client : $TC_NAME @ $TC_HOST:$TC_PORT"
    echo "  Categoria      : $SONARR_CATEGORY"
    echo "  Root folder    : $SONARR_ROOT_FOLDER (dentro del contenedor)"
    echo "  Sonarr         : $SONARR_URL"

    servarr_wait_ready "$SONARR_NAME" "$SONARR_URL" "$SONARR_API_KEY"
}

# =========================================================================
#  Conecta Sonarr -> qBittorrent.
#
#  Host 'gluetun' y NO 'sonarr'/'qbittorrent': qBittorrent usa
#  network_mode: service:gluetun, o sea comparte la pila de red de gluetun, y
#  el resto de los servicios lo alcanzan por ahi.
#
#  OJO: los campos NO son los de Radarr. QBittorrentSettings en Sonarr usa
#  tvCategory / recentTvPriority / olderTvPriority donde Radarr usa los movie*.
#  Mandar los de Radarr da un 400 de validacion.
# =========================================================================
sonarr_add_download_client() {
    local existing payload new_id

    # Idempotencia: ¿ya existe el download client?
    if servarr_api GET "$SONARR_URL/api/v3/downloadclient" "$SONARR_API_KEY"; then
        existing="$(echo "$HTTP_BODY" | jq -r --arg n "$TC_NAME" \
            '.[] | select(.name == $n) | .id' | head -n1 || true)"
        if [[ -n "$existing" ]]; then
            warn "Ya existe el download client '$TC_NAME' en Sonarr (id $existing). No se duplica."
            logfile "Sonarr: download client ya existe (id $existing)."
            return 0
        fi
    else
        die "No pude listar download clients de Sonarr (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi

    payload="$(jq -n \
        --arg name "$TC_NAME" --arg host "$TC_HOST" \
        --argjson port "$TC_PORT" --arg category "$SONARR_CATEGORY" \
        '{
            enable: true, protocol: "torrent", priority: 1, name: $name,
            implementation: "QBittorrent", implementationName: "qBittorrent",
            configContract: "QBittorrentSettings",
            fields: [
                { name: "host", value: $host },
                { name: "port", value: $port },
                { name: "useSsl", value: false },
                { name: "tvCategory", value: $category },
                { name: "recentTvPriority", value: 0 },
                { name: "olderTvPriority", value: 0 },
                { name: "initialState", value: 0 },
                { name: "sequentialOrder", value: false },
                { name: "firstAndLast", value: false }
            ], tags: []
        }')"

    # Test antes de guardar: no dejamos guardado un cliente que no conecta.
    log "Probando la conexion Sonarr -> qBittorrent (endpoint /test)..."
    if servarr_api POST "$SONARR_URL/api/v3/downloadclient/test" "$SONARR_API_KEY" "$payload"; then
        log "Test OK: Sonarr alcanza a qBittorrent."
    else
        warn "El test fallo (HTTP $HTTP_CODE):"
        servarr_print_errors
        warn "Log completo en: $LOG_FILE"
        die "Abortando: no guardo un download client que no conecta."
    fi

    log "Agregando el download client a Sonarr..."
    if servarr_api POST "$SONARR_URL/api/v3/downloadclient" "$SONARR_API_KEY" "$payload"; then
        new_id="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
        log "Download client '$TC_NAME' agregado a Sonarr (id ${new_id:-?})"
    else
        warn "Fallo al agregar (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "No se pudo agregar el download client a Sonarr. Ver $LOG_FILE"
    fi
}

# =========================================================================
#  Root folder de series.
#
#  Crea y chownea SU carpeta en vez de confiar en prepare_media_tree: esa
#  funcion tiene 'series' hardcodeado, asi que si cambias .sonarr.rootFolder en
#  el conf, aca se crea igual y con el dueño correcto.
# =========================================================================
sonarr_add_root_folder() {
    servarr_ensure_host_dir "$SONARR_ROOT_FOLDER"
    servarr_assert_dir_writable "$SONARR_CONTAINER" "$SONARR_ROOT_FOLDER"
    servarr_register_root_folder "$SONARR_NAME" "$SONARR_URL" "$SONARR_API_KEY" "$SONARR_ROOT_FOLDER"
}
