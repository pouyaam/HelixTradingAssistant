#!/usr/bin/env bash
# Helix Trading Assistant — one-shot bootstrap / regen / build / launch script.
#
# Usage:
#   ./run.sh                # debug build, install deps + regen + build + launch
#   ./run.sh --debug        # debug configuration (the default, stated explicitly)
#   ./run.sh --release      # release configuration
#   ./run.sh --ipad          # list iPad devices (sim + real), pick, build & run
#   ./run.sh --dmg          # package a distributable .dmg (implies --release, no launch)
#   ./run.sh --sign         # ad-hoc code-sign the .app before packaging (implies --dmg)
#   ./run.sh --sign=<id>    # sign with a named identity, e.g. "Developer ID Application: …"
#   ./run.sh --clean        # wipe ./build before building (forces SPM re-resolve)
#   ./run.sh --no-launch    # build only, don't open the .app
#   ./run.sh --quiet        # suppress xcodebuild noise
#   ./run.sh --skip-deps    # don't try to install brew/npm tooling
#
# Combine freely: ./run.sh --clean --release
# DMG output lands in ./dist/HelixTradingApp-<version>.dmg
# Tip: an *unsigned* DMG is flagged "damaged" by Gatekeeper on other
# Macs — pass --sign so the bundle launches cleanly (ad-hoc is enough
# for personal use; a Developer ID identity is needed for wide sharing).
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
DMG=false
SIGN=""   # empty = don't sign; "-" = ad-hoc; otherwise a named identity
IPAD=false

# ── Args ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --release)    CONFIG="Release" ;;
    --debug)      CONFIG="Debug" ;;
    # Packaging a DMG is inherently a release artifact, and we don't
    # want to pop the app open mid-package — so --dmg forces Release
    # and suppresses launch (either can't sensibly be overridden here).
    --dmg)        DMG=true; CONFIG="Release"; LAUNCH=false ;;
    # Signing only makes sense for a packaged build, so --sign implies
    # the full --dmg pipeline. Bare --sign = ad-hoc ("-"); --sign=<id>
    # uses a named identity (Developer ID for shareable, notarisable
    # builds).
    --sign)       SIGN="-";            DMG=true; CONFIG="Release"; LAUNCH=false ;;
    --sign=*)     SIGN="${arg#*=}";    DMG=true; CONFIG="Release"; LAUNCH=false ;;
    --clean)      CLEAN=true ;;
    --ipad)       IPAD=true ;;
    --no-launch)  LAUNCH=false ;;
    --quiet)      QUIET=true ;;
    --skip-deps)  SKIP_DEPS=true ;;
    -h|--help)
      sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "❌ Unknown option: $arg (use --help)" >&2
      exit 2 ;;
  esac
done

# --ipad switches to the iPad scheme and handles its own launch flow.
if [ "$IPAD" = true ]; then
  SCHEME="HelixTradingAppiPad"
  LAUNCH=false   # we launch manually via simctl / xcodebuild -run
fi

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

if [ "$IPAD" = true ]; then
  # iPad: build for "Any iOS Simulator" so we get a universal sim build;
  # the actual device is chosen at install time.
  APP_PATH="$DERIVED/Build/Products/$CONFIG-iphonesimulator/$SCHEME.app"
  DESTINATION="generic/platform=iOS Simulator"
else
  APP_PATH="$DERIVED/Build/Products/$CONFIG/$SCHEME.app"
  DESTINATION="platform=macOS"
fi

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -destination "$DESTINATION"
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

# ── Step 5a: Code-sign (optional) ──────────────────────────────────
# An unsigned .app inside a DMG trips Gatekeeper on other Macs ("app
# is damaged and can't be opened"). Signing fixes that. We sign the
# bundle in place, deep (so the embedded SwiftPM frameworks are covered
# too) — but deliberately WITHOUT --options runtime: hardened runtime
# blocks the unsandboxed `claude`/`codex` process spawning this app
# depends on. Ad-hoc ("-") is enough for personal use; pass a Developer
# ID identity via --sign=<id> for a build you intend to notarise/share.
if [ -n "$SIGN" ]; then
  if [ "$SIGN" = "-" ]; then
    log "Code-signing app (ad-hoc)"
  else
    log "Code-signing app ($SIGN)"
  fi
  codesign --force --deep --timestamp=none --sign "$SIGN" "$APP_PATH" \
    || die "codesign failed — check the identity name (security find-identity -v -p codesigning)."
  codesign --verify --deep --strict "$APP_PATH" \
    || die "codesign verification failed for $APP_PATH."
  ok "Signed: $APP_PATH"
