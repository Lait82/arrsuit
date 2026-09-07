#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/compose-up.sh <repo_root> [perfil...]
#
#  Sincroniza el stack con el compose.
#
#  'up -d' SIEMPRE, sin preguntar si el stack esta arriba: es idempotente y es
#  lo unico que crea los servicios que se hayan agregado al compose desde la
#  ultima corrida.
#
#  Los perfiles son opcionales y van sueltos al final. Hoy el unico es 'geo'
#  (el contenedor geoipupdate), que solo se levanta si hay credenciales de
#  MaxMind: sin ellas la imagen sale con error y quedaria reiniciandose.
#
#  EL PULL VA APARTE del 'up -d', DE A UNA IMAGEN y con reintentos. El pull es
#  el unico tramo que sale a internet y el que se cae: las capas de casi todo
#  el stack salen del CDN de GitHub (lscr.io es un alias de ghcr.io) y esa
#  descarga muere con 'connection reset by peer'.
#
#  De a una y no todas juntas por como reacciona compose al fallo: cuando una
#  descarga se corta, cancela las demas ('Interrupted') y se pierde lo que
#  estaban bajando. Servicio por servicio, un corte se lleva puesta una sola
#  imagen y el resto queda en el cache local. Con eso el reintento siempre
#  avanza, y las capas a medio bajar tambien quedan cacheadas.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PULL_RETRIES=3

REPO_ROOT="${1:?falta el repo_root}"; shift
cd "$REPO_ROOT" || die "No pude entrar a $REPO_ROOT"

DC="$(detect_compose)"

PROFILE_ARGS=()
for profile in "$@"; do
    PROFILE_ARGS+=(--profile "$profile")
done
if (( ${#PROFILE_ARGS[@]} > 0 )); then
    info "Perfiles activos: $*"
fi

# La lista sale del compose y no de una constante: un servicio nuevo entra solo.
mapfile -t SERVICES < <($DC "${PROFILE_ARGS[@]}" config --services)
(( ${#SERVICES[@]} > 0 )) || die "El compose no declara ningun servicio."

info "Bajando las imagenes que falten (${#SERVICES[@]} servicios, de a uno)..."
failed=()
for svc in "${SERVICES[@]}"; do
    for attempt in $(seq 1 "$PULL_RETRIES"); do
        if $DC "${PROFILE_ARGS[@]}" pull "$svc"; then
            break
        fi
        if (( attempt == PULL_RETRIES )); then
            # No se aborta en la primera imagen que falla: se sigue con las
            # demas para que la corrida deje bajado todo lo que se pueda.
            warn "No pude bajar '$svc' ($PULL_RETRIES intentos)."
            failed+=("$svc")
            break
        fi
        delay=$(( attempt * 10 ))
        warn "Fallo el pull de '$svc' (intento $attempt/$PULL_RETRIES). Reintento en ${delay}s..."
        sleep "$delay"
    done
done

if (( ${#failed[@]} > 0 )); then
    die "Quedaron imagenes sin bajar: ${failed[*]}. Volve a correr esto: lo ya bajado no se repite."
fi

before="$($DC ps --status running --quiet 2>/dev/null | wc -l)"
info "Sincronizando el stack con el compose ($before contenedores arriba)..."
$DC "${PROFILE_ARGS[@]}" up -d
after="$($DC ps --status running --quiet 2>/dev/null | wc -l)"

if [[ "$after" -gt "$before" ]]; then
    info "Arrancaron $(( after - before )) contenedores nuevos. Esperando 10s..."
    sleep 10
else
    info "El stack ya estaba al dia ($after contenedores)."
fi
