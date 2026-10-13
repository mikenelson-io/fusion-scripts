#!/usr/bin/env bash
# Install the Fusion MCP server into one or more AI agents.
# Repo: https://github.com/PureStorage-OpenConnect/fusion-mcp-server
set -euo pipefail

REPO="PureStorage-OpenConnect/fusion-mcp-server"
INSTALL_DIR="$HOME/.local/bin"
BINARY="$INSTALL_DIR/fusion-mcp-server"
AUTH_CONFIG="$HOME/.config/fusion-mcp/auth-config.json"
STATE_FILE="$HOME/.config/fusion-mcp/install-state.json"
VERSIONS_DIR="$HOME/.local/bin/.fusion-mcp-versions"
MANIFEST="$VERSIONS_DIR/manifest.json"
MCP_NAME="fusion-mcp"
CLAUDE_SCOPE="user"
UPDATE=false
PRERELEASE=false
ROLLBACK=false
ROLLBACK_VERSION=""
LIST_VERSIONS=false
LOCAL_FILE=""
REMOVE_AGENTS_ARG=""
AGENTS_ARG=""   # comma-separated list, or "all"

# ── colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' BOLD='\033[1m' NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi
info()   { printf "${BLUE}==> ${NC}%s\n" "$*"; }
ok()     { printf "${GREEN}✓ ${NC}%s\n" "$*"; }
warn()   { printf "${YELLOW}! ${NC}%s\n" "$*"; }
skip()   { printf "  ${YELLOW}–${NC} %s\n" "$*"; }
die()    { printf "${RED}Error: ${NC}%s\n" "$*" >&2; exit 1; }
header() { printf "\n${BOLD}%s${NC}\n" "$*"; }

# ── agent registry ────────────────────────────────────────────────────────────
# Each entry: key | display label | config path (informational)
AGENT_KEYS=(  "claude"  "desktop"        "vscode"  "gemini"  "copilot"  "augment"  "codex"  "opencode" )
AGENT_LABELS=("Claude Code" "Claude Desktop" "VS Code" "Gemini CLI" "GitHub Copilot CLI" "Augment" "Codex CLI" "OpenCode")

vscode_config_path() {
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/Application Support/Code/User/mcp.json" ;;
    *)      echo "$HOME/.config/Code/User/mcp.json" ;;
  esac
}

# Claude Desktop (the chat app) — distinct from Claude Code (the CLI, "claude"
# above). Different config file, different mechanism, same JSON shape.
claude_desktop_config_path() {
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
    *)      echo "$APPDATA/Claude/claude_desktop_config.json" ;;
  esac
}

agent_config_path() {
  case "$1" in
    claude)  echo "(via claude mcp add)" ;;
    desktop) claude_desktop_config_path ;;
    vscode)  vscode_config_path ;;
    gemini)  echo "$HOME/.gemini/settings.json" ;;
    copilot) echo "$HOME/.copilot/mcp-config.json" ;;
    augment) echo "$HOME/.augment/settings.json" ;;
    codex)   echo "$HOME/.codex/config.toml" ;;
    opencode) echo "$HOME/.config/opencode/opencode.json" ;;
  esac
}

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Download the Fusion MCP server binary and register it with AI agents.
Source: https://github.com/$REPO

Options:
  --agents LIST   Comma-separated agents to configure, or 'all'
                  Keys: claude, desktop, vscode, gemini, copilot, augment, codex, opencode
                  ('claude' = Claude Code CLI; 'desktop' = Claude Desktop app)
                  (Omit to choose interactively on first install;
                   omit on --update to reuse the agents from last time)
  --binary PATH   Install to this path instead of $INSTALL_DIR/fusion-mcp-server
  --file PATH     Install FROM this local file instead of downloading a
                  GitHub release. Skips the network and version-tag lookup
                  entirely — use this for a pre-release build that was
                  shared out-of-band and never published as a repo release.
                  The file is validated (executable, responds to --version)
                  before it's used, and the binary it replaces is still
                  backed up, so --rollback works exactly the same afterward.
                  Takes priority over --update if both are given.
  --update        Update mode instead of install mode:
                    - checks the latest release and only re-downloads the
                      binary if it's actually newer (not a blind re-fetch)
                    - never touches auth-config.json or prompts for tokens
                    - reconfigures the agents recorded from your last run
                      (pass --agents to override which agents get touched)
  --scope SCOPE   Claude Code MCP scope: user or local [default: user]
  --name NAME     Server name registered with agents [default: $MCP_NAME]
  --pre-release   With --update, install the newest release including
                  pre-releases (normally only stable releases are used)
  --rollback [VERSION]
                  Restore a previously-installed binary. Omit VERSION to
                  undo the last update; pass one (as shown by
                  --list-versions) to restore that specific build.
                  Does not touch agent configs — they point at a fixed
                  binary path, so rollback just swaps that file back.
  --list-versions Show binaries available to roll back to, then exit
  --remove-agent LIST
                  Unregister the server from these agents (comma-separated,
                  or 'all') and drop them from the saved list, so --update
                  stops touching them. The binary and auth config stay put.
  -h, --help      Show this help

