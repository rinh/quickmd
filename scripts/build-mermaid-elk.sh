#!/bin/sh
# Rebuilds QuickMD/QuickMD/Resources/mermaid-layout-elk.min.js.
# Run from the repository root: sh scripts/build-mermaid-elk.sh
#
# @mermaid-js/layout-elk ships as ~200 ES-module chunks. The template loads
# scripts with classic <script> tags from file:// (no module CORS), so the
# package is flattened into one IIFE that sets window.mermaidElkLayouts.
# Keep the layout-elk version on a 0.2.x release whose peer is the bundled
# Mermaid 11.x: 1.x targets Mermaid 12, and 0.2.3 embeds all of Mermaid 11.17.
set -eu

ELK_VERSION=0.2.1
ESBUILD_VERSION=0.25.0
OUT="$PWD/QuickMD/QuickMD/Resources/mermaid-layout-elk.min.js"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

npm pack --silent "@mermaid-js/layout-elk@$ELK_VERSION" >/dev/null
tar xzf mermaid-js-layout-elk-$ELK_VERSION.tgz
cat > entry.mjs <<'EOF'
import elkLayouts from './package/dist/mermaid-layout-elk.esm.mjs';
globalThis.mermaidElkLayouts = elkLayouts;
EOF

npx -y "esbuild@$ESBUILD_VERSION" entry.mjs --bundle --format=iife --minify \
  --platform=browser --legal-comments=none --log-level=error \
  --banner:js="/* @mermaid-js/layout-elk $ELK_VERSION (MIT, Mermaid contributors) with elkjs (EPL-2.0, Kiel University and others). Built by scripts/build-mermaid-elk.sh */" \
  --outfile="$OUT"

echo "Wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
