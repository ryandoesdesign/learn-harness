#!/bin/sh
# Rebuild LHResources/Resources/mathjax-svg.js from scripts/mathjax/entry.js:
# mathjax-full (pinned) is installed into a throwaway folder and bundled
# with the TS app's esbuild. Run from anywhere; needs npm.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$work" && npm init -y >/dev/null && npm install --ignore-scripts --no-audit --no-fund mathjax-full@3.2.2 >/dev/null)
"$repo/node_modules/.bin/esbuild" "$here/mathjax/entry.js" --bundle --format=iife --minify --platform=neutral \
	--main-fields=module,main --log-level=warning \
	--alias:mathjax-full="$work/node_modules/mathjax-full" \
	--outfile="$repo/macos/Packages/LHKit/Sources/LHResources/Resources/mathjax-svg.js"
echo "wrote mathjax-svg.js"
