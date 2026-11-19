"""The Windows build path: everything the Qt front end needs to produce an IPA on a PC.

This package is imported **only on Windows** (see `nspb_qt.model`). On macOS it is never
touched, so a Mac build behaves exactly as before; importing it here is still safe, because
no module in it runs a subprocess or reads a Windows-only path at import time.

The upstream pipeline (`scripts/build_ipa_from_nsp.py`) is not modified: `driver.py` loads it
as a module and replaces the functions that assume a Mac. `shim/` covers the calls that cross
process boundaries, where a function replacement cannot reach.
"""
from __future__ import annotations

#: Deployment target of the iOS app. `dm/ios/project.yml` says 26.0 (Metal 4), and the
#: cross-compiled objects must agree with it or the linker warns about platform versions.
IOS_DEPLOYMENT = '26.0'

#: CPU the host is compiled for. Matches `dm/ios/project.yml` (`apple-m1`), the oldest supported
#: chip (M1 iPad): provides LSE atomics without promising A15+ `I8MM` / `BF16` instructions that
#: cause `dav1d` to trap with `SIGILL` on M1 iPads.
IOS_CPU = 'apple-m1'

#: Environment variable names this package sets for the build. They all carry the `NSPB_`
#: prefix so they cannot collide with the upstream script's own vocabulary.
ENV_TOOLCHAIN = 'NSPB_TOOLCHAIN_JSON'
ENV_LLVM = 'NSPB_LLVM_DIR'
ENV_SDK = 'NSPB_IOS_SDK'
ENV_METAL = 'NSPB_METAL_DIR'
ENV_PREFIX = 'NSPB_PREFIX'
