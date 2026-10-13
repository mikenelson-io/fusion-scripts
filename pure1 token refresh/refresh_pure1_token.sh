#!/usr/bin/env bash
# =============================================================================
# refresh_pure1_token.sh
# Regenerates a Pure1 API access token and exports it system-wide so that
# Claude Desktop, VSCode, Augment, and any shell session can consume it
# without interruption.
#
# What this script does:
#   1. Mints a fresh Bearer token with pure1_token_factory.py, using the
#      application ID and encrypted private key from your macOS keychain
#   2. Validates the token against the Pure1 API (/api/1.0/arrays)
#   3. Writes the token to ~/.pure1_token.env  (sourceable by shells)
#   4. Calls `launchctl setenv` so macOS GUI apps (Claude, VSCode, Augment)
#      see PURE1_ACCESS_TOKEN without needing a restart
#
# Usage:
#   ./refresh_pure1_token.sh                      # refresh (what launchd runs)
#   ./refresh_pure1_token.sh --set-credentials    # first-time setup, or after
#                                                 # regenerating the API key in Pure1
#   ./refresh_pure1_token.sh --set-credentials --id pure1:apikey:XXXX --key new.pem
#   source ~/.pure1_token.env                     # pick it up in the current shell
#
# --set-credentials encrypts the private key with a random passphrase, stores
# the passphrase and application ID in the login keychain, and verifies the
# pair with Pure1 before replacing anything. Existing credentials are left
# untouched if the new ones are rejected.
# =============================================================================

set -euo pipefail
umask 077  # token file, log, key, and config backups readable by owner only

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_SCRIPT="$SCRIPT_DIR/pure1_token_factory.py"
PRIVATE_KEY="${PURE1_PRIVATE_KEY:-$SCRIPT_DIR/pure1_private_key.enc.pem}"
KEYCHAIN_SERVICE="pure1-token-refresh"
OUTPUT_ENV="$HOME/.pure1_token.env"
LOG_FILE="$SCRIPT_DIR/pure1_token_refresh.log"
ENV_VAR_NAME="PURE1_ACCESS_TOKEN"
VALIDATION_URL="https://api.pure1.purestorage.com/api/1.0/arrays"
# ──────────────────────────────────────────────────────────────────────────────

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}
die() { log "ERROR: $*"; exit 1; }

# ── Keychain helpers ──────────────────────────────────────────────────────────
# Secrets go to `security` on stdin (interactive mode), never as arguments,
# so they don't show up in `ps` output. The login keychain is named
# explicitly: jobs started by cron don't get the user's keychain search list.
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
keychain_get() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w "$KEYCHAIN" 2>/dev/null
}
keychain_set() {
  printf 'add-generic-password -U -s %s -a %s -w %s "%s"\n' "$KEYCHAIN_SERVICE" "$1" "$2" "$KEYCHAIN" \
    | security -i >/dev/null
}

# Mint an access token. The passphrase reaches Python on file descriptor 3
# (a pipe), not via argv or the environment. Calls the factory's functions
# directly rather than its CLI, which would prompt on a TTY.
mint_token() {
  local key="$1" pass="$2" id="$3"
  "$PYTHON_BIN" - "$SCRIPT_DIR" "$id" "$key" 3< <(printf '%s' "$pass") 2>>"$LOG_FILE" <<'PYEOF'
import os, sys
factory_dir, api_id, key_path = sys.argv[1:]
sys.path.insert(0, factory_dir)
import pure1_token_factory as factory
with os.fdopen(3) as fh:
    password = fh.read() or None
key = factory.get_private_key(key_path, password)
print(factory.get_access_token(factory.generate_id_token(api_id, key)))
PYEOF
}

is_encrypted() { grep -q 'ENCRYPTED' "$1"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
SET_CREDENTIALS=false NEW_ID="" NEW_KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --set-credentials) SET_CREDENTIALS=true; shift ;;
    --id)  NEW_ID="$2";  shift 2 ;;
    --key) NEW_KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

log "════════════════════════════════════════"
log "Starting Pure1 token refresh..."

command -v security &>/dev/null || die "macOS 'security' command not found; this script needs the keychain."
[[ -f "$FACTORY_SCRIPT" ]] || die "Token factory script not found at $FACTORY_SCRIPT"