fi

# ── Step 5b: Package DMG ───────────────────────────────────────────
# A compressed (UDZO) disk image with the .app plus an /Applications
# symlink so the user can drag-to-install. Notarisation is still a
# separate step (needs a Developer ID + `xcrun notarytool`); this just
# produces a shareable artifact. Uses only hdiutil (ships with macOS),
# so there's no extra dependency to install.
if [ "$DMG" = true ]; then
  log "Packaging DMG"

  # Pull the version straight from the built app so the filename always
  # matches what's inside, rather than re-reading project.yml.
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0.0")

  DIST="$SCRIPT_DIR/dist"
  mkdir -p "$DIST"
  DMG_PATH="$DIST/$SCHEME-$VERSION.dmg"

  # Stage the contents in a temp dir: the .app + a symlink to
  # /Applications. hdiutil snapshots this folder into the image.
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  cp -R "$APP_PATH" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"

  # Overwrite any prior image at this path (-ov). UDZO = compressed.
  rm -f "$DMG_PATH"
  if [ "$QUIET" = true ]; then
    hdiutil create -volname "$SCHEME" -srcfolder "$STAGING" \
      -ov -format UDZO "$DMG_PATH" >/dev/null
  else
    hdiutil create -volname "$SCHEME" -srcfolder "$STAGING" \
      -ov -format UDZO "$DMG_PATH"
  fi

  rm -rf "$STAGING"
  trap - EXIT
  [ -f "$DMG_PATH" ] || die "hdiutil reported success but $DMG_PATH is missing."
  ok "DMG: $DMG_PATH"
fi