Examples:
  $(basename "$0")                         # interactive agent selection
  $(basename "$0") --agents all            # configure all supported agents
  $(basename "$0") --agents claude,gemini  # configure two specific agents
  $(basename "$0") --update                # check for a newer binary and
                                            # reapply it to last time's agents
  $(basename "$0") --update --agents vscode
  $(basename "$0") --update --pre-release  # opt in to a pre-release build
  $(basename "$0") --file ~/Downloads/fusion-mcp-server-rc2  # local prerelease
  $(basename "$0") --rollback              # undo the last update
  $(basename "$0") --list-versions         # see what you can roll back to
  $(basename "$0") --remove-agent gemini   # stop managing one agent

Auth config:
  If $AUTH_CONFIG exists it will be used as-is.
  Otherwise you will be prompted to enter array credentials.
  (--update never prompts — it errors out if no auth config exists yet.)

State:
  Which agents you configured is remembered in $STATE_FILE
  so --update doesn't need to ask again.

Version history:
  Every binary --update replaces is backed up under $VERSIONS_DIR
  (last 5 kept) so --rollback has something to restore.

Env vars:
  FUSION_MCP_BINARY   Override binary path (same as --binary)
EOF
}

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents)  AGENTS_ARG="$2"; shift 2 ;;
    --binary)  BINARY="$2";     shift 2 ;;
    --file)    LOCAL_FILE="$2"; shift 2 ;;
    --remove-agent) REMOVE_AGENTS_ARG="$2"; shift 2 ;;
    --update)  UPDATE=true;     shift   ;;
    --scope)   CLAUDE_SCOPE="$2"; shift 2 ;;
    --name)    MCP_NAME="$2";   shift 2 ;;
    --pre-release)   PRERELEASE=true;    shift ;;
    --list-versions) LIST_VERSIONS=true; shift ;;
    --rollback)
      ROLLBACK=true
      # Optional VERSION argument — only consume it if it's actually there
      # and doesn't look like the next flag.
      if [[ $# -ge 2 && "$2" != -* ]]; then
        ROLLBACK_VERSION="$2"; shift 2
      else
        shift 1
      fi
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ -n "${FUSION_MCP_BINARY:-}" && "$BINARY" == "$INSTALL_DIR/fusion-mcp-server" ]] \
  && BINARY="$FUSION_MCP_BINARY"

# ── helpers ───────────────────────────────────────────────────────────────────
require() { command -v "$1" &>/dev/null || die "'$1' is required but not found in PATH."; }

platform_asset() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64)        arch="amd64" ;;
    *) die "Unsupported architecture: $arch" ;;
  esac
  echo "fusion-mcp-server-${os}-${arch}"
}

latest_tag() {
  # By default this only ever sees non-prerelease, non-draft releases —
  # GitHub's /releases/latest endpoint filters those out server-side.
  # If a "latest" build still turns out to be a pre-release in practice,
  # that means upstream published it without checking the pre-release box,
  # not that this script picked one up by mistake.
  if $PRERELEASE; then
    if command -v gh &>/dev/null; then
      gh api "repos/$REPO/releases" --jq '.[0].tag_name'
    else
      curl -fsSL "https://api.github.com/repos/$REPO/releases" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['tag_name'])"
    fi
  else
    if command -v gh &>/dev/null; then
      gh api "repos/$REPO/releases/latest" --jq '.tag_name'
    else
      curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])"
    fi
  fi
}

