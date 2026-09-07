#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/install-conf.sh <puid> <pgid> <src> <dst> [<src> <dst> ...]
#
#  Copia archivos de config del repo a /srv/config con el dueño correcto.
#  Los pares src/dst vienen sueltos como argumentos, en orden.
#
#  Por que copiar y no bind-mountear cada archivo desde el repo:
#  las imagenes de LinuxServer tratan /config como suyo. En el arranque
#  crean carpetas, copian defaults y corren chown ahi adentro. Un bind
#  read-only de un archivo suelto hace fallar ese chown y el contenedor no
#  levanta. Copiando, /config queda siendo un directorio comun y corriente.
#
#  Contra: /srv/config no se sincroniza solo si editas el repo. Por eso esto
#  corre en cada pasada de configure-stack.py, que es idempotente.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

PUID="${1:?falta puid}"; shift
PGID="${1:?falta pgid}"; shift

(( $# > 0 ))     || die "No me pasaste ningun par src/dst."
(( $# % 2 == 0 )) || die "Los argumentos van de a pares src/dst (recibi $#)."

# Crea un directorio y todos los niveles que falten, chowneando SOLO los que
# creo. Un 'mkdir -p' seguido de chown a la hoja dejaria los intermedios en
# root:root, y ahi es donde los contenedores escriben sus logs.
ensure_dir() {
    local dir="$1" d="$1"
    local missing=()

    while [[ ! -d "$d" && "$d" != "/" ]]; do
        missing+=("$d")
        d="$(dirname "$d")"
    done
    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    mkdir -p "$dir" || die "No pude crear $dir"
    for d in "${missing[@]}"; do
        chown "${PUID}:${PGID}" "$d"
    done
}

while (( $# > 0 )); do
    src="$1"; dst="$2"; shift 2

    [[ -f "$src" ]] || die "No existe el origen $src"

    ensure_dir "$(dirname "$dst")"

    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        info "Ya al dia: $dst"
        continue
    fi

    install -m 0644 -o "$PUID" -g "$PGID" "$src" "$dst" || die "No pude escribir $dst"
    info "Instalado: $dst"
done
