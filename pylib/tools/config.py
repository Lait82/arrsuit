"""Configuracion del stack: .env, services_setup.conf y las constantes fijas.

Separacion que se mantiene del bash:
  - CONSTANTES  -> las define el compose, no son configurables (puertos,
                   nombres de contenedor, subnet). Viven aca como codigo.
  - .env        -> secretos y la IP de Tailscale (la escribe setup-host.sh)
  - conf (JSON) -> lo que el usuario elige (categorias, carpetas)
"""

import json
import re
from pathlib import Path

from . import ui

# =========================================================================
#  CONSTANTES DEL STACK (definidas por compose.yml, NO son "config")
# =========================================================================
#  TC_HOST=gluetun  -> qBittorrent usa network_mode: service:gluetun, o sea
#                      comparte su stack de red. El resto de los servicios lo
#                      alcanzan como 'gluetun', NO como 'qbittorrent': ese
#                      nombre no resuelve en la red 'media'.
#  PUID/PGID=1000   -> los del compose. Adentro del contenedor ese uid es 'abc'.
TC_NAME = "qBittorrent"
TC_HOST = "gluetun"
TC_PORT = 8080

MEDIA_SUBNET = "172.20.0.0/16"
MEDIA_HOST_DIR = "/srv/media"
MEDIA_CTR_DIR = "/data"
CONFIG_HOST_DIR = "/srv/config"

PUID = 1000
PGID = 1000

QBIT_CONTAINER = "qbittorrent"
QBIT_CONF = "/srv/config/qbittorrent/qBittorrent/qBittorrent.conf"

# =========================================================================
#  RANGOS "LOCALES"
#
#
#  En SABnzbd esta lista REEMPLAZA el default, no lo extiende. Por
#  eso tienen que estar tambien loopback y los RFC1918.
#
#  No son configuracion: son las constantes de las RFC que definen cada rango.
LOCAL_RANGES=",".join([
    # Default local ranges
    "127.0.0.1",
    "::1",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",

    # Tailnet range
    "100.64.0.0/10"
])


def ctr_to_host_path(ctr_path: str) -> str:
    """/data/movies -> /srv/media/movies

    La config habla en rutas del CONTENEDOR; el mkdir y el chown pasan en el
    host. El compose monta /srv/media como /data.
    """
    if ctr_path == MEDIA_CTR_DIR:
        return MEDIA_HOST_DIR
    return MEDIA_HOST_DIR + ctr_path[len(MEDIA_CTR_DIR):]


def require_container_path(value: str, what: str) -> str:
    """Valida que una ruta sea interna del contenedor.

    Es el error mas facil de cometer en este stack: poner /srv/media/movies
    (ruta del host) donde va /data/movies (ruta que ve el servicio). El
    servicio no ve el filesystem del host, asi que falla con un mensaje
    confuso mucho despues.
    """
    if not value.startswith(MEDIA_CTR_DIR + "/"):
        ui.die(
            f"{what} debe ser una ruta interna del contenedor "
            f"({MEDIA_CTR_DIR}/...), no del host. Valor actual: {value}"
        )
    return value


class Config:
    def __init__(self, repo_root: Path):
        self.repo_root = repo_root
        self.conf_file = repo_root / "configs" / "services_setup.conf"
        self.env_file = repo_root / ".env"

        if not self.conf_file.is_file():
            ui.die(f"No existe {self.conf_file}")
        if not self.env_file.is_file():
            ui.die(f"No existe {self.env_file} (lo escribe setup-host.sh)")

        try:
            self._data = json.loads(self.conf_file.read_text())
        except json.JSONDecodeError as exc:
            ui.die(f"{self.conf_file} no es JSON valido: {exc}")

        self._env = self._read_env(self.env_file)

        self.tailscale_ip = self._env.get("TAILSCALE_IP", "")
        if not self.tailscale_ip:
            ui.die("TAILSCALE_IP vacio en .env. ¿Corriste setup-host.sh?")

    @staticmethod
    def _read_env(path: Path) -> dict[str, str]:
        """Parsea el .env sin sourcearlo.

        Sourcear un .env ejecuta lo que tenga adentro; aca solo queremos leer
        pares KEY=VALUE.
        """
        env: dict[str, str] = {}
        pattern = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")
        for line in path.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = pattern.match(line)
            if not match:
                continue
            key, raw = match.groups()
            raw = raw.split(" #")[0].strip()
            if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
                raw = raw[1:-1]
            env[key] = raw
        return env

    def env(self, name: str, required: bool = True) -> str:
        """Lee una variable del .env. Ahi viven los secretos, nunca en el JSON:
        services_setup.conf se commitea, el .env esta en .gitignore."""
        value = self._env.get(name, "")
        if not value and required:
            ui.die(
                f"Falta {name} en {self.env_file}. "
                f"Mirá env.example para saber que va ahi."
            )
        return value

    def get(self, *keys: str, default=None, required: bool = True):
        """conf.get('sabnzbd', 'port') -> valor de .sabnzbd.port"""
        node = self._data
        for key in keys:
            if not isinstance(node, dict) or key not in node:
                if required and default is None:
                    path = "." + ".".join(keys)
                    ui.die(f"Falta {path} en {self.conf_file}")
                return default
            node = node[key]
        return node