# Merge a single server entry into a JSON config file that uses "mcpServers" or "servers".
# Usage: merge_json_config <file> <top_key> <include_type_field>
merge_json_config() {
  local file="$1" top_key="$2" include_type="$3"
  mkdir -p "$(dirname "$file")"
  python3 - "$file" "$MCP_NAME" "$BINARY" "$AUTH_CONFIG" "$top_key" "$include_type" <<'PYEOF' || die "Could not update $file"
import json, os, sys
fpath, server_name, command, auth_config, top_key, include_type = sys.argv[1:]

try:
    with open(fpath) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
except json.JSONDecodeError as e:
    # Don't clobber a hand-edited config we can't parse
    sys.exit(f"{fpath} is not valid JSON ({e}) - fix it or add the server manually.")

entry = {"command": command, "args": ["start", "--auth-config", auth_config]}
if include_type == "true":
    entry = {"type": "stdio", **entry}

cfg.setdefault(top_key, {})[server_name] = entry

with open(fpath, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
}

# Add or replace a [section.name] block in a TOML file.
# Usage: merge_toml_mcp_server <file>
merge_toml_mcp_server() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  python3 - "$file" "$MCP_NAME" "$BINARY" "$AUTH_CONFIG" <<'PYEOF'
import re, sys, os

fpath, server_name, command, auth_config = sys.argv[1:]

try:
    with open(fpath) as f:
        content = f.read()
except FileNotFoundError:
    content = ""

section_key = f"mcp_servers.{server_name}"
new_block = (
    f"[{section_key}]\n"
    f'command = "{command}"\n'
    f'args = ["start", "--auth-config", "{auth_config}"]\n'
)

# Remove the existing block for this server if present.
# A TOML section runs until the next line that starts a header, or EOF.
# (Can't stop at any '[' — the args array contains one.)
pattern = rf"^\[{re.escape(section_key)}\][^\n]*\n(?:(?!\[)[^\n]*(?:\n|$))*"
content = re.sub(pattern, "", content, flags=re.MULTILINE)

# Older versions of this installer left the args array behind as an orphan
# line (breaking the TOML). Drop exact copies of it.
orphan = f'["start", "--auth-config", "{auth_config}"]'
content = "\n".join(l for l in content.split("\n") if l.strip() != orphan)

content = content.rstrip("\n") + "\n\n" + new_block

with open(fpath, "w") as f:
    f.write(content)
PYEOF
}

# Persist which agents/settings this run configured, so a later --update
# doesn't need --agents or interactive selection to know what to touch.
save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  python3 - "$STATE_FILE" "$MCP_NAME" "$CLAUDE_SCOPE" "$BINARY" "$AUTH_CONFIG" "${SELECTED_AGENTS[@]}" <<'PYEOF'
import json, sys
state_file, mcp_name, scope, binary, auth_config, *agents = sys.argv[1:]

# Union with previously saved agents (order-preserving) so configuring one
# agent doesn't make a later --update forget the rest.
try:
    with open(state_file) as f:
        previous = json.load(f).get("agents", [])
except (FileNotFoundError, json.JSONDecodeError):
    previous = []
agents = list(dict.fromkeys(previous + agents))

state = {
    "mcp_name": mcp_name,
    "scope": scope,
    "binary": binary,
    "auth_config": auth_config,
    "agents": agents,
}
with open(state_file, "w") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PYEOF
}

# Prints a comma-separated agent list from the last saved state, or nothing.
load_state_agents() {
  [[ -f "$STATE_FILE" ]] || return 1
  python3 -c "
import json
try:
    d = json.load(open('$STATE_FILE'))
    print(','.join(d.get('agents', [])))
except (FileNotFoundError, json.JSONDecodeError):
    pass
"
}

# ── version history / rollback ────────────────────────────────────────────────
# Snapshot the currently-installed binary before it gets overwritten, so a bad
# update (pre-release or otherwise) can be undone without re-running the whole
# install. Agent configs all point at the one fixed $BINARY path, so a
# rollback never needs to touch agent config — only the binary file changes.
backup_current_binary() {
  [[ -x "$BINARY" ]] || return 0
  local current_version safe_version dest_dir
  # A binary that can't even report its version is no use as a rollback target
  if ! current_version=$("$BINARY" --version 2>&1 | head -1) || [[ -z "$current_version" ]]; then
    warn "Current binary doesn't run — skipping backup."
    return 0
  fi
  safe_version=$(echo "$current_version" | tr -cs 'A-Za-z0-9._-' '_')
  dest_dir="$VERSIONS_DIR/$safe_version"
  mkdir -p "$dest_dir"
  cp "$BINARY" "$dest_dir/fusion-mcp-server"

  python3 - "$MANIFEST" "$current_version" "$dest_dir/fusion-mcp-server" <<'PYEOF'
import json, sys, datetime, os

manifest_path, version, path = sys.argv[1:]
try:
    with open(manifest_path) as f:
        manifest = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    manifest = {"versions": []}

manifest["versions"] = [v for v in manifest["versions"] if v.get("path") != path]
manifest["versions"].append({
    "version": version,
    "path": path,
    "backed_up_at": datetime.datetime.now().isoformat(timespec="seconds"),
})
manifest["versions"] = manifest["versions"][-5:]  # keep the last 5 only

os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PYEOF
  info "Backed up current binary ($current_version) before updating."
}

