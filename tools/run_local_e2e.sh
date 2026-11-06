#!/bin/bash
set -euo pipefail
TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$TOOLS_DIR/local_e2e.py" "$@"
