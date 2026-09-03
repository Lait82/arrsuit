"""Configuracion del stack: .env, services_setup.conf y las constantes fijas.

Separacion que se mantiene del bash:
  - CONSTANTES  -> las define el compose, no son configurables (puertos,
                   nombres de contenedor, subnet). Viven aca como codigo.
  - .env        -> secretos y la IP de Tailscale (la escribe el paso 1)
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

#  Rutas de config de nginx y fail2ban vistas DESDE EL HOST.
#  El 'nginx/nginx' y el 'fail2ban/fail2ban' repetidos no son un typo: el
#  compose monta /srv/config/nginx como /config, y adentro de esa imagen el
#  arbol de config cuelga de /config/nginx/. Lo mismo con fail2ban.
NGINX_CONTAINER = "nginx"
NGINX_SITE_CONFS_DIR = "/srv/config/nginx/nginx/site-confs"
NGINX_CONF_DIR = "/srv/config/nginx/nginx"

F2B_CONTAINER = "fail2ban"
F2B_FILTER_DIR = "/srv/config/fail2ban/fail2ban/filter.d"
F2B_JAIL_DIR = "/srv/config/fail2ban/fail2ban/jail.d"



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
            ui.die(f"No existe {self.env_file}. Copiá la plantilla: cp env.example .env")

        try:
            self._data = json.loads(self.conf_file.read_text())
        except json.JSONDecodeError as exc:
            ui.die(f"{self.conf_file} no es JSON valido: {exc}")

        self._env = self._read_env(self.env_file)

    def reload_env(self) -> None:
        """Vuelve a leer el .env.

        Hace falta porque el paso 1 del orquestador ESCRIBE en el .env: es el
        que descubre la IP de Tailscale. Sin esto, el resto de la corrida
        seguiria viendo el .env como estaba al arrancar.
        """
        self._env = self._read_env(self.env_file)

    @property
    def tailscale_ip(self) -> str:
        """IP del tailnet. La escribe el paso 1 (scripts/sys/tailscale-up.sh).

        Es una property y no un atributo fijado en __init__ a proposito: quien
        la produce corre DESPUES de que se construye este objeto. Leerla en el
        constructor devolvia siempre el valor viejo (o vacio, en la primera
        corrida) y las URLs de los servicios quedaban armadas mal.
        """
        ip = self._env.get("TAILSCALE_IP", "")
        if not ip:
            ui.die(
                "TAILSCALE_IP vacio en .env. La escribe el paso "
                "'Preparando el host'; si llegaste hasta aca sin ella, ese paso fallo."
            )
        return ip

    @property
    def ssh_port(self) -> str:
        """Puerto SSH a abrir en el firewall. Default 22.

        Si no coincide con el real, el 'ufw enable' te deja afuera del server.
        """
        return self._env.get("SSH_PORT", "") or "22"

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