list_versions() {
  header "Backed-up versions"
  if [[ ! -f "$MANIFEST" ]]; then
    echo "  (none yet — a version is backed up automatically each time --update installs a new one)"
    return
  fi
  python3 -c "
import json
manifest = json.load(open('$MANIFEST'))
versions = manifest.get('versions', [])
if not versions:
    print('  (none yet)')
for v in reversed(versions):
    print(f\"  {v['version']:<20} backed up {v['backed_up_at']}\")
"
}

rollback_binary() {
  local target_version="$1"
  [[ -f "$MANIFEST" ]] || die "No version history at $MANIFEST — nothing to roll back to."

  local entry
  entry=$(python3 -c "
import json, sys
manifest = json.load(open('$MANIFEST'))
versions = manifest.get('versions', [])
target = '$target_version'
if target:
    matches = [v for v in versions if v['version'] == target]
    if not matches:
        sys.exit(1)
    print(json.dumps(matches[-1]))
else:
    if not versions:
        sys.exit(1)
    print(json.dumps(versions[-1]))
" 2>/dev/null) || die "No matching backed-up version found. Run --list-versions to see what's available."

  local backup_path backup_version
  backup_path=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['path'])")
  backup_version=$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")
  [[ -f "$backup_path" ]] || die "Backup file missing on disk: $backup_path"

  header "Rollback"
  local current_version="(none installed)"
  [[ -x "$BINARY" ]] && { current_version=$("$BINARY" --version 2>&1 | head -1) || current_version="(installed, but won't run)"; }
  info "Current:  $current_version"
  info "Restoring: $backup_version"

  place_binary "$backup_path"
  ok "Rolled back to $backup_version"
  echo "  Restart any agent sessions using this binary (Claude Code, VS Code, etc.) to pick it up."
}

# ── step 1: binary ────────────────────────────────────────────────────────────
# Install $1 at $BINARY via a staged copy + rename, never an in-place
# overwrite. macOS caches a binary's code signature per inode; overwriting
# an existing binary on the same inode leaves that cache stale and the
# kernel SIGKILLs the new binary on launch (exit 137, no output).
place_binary() {
  local src="$1" staged
  mkdir -p "$INSTALL_DIR"
  staged=$(mktemp "$INSTALL_DIR/.fusion-mcp-server.XXXXXX")
  cp "$src" "$staged" || { rm -f "$staged"; die "Could not copy $src"; }
  chmod 755 "$staged"
  [[ "$(uname -s)" == "Darwin" ]] && xattr -d com.apple.quarantine "$staged" 2>/dev/null || true
  mv -f "$staged" "$BINARY"
}

install_from_local_file() {
  local src="$1"
  [[ -f "$src" ]] || die "No such file: $src"
  [[ -x "$src" ]] || die "$src exists but is not executable — chmod +x it first."

  # A bare filename (no slash) would be looked up on $PATH when executed,
  # not in the current directory — resolve to an absolute path first.
  src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"

  # Files downloaded via a browser carry a Gatekeeper quarantine flag on
  # macOS. Running a quarantined binary directly (e.g. for this --version
  # check) gets silently killed with no output — not a corrupt binary,
  # just Gatekeeper. Clear it on the source before we ever execute it.
  if [[ "$(uname -s)" == "Darwin" ]] && xattr -p com.apple.quarantine "$src" &>/dev/null; then
    warn "Removing macOS quarantine flag from $src"
    xattr -d com.apple.quarantine "$src" 2>/dev/null || true
  fi

  local reported_version
  reported_version=$("$src" --version 2>&1 | head -1) \
    || die "$src did not respond to --version — doesn't look like a valid fusion-mcp-server binary."
  info "Local file: $src"
  info "Reports: $reported_version"

  # If it's literally already sitting at the install path, there's nothing
  # to back up or copy — just accept it in place.
  local binary_abs=""
  [[ -f "$BINARY" ]] && binary_abs=$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")

  if [[ "$src" == "$binary_abs" ]]; then
    ok "Already at the install path: $BINARY"
    return
  fi

  backup_current_binary
  place_binary "$src"
  ok "Installed from local file: $BINARY ($reported_version)"
}

install_binary() {
  backup_current_binary

  local asset tag url
  asset=$(platform_asset)
  tag=$(latest_tag)
  url="https://github.com/$REPO/releases/download/$tag/$asset"

  info "Downloading $asset ($tag)…"
  if $PRERELEASE; then
    warn "This is a pre-release build. If it misbehaves: $(basename "$0") --rollback"
  fi
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fusion-mcp-download.XXXXXX")
  curl -fsSL --progress-bar -o "$tmp" "$url" \
    || { rm -f "$tmp"; die "Download failed. Visit: https://github.com/$REPO/releases"; }
  place_binary "$tmp"
  rm -f "$tmp"

  ok "Binary installed: $BINARY"
}

# ── step 2: auth config ───────────────────────────────────────────────────────
build_auth_config() {
  header "Array configuration"
  echo "You need an API token for at least one FlashArray or FlashBlade."
  echo "Docs: https://github.com/$REPO/blob/main/docs/USER_GUIDE.md"
  echo

  local fa_entries="" fb_entries=""

  while true; do
    local fa_host fa_token
    read -rp "FlashArray host (IP or hostname, blank to skip): " fa_host
    [[ -z "$fa_host" ]] && break
    fa_host="${fa_host#http://}"; fa_host="${fa_host#https://}"; fa_host="${fa_host%/}"
    read -rsp "  API token: " fa_token; echo
    [[ -z "$fa_token" ]] && { warn "Token cannot be empty."; continue; }
    [[ -n "$fa_entries" ]] && fa_entries+=';'
    fa_entries+="${fa_host},${fa_token}"
    local more; read -rp "  Add another FlashArray? [y/N]: " more
    [[ "$more" =~ ^[Yy]$ ]] || break
  done

  while true; do
    local fb_host fb_token
    read -rp "FlashBlade host (IP or hostname, blank to skip): " fb_host
    [[ -z "$fb_host" ]] && break
    fb_host="${fb_host#http://}"; fb_host="${fb_host#https://}"; fb_host="${fb_host%/}"
    read -rsp "  API token: " fb_token; echo
    [[ -z "$fb_token" ]] && { warn "Token cannot be empty."; continue; }
    [[ -n "$fb_entries" ]] && fb_entries+=';'
    fb_entries+="${fb_host},${fb_token}"
    local more; read -rp "  Add another FlashBlade? [y/N]: " more
    [[ "$more" =~ ^[Yy]$ ]] || break
  done

  if [[ -z "$fa_entries" && -z "$fb_entries" ]]; then
    die "At least one array is required."
  fi

  local gen_args=()
  [[ -n "$fa_entries" ]] && gen_args+=(--FA "$fa_entries")
  [[ -n "$fb_entries" ]] && gen_args+=(--FB "$fb_entries")

  echo
  info "Validating tokens and generating auth config…"
  "$BINARY" generate-config "${gen_args[@]}"
  ok "Auth config: $AUTH_CONFIG"
}

# ── step 3: per-agent install functions ───────────────────────────────────────
install_claude() {
  require claude
  if claude mcp get "$MCP_NAME" &>/dev/null; then
    warn "Existing '$MCP_NAME' found — replacing."
    claude mcp remove -s "$CLAUDE_SCOPE" "$MCP_NAME" 2>/dev/null \
      || claude mcp remove "$MCP_NAME" 2>/dev/null || true
  fi
  claude mcp add -s "$CLAUDE_SCOPE" "$MCP_NAME" -- "$BINARY" start --auth-config "$AUTH_CONFIG"
  ok "Claude Code: registered via 'claude mcp add -s $CLAUDE_SCOPE'"
}

install_vscode() {
  local cfg
  cfg=$(vscode_config_path)
  # VS Code uses "servers", not "mcpServers"; no "type" needed for stdio.
  merge_json_config "$cfg" "servers" "false"
  ok "VS Code: $cfg"
  skip "Restart VS Code (or run 'MCP: Restart MCP Server') to pick up the change."
}

install_desktop() {
  local cfg
  cfg=$(claude_desktop_config_path)
  merge_json_config "$cfg" "mcpServers" "false"
  ok "Claude Desktop: $cfg"
  skip "Fully quit and relaunch Claude Desktop (not just close the window) — it only reads this file on startup."
}

install_gemini() {
  local cfg="$HOME/.gemini/settings.json"
  merge_json_config "$cfg" "mcpServers" "false"
  ok "Gemini CLI: $cfg"
}

install_copilot() {
  local cfg="$HOME/.copilot/mcp-config.json"
  merge_json_config "$cfg" "mcpServers" "true"
  ok "GitHub Copilot CLI: $cfg"
}

install_augment() {
  local cfg="$HOME/.augment/settings.json"
  merge_json_config "$cfg" "mcpServers" "false"
  ok "Augment: $cfg"
  skip "Restart Augment to pick up the change."
}

install_codex() {
  local cfg="$HOME/.codex/config.toml"
  merge_toml_mcp_server "$cfg"
  ok "Codex CLI: $cfg"
}

# OpenCode's shape differs from the others: top-level "mcp", type "local",
# and command + args combined into one array.
install_opencode() {
  local cfg="$HOME/.config/opencode/opencode.json"
  mkdir -p "$(dirname "$cfg")"
  python3 - "$cfg" "$MCP_NAME" "$BINARY" "$AUTH_CONFIG" <<'PYEOF' || die "Could not update $cfg"
import json, sys
fpath, server_name, command, auth_config = sys.argv[1:]

try:
    with open(fpath) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {"$schema": "https://opencode.ai/config.json"}
except json.JSONDecodeError as e:
    # Don't clobber a hand-edited config we can't parse
    sys.exit(f"{fpath} is not valid JSON ({e}) - fix it or add the server manually.")

cfg.setdefault("mcp", {})[server_name] = {
    "type": "local",
    "command": [command, "start", "--auth-config", auth_config],
    "enabled": True,
}

with open(fpath, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  ok "OpenCode: $cfg"
  skip "Restart OpenCode to pick up the change."
}

install_agent() {
  case "$1" in
    claude)  install_claude  ;;
    desktop) install_desktop ;;
    vscode)  install_vscode  ;;
    gemini)  install_gemini  ;;
    copilot) install_copilot ;;
    augment) install_augment ;;
    codex)   install_codex   ;;
    opencode) install_opencode ;;
    *) warn "Unknown agent '$1' — skipping." ;;
  esac
}

