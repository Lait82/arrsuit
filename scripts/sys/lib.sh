#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/lib.sh - Helpers compartidos por los scripts de sistema
#
#  Se SOURCEA desde cada script de scripts/sys/. Mantiene la misma jerarquia
#  visual que el orquestador Python, para que la salida se vea uniforme aunque
#  venga mezclada de los dos lados.
# =========================================================================

info() { echo -e "  \033[1;36m->\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# docker compose v2 (plugin) o v1 (binario)
detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        die "No encuentro 'docker compose' ni 'docker-compose'."
    fi
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Este script necesita root (toca /srv y docker)."
}
