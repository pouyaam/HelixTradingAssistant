#!/usr/bin/env bash
# Helix Trading Assistant — one-shot bootstrap / regen / build / launch script.
#
# Usage:
#   ./run.sh                # debug build, install deps + regen + build + launch
#   ./run.sh --release      # release configuration
#   ./run.sh --clean        # wipe ./build before building (forces SPM re-resolve)
#   ./run.sh --no-launch    # build only, don't open the .app
#   ./run.sh --quiet        # suppress xcodebuild noise
#   ./run.sh --skip-deps    # don't try to install brew/npm tooling
#
# Combine freely: ./run.sh --clean --release
#
# What it does, in order:
#   1) Sanity-check toolchain (xcodebuild present — Xcode is the only
#      thing that can't be auto-installed).
#   2) Bootstrap dependencies (unless --skip-deps):
#       - Homebrew (prompts user before installing)
#       - xcodegen, node (brew)
#       - @anthropic-ai/claude-code, @openai/codex (npm globals)
#   3) Remove the stale `GoldMonitorMac.xcodeproj` leftover from the
#      old app name (renamed to HelixTradingApp).
#   4) Run `xcodegen generate` to produce HelixTradingApp.xcodeproj.
#   5) Build into ./build/ (out-of-tree DerivedData, predictable path).
#   6) Kill any running HelixTradingApp instance and open the fresh one.
#
# Designed to "just work" on a fresh checkout. Set -e + tight error
# handling so a failure at any step aborts with a clear message.

set -euo pipefail

# Resolve script directory so the script works no matter where it's
# invoked from (cron, IDE button, `./run.sh` from a sibling shell).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

PROJECT="HelixTradingApp.xcodeproj"
SCHEME="HelixTradingApp"
CONFIG="Debug"
LAUNCH=true
CLEAN=false
QUIET=false
SKIP_DEPS=false

# ── Args ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --release)    CONFIG="Release" ;;
    --debug)      CONFIG="Debug" ;;
    --clean)      CLEAN=true ;;
    --no-launch)  LAUNCH=false ;;
    --quiet)      QUIET=true ;;
    --skip-deps)  SKIP_DEPS=true ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "❌ Unknown option: $arg (use --help)" >&2
      exit 2 ;;
  esac
done

# ── Logging helpers ────────────────────────────────────────────────
log()  { printf "\033[1;34m▸ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m⚠ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ── Step 1: Xcode (the only thing we can't install for the user) ───
log "Checking Xcode"
command -v xcodebuild >/dev/null \
  || die "xcodebuild not found — install Xcode from the App Store, then run 'sudo xcode-select --switch /Applications/Xcode.app'."
ok "Xcode toolchain available"

# ── Step 2: Bootstrap deps (brew + node + npm globals) ─────────────
ensure_brew() {
  if command -v brew >/dev/null; then return 0; fi
  warn "Homebrew not found"
  read -r -p "Install Homebrew now? (y/N) " reply
  case "$reply" in
    y|Y)
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      ;;
    *)
      die "Homebrew is required for xcodegen + node. Skip with --skip-deps if you've installed them by hand."
      ;;
  esac
  # Apple Silicon installs brew to /opt/homebrew; Intel to /usr/local.
  # Either way, make sure it's on PATH for the rest of this script run.
  if [ -x "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  command -v brew >/dev/null || die "Homebrew install reported success but 'brew' is not on PATH."
}

ensure_brew_pkg() {
  local pkg="$1"
  local cmd="${2:-$1}"
  if command -v "$cmd" >/dev/null; then return 0; fi
  log "Installing $pkg via Homebrew"
  brew install "$pkg"
  command -v "$cmd" >/dev/null || die "$pkg installed but '$cmd' still not on PATH."
}

ensure_npm_global() {
  local pkg="$1"   # npm package name
  local cmd="$2"   # binary it provides
  local label="$3" # human-readable label

  if command -v "$cmd" >/dev/null; then
    ok "$label CLI already installed ($(command -v "$cmd"))"
    return 0
  fi

  # Common npm-global install dirs the engines also probe at runtime.
  for candidate in \
    "/opt/homebrew/bin/$cmd" \
    "/usr/local/bin/$cmd" \
    "$HOME/.local/bin/$cmd" \
    "$HOME/.npm-global/bin/$cmd" \
    "$HOME/.bun/bin/$cmd"
  do
    if [ -x "$candidate" ]; then
      ok "$label CLI already installed ($candidate)"
      return 0
    fi
  done

  log "Installing $label CLI ($pkg)"
  if npm i -g "$pkg"; then
    ok "$label CLI installed"
  else
    warn "Global install of $pkg failed (likely needs sudo or a writable npm prefix)."
    warn "Retrying with sudo — you'll be prompted for your password."
    sudo npm i -g "$pkg" \
      || die "Could not install $pkg. Install it manually: npm i -g $pkg"
  fi
}

