#!/usr/bin/env bash
# =========================================================================
#  scripts/sys/tailscale-up.sh <env_file>
#
#  Deja Tailscale instalado, levantado y con su IP escrita en el .env.
#
#  Esa IP es la que el compose lee como ${TAILSCALE_IP} para bindear los
#  paneles. Es lo unico que los tapa de internet: UFW no alcanza, porque
#  Docker publica los puertos con sus propias reglas de DNAT que se evaluan
#  antes que las cadenas de UFW.
#
#  DONDE FRENA: la autenticacion de Tailscale abre una URL en el navegador y
#  no se puede automatizar sin auth key. Si no estas autenticado, este script
#  aborta con las instrucciones y el orquestador entero se detiene. Autenticas,
#  volves a correr el orquestador y sigue de largo: todos los pasos son
#  idempotentes, asi que repetir no cuesta nada.
#
#  IDEMPOTENCIA: no reinstala si ya esta, no reinicia el daemon si ya corre, y
#  no reescribe el .env si la IP no cambio.
# =========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

ENV_FILE="${1:?falta el env_file}"
[[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE"

if ! command -v tailscale >/dev/null 2>&1; then
    info "Instalando Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh || die "Fallo la instalacion de Tailscale"
else
    info "Tailscale ya instalado."
fi

if [[ "$(systemctl is-active tailscaled 2>/dev/null || true)" != "active" ]]; then
    info "Levantando tailscaled..."
    systemctl enable --now tailscaled || die "No pude levantar tailscaled"
fi

if ! tailscale status >/dev/null 2>&1; then
    warn "Tailscale esta instalado pero SIN autenticar."
    echo ""
    echo "  Corré esto y autenticá en el navegador:"
    echo "      sudo tailscale up --ssh"
    echo ""
    echo "  Cuando termines, volvé a correr el orquestador."
    echo ""
    die "Autenticá Tailscale y reintentá."
fi

IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[[ -n "$IP" ]] || die "No pude obtener la IP de Tailscale pese a que 'tailscale status' anda."

if grep -qx "TAILSCALE_IP=$IP" "$ENV_FILE"; then
    info "IP de Tailscale: $IP (el .env ya esta al dia)"
    exit 0
fi

if grep -q '^TAILSCALE_IP=' "$ENV_FILE"; then
    # La IP no lleva caracteres que sed interprete, pero el delimitador '|'
    # evita sorpresas si algun dia esto pasa a aceptar IPv6.
    sed -i "s|^TAILSCALE_IP=.*|TAILSCALE_IP=$IP|" "$ENV_FILE"
else
    printf '\n# IP de Tailscale (la escribe scripts/sys/tailscale-up.sh)\nTAILSCALE_IP=%s\n' \
        "$IP" >> "$ENV_FILE"
fi
info "IP de Tailscale: $IP (escrita en $ENV_FILE)"
