#!/usr/bin/env bash
#
# CREA — one-command install.
#
#   curl -fsSL https://.../install.sh | bash
#
# Plug in the Mac Mini, run this once, answer a few questions. Everything else —
# runtimes, command-line tools, models, background services, integrations — is
# handled here.
#
# Two rules this script holds to:
#   1. Idempotent. Safe to re-run. Anything already present is left alone.
#   2. A step that changed nothing says so. It never reports success for merely
#      not erroring, and it verifies at the end rather than assuming.
#
set -uo pipefail

CREA_HOME="${CREA_HOME:-$HOME/crea}"
TTS_HOME="$CREA_HOME/tts"
LOG="$CREA_HOME/var/logs/install.log"
FAILED=(); SKIPPED=(); DID=()

# ---------------------------------------------------------------- output

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
step(){ printf "\n${B}%s${N}\n" "$*"; }
ok(){   printf "  ${G}ok${N}    %s\n" "$*"; DID+=("$*"); }
skip(){ printf "  ${D}have${N}  %s\n" "$*"; SKIPPED+=("$*"); }
warn(){ printf "  ${Y}note${N}  %s\n" "$*"; }
bad(){  printf "  ${R}FAIL${N}  %s\n" "$*"; FAILED+=("$*"); }
ask(){  printf "\n${C}?${N} %s\n" "$*"; }

mkdir -p "$CREA_HOME/var/logs" "$CREA_HOME/var/models" "$CREA_HOME/var/media"
exec 3>>"$LOG"
run(){ "$@" >&3 2>&1; }

cat <<'BANNER'

   ┌─────────────────────────────────────────┐
   │   C R E A                               │
   │   Cfilms Real Estate Adviser            │
   └─────────────────────────────────────────┘

   This will take 15–25 minutes, mostly downloading.
   You can walk away until it asks you something.

BANNER

# ---------------------------------------------------------------- 0. sanity

step "Checking the machine"

if [[ "$(uname -s)" != "Darwin" ]]; then bad "CREA needs macOS"; exit 1; fi
ok "macOS $(sw_vers -productVersion)"

ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] && ok "Apple Silicon ($ARCH)" \
                         || warn "Intel Mac — this will work but will be slow"

RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if (( RAM_GB < 16 )); then
  warn "${RAM_GB}GB of memory. 16GB is the recommended floor — CREA will run,"
  warn "but expect the voice to stutter when other apps are open."
else
  ok "${RAM_GB}GB memory"
fi

FREE_GB=$(( $(df -k / | awk 'NR==2{print $4}') / 1048576 ))
if (( FREE_GB < 12 )); then bad "Only ${FREE_GB}GB free. CREA needs ~12GB."; exit 1; fi
ok "${FREE_GB}GB disk free"

# ---------------------------------------------------------------- 1. brew

step "Package manager"

if ! command -v brew >/dev/null 2>&1; then
  warn "Installing Homebrew — this will ask for your password"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" ]] && eval "$($p shellenv)"
  done
  command -v brew >/dev/null 2>&1 && ok "Homebrew installed" || { bad "Homebrew install failed"; exit 1; }
else
  skip "Homebrew"
fi

# ---------------------------------------------------------------- 2. CLI tools

step "Command-line tools"

brew_need(){                       # $1 formula  $2 binary
  if command -v "$2" >/dev/null 2>&1; then skip "$1"; return; fi
  printf "  ...   installing %s\n" "$1"
  if run brew install "$1"; then
    command -v "$2" >/dev/null 2>&1 && ok "$1" || bad "$1 installed but '$2' not on PATH"
  else
    bad "$1 — see $LOG"
  fi
}

brew_need whisper-cpp whisper-cli   # speech to text, on-device
brew_need ffmpeg      ffmpeg        # audio conversion for the media pipeline
brew_need node        node          # n8n runtime
brew_need exiftool    exiftool      # shot timestamps for splitting shoots
brew_need uv          uv            # python environments

# ---------------------------------------------------------------- 3. source

step "CREA itself"

CREA_REPO="${CREA_REPO:-https://github.com/skw-fuj/crea.git}"
CREA_BRANCH="${CREA_BRANCH:-main}"

if [[ -f "$CREA_HOME/bin/crea" && -d "$CREA_HOME/core" ]]; then
  # Already installed — update in place, but never clobber the user's settings.
  if [[ -d "$CREA_HOME/.git" ]]; then
    if run git -C "$CREA_HOME" pull --ff-only origin "$CREA_BRANCH"; then
      ok "CREA updated to latest"
    else
      warn "Could not fast-forward (local changes?). Keeping what's here."
    fi
  else
    skip "CREA source"
  fi
