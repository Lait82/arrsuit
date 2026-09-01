"""Salida por consola y log a archivo.

Jerarquia visual (la misma que tenia el bash):
    step()  ==> verde, con linea en blanco arriba -> PASOS GRANDES
    info()  ->  cyan, indentado                   -> pasos intermedios
    warn()  [!] amarillo                          -> algo que hay que mirar
    die()   [x] rojo, a stderr                    -> fatal

El log a archivo guarda cada request/response completo. La consola muestra el
resumen; cuando algo falla, el detalle esta en el archivo.
"""

import sys
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


class StackError(Exception):
    """Error fatal: aborta la corrida. El main lo atrapa e imprime con die()."""


def init_log(path: Path, total_steps: int) -> None:
    """Trunca el log y fija el total de pasos para los banners 'N/M'."""
    global _log_path, _total_steps
    _log_path = path
    _total_steps = total_steps
    path.write_text("")
    logfile("=== configure-stack iniciado ===")


def logfile(msg: str) -> None:
    if _log_path is None:
        return
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with _log_path.open("a") as fh:
        fh.write(f"[{stamp}] {msg}\n")


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


def die(msg: str) -> None:
    raise StackError(msg)


def print_fatal(msg: str) -> None:
    print(f"{RED}[x]{RESET} {msg}", file=sys.stderr)
