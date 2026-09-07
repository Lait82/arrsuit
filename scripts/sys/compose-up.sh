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
#  EL PULL VA APARTE del 'up -d' y con reintentos: es el unico tramo que sale
#  a internet y el que se cae. Casi todas las imagenes del stack viven en
#  ghcr.io (lscr.io es un alias suyo), y GitHub corta las conexiones cuando el
#  compose le abre una decena de descargas en paralelo: el pull muere con
#  'connection reset by peer' y se lleva puesto todo el paso. Reintentar
#  alcanza porque las capas ya bajadas quedan en el cache local, asi que cada
#  vuelta arranca donde quedo la anterior.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Cuantos servicios toca compose a la vez. El default (todos juntos) es lo que
# dispara el corte de GitHub. Se puede subir por entorno si la red aguanta.
export COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-3}"
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

info "Bajando las imagenes que falten..."
for attempt in $(seq 1 "$PULL_RETRIES"); do
    if $DC "${PROFILE_ARGS[@]}" pull; then
        break
    fi
    (( attempt == PULL_RETRIES )) \
        && die "No pude bajar las imagenes ($PULL_RETRIES intentos). Revisa la salida de arriba."
    delay=$(( attempt * 10 ))
    warn "Fallo el pull (intento $attempt/$PULL_RETRIES). Reintento en ${delay}s..."
    sleep "$delay"
done

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