else
  printf "  ...   downloading CREA\n"
  if [[ -d "$CREA_HOME" ]] && [[ -n "$(ls -A "$CREA_HOME" 2>/dev/null | grep -v '^var$')" ]]; then
    # Non-empty target that isn't a CREA checkout: clone beside it, then merge in.
    TMP="$(mktemp -d)"
    if run git clone --depth 1 -b "$CREA_BRANCH" "$CREA_REPO" "$TMP/crea"; then
      run rsync -a --exclude 'var/' --exclude 'crea.config.json' "$TMP/crea/" "$CREA_HOME/"
      rm -rf "$TMP"; ok "CREA source installed"
    else
      rm -rf "$TMP"; bad "Could not download CREA from $CREA_REPO"; exit 1
    fi
  else
    if run git clone --depth 1 -b "$CREA_BRANCH" "$CREA_REPO" "$CREA_HOME"; then
      mkdir -p "$CREA_HOME/var/logs" "$CREA_HOME/var/models" "$CREA_HOME/var/media"
      ok "CREA source installed"
    else
      bad "Could not download CREA from $CREA_REPO"; exit 1
    fi
  fi
fi

# The settings file is yours. Seed it from the template only if absent — an
# upgrade must never overwrite a configured machine.
if [[ -f "$CREA_HOME/crea.config.json" ]]; then
  skip "your settings (left untouched)"
elif [[ -f "$CREA_HOME/crea.config.example.json" ]]; then
  cp "$CREA_HOME/crea.config.example.json" "$CREA_HOME/crea.config.json"
  ok "settings created from template"
fi

chmod +x "$CREA_HOME/bin/crea" 2>/dev/null

# ---------------------------------------------------------------- 4. models

step "Speech model"

WHISPER_MODEL="$CREA_HOME/var/models/ggml-base.en.bin"
if [[ -s "$WHISPER_MODEL" ]]; then
  skip "whisper base.en ($(du -h "$WHISPER_MODEL" | cut -f1))"
else
  printf "  ...   downloading whisper base.en (~148MB)\n"
  if run curl -fL --retry 3 -o "$WHISPER_MODEL" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
      && [[ -s "$WHISPER_MODEL" ]]; then
    ok "whisper base.en"
  else
    rm -f "$WHISPER_MODEL"; bad "whisper model download failed"
  fi
fi

# ---------------------------------------------------------------- 5. voice

step "Voice (on-device text-to-speech)"

if [[ -x "$TTS_HOME/.venv/bin/python" ]] \
   && "$TTS_HOME/.venv/bin/python" -c "import pocket_tts" >/dev/null 2>&1; then
  skip "Pocket TTS environment"
else
  printf "  ...   building the voice environment (~700MB, this is the slow part)\n"
  mkdir -p "$TTS_HOME"
  run uv venv --python 3.13 "$TTS_HOME/.venv"
  # resemblyzer rides along in this venv because it needs torch, which is
  # already here. setuptools is pinned because 81+ drops pkg_resources, which
  # webrtcvad (a resemblyzer dependency) still imports.
  if VIRTUAL_ENV="$TTS_HOME/.venv" run uv pip install pocket-tts numpy \
       resemblyzer "setuptools<81"; then
    ok "Pocket TTS + speaker recognition installed"
  else
    bad "Pocket TTS install failed — see $LOG"
  fi
fi

# ---------------------------------------------------------------- 6. python env

step "CREA environment"

if [[ -x "$CREA_HOME/.venv/bin/python" ]]; then
  skip "CREA environment"
else
  run uv venv --python 3.13 "$CREA_HOME/.venv"
  if VIRTUAL_ENV="$CREA_HOME/.venv" run uv pip install sounddevice numpy; then
    ok "CREA environment"
  else
    bad "CREA environment failed"
  fi
fi

# ---------------------------------------------------------------- 7. brain

step "Brain (Hermes)"

export PATH="$HOME/.local/bin:$PATH"
if command -v hermes >/dev/null 2>&1; then
  skip "Hermes $(hermes --version 2>/dev/null | head -1 | awk '{print $3}')"
else
  printf "  ...   installing Hermes\n"
  if run uv tool install hermes-agent; then ok "Hermes installed"; else bad "Hermes install failed"; fi
fi

if command -v hermes >/dev/null 2>&1; then
  printf "  ...   bootstrapping Hermes dependencies\n"
  run hermes postinstall || warn "hermes postinstall reported an issue — see $LOG"
