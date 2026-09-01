"""Radarr, Sonarr y Prowlarr: comparten base de codigo (Servarr).

Lo que comparten y por eso vive en la clase base:
  - API key en /config/config.xml
  - Header X-Api-Key
  - Endpoints /api/<version>/<recurso>
  - AuthenticationMethod=External en el mismo XML

Lo que NO comparten, y por eso son atributos de clase:
  - El puerto
  - La VERSION DE API: Prowlarr usa v1, Radarr y Sonarr v3. Pegarle a la
    version equivocada devuelve 404.
  - Los campos de categoria del download client: Radarr usa movieCategory /
    recentMoviePriority / olderMoviePriority, Sonarr usa los tv*. Mandar los
    del otro da un 400 de validacion.
"""

import copy
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from pylib.tools import api
from pylib.tools import ui

from pylib.tools import config


class Servarr:
    """Base de una app Servarr. No se instancia directa."""

    name: str = ""
    container: str = ""
    port: int = 0
    api_version: str = "v3"

    def __init__(self, cfg: config.Config):
        self.cfg = cfg
        self.config_xml = Path(f"/srv/config/{self.container}/config.xml")
        self.url = f"http://{cfg.tailscale_ip}:{self.port}"
        self.internal_url = f"http://{self.container}:{self.port}"
        self._api_key: str | None = None

    # --- API key ---------------------------------------------------------
    @property
    def api_key(self) -> str:
        """Lee <ApiKey> del config.xml. Se genera sola en el primer arranque."""
        if self._api_key is None:
            if not self.config_xml.is_file():
                ui.die(
                    f"No encuentro {self.config_xml}. "
                    f"¿El contenedor '{self.container}' arranco al menos una vez?"
                )
            try:
                root = ET.parse(self.config_xml).getroot()
            except ET.ParseError as exc:
                ui.die(f"{self.config_xml} no es XML valido: {exc}")
            node = root.find("ApiKey")
            if node is None or not (node.text or "").strip():
                ui.die(f"No pude extraer la ApiKey de {self.config_xml}")
            self._api_key = node.text.strip()
        return self._api_key

    # --- HTTP ------------------------------------------------------------
    def call(self, method: str, path: str, data: Any = None) -> api.Response:
        url = f"{self.url}/api/{self.api_version}{path}"
        return api.request(method, url, headers={"X-Api-Key": self.api_key}, data=data)

    def wait_ready(self, attempts: int = 30, delay: int = 2) -> None:
        ok = ui.wait_for(
            f"Esperando a que {self.name} responda",
            lambda: self.call("GET", "/system/status").ok,
            attempts,
            delay,
        )
        if not ok:
            ui.die(f"{self.name} no respondio despues de {attempts * delay}s.")

    # --- Auth ------------------------------------------------------------
    def apply_external_auth(self, scripts_dir: Path) -> None:
        """Delega en bash: es cirugia sobre el XML con el contenedor parado.

        Por que External y no DisabledForLocalAddresses: los *arr consideran
        "local" solo loopback y RFC1918. Tailscale usa 100.64.0.0/10 (CGNAT),
        que NO entra, asi que con DisabledForLocalAddresses te pide login igual.
        External delega la auth en la capa de acceso, que es el tailnet.
        """
        from pylib.tools import sh

        sh.run_script(
            scripts_dir / "servarr-auth.sh",
            self.container,
            str(self.config_xml),
        )
        # El script pudo haber reiniciado el contenedor: la key no cambia, pero
        # invalidamos el cache por si el XML se reescribio entero.
        self._api_key = None

    # --- Download clients -------------------------------------------------
    def find_download_client(self, client_name: str) -> int | None:
        resp = self.call("GET", "/downloadclient")
        if not resp.ok:
            ui.die(
                f"No pude listar download clients de {self.name} "
                f"(HTTP {resp.status})."
            )
        for item in resp.json() or []:
            if item.get("name") == client_name:
                return item.get("id")
        return None

    def upsert_download_client(self, client_name: str, payload: dict) -> None:
        """Idempotente, y siempre prueba con /test antes de guardar.

        No dejamos configurado un cliente que no conecta: si se guarda roto,
        despues falla en silencio a la hora de descargar y es dificil de ver.
        """
        existing = self.find_download_client(client_name)
        if existing is not None:
            ui.warn(
                f"'{client_name}' ya existe en {self.name} (id {existing}). "
                "No se duplica."
            )
            return

        ui.info(f"Probando {self.name} -> {client_name} (endpoint /test)...")
        test = self.call("POST", "/downloadclient/test", payload)
        if not test.ok:
            ui.warn(f"El test fallo (HTTP {test.status}):")
            print(test.errors())
            ui.die(f"Abortando: no guardo un download client que no conecta.")
        ui.info(f"Test OK: {self.name} alcanza a {client_name}.")

        saved = self.call("POST", "/downloadclient", payload)
        if not saved.ok:
            ui.warn(f"Fallo al agregar (HTTP {saved.status}):")
            print(saved.errors())
            ui.die(f"No se pudo agregar {client_name} a {self.name}.")
        new_id = (saved.json() or {}).get("id", "?")
        ui.info(f"'{client_name}' agregado a {self.name} (id {new_id})")

    # --- Root folders -----------------------------------------------------
    def add_root_folder(self, ctr_path: str) -> None:
        resp = self.call("GET", "/rootfolder")
        if not resp.ok:
            ui.die(f"No pude listar root folders de {self.name} (HTTP {resp.status}).")
        for item in resp.json() or []:
            if item.get("path") == ctr_path:
                ui.warn(
                    f"El root folder '{ctr_path}' ya existe en {self.name} "
                    f"(id {item.get('id')}). No se duplica."
                )
                return

        ui.info(f"Agregando el root folder a {self.name}...")
        saved = self.call("POST", "/rootfolder", {"path": ctr_path})
        if not saved.ok:
            ui.warn(f"Fallo al agregar el root folder (HTTP {saved.status}):")
            print(saved.errors())
            ui.die(f"No se pudo agregar el root folder a {self.name}.")
        body = saved.json() or {}
        ui.info(f"Root folder '{ctr_path}' agregado a {self.name} (id {body.get('id', '?')})")
        free = body.get("freeSpace")
        if free:
            ui.detail(f"Espacio libre: {free // 1024 // 1024 // 1024} GB")

    # --- qBittorrent como download client ---------------------------------
    #  Host 'gluetun' y NO 'qbittorrent': qbit usa network_mode:
    #  service:gluetun, o sea comparte su stack de red y no tiene nombre propio
    #  en la red 'media'.
    category_field: str = ""
    recent_priority_field: str = ""
    older_priority_field: str = ""

    def qbittorrent_payload(self, category: str) -> dict:
        return {
            "enable": True,
            "protocol": "torrent",
            "priority": 1,
            "name": config.TC_NAME,
            "implementation": "QBittorrent",
            "implementationName": "qBittorrent",
            "configContract": "QBittorrentSettings",
            "fields": [
                {"name": "host", "value": config.TC_HOST},
                {"name": "port", "value": config.TC_PORT},
                {"name": "useSsl", "value": False},
                {"name": self.category_field, "value": category},
                {"name": self.recent_priority_field, "value": 0},
                {"name": self.older_priority_field, "value": 0},
                {"name": "initialState", "value": 0},
                {"name": "sequentialOrder", "value": False},
                {"name": "firstAndLast", "value": False},
            ],
            "tags": [],
        }


