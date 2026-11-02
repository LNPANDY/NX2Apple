"""`python3 tools/verify <command>`: runs tools/verify/verify.py (see its docstring and tools/verify/README.md)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify  # noqa: E402

sys.exit(verify.main())
