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
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
