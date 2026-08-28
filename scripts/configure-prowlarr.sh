#!/usr/bin/env bash
# =========================================================================
#  scripts/configure-prowlarr.sh - Configura Prowlarr (gestor de indexers)
#
#  Se SOURCEA desde configure-stack.sh. Solo DEFINE funciones.
#
#  Prowlarr es el que sabe DONDE buscar. No descarga nada: mantiene la lista de
#  indexers y se la EMPUJA a Radarr y Sonarr. Por eso va despues de los dos:
#  necesita sus API keys para conectarse.
#
#  OJO CON LA VERSION DE API: Prowlarr usa /api/v1, no /api/v3 como Radarr y
#  Sonarr. Comparte la base de codigo Servarr (header X-Api-Key, config.xml)
#  pero NO el versionado de la API. Pegarle a /api/v3 devuelve 404.
#
#  Hace, en orden (las llama configure-stack.sh):
#    prowlarr_apply_auth       -> AuthenticationMethod=External (sin login)
#    prowlarr_wait_ready       -> saca la API key y espera a que responda
#    prowlarr_add_flaresolverr -> proxy para indexers detras de Cloudflare
#    prowlarr_connect_apps     -> conecta Prowlarr -> Radarr y Prowlarr -> Sonarr
#
#  LO QUE NO HACE: cargar indexers. Cada uno tiene campos propios y varios piden
#  credenciales, asi que eso queda manual en la UI (Indexers -> Add Indexer).
# =========================================================================

# --- Constantes propias del servicio (salen del compose) -----------------
PROWLARR_PORT=9696                                      # compose.yml: bind de Prowlarr
PROWLARR_CONFIG_XML="/srv/config/prowlarr/config.xml"
PROWLARR_CONTAINER="prowlarr"
PROWLARR_NAME="Prowlarr"
PROWLARR_API="v1"                                       # <-- no es v3

# URLs INTERNAS de la red 'media' (no las de Tailscale): son las que usan los
# contenedores para hablar entre si.
PROWLARR_INTERNAL_URL="http://prowlarr:9696"
RADARR_INTERNAL_URL="http://radarr:7878"
SONARR_INTERNAL_URL="http://sonarr:8989"

# FlareSolverr resuelve los challenges de Cloudflare. Corre en el compose pero
# no hace nada hasta que Prowlarr lo tenga cargado como indexer proxy.
FLARESOLVERR_NAME="FlareSolverr"
FLARESOLVERR_URL="http://flaresolverr:8191"
FLARESOLVERR_TAG="flaresolverr"

# =========================================================================
#  Auth en External, mismo motivo que Radarr y Sonarr: Tailscale usa
#  100.64.0.0/10 (CGNAT) y los *arr solo consideran "local" loopback y RFC1918.
# =========================================================================
prowlarr_apply_auth() {
    servarr_apply_external_auth "$PROWLARR_CONTAINER" "$PROWLARR_CONFIG_XML"
}

prowlarr_wait_ready() {
    PROWLARR_URL="http://${TAILSCALE_IP}:${PROWLARR_PORT}"
    PROWLARR_API_KEY="$(servarr_api_key "$PROWLARR_CONFIG_XML")"

    echo "  Prowlarr     : $PROWLARR_URL"
    echo "  FlareSolverr : $FLARESOLVERR_URL"

    servarr_wait_ready "$PROWLARR_NAME" "$PROWLARR_URL" "$PROWLARR_API_KEY" "$PROWLARR_API"
}

# =========================================================================
#  Devuelve el id del tag, creandolo si no existe. Prowlarr aplica el proxy
#  SOLO a los indexers que llevan el tag, asi que el tag es el mecanismo de
#  "este indexer si pasa por FlareSolverr, este no".
# =========================================================================
prowlarr_tag_id() {
    local label="$1" id
    if servarr_api GET "$PROWLARR_URL/api/$PROWLARR_API/tag" "$PROWLARR_API_KEY"; then
        id="$(echo "$HTTP_BODY" | jq -r --arg l "$label" \
            '.[] | select(.label == $l) | .id' | head -n1 || true)"
        [[ -n "$id" ]] && { echo "$id"; return 0; }
    else
        die "No pude listar tags de Prowlarr (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi

    if servarr_api POST "$PROWLARR_URL/api/$PROWLARR_API/tag" "$PROWLARR_API_KEY" \
        "$(jq -n --arg l "$label" '{ label: $l }')"; then
        echo "$HTTP_BODY" | jq -r '.id'
    else
        die "No pude crear el tag '$label' (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi
}

