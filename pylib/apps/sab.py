"""SABnzbd: cliente de descargas USENET.

NO ES UNA APP SERVARR, por eso no hereda de Servarr:
  - La API key esta en /config/sabnzbd.ini, no en un config.xml
  - Autentica por query param (?apikey=X), no por header X-Api-Key
  - La API es /api?mode=<accion>, no /api/vN/<recurso>
  - Devuelve HTTP 200 aunque la operacion falle: el error viene en el body

Convive con qBittorrent, no lo reemplaza: Radarr y Sonarr manejan torrent y
usenet a la vez.

LO QUE NO HACE: cargar tu proveedor de Usenet (servidor de news, usuario y
contrasenia). Es una credencial paga y personal -> a mano en Config -> Servers.
Sin eso SABnzbd no baja nada, por mas que Radarr le mande trabajo.
"""

import re
from pathlib import Path
from typing import Any

from pylib.tools import api
from pylib.tools import ui

from pylib.tools import config

SAB_NAME = "SABnzbd"
SAB_CONTAINER = "sabnzbd"
SAB_INI = Path("/srv/config/sabnzbd/sabnzbd.ini")

# Puerto INTERNO: el que usan Radarr y Sonarr por la red 'media'. Adentro del
# contenedor escucha en 8080 aunque afuera se publique en 8081.
SAB_INTERNAL_HOST = "sabnzbd"
SAB_INTERNAL_PORT = 8080


