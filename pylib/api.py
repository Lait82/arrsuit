"""Cliente HTTP sobre urllib (stdlib).

POR QUE urllib Y NO requests:
En Debian/Ubuntu modernos 'pip install' fuera de un venv falla por PEP 668
(externally-managed-environment), y montar un venv para un script que corre con
sudo es friccion pura. urllib alcanza y viene con el sistema: cero dependencias.

Diferencia importante con el bash que reemplaza: aca la respuesta se DEVUELVE
como objeto. El bash tenia que escribir HTTP_CODE y HTTP_BODY como globales
porque no puede retornar estructuras, y eso ya habia mordido: una llamada
dentro de $(...) corre en un subshell y las globales que setea se pierden.
"""

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from . import ui


class Response:
    def __init__(self, status: int, body: str):
        self.status = status
        self.body = body

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def json(self) -> Any:
        if not self.body:
            return None
        try:
            return json.loads(self.body)
        except json.JSONDecodeError:
            return None

    def errors(self) -> str:
        """Formatea los errores de validacion de Servarr.

        Vienen como lista de objetos con propertyName/errorMessage. Si no
        parsea, devuelve el cuerpo crudo.
        """
        data = self.json()
        if isinstance(data, list):
            lines = []
            for item in data:
                if isinstance(item, dict):
                    prop = item.get("propertyName", "?")
                    msg = item.get("errorMessage", "?")
                    extra = item.get("detailedDescription") or ""
                    lines.append(f"  - {prop}: {msg} {extra}".rstrip())
            if lines:
                return "\n".join(lines)
        return f"  {self.body}"


def request(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    data: Any = None,
    timeout: int = 30,
    secret: str | None = None,
) -> Response:
    """Hace la request y devuelve Response, sin excepciones por status != 2xx.

    'secret' se enmascara en el log: cuando la API key viaja en la URL (el caso
    de SABnzbd) no queremos que quede escrita en claro en el archivo.
    """
    headers = dict(headers or {})
    body_bytes = None
    if data is not None:
        body_bytes = json.dumps(data).encode()
        headers.setdefault("Content-Type", "application/json")

    safe_url = url.replace(secret, "<APIKEY>") if secret else url
    ui.logfile(f"--- REQUEST: {method} {safe_url}")
    if data is not None:
        ui.logfile(f"    PAYLOAD: {json.dumps(data)}")

    req = urllib.request.Request(url, data=body_bytes, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            result = Response(resp.status, resp.read().decode(errors="replace"))
    except urllib.error.HTTPError as exc:
        # Un 4xx/5xx no es una excepcion para nosotros: es un resultado que el
        # caller decide como tratar (ej: 409 al crear algo que ya existe).
        result = Response(exc.code, exc.read().decode(errors="replace"))
    except urllib.error.URLError as exc:
        result = Response(0, f"{exc.reason}")
    except OSError as exc:
        result = Response(0, str(exc))

    ui.logfile(f"    HTTP_CODE: {result.status}")
    ui.logfile(f"    RESPONSE: {result.body or '<vacio>'}")
    return result


def build_url(base: str, path: str, params: dict[str, Any] | None = None) -> str:
    url = base.rstrip("/") + "/" + path.lstrip("/")
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return url
