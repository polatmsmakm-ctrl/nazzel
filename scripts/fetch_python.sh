#!/bin/bash
# Downloads the embedded Python runtime and the pure-Python download engine.
# Run from the repository root before `xcodegen generate`.
set -euo pipefail

PY_SUPPORT_TAG="${PY_SUPPORT_TAG:-3.14-b11}"
PY_VER="${PY_SUPPORT_TAG%%-*}"
PY_BUILD="${PY_SUPPORT_TAG##*-}"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${PY_SUPPORT_TAG}/Python-${PY_VER}-iOS-support.${PY_BUILD}.tar.gz"

echo "==> Python ${PY_VER} (${PY_BUILD}) for iOS"
TMP="$(mktemp -d)"
curl -fsSL --retry 3 -o "$TMP/python.tgz" "$URL"
tar -xzf "$TMP/python.tgz" -C "$TMP"
rm -rf Python.xcframework
mv "$TMP/Python.xcframework" .
cat "$TMP/VERSIONS" || true
rm -rf "$TMP"

echo "==> Download engine (pure-Python wheels only)"
rm -rf python/app_packages
mkdir -p python/app_packages
VENV="$(mktemp -d)/venv"
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install \
    --target python/app_packages \
    --no-deps --only-binary=:all: \
    --platform any --implementation py --python-version "${PY_VER}" \
    yt-dlp yt-dlp-ejs yt-dlp-apple-webkit-jsi certifi \
    gallery-dl requests urllib3 idna charset-normalizer

# Command-line wrappers, man pages and caches are not needed inside the app.
rm -rf python/app_packages/bin python/app_packages/share
find python/app_packages -name "__pycache__" -type d -prune -exec rm -rf {} +

python3 - <<'EOF'
import pathlib, re
for d in sorted(pathlib.Path('python/app_packages').glob('*.dist-info')):
    print('   ', d.name.replace('.dist-info', ''))
EOF