if [ "$SKIP_DEPS" = false ]; then
  log "Bootstrapping dependencies (use --skip-deps to skip)"
  ensure_brew
  ensure_brew_pkg xcodegen xcodegen
  ensure_brew_pkg node node           # brings npm with it
  command -v npm >/dev/null || die "npm not found after installing node — something's wrong with the Homebrew install."

  # Claude Code CLI — drives the ClaudeEngine. No API key needed; it
  # reuses the CLI's own session (run `claude login` after install).
  ensure_npm_global "@anthropic-ai/claude-code" "claude" "Claude Code"

  # OpenAI Codex CLI — drives the CodexEngine. Same deal — reuses
  # the CLI's session (run `codex login` after install).
  ensure_npm_global "@openai/codex" "codex" "Codex"

  ok "Dependencies ready"
else
  log "Skipping dependency bootstrap (--skip-deps)"
  command -v xcodegen >/dev/null || die "xcodegen not found and --skip-deps was passed."
fi

# ── Step 3: Cleanup ────────────────────────────────────────────────
# The project was renamed from GoldMonitorMac → HelixTradingApp. If
# the old .xcodeproj is still around it confuses Xcode (and earlier
# versions of this script). Remove it unconditionally — it can always
# be regenerated, and keeping it means duplicate scheme entries.
if [ -d "GoldMonitorMac.xcodeproj" ]; then
  log "Removing stale GoldMonitorMac.xcodeproj"
  rm -rf "GoldMonitorMac.xcodeproj"
fi

if [ "$CLEAN" = true ] && [ -d "build" ]; then
  log "Cleaning ./build"
  rm -rf "build"
fi

# ── Step 4: Regenerate the Xcode project ───────────────────────────
log "Regenerating $PROJECT from project.yml"
if [ "$QUIET" = true ]; then
  xcodegen generate >/dev/null
else
  xcodegen generate
fi
[ -d "$PROJECT" ] || die "xcodegen finished but $PROJECT is missing — check project.yml syntax."
ok "Project regenerated"

# ── Step 5: Build ──────────────────────────────────────────────────
log "Building $SCHEME ($CONFIG)"

# Predictable derived-data location — keeps the .app at a known path
# instead of buried under DerivedData/${SCHEME}-${HASH}/Build/...
DERIVED="$SCRIPT_DIR/build"
APP_PATH="$DERIVED/Build/Products/$CONFIG/$SCHEME.app"

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
  -skipPackagePluginValidation
  -skipMacroValidation
  build
)

# xcodebuild is loud by default. In quiet mode we capture and only
# surface the lines that contain "error:" / "warning:" so the user
# sees what matters. xcpretty would be nicer but isn't a hard dep.
if [ "$QUIET" = true ]; then
  if ! BUILD_LOG=$(xcodebuild "${BUILD_ARGS[@]}" 2>&1); then
    printf "%s\n" "$BUILD_LOG" | grep -E "error:" | head -50
    die "Build failed — re-run without --quiet for the full log."
  fi
  printf "%s\n" "$BUILD_LOG" | grep -E "warning:" | head -20 || true
else
  xcodebuild "${BUILD_ARGS[@]}" | grep -E "(error:|warning:|note:|\*\* )" || true
fi

[ -d "$APP_PATH" ] || die "Build reported success but $APP_PATH is missing."
ok "Built: $APP_PATH"

# ── Step 6: Launch ─────────────────────────────────────────────────
if [ "$LAUNCH" = true ]; then
  log "Launching $SCHEME"
  # Kill any already-running instance so the fresh build is what
  # shows up on screen instead of an older still-open window.
  pkill -x "$SCHEME" 2>/dev/null || true
  sleep 0.2
  open "$APP_PATH"
  ok "$SCHEME launched"
fi

ok "Done"
