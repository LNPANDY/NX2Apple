"""On-demand `nsz` provisioning for compressed `.nsz` / `.xcz` builds without touching PEP 668 host Pythons."""
from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
import os
from pathlib import Path
import subprocess

from . import platform_util as pu

CORE_BUILD_PROBE = (
    'import lz4, capstone, fontTools, zbic, unicorn\n'
    'try:\n'
    '    from compression import zstd\n'
    'except ImportError:\n'
    '    from backports import zstd\n'
)

BUILD_PROBE = CORE_BUILD_PROBE + 'import nsz\n'

_GUIDANCE_PREFIX = 'nsz setup diagnosis:'


@dataclass(frozen=True)
class NszEnsureResult:
    """Outcome of ensuring `nsz` is available before running `build_ipa_from_nsp.py`."""

    ok: bool
    python_path: str
    switched_venv: bool = False
    cancelled: bool = False
    error_kind: str = ''
    error_summary: str = ''


def classify_pip_error(output: str) -> str:
    """Classify subprocess output from `pip` / `venv` into a concrete root cause."""
    low = (output or '').lower()
    if any(
        tok in low
        for tok in (
            'externally-managed-environment',
            'externally managed',
            'pep 668',
            'pep-668',
        )
    ):
        return 'pep668'
    if any(
        tok in low
        for tok in (
            'permissionerror',
            'permission denied',
            'errno 13',
            'access is denied',
            'operation not permitted',
        )
    ):
        return 'permission'
    if any(
        tok in low
        for tok in (
            'ensurepip',
            'no module named venv',
            'python3-venv',
            'venv creation failed',
        )
    ):
        return 'venv'
    if any(
        tok in low
        for tok in (
            'connectionerror',
            'newconnectionerror',
            'timed out',
            'timeout',
            'name or service not known',
            'temporary failure in name resolution',
            'nodename nor servname',
            'could not find a version that satisfies',
            'no matching distribution found',
            'proxyerror',
            'sslerror',
            'certificate verify failed',
            'connection reset',
            'failed to establish a new connection',
        )
    ):
        return 'network'
    return 'other'


def _tail_line(output: str) -> str:
    for line in reversed((output or '').splitlines()):
        s = line.strip()
        if s and not s.startswith(_GUIDANCE_PREFIX):
            return s[:200]
    return ''


def format_failure_guidance(kind: str, py: str, output: str = '') -> str:
    """Return a diagnostic message naming the failure cause and actionable remedy."""
    tail = _tail_line(output)
    detail = f' ({tail})' if tail else ''
    if kind == 'pep668':
        return (
            f'{_GUIDANCE_PREFIX} Python {py} is protected by PEP 668 (externally-managed-environment) '
            f'and could not install into {pu.venv_dir()}{detail}. '
            'Check that Python venv/pip support is installed or remove any broken app venv and retry.\n'
        )
    if kind == 'permission':
        return (
            f'{_GUIDANCE_PREFIX} Permission denied while writing packages for {py}{detail}. '
            'Verify folder permissions for the application data directory or remove any read-only venv.\n'
        )
    if kind == 'venv':
        return (
            f'{_GUIDANCE_PREFIX} Failed to create virtual environment at {pu.venv_dir()} from {py}{detail}. '
            'Ensure Python venv/ensurepip is installed (for example `python3-venv` on Debian/Ubuntu).\n'
        )
    if kind == 'network':
        return (
            f'{_GUIDANCE_PREFIX} Network or proxy error while installing nsz with {py}{detail}. '
            'Check internet connectivity and proxy settings (HTTP_PROXY / HTTPS_PROXY) and retry.\n'
        )
    return f'{_GUIDANCE_PREFIX} Failed to install nsz with {py}{detail}.\n'


def stream_command(
    cmd: list[str],
    *,
    env: Mapping[str, str] | None = None,
    log: Callable[[str], None],
    is_cancelled: Callable[[], bool] | None = None,
    on_proc: Callable[[subprocess.Popen | None], None] | None = None,
    popen_cls: type[subprocess.Popen] | None = None,
) -> tuple[int, bool, str]:
    """Run `cmd` while streaming combined stdout/stderr lines to `log` and honoring cancellation."""
    cancelled = is_cancelled or (lambda: False)
    if cancelled():
        return -1, True, ''
    popen = popen_cls or subprocess.Popen
    lines: list[str] = []
    proc: subprocess.Popen | None = None
    was_cancelled = False
    try:
        proc = popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8',
            errors='replace',
            bufsize=1,
            env=dict(env) if env is not None else pu.proxy_env(),
            **pu.process_group_kwargs(),
        )
        if on_proc is not None:
            on_proc(proc)
        if cancelled():
            was_cancelled = True
            pu.kill_process_tree(proc)
        if proc.stdout is not None:
            for raw in proc.stdout:
                line = raw if raw.endswith('\n') else raw + '\n'
                lines.append(line)
                log(line)
                if cancelled():
                    was_cancelled = True
                    pu.kill_process_tree(proc)
                    break
        rc = proc.wait()
        if cancelled():
            was_cancelled = True
        return rc, was_cancelled, ''.join(lines)
    except OSError as exc:
        msg = f'{exc}\n'
        log(msg)
        return -1, cancelled(), msg
    finally:
        if on_proc is not None:
            on_proc(None)
        if proc is not None:
            poll_fn = getattr(proc, 'poll', None)
            still_running = (poll_fn() is None) if callable(poll_fn) else False
            if was_cancelled or still_running:
                pu.kill_process_tree(proc)
            close_out = getattr(getattr(proc, 'stdout', None), 'close', None)
            if callable(close_out):
                try:
                    close_out()
                except OSError:
                    pass


