#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-24kswatt/casper-gay}"
BRANCH="${BRANCH:-main}"
APP_FILE="${APP_FILE:-qwen_tui.py}"

if [[ "$(id -u)" -eq 0 ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/opt/qwen-stack-tui}"
  BIN_DIR="${BIN_DIR:-/usr/local/bin}"
else
  INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/qwen-stack-tui}"
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
fi

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  rm -f "${INSTALL_DIR}/.${APP_FILE}.tmp" 2>/dev/null || true
  rm -f "${INSTALL_DIR}/README.md.tmp" 2>/dev/null || true
}
trap cleanup EXIT

download() {
  local url="$1"
  local out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=10 "$url" -O "$out"
  else
    die "curl or wget is required."
  fi
}

command -v python3 >/dev/null 2>&1 || die "python3 is required."

say "Installing Qwen Stack TUI"
echo "    repo:   ${REPO}@${BRANCH}"
echo "    target: ${INSTALL_DIR}"
echo

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

say "Downloading ${APP_FILE}"
download "${RAW_BASE}/${APP_FILE}" "${INSTALL_DIR}/.${APP_FILE}.tmp"

say "Validating Python"
python3 -m py_compile "${INSTALL_DIR}/.${APP_FILE}.tmp" \
  || die "Downloaded qwen_tui.py failed syntax validation."

mv -f "${INSTALL_DIR}/.${APP_FILE}.tmp" "${INSTALL_DIR}/${APP_FILE}"
chmod 755 "${INSTALL_DIR}/${APP_FILE}"

if [[ ! -f "${INSTALL_DIR}/config.ini" ]]; then
  say "Downloading config.ini"
  download "${RAW_BASE}/config.ini" "${INSTALL_DIR}/config.ini" \
    || die "config.ini not found in repo."
else
  ok "Existing config.ini preserved"
fi

if download "${RAW_BASE}/README.md" "${INSTALL_DIR}/README.md.tmp" 2>/dev/null; then
  mv -f "${INSTALL_DIR}/README.md.tmp" "${INSTALL_DIR}/README.md"
fi

say "Creating qwen-stack launcher"

cat > "${BIN_DIR}/qwen-stack" <<EOF
#!/usr/bin/env bash
set -e
cd "${INSTALL_DIR}"
exec python3 "${INSTALL_DIR}/${APP_FILE}" "\$@"
EOF

chmod 755 "${BIN_DIR}/qwen-stack"

ok "Qwen Stack TUI installed"
echo
echo "Run:"
echo "    qwen-stack"
echo

if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
  warn "${BIN_DIR} is not currently in PATH"
  echo
  echo "Run directly:"
  echo "    ${BIN_DIR}/qwen-stack"
  echo
  echo "or add:"
  echo "    export PATH=\"${BIN_DIR}:\$PATH\""
fi