fi

# ---------------------------------------------------------------- 8. routing

step "Model routing (free tier)"

# CREA talks to models through an OpenAI-compatible router so the model choice is
# config, not code. Default target is a local router; swapping LM_BASE_URL is the
# entire difference between free, local, and paid.
ROUTER="${CREA_ROUTER:-http://localhost:20128/v1}"
mkdir -p "$HOME/.hermes"
touch "$HOME/.hermes/.env"

setenv(){ # key value
  if grep -q "^$1=" "$HOME/.hermes/.env" 2>/dev/null; then
    /usr/bin/sed -i '' "s|^$1=.*|$1=$2|" "$HOME/.hermes/.env"
  else
    printf '%s=%s\n' "$1" "$2" >> "$HOME/.hermes/.env"
  fi
}
# Re-running the installer must not silently repoint a working brain. This
# script promises "safe to re-run", and it does leave crea.config.json alone —
# but the brain actually lives in Hermes' own config, and rewriting that
# unprompted moved a machine off a configured OpenRouter setup and back onto a
# router that was not running. The two configs then disagreed, and only kept
# working because CREA passes -m/--provider explicitly on every call.
#
# So: configure the default only when nothing is configured yet.
CURRENT_MODEL="$(hermes config get model 2>/dev/null \
                 | sed -n 's/.*default:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
[[ -z "$CURRENT_MODEL" ]] && CURRENT_MODEL="$(hermes config get model 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$CURRENT_MODEL" || "$CURRENT_MODEL" == "auto/best-fast" ]]; then
  setenv LM_BASE_URL "$ROUTER"
  setenv LM_API_KEY  "local"
  run hermes config set provider lmstudio
  run hermes config set model    auto/best-fast
  ok "Hermes routed to $ROUTER"
else
  skip "Hermes brain (already configured: $CURRENT_MODEL)"
fi

if curl -fsS -m 5 "$ROUTER/models" >/dev/null 2>&1; then
  ok "Router reachable"
else
  warn "Router not reachable yet at $ROUTER."
  warn "CREA will still install; set CREA_ROUTER, or run 'crea brain paid' to use a"
  warn "paid model instead. Nothing else depends on this step."
fi

# ---------------------------------------------------------------- 9. n8n

step "Integrations (n8n)"

if command -v n8n >/dev/null 2>&1; then
  skip "n8n"
else
  printf "  ...   installing n8n (~2 min)\n"
  if run npm install -g n8n; then ok "n8n installed"; else bad "n8n install failed"; fi
fi

# ---------------------------------------------------------------- 10. vault

step "Memory (Obsidian vault)"

if [[ -f "$CREA_HOME/vault/CREA.md" ]]; then
  skip "vault ($(ls "$CREA_HOME/vault/Jobs" 2>/dev/null | wc -l | tr -d ' ') jobs)"
else
  if "$CREA_HOME/bin/crea" init >&3 2>&1; then ok "vault created"; else bad "vault init failed"; fi
fi

if [[ -d "/Applications/Obsidian.app" ]]; then
  skip "Obsidian"
else
  printf "  ...   installing Obsidian\n"
  run brew install --cask obsidian && ok "Obsidian installed" \
    || warn "Obsidian not installed — grab it from obsidian.md (CREA works without it)"
fi

# ---------------------------------------------------------------- 11. services

step "Background services"

# launchd does NOT inherit your shell's PATH. A service started this way gets
# a bare /usr/bin:/bin:/usr/sbin:/sbin, which contains no Homebrew — so the
# agent could not find whisper-cli and every wake died with "whisper.cpp not
# installed", despite it being installed. ffmpeg and exiftool (the card
# pipeline) and hermes have the same problem. Pin the PATH explicitly.
SVC_PATH="$(dirname "$(command -v brew 2>/dev/null || echo /opt/homebrew/bin/brew)")"
SVC_PATH="$SVC_PATH:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

plist(){ # name  program-args...
  local name="$1"; shift
  local f="$HOME/Library/LaunchAgents/com.cfilms.crea.$name.plist"
  local args=""
  for a in "$@"; do args="$args    <string>$a</string>"$'\n'; done
  cat > "$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.cfilms.crea.$name</string>
  <key>ProgramArguments</key><array>
$args  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$SVC_PATH</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$CREA_HOME/var/logs/$name.log</string>
  <key>StandardErrorPath</key><string>$CREA_HOME/var/logs/$name.log</string>
</dict></plist>
PLIST
  launchctl unload "$f" >/dev/null 2>&1
  if launchctl load "$f" >/dev/null 2>&1; then ok "service: $name"; else bad "service: $name"; fi
}