# ── per-agent removal ─────────────────────────────────────────────────────────
report_removal() {
  if [[ "$1" == "removed" ]]; then
    ok "$2: removed '$MCP_NAME' from $3"
  else
    skip "$2: '$MCP_NAME' not in $3 — nothing to remove."
  fi
}

# Delete $MCP_NAME from <top_key> in a JSON config. No-op if the file or entry
# doesn't exist; refuses (rather than clobbers) a file it can't parse.
remove_json_server() {
  local file="$1" top_key="$2" label="$3"
  [[ -f "$file" ]] || { skip "$label: no config at $file — nothing to remove."; return 0; }
  local result
  result=$(python3 - "$file" "$MCP_NAME" "$top_key" <<'PYEOF'
import json, sys
fpath, server_name, top_key = sys.argv[1:]
try:
    with open(fpath) as f:
        cfg = json.load(f)
except json.JSONDecodeError as e:
    sys.exit(f"{fpath} is not valid JSON ({e}) - fix it or remove the server manually.")
servers = cfg.get(top_key)
if not isinstance(servers, dict) or server_name not in servers:
    print("absent"); sys.exit(0)
del servers[server_name]
with open(fpath, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("removed")
PYEOF
  ) || die "Could not update $file"
  report_removal "$result" "$label" "$file"
}

remove_toml_server() {
  local file="$1" label="$2"
  [[ -f "$file" ]] || { skip "$label: no config at $file — nothing to remove."; return 0; }
  local result
  result=$(python3 - "$file" "$MCP_NAME" <<'PYEOF'
import re, sys
fpath, server_name = sys.argv[1:]
with open(fpath) as f:
    content = f.read()
section_key = f"mcp_servers.{server_name}"
pattern = rf"^\[{re.escape(section_key)}\][^\n]*\n(?:(?!\[)[^\n]*(?:\n|$))*"
new = re.sub(pattern, "", content, flags=re.MULTILINE)
if new == content:
    print("absent"); sys.exit(0)
with open(fpath, "w") as f:
    f.write(new.rstrip("\n") + "\n" if new.strip() else "")
print("removed")
PYEOF
  ) || die "Could not update $file"
  report_removal "$result" "$label" "$file"
}

uninstall_agent() {
  case "$1" in
    claude)
      if ! command -v claude &>/dev/null; then
        warn "Claude Code: 'claude' not on PATH — can't unregister. Dropping from saved list only."
      elif claude mcp get "$MCP_NAME" &>/dev/null; then
        claude mcp remove -s "$CLAUDE_SCOPE" "$MCP_NAME" 2>/dev/null \
          || claude mcp remove "$MCP_NAME" 2>/dev/null \
          || die "Claude Code: 'claude mcp remove $MCP_NAME' failed."
        ok "Claude Code: unregistered '$MCP_NAME'"
      else
        skip "Claude Code: '$MCP_NAME' not registered — nothing to remove."
      fi
      ;;
    desktop)  remove_json_server "$(claude_desktop_config_path)" "mcpServers" "Claude Desktop" ;;
    vscode)   remove_json_server "$(vscode_config_path)" "servers" "VS Code" ;;
    gemini)   remove_json_server "$HOME/.gemini/settings.json" "mcpServers" "Gemini CLI" ;;
    copilot)  remove_json_server "$HOME/.copilot/mcp-config.json" "mcpServers" "GitHub Copilot CLI" ;;
    augment)  remove_json_server "$HOME/.augment/settings.json" "mcpServers" "Augment" ;;
    codex)    remove_toml_server "$HOME/.codex/config.toml" "Codex CLI" ;;
    opencode) remove_json_server "$HOME/.config/opencode/opencode.json" "mcp" "OpenCode" ;;
  esac
}