# =========================================================================
#  Carga FlareSolverr como indexer proxy.
#
#  Queda cargado y tageado, pero NO se aplica a nada hasta que le pongas el tag
#  '$FLARESOLVERR_TAG' a un indexer. Eso es a proposito: mandar todos los
#  indexers por FlareSolverr es mas lento y no hace falta.
# =========================================================================
prowlarr_add_flaresolverr() {
    local existing tag_id payload new_id

    if servarr_api GET "$PROWLARR_URL/api/$PROWLARR_API/indexerproxy" "$PROWLARR_API_KEY"; then
        existing="$(echo "$HTTP_BODY" | jq -r --arg n "$FLARESOLVERR_NAME" \
            '.[] | select(.name == $n) | .id' | head -n1 || true)"
        if [[ -n "$existing" ]]; then
            warn "El proxy '$FLARESOLVERR_NAME' ya existe (id $existing). No se duplica."
            logfile "Prowlarr: indexer proxy ya existe (id $existing)."
            return 0
        fi
    else
        die "No pude listar indexer proxies (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi

    tag_id="$(prowlarr_tag_id "$FLARESOLVERR_TAG")"
    info "Tag '$FLARESOLVERR_TAG' listo (id $tag_id)"

    payload="$(jq -n \
        --arg name "$FLARESOLVERR_NAME" --arg host "$FLARESOLVERR_URL" \
        --argjson tag "$tag_id" \
        '{
            name: $name,
            implementation: "FlareSolverr", implementationName: "FlareSolverr",
            configContract: "FlareSolverrSettings",
            fields: [
                { name: "host", value: $host },
                { name: "requestTimeout", value: 60 }
            ],
            tags: [ $tag ]
        }')"

    info "Probando la conexion a FlareSolverr (endpoint /test)..."
    if servarr_api POST "$PROWLARR_URL/api/$PROWLARR_API/indexerproxy/test" \
        "$PROWLARR_API_KEY" "$payload"; then
        info "Test OK: Prowlarr alcanza a FlareSolverr."
    else
        warn "El test de FlareSolverr fallo (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "Abortando: no guardo un proxy que no conecta."
    fi

    info "Agregando el indexer proxy..."
    if servarr_api POST "$PROWLARR_URL/api/$PROWLARR_API/indexerproxy" \
        "$PROWLARR_API_KEY" "$payload"; then
        new_id="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
        info "Proxy '$FLARESOLVERR_NAME' agregado (id ${new_id:-?})"
        info "Para usarlo: poné el tag '$FLARESOLVERR_TAG' en los indexers con Cloudflare."
    else
        warn "Fallo al agregar el proxy (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "No se pudo agregar FlareSolverr. Ver $LOG_FILE"
    fi
}

# =========================================================================
#  prowlarr_add_app <nombre> <implementation> <url_interna> <config.xml>
#
#  Registra una app en Prowlarr para que le empuje los indexers.
#  Las URLs son las INTERNAS de la red 'media' (http://radarr:7878), no las de
#  Tailscale: el que hace la request es el contenedor de Prowlarr, no vos.
#
#  syncLevel "fullSync": Prowlarr agrega, actualiza Y borra indexers en la app.
#  Es lo que hace que no tengas que tocar los indexers en Radarr/Sonarr nunca mas.
# =========================================================================
prowlarr_add_app() {
    local name="$1" impl="$2" app_url="$3" app_xml="$4"
    local existing app_key payload new_id

    if servarr_api GET "$PROWLARR_URL/api/$PROWLARR_API/applications" "$PROWLARR_API_KEY"; then
        existing="$(echo "$HTTP_BODY" | jq -r --arg n "$name" \
            '.[] | select(.name == $n) | .id' | head -n1 || true)"
        if [[ -n "$existing" ]]; then
            warn "La app '$name' ya esta conectada a Prowlarr (id $existing). No se duplica."
            logfile "Prowlarr: application '$name' ya existe (id $existing)."
            return 0
        fi
    else
        die "No pude listar applications de Prowlarr (HTTP $HTTP_CODE). Ver $LOG_FILE"
    fi

    app_key="$(servarr_api_key "$app_xml")"

    payload="$(jq -n \
        --arg name "$name" --arg impl "$impl" \
        --arg prowlarr "$PROWLARR_INTERNAL_URL" --arg appurl "$app_url" \
        --arg key "$app_key" \
        '{
            name: $name, syncLevel: "fullSync",
            implementation: $impl, implementationName: $impl,
            configContract: ($impl + "Settings"),
            fields: [
                { name: "prowlarrUrl", value: $prowlarr },
                { name: "baseUrl", value: $appurl },
                { name: "apiKey", value: $key }
            ],
            tags: []
        }')"

    info "Probando la conexion Prowlarr -> $name (endpoint /test)..."
    if servarr_api POST "$PROWLARR_URL/api/$PROWLARR_API/applications/test" \
        "$PROWLARR_API_KEY" "$payload"; then
        info "Test OK: Prowlarr alcanza a $name."
    else
        warn "El test contra $name fallo (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "Abortando: no guardo una app que no conecta."
    fi

    info "Conectando $name a Prowlarr..."
    if servarr_api POST "$PROWLARR_URL/api/$PROWLARR_API/applications" \
        "$PROWLARR_API_KEY" "$payload"; then
        new_id="$(echo "$HTTP_BODY" | jq -r '.id // empty')"
        info "App '$name' conectada (id ${new_id:-?})"
    else
        warn "Fallo al conectar $name (HTTP $HTTP_CODE):"
        servarr_print_errors
        die "No se pudo conectar $name a Prowlarr. Ver $LOG_FILE"
    fi
}

prowlarr_connect_apps() {
    prowlarr_add_app "Radarr" "Radarr" "$RADARR_INTERNAL_URL" "$RADARR_CONFIG_XML"
    prowlarr_add_app "Sonarr" "Sonarr" "$SONARR_INTERNAL_URL" "$SONARR_CONFIG_XML"
}
