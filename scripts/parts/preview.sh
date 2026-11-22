#!/usr/bin/env bash
# Build the local parts preview (the whole site plus the parts pages) and
# serve it on http://127.0.0.1:4002/parts/ (Codespaces: PORTS tab, port 4002).
# "Report a problem" notes from the pages are saved to
# data/parts/vw-tpl-1963-08/qa-reports.jsonl.
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
# serves the pages and saves "report a problem" notes to
# data/parts/vw-tpl-1963-08/qa-reports.jsonl (name: PP_REVIEWER, default "owner")
exec bundle exec ruby scripts/parts/preview-server.rb --root "$dest" --reviewer "${PP_REVIEWER:-owner}"