class Radarr(Servarr):
    name = "Radarr"
    container = "radarr"
    port = 7878
    category_field = "movieCategory"
    recent_priority_field = "recentMoviePriority"
    older_priority_field = "olderMoviePriority"


class Sonarr(Servarr):
    name = "Sonarr"
    container = "sonarr"
    port = 8989
    category_field = "tvCategory"
    recent_priority_field = "recentTvPriority"
    older_priority_field = "olderTvPriority"


class Prowlarr(Servarr):
    name = "Prowlarr"
    container = "prowlarr"
    port = 9696
    # Prowlarr comparte la base Servarr pero NO el versionado de la API.
    api_version = "v1"

    FLARESOLVERR_NAME = "FlareSolverr"
    FLARESOLVERR_URL = "http://flaresolverr:8191"
    FLARESOLVERR_TAG = "flaresolverr"

    def tag_id(self, label: str) -> int:
        """Devuelve el id del tag, creandolo si no existe.

        Prowlarr aplica el proxy SOLO a los indexers que llevan el tag: es el
        mecanismo de "este indexer si pasa por FlareSolverr, este no".
        """
        resp = self.call("GET", "/tag")
        if not resp.ok:
            ui.die(f"No pude listar tags de Prowlarr (HTTP {resp.status}).")
        for item in resp.json() or []:
            if item.get("label") == label:
                return item["id"]

        created = self.call("POST", "/tag", {"label": label})
        if not created.ok:
            ui.die(f"No pude crear el tag '{label}' (HTTP {created.status}).")
        return (created.json() or {})["id"]

    def add_flaresolverr(self) -> None:
        """Carga FlareSolverr como indexer proxy.

        Queda cargado y tageado, pero no se aplica a nada hasta que le pongas
        el tag a un indexer. Es a proposito: mandar todos los indexers por
        FlareSolverr es mas lento y no hace falta.
        """
        resp = self.call("GET", "/indexerproxy")
        if not resp.ok:
            ui.die(f"No pude listar indexer proxies (HTTP {resp.status}).")
        for item in resp.json() or []:
            if item.get("name") == self.FLARESOLVERR_NAME:
                ui.warn(
                    f"El proxy '{self.FLARESOLVERR_NAME}' ya existe "
                    f"(id {item.get('id')}). No se duplica."
                )
                return

        tag = self.tag_id(self.FLARESOLVERR_TAG)
        ui.info(f"Tag '{self.FLARESOLVERR_TAG}' listo (id {tag})")

        payload = {
            "name": self.FLARESOLVERR_NAME,
            "implementation": "FlareSolverr",
            "implementationName": "FlareSolverr",
            "configContract": "FlareSolverrSettings",
            "fields": [
                {"name": "host", "value": self.FLARESOLVERR_URL},
                {"name": "requestTimeout", "value": 60},
            ],
            "tags": [tag],
        }

        ui.info("Probando la conexion a FlareSolverr (endpoint /test)...")
        test = self.call("POST", "/indexerproxy/test", payload)
        if not test.ok:
            ui.warn(f"El test de FlareSolverr fallo (HTTP {test.status}):")
            print(test.errors())
            ui.die("Abortando: no guardo un proxy que no conecta.")
        ui.info("Test OK: Prowlarr alcanza a FlareSolverr.")

        saved = self.call("POST", "/indexerproxy", payload)
        if not saved.ok:
            ui.warn(f"Fallo al agregar el proxy (HTTP {saved.status}):")
            print(saved.errors())
            ui.die("No se pudo agregar FlareSolverr.")
        ui.info(f"Proxy '{self.FLARESOLVERR_NAME}' agregado (id {(saved.json() or {}).get('id', '?')})")
        ui.info(
            f"Para usarlo: poné el tag '{self.FLARESOLVERR_TAG}' en los "
            "indexers con Cloudflare."
        )

    # --- Indexers ---------------------------------------------------------
    def _indexer_definition(self, wanted: str) -> dict:
        """Busca la definicion del indexer en el catalogo de Prowlarr.

        Se pide el schema en vez de armar el payload a mano porque cada
        definicion trae su propia lista de 'fields' con los defaults que el
        servidor espera (apiPath, categorias, etc). Adivinarlos es como
        terminamos con el bug de movieCategory/tvCategory.

        Si el indexer no tiene definicion propia en el catalogo, cae a
        'Generic Newznab', que es lo que sirve para cualquier indexer de
        usenet que hable el protocolo estandar.
        """
        resp = self.call("GET", "/indexer/schema")
        if not resp.ok:
            ui.die(f"No pude leer el catalogo de indexers (HTTP {resp.status}).")

        definitions = resp.json() or []
        norm = lambda s: "".join(c for c in (s or "").lower() if c.isalnum())
        target = norm(wanted)

        for item in definitions:
            if norm(item.get("name")) == target:
                ui.info(f"Encontre la definicion propia de '{item.get('name')}' en Prowlarr.")
                return item

        for item in definitions:
            if norm(item.get("name")) == norm("Generic Newznab"):
                ui.info(
                    f"'{wanted}' no tiene definicion propia en Prowlarr; "
                    "lo cargo como Generic Newznab."
                )
                return item

        ui.die(
            f"No encontre ni '{wanted}' ni 'Generic Newznab' en el catalogo "
            "de Prowlarr."
        )

    def add_indexer(self, name: str, base_url: str, api_key: str) -> None:
        """Agrega un indexer de usenet. Idempotente por nombre."""
        ui.add_secret(api_key)

        resp = self.call("GET", "/indexer")
        if not resp.ok:
            ui.die(f"No pude listar indexers de Prowlarr (HTTP {resp.status}).")
        for item in resp.json() or []:
            if item.get("name") == name:
                ui.warn(
                    f"El indexer '{name}' ya existe (id {item.get('id')}). "
                    "No se duplica."
                )
                return

        payload = copy.deepcopy(self._indexer_definition(name))
        payload["name"] = name
        payload["enable"] = True

        # Sobre la definicion base solo pisamos lo nuestro: el resto de los
        # campos quedan con los defaults que mando el propio Prowlarr.
        overrides = {"baseUrl": base_url, "apiKey": api_key}
        present = set()
        for field in payload.get("fields", []):
            if field.get("name") in overrides:
                field["value"] = overrides[field["name"]]
                present.add(field["name"])
        for missing in overrides.keys() - present:
            payload.setdefault("fields", []).append(
                {"name": missing, "value": overrides[missing]}
            )

        # appProfileId: el perfil de sync que Prowlarr aplica al empujar el
        # indexer a Radarr/Sonarr. Se pide en vez de asumir el id 1.
        profiles = self.call("GET", "/appprofile")
        if profiles.ok and profiles.json():
            payload["appProfileId"] = profiles.json()[0]["id"]

        ui.info(f"Probando la conexion a {name} (endpoint /test)...")
        test = self.call("POST", "/indexer/test", payload)
        if not test.ok:
            ui.warn(f"El test de {name} fallo (HTTP {test.status}):")
            print(test.errors())
            ui.warn("Revisá la API key en .env y la URL en services_setup.conf.")
            ui.die("Abortando: no guardo un indexer que no conecta.")
        ui.info(f"Test OK: Prowlarr busca en {name}.")

        saved = self.call("POST", "/indexer", payload)
        if not saved.ok:
            ui.warn(f"Fallo al agregar {name} (HTTP {saved.status}):")
            print(saved.errors())
            ui.die(f"No se pudo agregar el indexer {name}.")
        ui.info(f"Indexer '{name}' agregado (id {(saved.json() or {}).get('id', '?')})")

    def connect_app(self, app: Servarr) -> None:
        """Registra una app para que Prowlarr le empuje los indexers.

        Las URLs son las INTERNAS de la red 'media' (http://radarr:7878), no
        las de Tailscale: quien hace la request es el contenedor de Prowlarr.

        syncLevel fullSync: Prowlarr agrega, actualiza Y borra indexers en la
        app. Es lo que hace que no toques los indexers en Radarr/Sonarr nunca mas.
        """
        resp = self.call("GET", "/applications")
        if not resp.ok:
            ui.die(f"No pude listar applications de Prowlarr (HTTP {resp.status}).")
        for item in resp.json() or []:
            if item.get("name") == app.name:
                ui.warn(
                    f"La app '{app.name}' ya esta conectada a Prowlarr "
                    f"(id {item.get('id')}). No se duplica."
                )
                return

        payload = {
            "name": app.name,
            "syncLevel": "fullSync",
            "implementation": app.name,
            "implementationName": app.name,
            "configContract": f"{app.name}Settings",
            "fields": [
                {"name": "prowlarrUrl", "value": self.internal_url},
                {"name": "baseUrl", "value": app.internal_url},
                {"name": "apiKey", "value": app.api_key},
            ],
            "tags": [],
        }

        ui.info(f"Probando la conexion Prowlarr -> {app.name} (endpoint /test)...")
        test = self.call("POST", "/applications/test", payload)
        if not test.ok:
            ui.warn(f"El test contra {app.name} fallo (HTTP {test.status}):")
            print(test.errors())
            ui.die("Abortando: no guardo una app que no conecta.")
        ui.info(f"Test OK: Prowlarr alcanza a {app.name}.")

        saved = self.call("POST", "/applications", payload)
        if not saved.ok:
            ui.warn(f"Fallo al conectar {app.name} (HTTP {saved.status}):")
            print(saved.errors())
            ui.die(f"No se pudo conectar {app.name} a Prowlarr.")
        ui.info(f"App '{app.name}' conectada (id {(saved.json() or {}).get('id', '?')})")
