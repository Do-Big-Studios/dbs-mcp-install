#!/usr/bin/env bash
# -- dbs-mcp installer (macOS / Linux) -----------------------------------------
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Do-Big-Studios/dbs-mcp-install/main/install.sh | bash
#
# What it does:
#   1. Installs git and bun if they are missing.
#   2. Signs you in with GitHub (browser, one-time). Access is granted only if
#      your GitHub account is in the Do Big Studios organisation.
#   3. Clones the private Do-Big-Studios/dbs-mcp repo to ~/.dbs-mcp so you can
#      read exactly what runs on your machine.
#   4. Installs dependencies and registers the "dbs" MCP server with every
#      supported client found on this machine: Cursor, Claude Code, Claude
#      Desktop and Codex.
#
# Re-running is safe: it updates the existing install and skips finished steps.
#
# Environment overrides:
#   DBS_MCP_DIR=<path>              install somewhere other than ~/.dbs-mcp
#   DBS_MCP_REAUTH=1                force a fresh GitHub sign-in
#   DBS_MCP_CLIENTS=cursor,codex    only register with these clients
#                                   (cursor, claude, claude-desktop, codex, all)
# ------------------------------------------------------------------------------

set -euo pipefail

ORG="Do-Big-Studios"
REPO="dbs-mcp"
REPO_URL="https://github.com/$ORG/$REPO.git"
NPM_SCOPE="@do-big-studios"
NPM_REGISTRY="https://npm.pkg.github.com"
OAUTH_CLIENT_ID="Ov23ligfaE4p3HgYZXI0"
PAT_URL="https://github.com/settings/tokens/new?scopes=repo,read:packages&description=dbs-mcp"
INSTALL_DIR="${DBS_MCP_DIR:-$HOME/.dbs-mcp}"

# -- Helpers -------------------------------------------------------------------

if [ -t 1 ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

info()  { printf '%s[dbs-mcp]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()    { printf '%s[dbs-mcp]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[dbs-mcp]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fatal() { printf '%s[dbs-mcp]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# stdin is the curl pipe, so prompts must read from the terminal.
prompt() { read -r "$@" </dev/tty; }

open_url() {
  if has open; then open "$1" >/dev/null 2>&1 || true
  elif has xdg-open; then xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

# Minimal JSON string/number field extraction (no jq dependency).
json_field() { sed -n 's/.*"'"$2"'":[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' <<<"$1" | head -1; }

OS="$(uname -s)"

pkg_install() {
  if [ "$OS" = "Darwin" ]; then
    ensure_brew
    brew install "$1"
  elif has apt-get; then
    sudo apt-get update -qq && sudo apt-get install -y -qq "$1"
  elif has dnf; then
    sudo dnf install -y "$1"
  elif has pacman; then
    sudo pacman -Sy --noconfirm "$1"
  else
    fatal "Could not find a package manager to install $1. Install it manually and re-run."
  fi
}

ensure_brew() {
  if has brew; then return; fi
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
  has brew || fatal "Homebrew installation failed."
}

# -- git -----------------------------------------------------------------------

ensure_git() {
  if has git; then ok "git found ($(git --version | head -1))."; return; fi
  info "Installing git..."
  pkg_install git
  has git || fatal "git installation failed. Install it from https://git-scm.com and re-run."
  ok "git installed."
}

# -- bun -----------------------------------------------------------------------

ensure_bun() {
  if has bun; then ok "bun found (v$(bun --version))."; return; fi
  info "Installing bun..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"
  has bun || fatal "bun installation failed. Install it from https://bun.sh and re-run."
  ok "bun installed (v$(bun --version))."
}

# -- GitHub auth ---------------------------------------------------------------
#
# One token does two jobs: git needs it to clone/pull the private repo, and bun
# needs it to fetch @do-big-studios packages from GitHub Packages. It is stored
# in ~/.npmrc and in git's credential helper.

NPMRC="$HOME/.npmrc"

npmrc_token() {
  [ -f "$NPMRC" ] || return 0
  sed -n 's#^[[:space:]]*//npm\.pkg\.github\.com/:_authToken=\(.*\)$#\1#p' "$NPMRC" | head -1 | tr -d '[:space:]'
}

save_npmrc_token() {
  local token="$1" tmp
  tmp="$(mktemp)"
  if [ -f "$NPMRC" ]; then
    grep -v -e '^[[:space:]]*//npm\.pkg\.github\.com/:_authToken=' -e "^[[:space:]]*$NPM_SCOPE:registry=" "$NPMRC" >"$tmp" || true
  fi
  printf '%s:registry=%s\n//npm.pkg.github.com/:_authToken=%s\n' "$NPM_SCOPE" "$NPM_REGISTRY" "$token" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$NPMRC"
}

# Does this token see the private repo? Prints ok / denied / error.
test_repo_access() {
  local token="$1" status
  [ -n "$token" ] || { echo denied; return; }
  status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" -H "User-Agent: dbs-mcp-install" \
    "https://api.github.com/repos/$ORG/$REPO" 2>/dev/null || echo 000)"
  case "$status" in
    200) echo ok ;;
    401|403|404) echo denied ;;
    *) warn "Could not reach api.github.com (HTTP $status)."; echo error ;;
  esac
}

# Can git already reach the repo without asking anything? (Existing sign-in.)
test_git_access() {
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git ls-remote --exit-code "$REPO_URL" HEAD >/dev/null 2>&1
}

save_git_credential() {
  local token="$1"
  if [ -z "$(git config --get credential.helper 2>/dev/null || true)" ]; then
    if [ "$OS" = "Darwin" ]; then
      git config --global credential.helper osxkeychain
    else
      warn "No git credential helper configured; using 'store' (~/.git-credentials, plain text)."
      git config --global credential.helper store
    fi
  fi
  printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n\n' "$token" | git credential approve \
    || fatal "Could not store the GitHub credential for git."
}

device_flow() {
  local scope="$1" res device_code user_code verification_uri interval expires_in elapsed=0 err
  res="$(curl -sS -X POST -H "Accept: application/json" \
    --data-urlencode "client_id=$OAUTH_CLIENT_ID" --data-urlencode "scope=$scope" \
    https://github.com/login/device/code 2>/dev/null || true)"
  device_code="$(json_field "$res" device_code)"
  user_code="$(json_field "$res" user_code)"
  verification_uri="$(json_field "$res" verification_uri)"
  interval="$(json_field "$res" interval)"; interval="${interval:-5}"
  expires_in="$(json_field "$res" expires_in)"; expires_in="${expires_in:-900}"
  [ -n "$device_code" ] && [ -n "$user_code" ] || return 1

  echo >&2
  info "Sign in with GitHub to continue. Open this page and enter the code:" >&2
  echo >&2
  printf '    %s%s%s\n' "$C_CYAN" "$verification_uri" "$C_RESET" >&2
  printf '    Code: %s%s%s\n' "$C_GREEN" "$user_code" "$C_RESET" >&2
  echo >&2
  open_url "$verification_uri"
  info "Waiting for you to approve in the browser..." >&2

  while [ "$elapsed" -lt "$expires_in" ]; do
    sleep "$interval"; elapsed=$((elapsed + interval))
    res="$(curl -sS -X POST -H "Accept: application/json" \
      --data-urlencode "client_id=$OAUTH_CLIENT_ID" --data-urlencode "device_code=$device_code" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      https://github.com/login/oauth/access_token 2>/dev/null || true)"
    local token; token="$(json_field "$res" access_token)"
    if [ -n "$token" ]; then echo "$token"; return 0; fi
    err="$(json_field "$res" error)"
    case "$err" in
      authorization_pending|"") ;;
      slow_down) interval=$((interval + 5)) ;;
      expired_token) warn "Sign-in timed out."; return 1 ;;
      access_denied) warn "Sign-in was denied."; return 1 ;;
      *) warn "Unexpected response from GitHub: $err"; return 1 ;;
    esac
  done
  warn "Sign-in timed out."
  return 1
}

