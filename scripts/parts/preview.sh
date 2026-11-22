#!/usr/bin/env bash
# Build the local parts preview (the whole site plus the parts pages) and
# serve it on http://127.0.0.1:4002/parts/ (Codespaces: PORTS tab, port 4002).
# The output folder is outside the repository and is never committed.
#
#   scripts/parts/preview.sh          build and serve
#   scripts/parts/preview.sh --build  build only
set -euo pipefail
cd "$(dirname "$0")/../.."
repo=$(pwd)
dest=$(ruby -ryaml -e 'puts YAML.safe_load_file("_config.preview.yml")["destination"]')
case "$(realpath -m "$dest")/" in "$repo"/*) echo "preview destination must be outside the repository" >&2; exit 1;; esac
bundle exec jekyll build --config _config.yml,_config.preview.yml
[ "${1:-}" = "--build" ] && exit 0
echo "Serving $dest on http://127.0.0.1:4002/parts/  (Ctrl-C to stop)"
exec ruby -run -e httpd "$dest" -p 4002 -b 127.0.0.1
