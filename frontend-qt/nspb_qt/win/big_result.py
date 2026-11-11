"""Results of pool workers that are too large for a Windows pipe.

A `ProcessPoolExecutor` worker sends its result to the parent as one pipe message. On Windows a
message of 4 GiB or more is refused: `WriteFile` fails with `OSError: [WinError 87] The parameter
is incorrect`, the future raises it and the tool stops. On macOS the same message is sent in
pieces, so the upstream tools never meet the limit. `dm/gfx/tools/shader_split.py` returns the
shaders of one archive range in one result, and for Pokémon Pokopia that result is past the limit
(#858).

The shim routes every `ProcessPoolExecutor.submit` of a build through `submit` below. The worker
measures its result, and one of `LIMIT` bytes or more goes to a temporary file, with only the
file's path in the pipe. The parent reads the file when the result is asked for and removes it.
Smaller results take the pipe as before.

This is a plain module beside `mp_worker.py`, not text inside the generated `sitecustomize.py`,
so that a worker process can import the function it is asked to run, and so that the tests run
on every platform.
"""
from __future__ import annotations

import os
import pickle
import tempfile
import threading

LIMIT = 1 << 30   # far below the 4 GiB a pipe message may have; a result this large is rare


class Spooled:
    """What the worker returns in place of a result it wrote to `path`."""

    def __init__(self, path: str) -> None:
        self.path = path


def call(limit, fn, args, kwargs):
    """In the worker: run the job, and return its result or the file that holds it."""
    result = fn(*args, **kwargs)
    blob = pickle.dumps(result, pickle.HIGHEST_PROTOCOL)
    if len(blob) < limit:
        return result
    fd, path = tempfile.mkstemp(prefix='nspb-result-', suffix='.pickle')
    with os.fdopen(fd, 'wb') as f:
        f.write(blob)
    return Spooled(path)


def submit(pool_submit, fn, args, kwargs):
    """In the parent: submit the job through `pool_submit` (the executor's own `submit`).

    The future is the executor's. Its `result()` reads a spooled result from its file once,
    removes the file and returns the same object on every later call.
    """
    future = pool_submit(call, LIMIT, fn, args, kwargs)
    plain, lock, loaded = future.result, threading.Lock(), []

    def result(timeout=None):
        got = plain(timeout)
        if not isinstance(got, Spooled):
            return got
        with lock:
            if not loaded:
                with open(got.path, 'rb') as f:
                    loaded.append(pickle.load(f))
                os.unlink(got.path)
        return loaded[0]

    future.result = result
    return future