manual_token() {
  local token
  echo >&2
  info "Falling back to a personal access token. In the page that opens:" >&2
  info "  1. Keep 'repo' and 'read:packages' checked, click 'Generate token'" >&2
  info "  2. Copy the token and paste it below" >&2
  echo >&2
  open_url "$PAT_URL"
  prompt -s -p "[dbs-mcp] Paste your GitHub token (input is hidden): " token
  echo >&2
  token="$(tr -d '[:space:]' <<<"$token")"
  [ -n "$token" ] || fatal "No token provided."
  echo "$token"
}

ensure_github_access() {
  local git_ok=0 npm_ok=0 token scope
  if [ "${DBS_MCP_REAUTH:-}" != "1" ]; then
    test_git_access && git_ok=1
    token="$(npmrc_token)"
    [ -n "$token" ] && [ "$(test_repo_access "$token")" = ok ] && npm_ok=1
  fi
  if [ "$git_ok" = 1 ] && [ "$npm_ok" = 1 ]; then ok "GitHub access already configured."; return; fi

  # Get one token that covers whatever is missing.
  if [ "$git_ok" = 1 ]; then scope="read:packages"; else scope="repo read:packages"; fi
  echo
  info "dbs-mcp is private to the Do Big Studios GitHub organisation."
  token="$(device_flow "$scope" || true)"
  [ -n "$token" ] || token="$(manual_token)"

  case "$(test_repo_access "$token")" in
    denied)
      echo
      warn "Your GitHub account cannot see $ORG/$REPO."
      fatal "Ask your team lead to add you to the Do Big Studios organisation, then re-run this installer." ;;
    error) fatal "Could not verify access with GitHub. Check your connection and re-run." ;;
  esac
  ok "GitHub access confirmed."

  save_npmrc_token "$token"
  if [ "$git_ok" != 1 ]; then
    save_git_credential "$token"
    # Pin the username so the credential helper never has to pick between accounts.
    REPO_URL="https://x-access-token@github.com/$ORG/$REPO.git"
  fi
}

# -- Install -------------------------------------------------------------------

ensure_checkout() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing install at $INSTALL_DIR..."
    GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" pull --ff-only || warn "git pull failed, continuing with the current version."
    return
  fi
  [ -e "$INSTALL_DIR" ] && fatal "$INSTALL_DIR exists but is not a git checkout. Move it aside and re-run."
  info "Cloning $ORG/$REPO into $INSTALL_DIR..."
  GIT_TERMINAL_PROMPT=0 git clone --quiet "$REPO_URL" "$INSTALL_DIR" || fatal "git clone failed."
  ok "Cloned."
}

install_server() {
  info "Installing dependencies..."
  (cd "$INSTALL_DIR" && bun install) || fatal "bun install failed."
  info "Registering the dbs MCP server..."
  # --here: register this checkout (already cloned above) instead of letting
  # setup clone its own copy.
  (cd "$INSTALL_DIR" && bun run scripts/install.ts --here) || fatal "setup failed."
}

# -- Main ----------------------------------------------------------------------

echo
echo "  dbs-mcp installer"
echo

ensure_git
ensure_bun
ensure_github_access
ensure_checkout
install_server

echo
ok "Done."
info "Restart the clients listed above; each will show a 'dbs' MCP server."
info "See the README in $INSTALL_DIR for what it can do and how sign-in works."
echo