# ── Step 6: Launch ─────────────────────────────────────────────────
if [ "$IPAD" = true ]; then
  # ── iPad: list devices, let user pick, install & launch ────────
  log "Scanning for iPad devices"

  # Collect simulators (booted first, then shutdown) and real devices.
  # Format: "UDID | Name | OS | State"
  DEVICES=()
  IDX=0
  CURRENT_OS=""

  # Simulators — parse xcrun simctl list devices output.  Section
  # headers are "-- iOS 18.2 --", device lines are:
  #   iPad Name (UDID) (State)
  while IFS= read -r line; do
    # Track current OS version from section headers
    if [[ "$line" =~ ^--[[:space:]]+iOS[[:space:]]+([0-9.]+) ]]; then
      CURRENT_OS="${BASH_REMATCH[1]}"
      continue
    fi

    # Skip headers, empty lines, and non-device lines
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == "=="* ]] && continue
    [[ "$line" == "Known"* ]] && continue
    [[ "$line" == "--"* ]] && continue
    [[ "$line" =~ [A-F0-9]{8}- ]] || continue

    # Simulator format: "    iPad (A16) (UDID) (State)"
    # The UDID is always a UUID (8-4-4-4-12 hex). Extract it first,
    # then derive name and state from the remaining parts.
    udid=$(echo "$line" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
    [ -z "$udid" ] && continue
    # Name = everything before the UDID token
    name=$(echo "$line" | sed "s/ *([A-F0-9-]*${udid}.*//" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # State = word inside parens right after UDID
    state=$(echo "$line" | grep -oE "${udid}\) \([A-Za-z ]+\)" | sed "s/${udid}) *(//;s/).*//")
    [ -z "$name" ] && continue

    IDX=$((IDX + 1))
    icon="📱"
    [ "$state" = "Booted" ] && icon="🟢"
    DEVICES+=("$udid|$name|$CURRENT_OS|$state|sim")
    printf "  \033[1;36m%d)\033[0m %s %s (iOS %s) [%s]\n" "$IDX" "$icon" "$name" "$CURRENT_OS" "$state"
  done < <(xcrun simctl list devices iPad available 2>/dev/null)

  # Real devices — parse xcrun xctrace list devices
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == "=="* ]] && continue
    [[ "$line" == *"--"* ]] && continue
    [[ "$line" == *"Simulator"* ]] && continue
    [[ "$line" == *"MacBook"* ]] && continue
    [[ "$line" == *"Watch"* ]] && continue
    # Must contain a UUID-like hex string and a version number
    [[ "$line" =~ [0-9A-F]{8}- ]] || continue
    [[ "$line" =~ [0-9]+\.[0-9]+ ]] || continue

    # Format: "Name (OS) (UDID)" — split by parentheses
    name=$(echo "$line" | awk -F'[()]' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    os_ver=$(echo "$line" | awk -F'[()]' '{print $2}')
    udid=$(echo "$line" | awk -F'[()]' '{print $(NF-1)}')
    [ -z "$udid" ] && continue
    [ -z "$name" ] && continue

    IDX=$((IDX + 1))
    DEVICES+=("$udid|$name|$os_ver|connected|real")
    printf "  \033[1;32m%d)\033[0m 🔌 %s (iOS %s) [connected]\n" "$IDX" "$name" "$os_ver"
  done < <(xcrun xctrace list devices 2>/dev/null)

  if [ ${#DEVICES[@]} -eq 0 ]; then
    die "No iPad devices or simulators found. Open Simulator.app or connect a device."
  fi

  echo ""
  read -r -p "Pick a device (1-$IDX): " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$IDX" ] \
    || die "Invalid choice."

  IFS='|' read -r DEV_UDID DEV_NAME DEV_OS DEV_STATE DEV_TYPE <<< "${DEVICES[$((choice - 1))]}"
  ok "Selected: $DEV_NAME ($DEV_UDID)"

  if [ "$DEV_TYPE" = "sim" ]; then
    # Boot the simulator if it's not already running
    if [ "$DEV_STATE" != "Booted" ]; then
      log "Booting simulator $DEV_NAME"
      xcrun simctl boot "$DEV_UDID" 2>/dev/null || true
    fi
    # Open Simulator.app so the user can see it
    open -a Simulator --args -CurrentDeviceUDID "$DEV_UDID" 2>/dev/null || true
    sleep 1

    log "Installing $SCHEME on $DEV_NAME"
    xcrun simctl install "$DEV_UDID" "$APP_PATH"

    # Derive the bundle ID from the built Info.plist
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                  "$APP_PATH/Info.plist" 2>/dev/null)
    [ -n "$BUNDLE_ID" ] || die "Could not read CFBundleIdentifier from $APP_PATH/Info.plist"

    log "Launching $BUNDLE_ID on $DEV_NAME"
    xcrun simctl launch "$DEV_UDID" "$BUNDLE_ID"
    ok "$SCHEME launched on $DEV_NAME (simulator)"
  else
    # Real device — build, then install & launch via devicectl
    log "Installing & launching $SCHEME on $DEV_NAME"

    # Detect development team: env var > security keychain > error
    team_id="${DEVELOPMENT_TEAM:-}"
    if [ -z "$team_id" ]; then
      team_id=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '[A-F0-9]{10}' | head -1)
    fi
    if [ -z "$team_id" ]; then
      die "No development team found. Either:
  1) Open Xcode → Settings → Accounts → sign in with your Apple ID
  2) Or run: DEVELOPMENT_TEAM=<your-team-id> ./run.sh --ipad
You can find your team id at https://developer.apple.com/account"
    fi

    # Build for device with signing
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -destination "id=$DEV_UDID" \
      -derivedDataPath "$DERIVED" \
      -skipPackagePluginValidation \
      -skipMacroValidation \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$team_id" \
      CODE_SIGN_STYLE=Automatic \
      build

    # Find the built .app for device
    app_glob="$DERIVED/Build/Products/$CONFIG-iphoneos/$SCHEME.app"
    device_app=$(ls -d $app_glob 2>/dev/null | head -1)
    [ -d "$device_app" ] || die "Device build succeeded but .app not found at $app_glob"

    # Install and launch via devicectl (Xcode 15+)
    xcrun devicectl device install app --device "$DEV_UDID" "$device_app"
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                  "$device_app/Info.plist" 2>/dev/null)
    [ -n "$BUNDLE_ID" ] || die "Could not read CFBundleIdentifier from $device_app/Info.plist"
    xcrun devicectl device process launch --device "$DEV_UDID" "$BUNDLE_ID"
    ok "$SCHEME launched on $DEV_NAME (device)"
  fi

elif [ "$LAUNCH" = true ]; then
  log "Launching $SCHEME"
  # Kill any already-running instance so the fresh build is what
  # shows up on screen instead of an older still-open window.
  pkill -x "$SCHEME" 2>/dev/null || true
  sleep 0.2
  open "$APP_PATH"
  ok "$SCHEME launched"
fi

ok "Done"