# Resolve a python3 that actually has the 'requests' module. The bare `python3`
# on PATH varies by caller (launchd sees /usr/bin/python3 with requests;
# an interactive shell may see pyenv's, which does not) — so pick explicitly
# instead of trusting PATH. This is what caused the intermittent
# "ModuleNotFoundError: No module named 'requests'" in the log.
PYTHON_BIN=""
for cand in /usr/bin/python3 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$cand" &>/dev/null && "$cand" -c "import requests" &>/dev/null; then
    PYTHON_BIN="$cand"
    break
  fi
done
[[ -n "$PYTHON_BIN" ]] || die "no python3 with the 'requests' module found. Install it: /usr/bin/python3 -m pip install requests"

# ── Optional: store new credentials ──────────────────────────────────────────
if $SET_CREDENTIALS; then
  [[ -n "$NEW_ID" ]] || read -rp "Pure1 application ID (pure1:apikey:...): " NEW_ID
  [[ "$NEW_ID" =~ ^pure1:apikey:[A-Za-z0-9]+$ ]] || die "That doesn't look like a Pure1 application ID: '$NEW_ID'"
  [[ -n "$NEW_KEY" ]] || read -rp "Path to the private key registered with that ID: " NEW_KEY
  NEW_KEY="${NEW_KEY/#\~/$HOME}"
  [[ -f "$NEW_KEY" ]] || die "Private key not found: $NEW_KEY"

  # Encrypt to a temp file first; nothing is replaced until Pure1 accepts it.
  NEW_PASS=$(openssl rand -hex 32)
  STAGED=$(mktemp "$SCRIPT_DIR/.pure1_key.XXXXXX")
  trap 'rm -f "$STAGED"' EXIT
  openssl pkey -in "$NEW_KEY" -aes256 -passout fd:3 -out "$STAGED" 3< <(printf '%s' "$NEW_PASS") \
    || die "Could not read or encrypt $NEW_KEY (if it has a passphrase, openssl prompts for it)."

  log "Verifying new credentials with Pure1..."
  mint_token "$STAGED" "$NEW_PASS" "$NEW_ID" >/dev/null \
    || die "Pure1 rejected the new ID/key pair. Existing credentials left unchanged."

  keychain_set api-key-id "$NEW_ID" || die "Could not write application ID to the keychain."
  keychain_set private-key-passphrase "$NEW_PASS" || die "Could not write passphrase to the keychain."
  mv -f "$STAGED" "$PRIVATE_KEY"
  trap - EXIT
  log "Credentials updated: ID in keychain, encrypted key at $PRIVATE_KEY."
  log "The unencrypted key at $NEW_KEY is no longer used. Delete it or move it offline."
fi

# ── Load credentials ──────────────────────────────────────────────────────────
[[ -f "$PRIVATE_KEY" ]] || die "No private key at $PRIVATE_KEY. Run: $0 --set-credentials"
API_KEY="${PURE1_API_KEY:-$(keychain_get api-key-id || true)}"
[[ -n "$API_KEY" ]] || die "No Pure1 application ID in the keychain. Run: $0 --set-credentials"
PASSPHRASE=""
if is_encrypted "$PRIVATE_KEY"; then
  PASSPHRASE=$(keychain_get private-key-passphrase || true)
  [[ -n "$PASSPHRASE" ]] || die "Key is encrypted but no passphrase is in the keychain. Run: $0 --set-credentials"
else
  log "WARNING: $PRIVATE_KEY is not encrypted. Run --set-credentials to encrypt it."
fi

# ── Step 1: Generate the token ─────────────────────────────────────────────
log "Generating new access token (interpreter: $PYTHON_BIN)..."
ACCESS_TOKEN=$(mint_token "$PRIVATE_KEY" "$PASSPHRASE" "$API_KEY" || true)
unset PASSPHRASE
[[ -n "$ACCESS_TOKEN" ]] || die "Token generation failed (see log). Token NOT updated."

log "Token generated successfully (preview: ${ACCESS_TOKEN:0:20}...)"

# ── Step 2: Validate the token against the Pure1 API ─────────────────────
log "Validating token against $VALIDATION_URL ..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$VALIDATION_URL" 2>>"$LOG_FILE")

