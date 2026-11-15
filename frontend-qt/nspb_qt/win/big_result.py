"""Results of pool workers that are too large for a Windows pipe.

A `ProcessPoolExecutor` worker sends its result to the parent as one pipe message. On Windows a
message of 4 GiB or more is refused: `WriteFile` fails with `OSError: [WinError 87] The parameter
is incorrect`, the future raises it and the tool stops. On macOS the same message is sent in
pieces, so the upstream tools never meet the limit. `dm/gfx/tools/shader_split.py` returns the
shaders of one archive range in one result, and for Pokémon Pokopia that result is past the limit
(#858).

The shim routes every `ProcessPoolExecutor.submit` of a build through `submit` below. The worker
pickles its result once: payloads below `LIMIT` cross the pipe as pre-pickled `Inline` bytes (so
the object graph is never pickled a second time), while payloads of `LIMIT` bytes or more go to a
temporary file with only `Spooled(path)` in the pipe.

Cleanup covers every exit path:
* reading `future.result()` unlinks a spooled file in `finally` (even on corrupt pickle bytes);
* an unconsumed future unlinks its file as soon as the `Spooled` wrapper is collected (no
  reference cycle on `future.result`), with a single process `atexit` sweep as fallback;
* `NSPB_SPOOL_DIR` scopes all spool files of a build to one temporary directory that `model.py`
  and `driver.py` remove unconditionally in `finally` (even after `kill_process_tree`).

This is a plain module beside `mp_worker.py`, not text inside the generated `sitecustomize.py`,
so that a worker process can import the function it is asked to run, and so that the tests run
on every platform.
"""
from __future__ import annotations

import atexit
import os
import pickle
import tempfile
import threading
import weakref

ENV_SPOOL_DIR = 'NSPB_SPOOL_DIR'
LIMIT = 1 << 30   # far below the 4 GiB a pipe message may have; a result this large is rare

_active_lock = threading.Lock()
_active_spools: set[str] = set()
_atexit_registered = False


def _unlink_quietly(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _cleanup_active_spools() -> None:
    with _active_lock:
        paths = list(_active_spools)
        _active_spools.clear()
    for path in paths:
        _unlink_quietly(path)


def _track_spool(path: str) -> None:
    global _atexit_registered
    with _active_lock:
        _active_spools.add(path)
        if not _atexit_registered:
            atexit.register(_cleanup_active_spools)
            _atexit_registered = True


def _untrack_and_unlink(path: str) -> None:
    with _active_lock:
        _active_spools.discard(path)
    _unlink_quietly(path)


def _spool_dir() -> str | None:
    raw = os.environ.get(ENV_SPOOL_DIR, '').strip()
    if not raw:
        return None
    try:
        os.makedirs(raw, exist_ok=True)
        return raw
    except OSError:
        return None


class Inline:
    """Pre-pickled bytes for a result below `LIMIT`, avoiding a second object-graph pickle."""

    __slots__ = ('blob',)

    def __init__(self, blob: bytes) -> None:
        self.blob = blob


class Spooled:
    """What the worker returns in place of a result it wrote to `path`."""

    def __init__(self, path: str) -> None:
        self.path = path
        self._finalizer: weakref.finalize | None = None

    def __getstate__(self) -> str:
        return self.path

    def __setstate__(self, path: str) -> None:
        self.path = path
        _track_spool(path)
        self._finalizer = weakref.finalize(self, _untrack_and_unlink, path)

    def cleanup(self) -> None:
        if self._finalizer is not None:
            self._finalizer()
        else:
            _untrack_and_unlink(self.path)


def call(limit, fn, args, kwargs):
    """In the worker: run the job, and return `Inline` bytes or a `Spooled` file handle."""
    result = fn(*args, **kwargs)
    blob = pickle.dumps(result, pickle.HIGHEST_PROTOCOL)
    del result
    if len(blob) < limit:
        return Inline(blob)
    fd, path = tempfile.mkstemp(prefix='nspb-result-', suffix='.pickle', dir=_spool_dir())
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(blob)
    except BaseException:
        _unlink_quietly(path)
        raise
    return Spooled(path)


def submit(pool_submit, fn, args, kwargs):
    """In the parent: submit the job through `pool_submit` (the executor's own `submit`).

    The future is the executor's. Its `result()` unpacks `Inline` bytes or reads a `Spooled`
    file once, removes any backing file in `finally`, and returns the same object on every
    later call without introducing a reference cycle on the future.
    """
    future = pool_submit(call, LIMIT, fn, args, kwargs)
    raw_result = type(future).result
    fut_ref = weakref.ref(future)
    lock = threading.Lock()
    state: list[tuple[bool, object]] = []

    def result(timeout=None):
        fut = fut_ref()
        if fut is None:  # pragma: no cover
            raise RuntimeError('future was collected')
        got = raw_result(fut, timeout)
        if isinstance(got, Inline):
            with lock:
                if not state:
                    try:
                        state.append((True, pickle.loads(got.blob)))
                    except Exception as exc:
                        state.append((False, exc))
                    finally:
                        got.blob = b''
            ok, item = state[0]
            if not ok:
                raise item  # type: ignore[misc]
            return item
        if not isinstance(got, Spooled):
            return got
        with lock:
            if not state:
                try:
                    with open(got.path, 'rb') as f:
                        state.append((True, pickle.load(f)))
                except Exception as exc:
                    state.append((False, exc))
                finally:
                    got.cleanup()
        ok, item = state[0]
        if not ok:
            raise item  # type: ignore[misc]
        return item

    future.result = result
    return future
