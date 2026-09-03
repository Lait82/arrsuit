"""La capa del host: Tailscale y el firewall.

Es lo unico del stack que NO puede vivir en un contenedor. Tailscale crea una
interfaz de red del host y UFW son las reglas del host; meterlos adentro no
tendria sentido. Todo lo demas (nginx, fail2ban, geoipupdate, los *arr) es
compose.

ES EL PASO 1 Y NO UN SCRIPT APARTE porque produce algo que el resto necesita:
la IP del tailnet, que se escribe en el .env y que el compose lee como
${TAILSCALE_IP} para bindear los paneles. Corriendolo por fuera, el orden
quedaba a cargo de quien leyera la guia.

DONDE PUEDE FRENAR LA CORRIDA: si Tailscale no esta autenticado. Esa parte abre
una URL en el navegador y no se automatiza sin auth key, asi que el paso aborta
con las instrucciones. Autenticas, volves a correr el orquestador entero y
sigue: todos los pasos son idempotentes.
"""

from pathlib import Path

from ..tools import config, sh

# Lo unico que el host necesita por fuera de Docker.
PACKAGES = ["ufw"]


class Host:
    def __init__(self, cfg: config.Config):
        self.cfg = cfg

    def setup(self, sys_scripts: Path) -> None:
        sh.run_script(sys_scripts / "host-packages.sh", *PACKAGES)

        # Escribe TAILSCALE_IP en el .env; el reload es lo que hace que el
        # resto de la corrida (y el compose) vean la IP recien descubierta.
        sh.run_script(sys_scripts / "tailscale-up.sh", self.cfg.env_file)
        self.cfg.reload_env()

        # El firewall va ULTIMO: necesita que la interfaz tailscale0 exista
        # para poder abrirla antes del enable, o te deja afuera del server.
        sh.run_script(sys_scripts / "ufw-rules.sh", self.cfg.ssh_port)