case "$HTTP_STATUS" in
  200)
    log "Validation PASSED (HTTP 200) — token is valid and authorized."
    ;;
  401|403)
    log "Validation FAILED (HTTP $HTTP_STATUS) — token is invalid, expired, or not authorized."
    log "The existing token in $OUTPUT_ENV has NOT been overwritten."
    exit 1
    ;;
  5*)
    log "WARNING: Validation inconclusive (HTTP $HTTP_STATUS) — server/network error."
    log "This is likely an environment or network issue, not a bad token."
    log "Proceeding with token write, but verify connectivity to Pure1 API."
    ;;
  *)
    log "WARNING: Unexpected HTTP status '$HTTP_STATUS' during validation."
    log "Proceeding with token write — check logs if issues arise."
    ;;
esac

# ── Step 3: Write ~/.pure1_token.env ──────────────────────────────────────
cat > "$OUTPUT_ENV" <<EOF
# Pure1 API Access Token
# Auto-generated by refresh_pure1_token.sh
# Last refreshed: $(date '+%Y-%m-%d %H:%M:%S %Z')
# Token expires approximately 10 hours after generation.
#
# Usage:
#   source ~/.pure1_token.env
#   echo \$PURE1_ACCESS_TOKEN
#
export ${ENV_VAR_NAME}="${ACCESS_TOKEN}"
EOF
log "Token written to: $OUTPUT_ENV"

# ── Step 4: Export to macOS GUI apps via launchctl ─────────────────────────
if command -v launchctl &>/dev/null; then
  launchctl setenv "$ENV_VAR_NAME" "$ACCESS_TOKEN"
  log "launchctl setenv applied — Claude Desktop, VSCode, and Augment will"
  log "   pick up \$${ENV_VAR_NAME} on their next request (no restart needed)."
else
  log "WARNING: launchctl not found (non-macOS?). GUI apps may not see the token."
  log "   On Linux, consider adding to /etc/environment or your DE's env config."
fi

# ── Step 5: Also export into the current shell session ────────────────────
export "${ENV_VAR_NAME}"="$ACCESS_TOKEN"

# ── Step 6: Self-heal the Claude Desktop MCP config ────────────────────────
# If the "Pure1 API" entry in claude_desktop_config.json is missing (wiped by
# another tool, a Desktop update, a bad manual edit) or holds a stale token,
# rewrite it. This makes both token expiry AND config drift self-correcting.
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [[ -f "$CLAUDE_CONFIG" ]]; then
  log "Checking Claude Desktop config for a healthy Pure1 API entry..."
  PATCH_RESULT=$("$PYTHON_BIN" - "$CLAUDE_CONFIG" "$ACCESS_TOKEN" <<'PYEOF'
import json, sys, shutil, datetime

config_path, token = sys.argv[1], sys.argv[2]

with open(config_path) as f:
    config = json.load(f)

config.setdefault("mcpServers", {})

desired = {
    "command": "npx",
    "args": [
        "-y", "mcp-remote",
        "https://api.pure1.purestorage.com/mcp",
        "--header", "Authorization:${AUTHORIZATION_HEADER}"
    ],
    "env": {"AUTHORIZATION_HEADER": f" Bearer {token}"}
}

if config["mcpServers"].get("Pure1 API") == desired:
    print("UNCHANGED")
else:
    backup = f"{config_path}.bak.{datetime.datetime.now():%Y%m%d%H%M%S}"
    shutil.copy2(config_path, backup)
    config["mcpServers"]["Pure1 API"] = desired
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"PATCHED backup={backup}")

# Each backup holds the token of its day; keep only the newest 5.
import glob, os, re
ours = sorted(p for p in glob.glob(f"{config_path}.bak.*")
              if re.fullmatch(r"\d{14}", p.rsplit(".", 1)[-1]))
for old in ours[:-5]:
    os.remove(old)
PYEOF
  )
  log "Config self-heal result: $PATCH_RESULT"
  if [[ "$PATCH_RESULT" == PATCHED* ]]; then
    log "Pure1 API entry was restored/updated. Restart Claude Desktop to pick it up."
    if command -v osascript &>/dev/null; then
      osascript -e 'display notification "Pure1 MCP config was repaired. Restart Claude Desktop to reload it." with title "Pure1 Token Refresh"' &>/dev/null || true
    fi
  fi
else
  log "WARNING: Claude Desktop config not found at $CLAUDE_CONFIG — skipping self-heal."
fi

log "Done. Source the token in a new shell with:"
log "   source ~/.pure1_token.env"
log "════════════════════════════════════════"