def _python_usable_for_app_venv(vpy: str) -> bool:
    if not vpy or not Path(vpy).is_file():
        return False
    ver = pu._python_version(vpy)
    if not ver:
        return False
    vt = pu._ver_tuple(ver)
    if vt < pu.MIN_PYTHON:
        return False
    if pu.IS_WIN and vt != (3, 12):
        return False
    return True


def _pip_install_args(pkgs: list[str], wheels: Path | None) -> list[str]:
    if wheels:
        return ['install', '--no-index', '--find-links', str(wheels), *pkgs]
    return ['install', *pkgs]


def _install_nsz_into_python(
    py: str,
    *,
    log: Callable[[str], None],
    bundled_wheels: Callable[[], Path | None] | None,
    run_env: Mapping[str, str],
    is_cancelled: Callable[[], bool],
    on_proc: Callable[[subprocess.Popen | None], None] | None,
    popen_cls: type[subprocess.Popen] | None,
) -> tuple[bool, bool, str]:
    wheels = bundled_wheels() if bundled_wheels is not None else None
    attempts: list[Path | None] = [wheels, None] if wheels else [None]
    last_out = ''
    for attempt_wheels in attempts:
        if is_cancelled():
            return False, True, last_out
        args = _pip_install_args(['nsz'], attempt_wheels)
        pip_env = dict(run_env)
        if attempt_wheels is not None:
            pip_env['PIP_CONFIG_FILE'] = os.devnull
        suffix = '' if attempt_wheels else '  (from PyPI)'
        log(f'$ {py} -m pip {" ".join(args)}{suffix}\n')
        rc, cancelled, out = stream_command(
            [py, '-m', 'pip', *args],
            env=pip_env,
            log=log,
            is_cancelled=is_cancelled,
            on_proc=on_proc,
            popen_cls=popen_cls,
        )
        last_out = out
        if cancelled:
            return False, True, out
        if rc == 0:
            return True, False, out
    return False, False, last_out


def _install_via_app_venv(
    base_py: str,
    *,
    emit: Callable[[str], None],
    captured: list[str],
    make_venv: Callable[[str], bool],
    bundled_wheels: Callable[[], Path | None] | None,
    run_env: Mapping[str, str],
    is_cancelled: Callable[[], bool],
    on_proc: Callable[[subprocess.Popen | None], None] | None,
    popen_cls: type[subprocess.Popen] | None,
) -> NszEnsureResult:
    vdir = pu.venv_dir()
    vpy = pu.venv_python()
    emit(f'external or managed Python ({base_py}); using isolated app venv {vdir} for nsz\n')

    if (
        _python_usable_for_app_venv(vpy)
        and not pu.has_externally_managed_marker(vpy, env=run_env)
        and pu._runs(vpy, ['-c', CORE_BUILD_PROBE])
    ):
        ok_pip, cancelled, out = _install_nsz_into_python(
            vpy,
            log=emit,
            bundled_wheels=bundled_wheels,
            run_env=run_env,
            is_cancelled=is_cancelled,
            on_proc=on_proc,
            popen_cls=popen_cls,
        )
        if cancelled:
            return NszEnsureResult(ok=False, python_path=vpy, cancelled=True)
        if ok_pip and pu._runs(vpy, ['-c', 'import nsz']):
            return NszEnsureResult(ok=True, python_path=vpy, switched_venv=True)
        kind = classify_pip_error(out)
        if not ok_pip and kind == 'network':
            guidance = format_failure_guidance(kind, vpy, out)
            emit(guidance)
            return NszEnsureResult(
                ok=False,
                python_path=vpy,
                error_kind=kind,
                error_summary=guidance.strip(),
            )

    if is_cancelled():
        return NszEnsureResult(ok=False, python_path=vpy, cancelled=True)

    ok_venv = make_venv(base_py)
    if is_cancelled():
        return NszEnsureResult(ok=False, python_path=vpy, cancelled=True)

    vpy_after = pu.venv_python()
    if ok_venv:
        if pu._runs(vpy_after, ['-c', 'import nsz']):
            return NszEnsureResult(ok=True, python_path=vpy_after, switched_venv=True)
        ok_pip, cancelled, out = _install_nsz_into_python(
            vpy_after,
            log=emit,
            bundled_wheels=bundled_wheels,
            run_env=run_env,
            is_cancelled=is_cancelled,
            on_proc=on_proc,
            popen_cls=popen_cls,
        )
        if cancelled:
            return NszEnsureResult(ok=False, python_path=vpy_after, cancelled=True)
        if ok_pip and pu._runs(vpy_after, ['-c', 'import nsz']):
            return NszEnsureResult(ok=True, python_path=vpy_after, switched_venv=True)
        kind = classify_pip_error(out or ''.join(captured))
        guidance = format_failure_guidance(kind, vpy_after, out or ''.join(captured))
        emit(guidance)
        return NszEnsureResult(
            ok=False,
            python_path=vpy_after,
            error_kind=kind,
            error_summary=guidance.strip(),
        )

    combined = ''.join(captured)
    kind = classify_pip_error(combined)
    if _GUIDANCE_PREFIX not in combined:
        guidance = format_failure_guidance(kind, vpy_after or base_py, combined)
        emit(guidance)
    else:
        guidance = _tail_line(combined)
    return NszEnsureResult(
        ok=False,
        python_path=vpy_after or base_py,
        error_kind=kind,
        error_summary=guidance.strip(),
    )


