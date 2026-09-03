"""Salida por consola y log a archivo.

Jerarquia visual (la misma que tenia el bash):
    step()    ==> verde, con linea en blanco arriba -> PASOS GRANDES
    info()    ->  cyan, indentado                   -> pasos intermedios
    spinner() ⠋   cyan animado -> ✓/✗               -> esperas largas
    warn()    [!] amarillo                          -> algo que hay que mirar
    die()     [x] rojo, a stderr                    -> fatal

El log a archivo guarda cada request/response completo. La consola muestra el
resumen; cuando algo falla, el detalle esta en el archivo.
"""

import sys
import threading
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

GREEN = "\033[1;32m"
CYAN = "\033[1;36m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"

_log_path: Path | None = None
_total_steps = 0
_current_step = 0
_secrets: set[str] = set()


class StackError(Exception):
    """Error fatal: aborta la corrida. El main lo atrapa e imprime con die()."""


def init_log(path: Path, total_steps: int) -> None:
    """Trunca el log y fija el total de pasos para los banners 'N/M'."""
    global _log_path, _total_steps
    _log_path = path
    _total_steps = total_steps
    path.write_text("")
    logfile("=== configure-stack iniciado ===")


def add_secret(value: str) -> None:
    """Registra un valor para que NUNCA aparezca en claro en el log.

    El filtro esta en logfile() y no en el punto de uso porque el secreto
    aparece tanto en la request como en la respuesta: los *arr repiten la
    config que acaban de guardar.

    Se registran tambien las formas escapadas: cuando el valor viaja como query
    param, urlencode lo transforma ('X7@K^!' -> 'X7%40K%5E%21') y el reemplazo
    literal no matchearia.
    """
    if not value or len(value) < 8:    # los valores cortos darian falsos positivos
        return
    for variant in (
        value,
        urllib.parse.quote_plus(value),   # el que usa urlencode
        urllib.parse.quote(value, safe=""),
    ):
        _secrets.add(variant)


def _mask(msg: str) -> str:
    for secret in _secrets:
        msg = msg.replace(secret, "<SECRETO>")
    return msg


def logfile(msg: str) -> None:
    if _log_path is None:
        return
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with _log_path.open("a") as fh:
        fh.write(f"[{stamp}] {_mask(msg)}\n")


def step(title: str) -> None:
    """Paso grande. Lleva la cuenta sola: no hay que renumerar a mano."""
    global _current_step
    _current_step += 1
    print(f"\n{GREEN}==>{RESET} {_current_step}/{_total_steps} {title}")
    logfile(f"=== PASO {_current_step}/{_total_steps}: {title} ===")


def info(msg: str) -> None:
    print(f"  {CYAN}->{RESET} {msg}")


def warn(msg: str) -> None:
    print(f"{YELLOW}[!]{RESET} {msg}")


def detail(msg: str) -> None:
    """Linea de datos alineada, sin simbolo (para los resumenes)."""
    print(f"     {msg}")


# =========================================================================
#  Spinner para las esperas largas
#
#  Frames braille en cyan y, al terminar, la linea se reemplaza por un
#  ✓ verde o un ✗ rojo.
#
#  Si no hay TTY (salida a archivo, CI, o corriendo por cron) NO anima: imprime
#  el mensaje una vez y listo. Animar sin terminal llena el log de basura con
#  cada \r y cada frame.
# =========================================================================
_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
_HIDE_CURSOR = "\033[?25l"
_SHOW_CURSOR = "\033[?25h"


class Spinner:
    def __init__(self, msg: str):
        self.msg = msg
        self.ok = True
        self._tty = sys.stdout.isatty()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "Spinner":
        logfile(f"esperando: {self.msg}")
        if not self._tty:
            print(f"  {self.msg}...")
            return self
        sys.stdout.write(_HIDE_CURSOR)
        sys.stdout.flush()
        self._thread = threading.Thread(target=self._spin, daemon=True)
        self._thread.start()
        return self

    def _spin(self) -> None:
        i = 0
        while not self._stop.is_set():
            frame = _FRAMES[i % len(_FRAMES)]
            sys.stdout.write(f"\r  {CYAN}{frame}{RESET} {self.msg}")
            sys.stdout.flush()
            i += 1
            self._stop.wait(0.1)

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is not None:
            self.ok = False
        if self._thread is not None:
            self._stop.set()
            self._thread.join()
            # \033[K borra hasta el fin de linea: si el mensaje final es mas
            # corto que el que estaba animandose, si no quedan restos.
            mark = f"{GREEN}✓{RESET}" if self.ok else f"{RED}✗{RESET}"
            sys.stdout.write(f"\r  {mark} {self.msg}\033[K\n")
            sys.stdout.write(_SHOW_CURSOR)
            sys.stdout.flush()
        elif not self.ok:
            print(f"  {self.msg}: fallo")
        return False   # nunca tragamos la excepcion


def wait_for(msg: str, check, attempts: int = 30, delay: int = 2) -> bool:
    """Llama a check() hasta que devuelva True, con el spinner al lado.

    check() no deberia imprimir nada: la linea del spinner se reescribe con \\r
    y cualquier print de por medio la parte al medio.
    """
    with Spinner(msg) as spin:
        for _ in range(attempts):
            if check():
                return True
            time.sleep(delay)
        spin.ok = False
    return False


def die(msg: str) -> None:
    raise StackError(msg)


def print_fatal(msg: str) -> None:
    print(f"{RED}[x]{RESET} {msg}", file=sys.stderr)