class Sabnzbd:
    def __init__(self, cfg: config.Config):
        self.cfg = cfg
        self.port = cfg.get("sabnzbd", "port")
        self.complete_dir = config.require_container_path(
            cfg.get("sabnzbd", "completeDir"), "sabnzbd.completeDir"
        )
        self.incomplete_dir = config.require_container_path(
            cfg.get("sabnzbd", "incompleteDir"), "sabnzbd.incompleteDir"
        )

        # POR LOOPBACK Y NO POR LA IP DE TAILSCALE:
        # SABnzbd rechaza con 403 "External internet access denied" todo lo que
        # no venga de sus rangos locales (loopback + RFC1918). Por la IP de
        # Tailscale el paquete da la vuelta por esa interfaz y SABnzbd ve como
        # origen 100.64.x.x, que es CGNAT y NO es RFC1918 -> 403, aunque la
        # request salga de la misma maquina.
        # El compose publica el puerto en las dos IPs justamente para esto.
        self.url = f"http://127.0.0.1:{self.port}"
        self.ui_url = f"http://{cfg.tailscale_ip}:{self.port}"
        self._api_key: str | None = None

    @property
    def api_key(self) -> str:
        if self._api_key is None:
            if not SAB_INI.is_file():
                ui.die(f"No encuentro {SAB_INI}. ¿SABnzbd arranco al menos una vez?")
            match = re.search(r"^api_key\s*=\s*(\S+)", SAB_INI.read_text(), re.MULTILINE)
            if not match:
                ui.die(f"No pude extraer api_key de {SAB_INI}")
            self._api_key = match.group(1)
        return self._api_key

    def call(self, mode: str, **params: Any) -> api.Response:
        query = {"mode": mode, "output": "json", "apikey": self.api_key, **params}
        url = api.build_url(self.url, "api", query)
        resp = api.request("GET", url, secret=self.api_key)

        # SABnzbd devuelve 200 aunque la operacion falle; el error viene en el
        # body como {"status": false, "error": "..."}. Chequear solo el codigo
        # HTTP daria un falso OK.
        if resp.ok:
            data = resp.json()
            if isinstance(data, dict) and data.get("status") is False:
                resp.status = 400
        return resp

    @staticmethod
    def error_of(resp: api.Response) -> str:
        data = resp.json()
        if isinstance(data, dict) and data.get("error"):
            return str(data["error"])
        return resp.body

    def wait_ready(self, attempts: int = 30, delay: int = 2) -> None:
        ui.detail(f"SABnzbd (API): {self.url}")
        ui.detail(f"SABnzbd (UI) : {self.ui_url}")
        ui.detail(f"Completos    : {self.complete_dir}")
        ui.detail(f"Incompletos  : {self.incomplete_dir}")

        ok = ui.wait_for(
            "Esperando a que SABnzbd responda",
            lambda: self.call("version").ok,
            attempts,
            delay,
        )
        if not ok:
            ui.die(f"SABnzbd no respondio despues de {attempts * delay}s.")

    def set_config(self, section: str, keyword: str, **values: Any) -> None:
        resp = self.call("set_config", section=section, keyword=keyword, **values)
        if not resp.ok:
            ui.warn(f"Fallo set_config {section}/{keyword}: {self.error_of(resp)}")
            ui.die("No pude configurar SABnzbd.")

    def ensure_host_whitelist(self) -> None:
        """host_whitelist es un chequeo DISTINTO de local_ranges.

        local_ranges mira la IP de origen; host_whitelist mira el header Host.
        Son dos filtros independientes:

            script  -> http://127.0.0.1:8081   Host es una IP    -> no se verifica
            Radarr  -> http://sabnzbd:8080     Host es 'sabnzbd' -> SI se verifica

        Sin esto, Radarr y Sonarr reciben "Hostname verification failed" y el
        download client no conecta nunca.
        """
        resp = self.call("get_config", section="misc", keyword="host_whitelist")
        current = ""
        if resp.ok:
            data = resp.json() or {}
            current = (data.get("config", {}).get("misc", {}).get("host_whitelist")[0] or "")

        entries = [e for e in current.split(",") if e]
        if SAB_INTERNAL_HOST in entries:
            ui.info(f"host_whitelist ya incluye '{SAB_INTERNAL_HOST}'. No se toca.")
            return

        entries.append(SAB_INTERNAL_HOST)
        ui.info(f"Agregando '{SAB_INTERNAL_HOST}' al host_whitelist...")
        self.set_config("misc", "host_whitelist", value=",".join(entries))

    def configure_dirs(self) -> None:
        ui.info("Configurando carpetas de descarga...")
        self.set_config("misc", "download_dir", value=self.incomplete_dir)
        self.set_config("misc", "complete_dir", value=self.complete_dir)

    def configure_categories(self, categories: list[str]) -> None:
        """Reusan los nombres de las categorias de qBittorrent, asi Radarr y
        Sonarr usan la misma etiqueta para torrent y para usenet."""
        for cat in categories:
            ui.info(f"Creando categoria '{cat}' en SABnzbd...")
            self.set_config("categories", cat, name=cat, dir=cat)

    # =====================================================================
    #  Proveedor de Usenet (news server)
    #
    #  ES LA PIEZA SIN LA CUAL NADA BAJA. El indexer (nzb.life) dice DONDE
    #  esta el contenido; el proveedor es DE DONDE se descarga. Son dos
    #  suscripciones distintas y SABnzbd necesita las dos.
    #
    #  El host y el puerto van en el conf (no son secretos); el usuario y la
    #  contrasenia van en el .env, que esta en .gitignore.
    # =====================================================================
    def configure_server(self) -> None:
        server = self.cfg.get("sabnzbd", "server", default=None, required=False)
        if not server:
            ui.warn(
                "No hay .sabnzbd.server en el conf: SABnzbd queda sin proveedor "
                "y no va a poder descargar nada."
            )
            return

        host = (server.get("host") or "").strip()
        if not host or host.startswith("USENET"):
            ui.warn(
                f"El host del proveedor sigue sin completar en {self.cfg.conf_file} "
                "(.sabnzbd.server.host). SABnzbd no va a poder descargar."
            )
            return

        use_ssl = server.get("ssl", True)
        if use_ssl:
            port =(server.get("sslPort") or "")
            if not port:
                ui.warn(
                    f"Ssl esta activado y el port ssl del proveedor de usenet en {self.cfg.conf_file} esta vacio"
                    " SABnzbd no va a poder descargar."
                )
                return
        else:
            port =(server.get("noSslPort") or "")
            if not port:
                ui.warn(
                    f"El port del proveedor de usenet en {self.cfg.conf_file} esta vacio"
                    " SABnzbd no va a poder descargar."
                )
                return

        name = host
        connections = server.get("connections", 8)
        username = self.cfg.env(server["usernameEnv"])
        password = self.cfg.env(server["passwordEnv"])

        # La password viaja como query param: registrarla ANTES de la primera
        # llamada, si no queda en claro en configure-stack.log.
        ui.add_secret(password)
        ui.add_secret(username)

        params = {
            "host": host,
            "port": port,
            "username": username,
            "password": password,
            "connections": connections,
            "ssl": 1 if use_ssl else 0,
        }

        # Idempotencia: SABnzbd indexa los servidores por nombre, pero lo que
        # importa es que no haya dos apuntando al mismo host.
        existing = self.call("get_config", section="servers")
        if existing.ok:
            servers = (existing.json() or {}).get("config", {}).get("servers", [])
            for srv in servers:
                if srv.get("host") == host:
                    ui.warn(
                        f"El proveedor '{srv.get('name', host)}' ya esta cargado. "
                        "No se duplica."
                    )
                    return

        ui.detail(f"Proveedor : {host}:{port} ({'SSL' if use_ssl else 'sin SSL'})")
        ui.detail(f"Conexiones: {connections}")

        # test_server valida credenciales contra el proveedor real antes de
        # guardar. Mismo criterio que con los download clients: no dejamos
        # configurado algo que no conecta, porque despues falla en silencio.
        ui.info(f"Probando el proveedor {host}...")
        test = self.call("test_server", **params)
        if not test.ok:
            ui.warn(f"El proveedor rechazo la conexion: {self.error_of(test)}")
            ui.warn("Revisá host, puerto, usuario y contrasenia.")
            ui.warn("Si el puerto es 119 en vez de 563, poné \"ssl\": false en el conf.")
            ui.die("Abortando: no guardo un proveedor que no conecta.")
        ui.info("Test OK: el proveedor acepta la conexion.")

        ui.info(f"Guardando el proveedor '{name}'...")
        self.set_config("servers", name, **params)
        ui.info(f"Proveedor '{name}' cargado. SABnzbd ya puede descargar.")

    def client_payload(self, category_field: str, category: str) -> dict:
        """host/port son los INTERNOS (sabnzbd:8080): quien hace la request es
        el contenedor de Radarr/Sonarr por la red 'media', no vos por Tailscale."""
        return {
            "enable": True,
            "protocol": "usenet",
            "priority": 1,
            "name": SAB_NAME,
            "implementation": "Sabnzbd",
            "implementationName": "SABnzbd",
            "configContract": "SabnzbdSettings",
            "fields": [
                {"name": "host", "value": SAB_INTERNAL_HOST},
                {"name": "port", "value": SAB_INTERNAL_PORT},
                {"name": "apiKey", "value": self.api_key},
                {"name": "useSsl", "value": False},
                {"name": "urlBase", "value": ""},
                {"name": category_field, "value": category},
            ],
            "tags": [],
        }