def ensure_nsz_for_build(
    *,
    py: str,
    log: Callable[[str], None],
    make_venv: Callable[[str], bool],
    bundled_wheels: Callable[[], Path | None] | None = None,
    installing_notice: str = '',
    is_cancelled: Callable[[], bool] | None = None,
    on_proc: Callable[[subprocess.Popen | None], None] | None = None,
    env: Mapping[str, str] | None = None,
    popen_cls: type[subprocess.Popen] | None = None,
) -> NszEnsureResult:
    """Ensure `nsz` is available for a `.nsz`/`.xcz` build, isolating external/PEP 668 Pythons in the app venv."""
    cancelled_fn = is_cancelled or (lambda: False)
    if cancelled_fn():
        return NszEnsureResult(ok=False, python_path=py, cancelled=True)

    run_env = pu.proxy_env(env if env is not None else pu.child_env())

    if pu._runs(py, ['-c', 'import nsz']):
        return NszEnsureResult(ok=True, python_path=py)

    standalone = pu.find_standalone_nsz(run_env)
    if standalone:
        log(f'using standalone nsz on PATH: {standalone}\n')
        return NszEnsureResult(ok=True, python_path=py)

    vpy = pu.venv_python()
    if (
        vpy
        and os.path.abspath(vpy) != os.path.abspath(py)
        and _python_usable_for_app_venv(vpy)
        and not pu.has_externally_managed_marker(vpy, env=run_env)
        and pu._runs(vpy, ['-c', BUILD_PROBE])
    ):
        log(f'reusing app venv with nsz: {vpy}\n')
        return NszEnsureResult(ok=True, python_path=vpy, switched_venv=True)

    captured: list[str] = []

    def emit(text: str) -> None:
        captured.append(text)
        log(text)

    if installing_notice:
        emit(installing_notice.rstrip('\n') + '\n')

    in_app_venv = pu._is_under_dir(Path(os.path.abspath(py)), pu.venv_dir()) if py else False
    can_install_directly = pu.is_app_managed_python(py) and not pu.has_externally_managed_marker(py, env=run_env)

    if can_install_directly:
        ok_pip, cancelled, out = _install_nsz_into_python(
            py,
            log=emit,
            bundled_wheels=bundled_wheels,
            run_env=run_env,
            is_cancelled=cancelled_fn,
            on_proc=on_proc,
            popen_cls=popen_cls,
        )
        if cancelled:
            return NszEnsureResult(ok=False, python_path=py, cancelled=True)
        if ok_pip and pu._runs(py, ['-c', 'import nsz']):
            return NszEnsureResult(ok=True, python_path=py)
        kind = classify_pip_error(out)
        if not ok_pip and kind in ('pep668', 'permission') and not in_app_venv:
            emit(f'direct nsz install hit {kind}; switching to isolated app venv {pu.venv_dir()}\n')
        else:
            guidance = format_failure_guidance(kind, py, out)
            emit(guidance)
            return NszEnsureResult(
                ok=False,
                python_path=py,
                error_kind=kind,
                error_summary=guidance.strip(),
            )

    return _install_via_app_venv(
        py,
        emit=emit,
        captured=captured,
        make_venv=make_venv,
        bundled_wheels=bundled_wheels,
        run_env=run_env,
        is_cancelled=cancelled_fn,
        on_proc=on_proc,
        popen_cls=popen_cls,
    )