# Drop the given agent keys from the saved state, leaving everything else.
remove_from_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  python3 - "$STATE_FILE" "$@" <<'PYEOF' || die "Could not update $STATE_FILE"
import json, sys
state_file, *drop = sys.argv[1:]
with open(state_file) as f:
    state = json.load(f)
state["agents"] = [a for a in state.get("agents", []) if a not in drop]
with open(state_file, "w") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PYEOF
}

# ── interactive agent selection ───────────────────────────────────────────────
select_agents_interactive() {
  echo
  echo "Which agents do you want to configure?"
  echo
  local i=0
  for key in "${AGENT_KEYS[@]}"; do
    i=$((i+1))
    printf "  [%d] %-22s %s\n" "$i" "${AGENT_LABELS[$((i-1))]}" "$(agent_config_path "$key")"
  done
  echo
  printf "Enter numbers (space-separated), or 'all' [all]: "
  read -r selection
  selection="${selection:-all}"

  if [[ "$selection" == "all" ]]; then
    SELECTED_AGENTS=("${AGENT_KEYS[@]}")
    return
  fi

  SELECTED_AGENTS=()
  for token in $selection; do
    if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#AGENT_KEYS[@]} )); then
      SELECTED_AGENTS+=("${AGENT_KEYS[$((token-1))]}")
    else
      warn "Ignoring unrecognised selection: '$token'"
    fi
  done

  if [[ ${#SELECTED_AGENTS[@]} -eq 0 ]]; then
    die "No valid agents selected."
  fi
}

parse_agents_arg() {
  SELECTED_AGENTS=()
  if [[ "$AGENTS_ARG" == "all" ]]; then
    SELECTED_AGENTS=("${AGENT_KEYS[@]}")
    return
  fi
  IFS=',' read -ra tokens <<< "$AGENTS_ARG"
  for t in "${tokens[@]}"; do
    t="${t// /}"  # trim whitespace
    local valid=false
    for k in "${AGENT_KEYS[@]}"; do
      [[ "$t" == "$k" ]] && valid=true && break
    done
    $valid && SELECTED_AGENTS+=("$t") || warn "Unknown agent key '$t' — skipping."
  done
  if [[ ${#SELECTED_AGENTS[@]} -eq 0 ]]; then
    die "No valid agents in --agents list. Valid keys: ${AGENT_KEYS[*]}"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
require curl
require python3

printf "\n${BOLD}Fusion MCP Server installer${NC}\n"
printf "${BLUE}%s${NC}\n" "https://github.com/$REPO"
printf '─%.0s' {1..42}; echo

# 0. Standalone modes that bypass install/update entirely
if $LIST_VERSIONS; then
  list_versions
  exit 0
fi

if $ROLLBACK; then
  rollback_binary "$ROLLBACK_VERSION"
  exit 0
fi

if [[ -n "$REMOVE_AGENTS_ARG" ]]; then
  [[ -z "$AGENTS_ARG" ]] || die "--remove-agent can't be combined with --agents."
  AGENTS_ARG="$REMOVE_AGENTS_ARG"
  parse_agents_arg
  header "Agent removal"
  echo
  for agent in "${SELECTED_AGENTS[@]}"; do
    uninstall_agent "$agent"
  done
  remove_from_state "${SELECTED_AGENTS[@]}"
  echo
  ok "Removed from saved list: ${SELECTED_AGENTS[*]}"
  skip "Restart those agents to drop the server. Binary left at $BINARY."
  exit 0
fi

# 1. Binary
header "Binary"
if [[ -n "$LOCAL_FILE" ]]; then
  if $UPDATE; then
    info "Note: --file takes priority — skipping the GitHub update check."
  fi
  install_from_local_file "$LOCAL_FILE"
elif $UPDATE; then
  if [[ -x "$BINARY" ]]; then
    CURRENT_VERSION=$("$BINARY" --version 2>&1 | head -1)
    LATEST_TAG=$(latest_tag)
    # Heuristic: version output is expected to contain the release tag
    # somewhere in it. If we can't confirm a match, err on the side of
    # updating rather than silently staying stale.
    if [[ "$CURRENT_VERSION" == *"$LATEST_TAG"* ]]; then
      ok "Already at the latest release ($CURRENT_VERSION) — nothing to update."
    else
      info "Newer release available: $CURRENT_VERSION -> $LATEST_TAG"
      install_binary
      VERSION=$("$BINARY" --version 2>&1 | head -1)
      ok "Updated: $VERSION"
    fi
  else
    warn "No existing binary at $BINARY — --update has nothing to update."
    warn "Running a full install instead."
    install_binary
    VERSION=$("$BINARY" --version 2>&1 | head -1)
    ok "Version: $VERSION"
  fi
elif [[ -x "$BINARY" ]]; then
  VERSION=$("$BINARY" --version 2>&1 | head -1)
  ok "Already installed: $BINARY ($VERSION)"
  echo "   Pass --update to check for a newer release."
else
  install_binary
  VERSION=$("$BINARY" --version 2>&1 | head -1)
  ok "Version: $VERSION"
fi

# 2. Auth config
header "Auth config"
if [[ -f "$AUTH_CONFIG" ]]; then
  ARRAY_COUNT=$(python3 -c "import json; d=json.load(open('$AUTH_CONFIG')); print(len(d.get('arrays',[])))" 2>/dev/null \
    || grep -c '"name"' "$AUTH_CONFIG" 2>/dev/null || echo "?")
  ok "Found: $AUTH_CONFIG ($ARRAY_COUNT array(s))"
elif $UPDATE; then
  die "No auth config at $AUTH_CONFIG. --update never creates credentials — run a full install first (without --update)."
else
  build_auth_config
fi

# 3. Agent selection
SELECTED_AGENTS=()
if [[ -n "$AGENTS_ARG" ]]; then
  parse_agents_arg
elif $UPDATE; then
  info "Update mode: reusing agents from a previous run ($STATE_FILE)"
  AGENTS_ARG="$(load_state_agents || true)"
  if [[ -z "$AGENTS_ARG" ]]; then
    die "No saved agent list found. Pass --agents to specify which agents to update."
  fi
  parse_agents_arg
else
  select_agents_interactive
fi

# 4. Install per agent
header "$($UPDATE && echo "Agent update" || echo "Agent configuration")"
echo
for agent in "${SELECTED_AGENTS[@]}"; do
  install_agent "$agent"
done

save_state

echo
if $UPDATE; then
  ok "Update complete. Start a new session in each agent to pick up the changes."
else
  ok "Done. Start a new session in each configured agent and ask:"
  echo "     \"Show me my Fusion fleet overview.\""
fi
echo
echo "  Docs  : https://github.com/$REPO/blob/main/docs/USER_GUIDE.md"
echo "  Update: $(basename "$0") --update"
echo
