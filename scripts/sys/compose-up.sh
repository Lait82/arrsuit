#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/compose-up.sh <repo_root>
#
#  Sincroniza el stack con el compose.
#
#  'up -d' SIEMPRE, no solo cuando el stack esta abajo. Es idempotente: crea lo
#  que falta, recrea lo que cambio de config y no toca el resto.
#
#  Antes esto estaba detras de un "¿esta corriendo qbittorrent?" y se salteaba
#  entero si el stack ya estaba arriba. Consecuencia: al agregar un servicio
#  nuevo al compose (SABnzbd fue el caso), el contenedor NUNCA se creaba y los
#  pasos siguientes fallaban buscando un archivo que no existia.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT="${1:?falta el repo_root}"
cd "$REPO_ROOT" || die "No pude entrar a $REPO_ROOT"

DC="$(detect_compose)"

before="$($DC ps --status running --quiet 2>/dev/null | wc -l)"
info "Sincronizando el stack con el compose ($before contenedores arriba)..."
$DC up -d
after="$($DC ps --status running --quiet 2>/dev/null | wc -l)"

if [[ "$after" -gt "$before" ]]; then
    info "Arrancaron $(( after - before )) contenedores nuevos. Esperando 10s..."
    sleep 10
else
    info "El stack ya estaba al dia ($after contenedores)."
fi