plist voice "$TTS_HOME/.venv/bin/python" "$TTS_HOME/server.py"
plist agent "$CREA_HOME/.venv/bin/python" "$CREA_HOME/bin/crea" listen

# An always-on assistant that goes to sleep is not always on. caffeinate holds
# off idle and display sleep without needing an admin password, and without
# touching the machine's own power settings — so nothing here is left behind if
# CREA is ever removed. The Mac still sleeps if the lid is closed or you tell it
# to; this only stops it drifting off on its own.
plist awake /usr/bin/caffeinate -dis

# ---------------------------------------------------------------- 12. shortcut

step "Command shortcut"

SHIM=/usr/local/bin/crea
if [[ -L "$SHIM" || -f "$SHIM" ]]; then
  skip "'crea' command"
else
  if ln -sf "$CREA_HOME/bin/crea" "$SHIM" 2>/dev/null; then
    ok "'crea' command"
  else
    warn "Could not link into /usr/local/bin (needs sudo)."
    warn "Add this to your shell profile instead:"
    warn "  export PATH=\"$CREA_HOME/bin:\$PATH\""
  fi
fi

# ---------------------------------------------------------------- 13. schedule

step "Background jobs"

if "$CREA_HOME/bin/crea" schedule >&3 2>&1; then
  N=$("$CREA_HOME/bin/crea" schedule status 2>/dev/null | grep -c . || echo 0)
  ok "$N scheduled job(s) — briefing, bookings, invoicing, the board"
else
  bad "could not install the scheduled jobs — see $LOG"
fi

# ---------------------------------------------------------------- 14. accounts

step "Connecting your accounts"

cat <<'EOS'
  This is the only part that needs you. Each one is optional and each can be
  done later with `crea connect`. Everything installed above already works
  without them.
EOS

if [ -t 0 ]; then
  "$CREA_HOME/bin/crea" connect </dev/tty || true
else
  warn "not an interactive terminal — run 'crea connect' when you're ready"
fi

# ---------------------------------------------------------------- 15. verify

step "Verifying"

sleep 6
V_OK=0; V_TOT=0
check(){ # label  command...
  V_TOT=$((V_TOT+1))
  if "${@:2}" >/dev/null 2>&1; then ok "$1"; V_OK=$((V_OK+1)); else bad "$1"; fi
}
check "voice service"  curl -fsS -m 8 http://127.0.0.1:8812/health
check "speech-to-text" command -v whisper-cli
check "speech model"   test -s "$CREA_HOME/var/models/ggml-base.en.bin"
check "speaker id"     bash -c "curl -fsS -m 8 http://127.0.0.1:8812/health | grep -q speaker_id"
check "brain"          command -v hermes
check "integrations"   command -v n8n
check "vault"          test -f "$CREA_HOME/vault/CREA.md"
check "stays awake"    pgrep -f "caffeinate -dis"
check "skills"         "$CREA_HOME/bin/crea" skills

READY=$("$CREA_HOME/bin/crea" skills 2>/dev/null | grep -c "^  ok " || echo 0)
TOTAL=$("$CREA_HOME/bin/crea" skills 2>/dev/null | grep -cE "^  (ok|needs)" || echo 0)
[ "$READY" -gt 0 ] && ok "$READY of $TOTAL skills ready to run now"

printf "\n"
if (( ${#FAILED[@]} == 0 )); then
  cat <<EOS
${G}${B}CREA is installed and running.${N}

  Say  ${B}"Hey CREA"${N}  out loud, or try:

    ${B}crea ask "what have I got on this week?"${N}
    ${B}crea skills${N}                 everything it can do
    ${B}crea status${N}                 how every part is doing
    ${B}crea connect${N}                add an account you skipped
    ${B}crea card${N}                   import a plugged-in SD card
    ${B}crea enrol${N}                  teach it your voice, so it answers only you

  Your job vault:  $CREA_HOME/vault
  Full log:        $LOG
EOS
else
  printf "${R}${B}Installed with %d problem(s):${N}\n\n" "${#FAILED[@]}"
  for f in "${FAILED[@]}"; do printf "  ${R}·${N} %s\n" "$f"; done
  cat <<EOS

  ${V_OK}/${V_TOT} core checks passed, so CREA may still partly work.
  Send this file to Tristan and he'll sort it:  $LOG
EOS
  exit 1
fi
