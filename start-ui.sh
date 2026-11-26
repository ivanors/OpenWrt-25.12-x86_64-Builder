#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v python3 >/dev/null || { echo "Python 3 belum terpasang"; exit 1; }
command -v git >/dev/null || { echo "Git belum terpasang"; exit 1; }
echo "Buka browser: http://127.0.0.1:8787"
python3 server.py --host 127.0.0.1 --port 8787
