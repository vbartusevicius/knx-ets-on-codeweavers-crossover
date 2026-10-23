#!/usr/bin/env bash
# =============================================================================
# install-ets.sh
#
# Automated installer for KNX ETS5 and ETS6 on macOS and Linux, using either
# CodeWeavers CrossOver or vanilla Wine (>= 11.0).
#
# What it does:
#   1. Creates a dedicated CrossOver bottle (cxbottle) or Wine prefix.
#   2. Optional (--case-store, macOS only): puts ProgramData/KNX on a
#      Case-sensitive APFS sparsebundle (remounted at login).
#   3. Installs .NET 4.8 (in Win7 mode before switching to Win10), VC++ 2022,
#      native Microsoft mscoree.dll, and missing .NET 4.0 COM registrations.
#   4. Installs Windows fonts (macOS Supplemental / Linux core fonts or
#      fontconfig substitutes), generates segmdl2.ttf, forces WPF software
#      rendering (fixes black windows/menus), and sets WebView2 options.
#   5. Installs ETS5/ETS6, applies ETS6N.exe.config runtime switches, extracts
#      the EIBAsc plugin compatibility layer, applies an app-local msi.dll fix
#      for KNX-Secure project passwords.
#   6. Registers a launcher: CrossOver app list (CrossOver), ~/Applications
#      app bundle (Wine on macOS) or .desktop entry (Wine on Linux).
#
# Usage:
#   ./install-ets.sh <Ets5Setup.exe|Ets6Setup.exe|zip> [options]
#   Run with --help for the list of options.
# =============================================================================
set -euo pipefail

case "$(uname -s)" in
  Darwin) HOST_OS=macos ;;
  Linux)  HOST_OS=linux ;;
  *) printf 'error: unsupported OS: %s (macOS or Linux required)\n' "$(uname -s)" >&2; exit 1 ;;
esac

# Ensure Homebrew paths (Apple Silicon, Workbrew, Intel) are on PATH
if [ "$HOST_OS" = macos ]; then
  for brew_dir in /opt/homebrew/bin /opt/workbrew/bin /usr/local/bin; do
    if [ -d "$brew_dir" ]; then
      case ":$PATH:" in
        *":$brew_dir:"*) ;;
        *) export PATH="$brew_dir:$PATH" ;;
      esac
    fi
  done
fi

die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  ./install-ets.sh <Ets5Setup.exe|Ets6Setup.exe|zip> [options]

Runtime selection (default: CrossOver if installed, otherwise Wine):
  --runtime <crossover|wine>
  --crossover <Path>     CrossOver install: CrossOver.app (macOS) or /opt/cxoffice (Linux)
                         (default: auto-detect, Preview preferred on macOS)
  --wine <Path>          wine binary to use (default: wine on PATH, then common locations)
  --prefix <Dir>         Wine prefix directory for --runtime wine
                         (default: ~/.local/share/wineprefixes/<name>)

Options:
  --bottle <Name>        Bottle / prefix name (default: ETS5 / ETS6)
  --ets-version <5|6>    Force ETS major version (default: detected from installer)
  --dpi <N>              Display DPI: 96=100%, 120=125%, 144=150% (default: 96)
  --interactive          Run the ETS installer with its GUI instead of /quiet
  --reinstall            Run the ETS installer even if ETS is already installed
  --skip-msi-fix         Do not apply the app-local msi.dll KNX-Secure fix
  --case-store           macOS only: keep ProgramData/KNX on a Case-sensitive APFS
                         disk image (only if projects fail to reopen with checksum errors)
  -h, --help             Show this help

Examples:
  ./install-ets.sh ~/Downloads/Ets6Setup.exe
  ./install-ets.sh ~/Downloads/Ets5Setup.exe --runtime wine --dpi 144
  ./install-ets.sh ~/Downloads/ETS6.zip --bottle "KNX-ETS6" --interactive
EOF
  exit 1
}

# -----------------------------------------------------------------------------
# 0. Parse arguments & validate ETS installer binary
# -----------------------------------------------------------------------------
INPUT_PATH=""
RUNTIME=""
BOTTLE_NAME=""
ETS_MAJOR=""
CROSSOVER_ARG=""
WINE_ARG=""
PREFIX_ARG=""
ETS_DPI=96
INTERACTIVE=0
REINSTALL=0
SKIP_MSI_FIX=0
CASE_STORE=0

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --runtime)      need_value "$@"; RUNTIME="$2";       shift 2 ;;
    --crossover)    need_value "$@"; CROSSOVER_ARG="$2"; shift 2 ;;
    --wine)         need_value "$@"; WINE_ARG="$2";      shift 2 ;;
    --prefix)       need_value "$@"; PREFIX_ARG="$2";    shift 2 ;;
    --bottle)       need_value "$@"; BOTTLE_NAME="$2";   shift 2 ;;
    --ets-version)  need_value "$@"; ETS_MAJOR="$2";     shift 2 ;;
    --dpi)          need_value "$@"; ETS_DPI="$2";       shift 2 ;;
    --interactive)  INTERACTIVE=1;  shift ;;
    --reinstall)    REINSTALL=1;    shift ;;
    --skip-msi-fix) SKIP_MSI_FIX=1; shift ;;
    --case-store)   CASE_STORE=1;   shift ;;
    -*) die "Unknown option: $1 (see --help)" ;;
    *)
      if [ -z "$INPUT_PATH" ]; then
        INPUT_PATH="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

[ -n "$INPUT_PATH" ] || usage
[ -f "$INPUT_PATH" ] || die "File not found: $INPUT_PATH"
INPUT_PATH="$(cd "$(dirname "$INPUT_PATH")" && pwd)/$(basename "$INPUT_PATH")"
case "$ETS_DPI" in ''|*[!0-9]*) die "--dpi must be a number (e.g. 96, 120, 144)" ;; esac
case "$RUNTIME" in ''|crossover|wine) ;; *) die "--runtime must be 'crossover' or 'wine'" ;; esac
if [ -n "$CROSSOVER_ARG" ] && { [ -n "$WINE_ARG" ] || [ -n "$PREFIX_ARG" ]; }; then
  die "--crossover cannot be combined with --wine / --prefix"
fi
if [ -n "$CROSSOVER_ARG" ]; then
  [ "$RUNTIME" != wine ] || die "--crossover cannot be used with --runtime wine"
  RUNTIME=crossover
fi
if [ -n "$WINE_ARG" ] || [ -n "$PREFIX_ARG" ]; then
  [ "$RUNTIME" != crossover ] || die "--wine / --prefix cannot be used with --runtime crossover"
  RUNTIME=wine
fi
[ "$CASE_STORE" != 1 ] || [ "$HOST_OS" = macos ] \
  || die "--case-store is macOS only (Linux filesystems are already case-sensitive)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [ "$HOST_OS" = macos ]; then
  ETS_CACHE="$HOME/Library/Caches/ets-on-crossover"
else
  ETS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ets-on-crossover"
fi
mkdir -p "$ETS_CACHE"

# If the user passed a .zip archive downloaded from MyKNX, extract the .exe from it
SETUP_EXE="$INPUT_PATH"
case "$(basename "$INPUT_PATH")" in
  *.[Zz][Ii][Pp])
    info "Extracting installer archive: $(basename "$INPUT_PATH")"
    unzip_dir="$ETS_CACHE/unzipped-installer"
    rm -rf "$unzip_dir"
    mkdir -p "$unzip_dir"
    python3 -m zipfile -e "$INPUT_PATH" "$unzip_dir"
    SETUP_EXE=$(find "$unzip_dir" -type f \( -iname '*Ets*Setup*.exe' -o -iname 'ETS*.exe' \) | head -n 1)
    [ -n "$SETUP_EXE" ] && [ -f "$SETUP_EXE" ] || die "Could not find Ets5Setup.exe / Ets6Setup.exe inside $INPUT_PATH"
    ok "Found installer inside archive: $(basename "$SETUP_EXE")"
    ;;
esac

# Detect ETS5 vs ETS6 from filename or binary contents (unless --ets-version was given)
if [ -z "$ETS_MAJOR" ]; then
  case "$(basename "$SETUP_EXE")" in
    *[Ee][Tt][Ss]5*) ETS_MAJOR=5 ;;
    *[Ee][Tt][Ss]6*) ETS_MAJOR=6 ;;
    *)
      if LC_ALL=C grep -aqi 'ETS6' "$SETUP_EXE"; then
        ETS_MAJOR=6
      elif LC_ALL=C grep -aqi 'ETS5' "$SETUP_EXE"; then
        ETS_MAJOR=5
      else
        ETS_MAJOR=6
      fi
      ;;
  esac
fi
case "$ETS_MAJOR" in 5|6) ;; *) die "--ets-version must be 5 or 6" ;; esac

BOTTLE_NAME="${BOTTLE_NAME:-ETS${ETS_MAJOR}}"
APP_NAME="ETS${ETS_MAJOR}"
ETS_SPARSEBUNDLE="$HOME/Library/Application Support/ETSStore.sparsebundle"
ETS_STORE_VOLUME="/Volumes/ETSStore"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.ets-on-crossover.etsstore.plist"

DOTNET48_URL="https://download.microsoft.com/download/f/3/a/f3a6af84-da23-40a5-8d1c-49cc10c8e76f/NDP48-x86-x64-AllOS-ENU.exe"
DOTNET48_SHA256="0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40"
DOTNET40_URL="https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
DOTNET40_SHA256="65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"
VCRUN2022_X64_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VCRUN2022_X86_URL="https://aka.ms/vs/17/release/vc_redist.x86.exe"
DOTNET48_RELEASE=528049
WEBVIEW2_ARGS="--no-sandbox --disable-gpu"

# -----------------------------------------------------------------------------
# 1. Locate CrossOver or Wine
# -----------------------------------------------------------------------------
realpath_py() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# Prints the CrossOver root (directory containing bin/cxbottle) for an app bundle or install dir
cx_root_of() {
  if [ -x "$1/Contents/SharedSupport/CrossOver/bin/cxbottle" ]; then
    printf '%s\n' "$1/Contents/SharedSupport/CrossOver"
  elif [ -x "$1/bin/cxbottle" ]; then
    printf '%s\n' "$1"
  else
    return 1
  fi
}

find_crossover() {
  local cand
  if [ -n "$CROSSOVER_ARG" ]; then
    cx_root_of "$CROSSOVER_ARG" || die "--crossover: not a CrossOver installation: $CROSSOVER_ARG"
    return 0
  fi
  if [ "$HOST_OS" = macos ]; then
    for cand in "/Applications/CrossOver Preview.app" "$HOME/Applications/CrossOver Preview.app" \
                "/Applications/CrossOver.app" "$HOME/Applications/CrossOver.app"; do
      cx_root_of "$cand" && return 0
    done
    cand=$(mdfind "kMDItemCFBundleIdentifier == 'com.codeweavers.CrossOver*'" 2>/dev/null | head -n 1 || true)
    [ -n "$cand" ] && cx_root_of "$cand" && return 0
  else
    for cand in /opt/cxoffice "$HOME/cxoffice"; do
      cx_root_of "$cand" && return 0
    done
  fi
  return 1
}

find_wine() {
  local cand
  if [ -n "$WINE_ARG" ]; then
    [ -x "$WINE_ARG" ] || die "--wine: not an executable: $WINE_ARG"
    realpath_py "$WINE_ARG"
    return 0
  fi
  cand=$(command -v wine 2>/dev/null || true)
  if [ -n "$cand" ]; then realpath_py "$cand"; return 0; fi
  for cand in \
    "/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine" \
    "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine" \
    "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine" \
    "$HOME/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine" \
    /opt/wine-devel/bin/wine /opt/wine-staging/bin/wine /opt/wine-stable/bin/wine; do
    if [ -x "$cand" ]; then realpath_py "$cand"; return 0; fi
  done
  return 1
}

wine_install_hint() {
  if [ "$HOST_OS" = macos ]; then
    printf 'Install CrossOver (https://www.codeweavers.com) or Wine Devel >= 11.0 from https://github.com/Gcenx/macOS_Wine_builds/releases (move "Wine Devel.app" to /Applications, then: xattr -dr com.apple.quarantine "/Applications/Wine Devel.app")'
  else
    printf 'Install CrossOver (https://www.codeweavers.com) or WineHQ wine-devel/wine-staging >= 11.0 (https://gitlab.winehq.org/wine/wine/-/wikis/Download)'
  fi
}

CX_ROOT=""
WINE_BIN=""
if [ "$RUNTIME" != wine ]; then
  CX_ROOT=$(find_crossover || true)
  if [ -z "$CX_ROOT" ] && [ "$RUNTIME" = crossover ]; then
    die "CodeWeavers CrossOver was not found. $(wine_install_hint)"
  fi
fi
if [ -n "$CX_ROOT" ]; then
  RUNTIME=crossover
else
  RUNTIME=wine
  WINE_BIN=$(find_wine || true)
  [ -n "$WINE_BIN" ] || die "Neither CrossOver nor Wine was found. $(wine_install_hint)"
fi

if [ "$RUNTIME" = crossover ]; then
  CX_BIN="$CX_ROOT/bin"
  WINE_BIN="$CX_BIN/wine"
  WINESERVER_BIN="$CX_BIN/wineserver"
  CX_BOTTLE_TOOL="$CX_BIN/cxbottle"
  CX_MENU_TOOL="$CX_BIN/cxmenu"
  for tool in "$WINE_BIN" "$CX_BOTTLE_TOOL" "$CX_MENU_TOOL"; do
    [ -x "$tool" ] || die "CrossOver tool not found: $tool"
  done
  if [ "$HOST_OS" = macos ]; then
    CX_BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles"
  else
    CX_BOTTLE_DIR="$HOME/.cxoffice"
  fi
  WINEPREFIX="$CX_BOTTLE_DIR/$BOTTLE_NAME"
  RUNTIME_ROOT="$CX_ROOT"
  WINE_CMD=("$WINE_BIN" --bottle "$BOTTLE_NAME")
  export CX_BOTTLE="$BOTTLE_NAME"
  export CX_BOTTLE_PATH="$CX_BOTTLE_DIR"
else
  wine_dir=$(dirname "$WINE_BIN")
  WINESERVER_BIN=""
  for cand in "$wine_dir/wineserver" "$(command -v wineserver 2>/dev/null || true)" \
              /usr/lib/wine/wineserver64 /usr/lib/wine/wineserver /usr/lib/x86_64-linux-gnu/wine/wineserver; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then WINESERVER_BIN="$cand"; break; fi
  done
  [ -n "$WINESERVER_BIN" ] || die "wineserver not found next to $WINE_BIN or on PATH"
  WINEPREFIX="${PREFIX_ARG:-${XDG_DATA_HOME:-$HOME/.local/share}/wineprefixes/$BOTTLE_NAME}"
  case "$WINEPREFIX" in /*) ;; *) WINEPREFIX="$PWD/$WINEPREFIX" ;; esac
  RUNTIME_ROOT=$(dirname "$wine_dir")
  WINE_CMD=("$WINE_BIN")

  wine_version=$("$WINE_BIN" --version 2>/dev/null | head -n 1 || true)
  if [ -z "$wine_version" ]; then
    [ "$HOST_OS" = macos ] && warn "If macOS blocked Wine, run: xattr -dr com.apple.quarantine \"/Applications/Wine Devel.app\""
    die "Could not run $WINE_BIN --version"
  fi
  ver_nums=$(printf '%s\n' "$wine_version" | sed -nE 's/^wine-([0-9]+)\.([0-9]+).*/\1 \2/p')
  if [ -z "$ver_nums" ]; then
    warn "Could not parse Wine version '$wine_version'; continuing"
  else
    wmaj=${ver_nums% *}
    wmin=${ver_nums#* }
    [ "$wmaj" -ge 11 ] || die "$wine_version is too old; Wine >= 11.0 is required (11.10+ recommended). $(wine_install_hint)"
    if [ "$wmaj" -eq 11 ] && [ "$wmin" -lt 10 ]; then
      warn "$wine_version lacks the Wine 11.10 USB fix (CM_Get_Parent); KNX USB license dongles may not be detected. Cloud licenses work."
    fi
  fi
fi
export WINEPREFIX

wrun() { "${WINE_CMD[@]}" "$@"; }
wsrv() { "$WINESERVER_BIN" "$@" 2>/dev/null || true; }

strip_cr() { tr -d '\r'; }

# True if the file is missing or a Wine builtin/placeholder DLL (not a real Microsoft DLL)
is_wine_dll() {
  [ -f "$1" ] || return 0
  head -c 512 "$1" | LC_ALL=C grep -aqE 'Wine (builtin|placeholder) DLL'
}

# PE helpers:
#   pe_tool bits <dll>           -> 64 | 32
#   pe_tool arch <exe>           -> x86_64 | i386 (process architecture, honours .NET AnyCPU)
#   pe_tool icon <exe> <outbase> -> writes <outbase>.png or <outbase>.ico, prints the path
pe_tool() {
  python3 - "$@" <<'PY'
import struct, sys

cmd, path = sys.argv[1], sys.argv[2]
d = open(path, "rb").read()
pe = struct.unpack_from("<I", d, 0x3C)[0]
machine, nsec = struct.unpack_from("<HH", d, pe + 4)
optsz = struct.unpack_from("<H", d, pe + 20)[0]
opt = pe + 24
ddir = opt + (96 if struct.unpack_from("<H", d, opt)[0] == 0x10B else 112)
secs = [struct.unpack_from("<IIII", d, opt + optsz + 40 * i + 8) for i in range(nsec)]

def off(rva):
    for vsize, va, rsize, raw in secs:
        if va <= rva < va + max(vsize, rsize):
            return rva - va + raw
    raise ValueError(rva)

def datadir(i):
    return struct.unpack_from("<II", d, ddir + 8 * i)

if cmd == "bits":
    print(64 if machine == 0x8664 else 32)
elif cmd == "arch":
    clr = datadir(14)[0]
    if machine == 0x8664 or (clr and not struct.unpack_from("<I", d, off(clr) + 16)[0] & 0x2):
        print("x86_64")
    else:
        print("i386")
elif cmd == "icon":
    base = off(datadir(2)[0])
    def entries(o):
        n = sum(struct.unpack_from("<HH", d, o + 12))
        return [struct.unpack_from("<II", d, o + 16 + 8 * k) for k in range(n)]
    def sub(t):
        return base + (t & 0x7FFFFFFF)
    def leaf(t):
        while t & 0x80000000:
            t = entries(sub(t))[0][1]
        rva, size = struct.unpack_from("<II", d, base + t)
        return d[off(rva):off(rva) + size]
    types = dict(entries(base))
    icons = {name: leaf(t) for name, t in entries(sub(types[3]))}
    grp = leaf(entries(sub(types[14]))[0][1])
    best = None
    for k in range(struct.unpack_from("<H", grp, 4)[0]):
        e = grp[6 + 14 * k:20 + 14 * k]
        w, _, _, _, _, bpp, _, iid = struct.unpack("<BBBBHHIH", e)
        key = (w or 256, bpp)
        if iid in icons and (best is None or key > best[0]):
            best = (key, icons[iid], e[:8])
    img = best[1]
    if img[:8] == b"\x89PNG\r\n\x1a\n":
        out = sys.argv[3] + ".png"
        open(out, "wb").write(img)
    else:
        out = sys.argv[3] + ".ico"
        open(out, "wb").write(struct.pack("<HHH", 0, 1, 1) + best[2] + struct.pack("<II", len(img), 22) + img)
    print(out)
PY
}

run_timeout() {
  local secs=$1
  shift
  python3 - "$secs" "$@" <<'PY'
import subprocess, sys
try:
    p = subprocess.run(sys.argv[2:], timeout=float(sys.argv[1]))
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

download() {
  local url=$1 dest=$2 sha=${3:-}
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    if [ -z "$sha" ] || [ "$(sha256_file "$dest")" = "$sha" ]; then
      return 0
    fi
    rm -f "$dest"
  fi
  info "Downloading $(basename "$dest")..."
  curl -fL --retry 3 --retry-delay 2 -o "$dest.partial" "$url"
  if [ -n "$sha" ]; then
    local got
    got=$(sha256_file "$dest.partial")
    [ "$got" = "$sha" ] || { rm -f "$dest.partial"; die "SHA-256 mismatch for $url"; }
  fi
  mv "$dest.partial" "$dest"
}

if pgrep -f 'ETS[56]N?\.exe' >/dev/null 2>&1; then
  die "ETS is currently running. Please close ETS before running this installer."
fi

info "Target:      KNX $APP_NAME ($(basename "$SETUP_EXE"))"
if [ "$RUNTIME" = crossover ]; then
  info "Runtime:     CrossOver ($CX_ROOT)"
  info "Bottle:      $BOTTLE_NAME ($WINEPREFIX)"
  case "$CX_ROOT" in
    *Preview*) ;;
    *) warn "Stable CrossOver may lack the Wine 11.10 USB fix (CM_Get_Parent); KNX USB license dongles may not be detected. Cloud licenses work. Use CrossOver Preview for dongles." ;;
  esac
else
  info "Runtime:     Wine ($wine_version, $WINE_BIN)"
  info "Prefix:      $WINEPREFIX"
fi

# -----------------------------------------------------------------------------
# 2. Ensure Host Extraction & Font Prerequisites
# -----------------------------------------------------------------------------
info "Step 1/8: Checking host prerequisites..."
if [ "$HOST_OS" = macos ]; then
  if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    info "Installing Rosetta 2 (required for Wine/CrossOver on Apple Silicon)..."
    softwareupdate --install-rosetta --agree-to-license || true
  fi
elif [ "$(uname -m)" != "x86_64" ]; then
  warn "Host is $(uname -m); ETS and .NET are x86 Windows binaries and need an x86_64 Wine/CrossOver."
fi

# Homebrew's "sevenzip" and newer distro "7zip" packages install 7zz; p7zip provides 7z
find_7z() { command -v 7zz 2>/dev/null || command -v 7z 2>/dev/null || true; }

missing=()
[ -n "$(find_7z)" ]                   || missing+=(7zip)
command -v msiextract >/dev/null 2>&1 || missing+=(msitools)
command -v msiinfo >/dev/null 2>&1    || missing+=(msitools)
command -v curl >/dev/null 2>&1       || missing+=(curl)
python3 -c "import fontTools" >/dev/null 2>&1 || missing+=(fonttools)

if [ "${#missing[@]}" -gt 0 ]; then
  missing_list=$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')
  if [ "$HOST_OS" = macos ]; then
    command -v brew >/dev/null 2>&1 || die "Homebrew is required to install: $missing_list"
    brew_pkgs=()
    for m in $missing_list; do
      case "$m" in
        7zip) brew_pkgs+=(sevenzip) ;;
        msitools|curl) brew_pkgs+=("$m") ;;
      esac
    done
    if [ "${#brew_pkgs[@]}" -gt 0 ]; then
      info "Installing Homebrew tools: ${brew_pkgs[*]}"
      brew install "${brew_pkgs[@]}"
    fi
  fi
  if ! python3 -c "import fontTools" >/dev/null 2>&1; then
    info "Installing Python package fonttools..."
    python3 -m pip install --user --quiet fonttools 2>/dev/null \
      || python3 -m pip install --break-system-packages --user --quiet fonttools 2>/dev/null || true
  fi
  if [ "$HOST_OS" = linux ]; then
    still=()
    [ -n "$(find_7z)" ]                   || still+=(7zip)
    command -v msiextract >/dev/null 2>&1 || still+=(msitools)
    command -v curl >/dev/null 2>&1       || still+=(curl)
    python3 -c "import fontTools" >/dev/null 2>&1 || still+=(fonttools)
    if [ "${#still[@]}" -gt 0 ]; then
      if command -v apt-get >/dev/null 2>&1; then hint="sudo apt install 7zip msitools curl python3-fonttools fontconfig"
      elif command -v dnf >/dev/null 2>&1; then hint="sudo dnf install 7zip msitools curl python3-fonttools fontconfig"
      elif command -v pacman >/dev/null 2>&1; then hint="sudo pacman -S 7zip msitools curl python-fonttools fontconfig"
      elif command -v zypper >/dev/null 2>&1; then hint="sudo zypper install 7zip msitools curl python3-fonttools fontconfig"
      else hint="install 7-Zip, msitools, curl, python3 fonttools and fontconfig with your package manager"
      fi
      die "Missing host tools: ${still[*]}. Install them with: $hint (on older Debian/Ubuntu use p7zip-full instead of 7zip)"
    fi
  fi
fi
SEVENZIP=$(find_7z)
[ -n "$SEVENZIP" ] || die "7-Zip (7zz or 7z) not found"
python3 -c "import fontTools" >/dev/null 2>&1 || die "Python package fonttools could not be installed"
ok "Host prerequisites ready"

# -----------------------------------------------------------------------------
# 3. Optional: Case-Sensitive APFS Sparsebundle for KNX ProjectStore (macOS)
# -----------------------------------------------------------------------------
if [ "$CASE_STORE" = "1" ]; then
  info "Step 2/8: Preparing Case-sensitive APFS volume for KNX ProjectStore..."
  if [ ! -d "$ETS_STORE_VOLUME/KNX" ] && ! mount | grep -q " on $ETS_STORE_VOLUME "; then
    if [ ! -d "$ETS_SPARSEBUNDLE" ]; then
      mkdir -p "$(dirname "$ETS_SPARSEBUNDLE")"
      hdiutil create -size 20g -type SPARSEBUNDLE -fs "Case-sensitive APFS" -volname "ETSStore" "$ETS_SPARSEBUNDLE" >/dev/null
    fi
    hdiutil attach "$ETS_SPARSEBUNDLE" -mountpoint "$ETS_STORE_VOLUME" -nobrowse -quiet
  fi
  mkdir -p "$ETS_STORE_VOLUME/KNX"

  # Remount automatically at login, otherwise ProgramData/KNX is a dangling link after reboot
  mkdir -p "$(dirname "$LAUNCH_AGENT")"
  cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ets-on-crossover.etsstore</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/hdiutil</string>
    <string>attach</string>
    <string>$ETS_SPARSEBUNDLE</string>
    <string>-mountpoint</string>
    <string>$ETS_STORE_VOLUME</string>
    <string>-nobrowse</string>
    <string>-quiet</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  ok "Case-sensitive APFS ProjectStore mounted at $ETS_STORE_VOLUME/KNX (auto-mounted at login)"
else
  info "Step 2/8: Case-sensitive ProjectStore volume not requested"
fi

# -----------------------------------------------------------------------------
# 4. Create CrossOver Bottle / Wine Prefix
# -----------------------------------------------------------------------------
if [ "$RUNTIME" = crossover ]; then
  info "Step 3/8: Creating / preparing CrossOver bottle '$BOTTLE_NAME'..."
  mkdir -p "$CX_BOTTLE_DIR"
  if [ ! -f "$WINEPREFIX/system.reg" ]; then
    "$CX_BOTTLE_TOOL" --bottle "$BOTTLE_NAME" --create --template win10_64 --install \
      --param "EnvironmentVariables:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=$WEBVIEW2_ARGS" \
      || die "cxbottle failed to create bottle '$BOTTLE_NAME'"
    wsrv -k
    sleep 1
  fi
  [ -f "$WINEPREFIX/system.reg" ] || die "Bottle '$BOTTLE_NAME' was not created at $WINEPREFIX"

  # Make sure WebView2 args are present for bottles created earlier
  if [ -f "$WINEPREFIX/cxbottle.conf" ] && ! grep -q WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS "$WINEPREFIX/cxbottle.conf"; then
    python3 - "$WINEPREFIX/cxbottle.conf" "$WEBVIEW2_ARGS" <<'PY'
import sys
path, args = sys.argv[1:]
text = open(path, encoding="utf-8", errors="replace").read()
line = f'"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS" = "{args}"'
if "[EnvironmentVariables]" in text:
    text = text.replace("[EnvironmentVariables]", "[EnvironmentVariables]\n" + line, 1)
else:
    text += "\n[EnvironmentVariables]\n" + line + "\n"
open(path, "w", encoding="utf-8").write(text)
PY
  fi
else
  info "Step 3/8: Creating / preparing Wine prefix '$WINEPREFIX'..."
  if [ ! -f "$WINEPREFIX/system.reg" ]; then
    mkdir -p "$(dirname "$WINEPREFIX")"
    # No Wine Mono / Gecko (they intercept .NET), no host menu entries from winemenubuilder
    WINEARCH=win64 WINEDLLOVERRIDES="mscoree=;mshtml=;winemenubuilder.exe=" WINEDEBUG=-all \
      wrun wineboot --init >/dev/null 2>&1 || true
    wsrv -w
  fi
  [ -f "$WINEPREFIX/system.reg" ] || die "Wine prefix was not created at $WINEPREFIX"
  # Keep winemenubuilder off; the script creates its own launcher with the right wine binary
  wrun reg add 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /t REG_SZ /d '' /f >/dev/null
fi

# WebView2 sandbox/GPU args for every process in the bottle (Wine imports HKCU\Environment)
wrun reg add 'HKCU\Environment' /v WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS /t REG_SZ /d "$WEBVIEW2_ARGS" /f >/dev/null

# Symlink drive_c/ProgramData/KNX -> /Volumes/ETSStore/KNX
if [ "$CASE_STORE" = "1" ]; then
  progdata="$WINEPREFIX/drive_c/ProgramData"
  mkdir -p "$progdata"
  knx_dir="$progdata/KNX"
  if [ ! -L "$knx_dir" ]; then
    if [ -d "$knx_dir" ]; then
      cp -R "$knx_dir/." "$ETS_STORE_VOLUME/KNX/"
      mv "$knx_dir" "${knx_dir}.bak-$(date +%s)"
    fi
    ln -s "$ETS_STORE_VOLUME/KNX" "$knx_dir"
  fi
fi
ok "Bottle / prefix '$BOTTLE_NAME' ready"

# -----------------------------------------------------------------------------
# 5. Install .NET Framework 4.8 + Visual C++ 2015-2022 Runtime
# -----------------------------------------------------------------------------
info "Step 4/8: Installing Microsoft .NET Framework 4.8 & Visual C++ 2022 Runtime..."

set_windows_version() {
  run_timeout 60 "${WINE_CMD[@]}" winecfg -v "$1" >/dev/null 2>&1 || true
  wsrv -k
  sleep 1
}

windows_product_name() {
  wrun reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v ProductName 2>/dev/null \
    | strip_cr | awk -F'REG_SZ' '/ProductName/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}'
}

dotnet_release() {
  local raw
  raw=$(wrun reg query "$1" /v Release 2>/dev/null | strip_cr | awk '/Release/ {print $NF}' || true)
  if [ -n "$raw" ]; then printf '%s\n' "$((raw))"; else printf '0\n'; fi
}

# Remove Wine Mono if it was installed into the bottle (it intercepts .NET)
mono_guids=$(wrun uninstaller --list 2>/dev/null | strip_cr | grep -i 'Wine Mono' | grep -oE '\{[0-9A-Fa-f-]{36}\}' || true)
for guid in $mono_guids; do
  info "Removing Wine Mono ($guid)..."
  wrun uninstaller --remove "$guid" >/dev/null 2>&1 || true
done

# The registry alone can't be trusted: CrossOver/Wine Mono pre-register a fake .NET 4.8.1
# (Release 533320) without installing Microsoft's runtime. Check the actual runtime files.
dotnet48_files_ok() {
  local fw f
  for fw in Framework Framework64; do
    for f in clr.dll mscoreei.dll mscorlib.dll; do
      [ -f "$WINEPREFIX/drive_c/windows/Microsoft.NET/$fw/v4.0.30319/$f" ] || return 1
      is_wine_dll "$WINEPREFIX/drive_c/windows/Microsoft.NET/$fw/v4.0.30319/$f" && return 1
    done
  done
  return 0
}

rel=$(dotnet_release 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full')
wow=$(dotnet_release 'HKLM\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4\Full')
if ! dotnet48_files_ok || [ "$rel" -lt "$DOTNET48_RELEASE" ] || [ "$wow" -lt "$DOTNET48_RELEASE" ]; then
  download "$DOTNET48_URL" "$ETS_CACHE/NDP48-x86-x64-AllOS-ENU.exe" "$DOTNET48_SHA256"
  if ! dotnet48_files_ok; then
    # Remove the fake registration, otherwise the installer sees a "newer" .NET and exits without installing
    info "Removing fake .NET 4.x registration (Release $rel) left by Wine Mono / CrossOver..."
    for node in 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4' \
                'HKLM\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4'; do
      wrun reg delete "$node" /f >/dev/null 2>&1 || true
    done
  fi
  # The 4.8 installer treats Windows 10 as "already has 4.8" and silently does nothing
  info "Setting bottle to Windows 7 so the .NET 4.8 installer actually installs..."
  set_windows_version win7
  case "$(windows_product_name)" in
    *"Windows 7"*) ;;
    *) die "Bottle still reports '$(windows_product_name)' instead of Windows 7; refusing to run .NET 4.8 installer" ;;
  esac
  info "Running Microsoft .NET Framework 4.8 installer (takes several minutes, please wait)..."
  wrun "$ETS_CACHE/NDP48-x86-x64-AllOS-ENU.exe" /q /norestart || true
  wsrv -w
  rel=$(dotnet_release 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full')
  wow=$(dotnet_release 'HKLM\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4\Full')
  [ "$rel" -ge "$DOTNET48_RELEASE" ] && [ "$wow" -ge "$DOTNET48_RELEASE" ] \
    || die ".NET 4.8 installation incomplete (Release native=$rel wow=$wow, expected >= $DOTNET48_RELEASE)"
  dotnet48_files_ok \
    || die ".NET 4.8 installer finished but Microsoft's runtime files (clr.dll, mscoreei.dll) are missing from Microsoft.NET\\Framework(64)\\v4.0.30319"
fi

info "Switching bottle to Windows 10..."
set_windows_version win10

if is_wine_dll "$WINEPREFIX/drive_c/windows/system32/vcruntime140.dll" || \
   is_wine_dll "$WINEPREFIX/drive_c/windows/syswow64/vcruntime140.dll"; then
  download "$VCRUN2022_X86_URL" "$ETS_CACHE/vc_redist.x86.exe"
  download "$VCRUN2022_X64_URL" "$ETS_CACHE/vc_redist.x64.exe"
  info "Installing Visual C++ 2015-2022 Redistributable (x86 & x64)..."
  wrun "$ETS_CACHE/vc_redist.x86.exe" /install /quiet /norestart || true
  wsrv -w
  wrun "$ETS_CACHE/vc_redist.x64.exe" /install /quiet /norestart || true
  wsrv -w
fi

for dll in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait \
           msvcp140_codecvt_ids vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1; do
  wrun reg add 'HKCU\Software\Wine\DllOverrides' /v "*$dll" /t REG_SZ /d 'native,builtin' /f >/dev/null
done
ok ".NET Framework 4.8 (Release $rel) and VC++ 2022 installed"

# -----------------------------------------------------------------------------
# 6. Native Microsoft mscoree.dll & .NET 4.0 COM Class Registrations
# -----------------------------------------------------------------------------
info "Step 5/8: Installing native Microsoft mscoree.dll & .NET 4.0 COM registrations..."
download "$DOTNET40_URL" "$ETS_CACHE/dotNetFx40_Full_x86_x64.exe" "$DOTNET40_SHA256"

extract="$ETS_CACHE/dotnet40-msis"
rm -rf "$extract"
mkdir -p "$extract"
"$SEVENZIP" x -y "-o$extract" "$ETS_CACHE/dotNetFx40_Full_x86_x64.exe" \
  netfx_Core_x86.msi netfx_Core_x64.msi netfx_Core.mzz >/dev/null

x86_msi="$extract/netfx_Core_x86.msi"
x64_msi="$extract/netfx_Core_x64.msi"
[ -f "$x86_msi" ] && [ -f "$x64_msi" ] || die "netfx_Core MSIs not found in the .NET 4.0 redistributable"
cab_name=$(msiinfo export "$x86_msi" Media | awk -F'\t' 'NR==4 { print $4 }' | strip_cr)
[ -n "$cab_name" ] || die "netfx_Core_x86.msi has no cabinet in its Media table"
if [ ! -e "$extract/$cab_name" ]; then
  cab_path=$(find "$extract" -maxdepth 1 -iname "$cab_name" | head -n 1)
  [ -n "$cab_path" ] || die "Cabinet $cab_name not found in the .NET 4.0 redistributable"
  ln -s "$(basename "$cab_path")" "$extract/$cab_name"
fi

files="$ETS_CACHE/dotnet40-files"
rm -rf "$files"
mkdir -p "$files/x86" "$files/x64"
msiextract --directory "$files/x86" "$x86_msi" >/dev/null 2>&1
msiextract --directory "$files/x64" "$x64_msi" >/dev/null 2>&1

sys32="$WINEPREFIX/drive_c/windows/system32"
syswow="$WINEPREFIX/drive_c/windows/syswow64"
while IFS= read -r dll; do
  case "$(pe_tool bits "$dll" 2>/dev/null || true)" in
    64) cp -f "$dll" "$sys32/mscoree.dll" ;;
    32) cp -f "$dll" "$syswow/mscoree.dll" ;;
  esac
done < <(find "$files" -iname 'mscoree.dll' -type f)
is_wine_dll "$sys32/mscoree.dll" && die "Failed to install native 64-bit mscoree.dll"
is_wine_dll "$syswow/mscoree.dll" && die "Failed to install native 32-bit mscoree.dll"

wrun reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree  /t REG_SZ /d 'native,builtin' /f >/dev/null
wrun reg add 'HKCU\Software\Wine\DllOverrides' /v '*mscoree' /t REG_SZ /d 'native,builtin' /f >/dev/null
wrun reg add 'HKLM\SOFTWARE\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ \
  /d 'C:\windows\Microsoft.NET\Framework64\' /f >/dev/null
wrun reg add 'HKLM\SOFTWARE\Wow6432Node\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ \
  /d 'C:\windows\Microsoft.NET\Framework\' /f >/dev/null
# Wine registers a fake .NET 2.0 runtime (policy v2.0 + stub mscorwks.dll). The native shim then
# picks "v2.0" for legacy hosts (MSI custom actions) and crashes in mscorwks.DllGetClassObjectInternal.
# Force all legacy activation onto the real .NET 4 runtime.
for node in 'HKLM\SOFTWARE\Microsoft\.NETFramework' 'HKLM\SOFTWARE\Wow6432Node\Microsoft\.NETFramework'; do
  wrun reg add "$node" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f >/dev/null
  wrun reg delete "$node\\Policy\\v2.0" /f >/dev/null 2>&1 || true
done

wsrv -k
sleep 1

regfile="$ETS_CACHE/dotnet40-com.reg"
python3 - "$x86_msi" "$x64_msi" "$WINEPREFIX/system.reg" "$regfile" <<'PY'
import re, subprocess, sys
from collections import OrderedDict

SUBS = {
    "FXAssemblyVersion": "4.0.0.0",
    "RTM_ProductVersion": "4.0.30319",
    "VSAssemblyVersion": "10.0.0.0",
    "URTVersion": "v4.0.30319",
    "URTBuildNum": "30319",
    "ProductName": "Microsoft .NET Framework 4 Client Profile",
    "LocProductName": "Microsoft .NET Framework 4 Client Profile",
    "WPFRegistryKey": "Windows Presentation Foundation",
    "WPFStaticVersion": "4.0",
    "ProductCode": "{3C3901C5-3455-3E0A-A214-0B093A5070A6}",
    "SystemFolder_x86": r"C:\windows\syswow64\\",
    "SystemFolder_amd64": r"C:\windows\system32\\",
    "FrameworkVersionFolder_x86": r"C:\windows\Microsoft.NET\Framework\v4.0.30319\\",
    "FrameworkVersionFolder_amd64": r"C:\windows\Microsoft.NET\Framework64\v4.0.30319\\",
    "Framework_x86": r"C:\windows\Microsoft.NET\Framework\\",
    "Framework_amd64": r"C:\windows\Microsoft.NET\Framework64\\",
    "~": "",
}
FILE_TOKENS = {
    "#_003_mscoree_dll_x86": r"C:\windows\syswow64\mscoree.dll",
    "#_003_mscoree_dll_amd64": r"C:\windows\system32\mscoree.dll",
}

def expand(text):
    def repl(m):
        tok = m.group(1)
        if tok in SUBS: return SUBS[tok]
        w = m.group(0)
        return FILE_TOKENS.get(w, w)
    return re.sub(r"\[([^\]]+)\]", repl, text)

def export_registry(msi):
    out = subprocess.check_output(["msiinfo", "export", msi, "Registry"], text=True, errors="replace")
    return [l.rstrip("\r").split("\t") for i, l in enumerate(out.splitlines()) if i >= 3 and len(l.split("\t")) >= 6]

def place(root, key, wow):
    if root == "0":
        return (r"Software\Classes\Wow6432Node" if wow else r"Software\Classes") + "\\" + key
    if root != "2": return None
    low = key.lower()
    if low.startswith("software\\classes\\"):
        return (r"Software\Classes\Wow6432Node" if wow else r"Software\Classes") + "\\" + key.split("\\", 2)[2]
    if low.startswith("software\\"):
        return ("Software\\Wow6432Node\\" if wow else "Software\\") + key.split("\\", 1)[1]
    return None

def rows_to_entries(rows, wow):
    entries = []
    for p in rows:
        root, key, name, value, comp = p[1], p[2], p[3], p[4], p[5]
        if not wow and not ("amd64" in comp.lower() or comp.lower().endswith("x64")): continue
        key, value = expand(key), expand(value)
        if "[" in key or "[" in value: continue
        full = place(root, key, wow)
        if not full: continue
        dword = None
        if value.startswith("#%"): value = value[2:]
        elif value.startswith("#x") and all(c in "0123456789abcdefABCDEF" for c in value[2:]): dword = int(value[2:], 16)
        elif value.startswith("#") and value[1:].isdigit(): dword = int(value[1:])
        entries.append((full, name, value, dword))
    return entries

x86, x64, sys_path, out_path = sys.argv[1:]
entries = rows_to_entries(export_registry(x86), True) + rows_to_entries(export_registry(x64), False)
sys_text = open(sys_path, encoding="utf-8", errors="replace").read()
system = {}
for b in re.split(r"\n(?=\[)", sys_text):
    h = b.split("\n", 1)[0]
    if h.startswith("["): system[h[1:].split("]")[0].replace("\\\\", "\\").lower()] = b

chosen, seen = [], set()
for full, name, value, dword in entries:
    if full.lower() in system or (full.lower(), name.lower()) in seen: continue
    seen.add((full.lower(), name.lower()))
    chosen.append((full, name, value, dword))

for child in [k for k in system if k.endswith("\\inprocserver32\\4.0.30319")]:
    parent = child.rsplit("\\", 1)[0]
    if any(l.startswith("@=") for l in system.get(parent, "").splitlines()[1:15]): continue
    wow = "wow6432node" in parent
    dll = r"C:\windows\syswow64\mscoree.dll" if wow else r"C:\windows\system32\mscoree.dll"
    pkey = system[child].split("\n", 1)[0][1:].split("]")[0].replace("\\\\", "\\").rsplit("\\", 1)[0]
    for item in [(pkey, "", dll, None), (pkey, "ThreadingModel", "Both", None)]:
        if (item[0].lower(), item[1].lower()) not in seen:
            seen.add((item[0].lower(), item[1].lower()))
            chosen.append(item)

groups = OrderedDict()
for full, name, value, dword in chosen:
    groups.setdefault(full, []).append((name, value, dword))
out = ["Windows Registry Editor Version 5.00\r\n\r\n"]
for full, vals in groups.items():
    out.append(f"[HKEY_LOCAL_MACHINE\\{full}]\r\n")
    for name, value, dword in vals:
        if dword is not None:
            out.append(("@=" if name == "" else f'"{name}"=') + f"dword:{dword:08x}\r\n")
        else:
            esc = value.replace("\\", "\\\\").replace('"', '\\"')
            nesc = name.replace("\\", "\\\\").replace('"', '\\"')
            out.append(f'@="{esc}"\r\n' if name == "" else f'"{nesc}"="{esc}"\r\n')
    out.append("\r\n")
open(out_path, "wb").write("".join(out).encode("utf-16"))
PY

wrun regedit /s "$regfile"
wsrv -k
sleep 1
ok "Native Microsoft mscoree.dll and .NET 4.0 COM registrations imported"

# -----------------------------------------------------------------------------
# 7. Fonts, WPF Software Rendering & WebView2
# -----------------------------------------------------------------------------
info "Step 6/8: Configuring fonts, WPF software rendering & WebView2..."
fontsdir="$WINEPREFIX/drive_c/windows/Fonts"
mkdir -p "$fontsdir"

# Copy Windows core fonts from the host (macOS Supplemental fonts, Linux msttcorefonts or
# fontconfig substitutes such as Liberation/DejaVu). Prints the real family names used.
font_map=$(python3 - "$fontsdir" "$HOST_OS" <<'PY'
import glob, os, shutil, subprocess, sys
from fontTools.ttLib import TTFont

fontsdir, host = sys.argv[1:]
# Windows file name, Windows family, macOS Supplemental file, fontconfig pattern
FONTS = [
    ("arial.ttf",    "Arial",                "Arial.ttf",                "Arial:style=Regular"),
    ("arialbd.ttf",  "Arial",                "Arial Bold.ttf",           "Arial:style=Bold"),
    ("ariali.ttf",   "Arial",                "Arial Italic.ttf",         "Arial:style=Italic"),
    ("arialbi.ttf",  "Arial",                "Arial Bold Italic.ttf",    "Arial:style=Bold Italic"),
    ("tahoma.ttf",   "Tahoma",               "Tahoma.ttf",               "Tahoma:style=Regular"),
    ("tahomabd.ttf", "Tahoma",               "Tahoma Bold.ttf",          "Tahoma:style=Bold"),
    ("verdana.ttf",  "Verdana",              "Verdana.ttf",              "Verdana:style=Regular"),
    ("verdanab.ttf", "Verdana",              "Verdana Bold.ttf",         "Verdana:style=Bold"),
    ("cour.ttf",     "Courier New",          "Courier New.ttf",          "Courier New:style=Regular"),
    ("courbd.ttf",   "Courier New",          "Courier New Bold.ttf",     "Courier New:style=Bold"),
    ("micross.ttf",  "Microsoft Sans Serif", "Microsoft Sans Serif.ttf", "Microsoft Sans Serif"),
    ("trebuc.ttf",   "Trebuchet MS",         "Trebuchet MS.ttf",         "Trebuchet MS"),
    ("times.ttf",    "Times New Roman",      "Times New Roman.ttf",      "Times New Roman:style=Regular"),
]
LINUX_DIRS = ["/usr/share/fonts", "/usr/local/share/fonts", "~/.local/share/fonts", "~/.fonts"]

index = {}
if host == "linux":
    for d in LINUX_DIRS:
        for p in glob.glob(os.path.join(os.path.expanduser(d), "**", "*.[tT][tT][fF]"), recursive=True):
            index.setdefault(os.path.basename(p).lower(), p)

def family(path):
    try:
        return TTFont(path, fontNumber=0, lazy=True)["name"].getDebugName(1)
    except Exception:
        return None

def source(win_file, mac_file, pattern):
    if host == "macos":
        p = os.path.join("/System/Library/Fonts/Supplemental", mac_file)
        return p if os.path.isfile(p) else None
    if win_file in index:
        return index[win_file]
    try:
        p = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        return None
    return p if p.lower().endswith((".ttf", ".otf")) and os.path.isfile(p) else None

families = {}
for win_file, win_family, mac_file, pattern in FONTS:
    src = source(win_file, mac_file, pattern)
    fam = family(src) if src else None
    if not fam:
        continue
    shutil.copyfile(src, os.path.join(fontsdir, win_file))
    families.setdefault(win_family, fam)
    if win_file == "arial.ttf" and not os.path.isfile(os.path.join(fontsdir, "segoeui.ttf")):
        shutil.copyfile(src, os.path.join(fontsdir, "segoeui.ttf"))

if "Arial" not in families:
    sys.exit("No Arial or Arial-compatible font found on the host")
print(f"SANS\t{families['Arial']}")
print(f"MONO\t{families.get('Courier New', families['Arial'])}")
for win_family, fam in families.items():
    if fam != win_family:
        print(f"REPL\t{win_family}\t{fam}")
PY
) || {
  if [ "$HOST_OS" = linux ]; then
    die "No Arial-compatible font found. Install Microsoft core fonts (ttf-mscorefonts-installer / msttcore-fonts) or Liberation fonts (fonts-liberation) and fontconfig"
  fi
  die "Arial.ttf not found in /System/Library/Fonts/Supplemental (needed as Segoe UI substitute)"
}

sans_family=Arial
mono_family="Courier New"
replacements=()
while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    SANS) sans_family="$a" ;;
    MONO) mono_family="$a" ;;
    REPL) replacements+=("$a:$b") ;;
  esac
done <<< "$font_map"
[ "$sans_family" = Arial ] || info "Using '$sans_family' as Arial / Segoe UI substitute"

# Generate procedural segmdl2.ttf (Segoe MDL2 Assets for ETS6 titlebar buttons)
python3 - "$fontsdir/segmdl2.ttf" <<'PY'
import sys
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

EM = 2048
CP = {0xE106: "close", 0xE73C: "indeterminate", 0xE921: "minimize",
      0xE922: "maximize", 0xE923: "restore", 0xEB90: "projectclose"}
ORDER = [".notdef"] + list(dict.fromkeys(CP.values()))

def box(pen, x0, y0, x1, y1, t=90):
    pen.moveTo((x0, y0)); pen.lineTo((x1, y0)); pen.lineTo((x1, y1)); pen.lineTo((x0, y1)); pen.closePath()
    pen.moveTo((x0+t, y0+t)); pen.lineTo((x0+t, y1-t)); pen.lineTo((x1-t, y1-t)); pen.lineTo((x1-t, y0+t)); pen.closePath()

def stroke_h(pen, x0, x1, y, t=90):
    pen.moveTo((x0, y-t)); pen.lineTo((x1, y-t)); pen.lineTo((x1, y+t)); pen.lineTo((x0, y+t)); pen.closePath()

def draw(name, pen):
    if name == "minimize": stroke_h(pen, 400, 1400, 300)
    elif name == "maximize": box(pen, 400, 300, 1400, 1300)
    elif name == "restore": box(pen, 300, 200, 1250, 1150); box(pen, 550, 450, 1500, 1400)
    elif name in ("close", "projectclose"):
        pen.moveTo((400, 350)); pen.lineTo((520, 230)); pen.lineTo((1500, 1210)); pen.lineTo((1380, 1330)); pen.closePath()
        pen.moveTo((1380, 230)); pen.lineTo((1500, 350)); pen.lineTo((520, 1330)); pen.lineTo((400, 1210)); pen.closePath()
    elif name == "indeterminate": stroke_h(pen, 500, 1300, 800)
    else: box(pen, 200, 100, 900, 1400, t=70)

fb = FontBuilder(EM, isTTF=True)
fb.setupGlyphOrder(ORDER)
fb.setupCharacterMap(CP)
glyphs, metrics = {}, {}
for n in ORDER:
    pen = TTGlyphPen(None)
    draw(n, pen)
    glyphs[n] = pen.glyph()
    metrics[n] = (1800, 0)
fb.setupGlyf(glyphs)
fb.setupHorizontalMetrics(metrics)
fb.setupHorizontalHeader(ascent=1638, descent=-410)
fb.setupNameTable({"familyName": "Segoe MDL2 Assets", "styleName": "Regular",
                   "fullName": "Segoe MDL2 Assets", "psName": "SegoeMDL2Assets-Regular"})
fb.setupOS2(sTypoAscender=1638, sTypoDescender=-410, usWinAscent=1638, usWinDescent=410)
fb.setupPost()
fb.save(sys.argv[1])
PY

wrun reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' /v 'Segoe UI (TrueType)' /t REG_SZ /d 'segoeui.ttf' /f >/dev/null
wrun reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' /v 'Segoe MDL2 Assets (TrueType)' /t REG_SZ /d 'segmdl2.ttf' /f >/dev/null

for pair in "Segoe UI:$sans_family" "Segoe UI Symbol:$sans_family" "Segoe UI Emoji:$sans_family" \
            "Segoe UI Historic:$sans_family" "Consolas:$mono_family" ${replacements[@]+"${replacements[@]}"}; do
  wrun reg add 'HKCU\Software\Wine\Fonts\Replacements' /v "${pair%%:*}" /t REG_SZ /d "${pair#*:}" /f >/dev/null
done

for face in "Microsoft Sans Serif" "Segoe UI" "Arial" "Tahoma"; do
  wrun reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink' /v "$face" /t REG_MULTI_SZ /d "arial.ttf,$sans_family" /f >/dev/null
done

desktop='HKCU\Control Panel\Desktop'
wrun reg add "$desktop" /v FontSmoothing /d 2 /f >/dev/null
wrun reg add "$desktop" /v FontSmoothingType /t REG_DWORD /d 2 /f >/dev/null
wrun reg add "$desktop" /v FontSmoothingGamma /t REG_DWORD /d 1400 /f >/dev/null
wrun reg add "$desktop" /v FontSmoothingOrientation /t REG_DWORD /d 1 /f >/dev/null
wrun reg add "$desktop" /v LogPixels /t REG_DWORD /d "$ETS_DPI" /f >/dev/null

rm -rf "$WINEPREFIX"/drive_c/users/*/AppData/Local/Microsoft/FontCache \
       "$WINEPREFIX"/drive_c/users/*/AppData/Local/FontCache 2>/dev/null || true

# Force WPF onto the CPU software rasterizer (fixes black main window & black menus)
wrun reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >/dev/null

# WebView2 registry stubs checked by ETS6 at startup
guid='{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
ver='109.0.1518.140'
wrun reg add "HKCU\\Software\\Microsoft\\EdgeUpdate\\ClientState\\$guid" /v pv /t REG_SZ /d "$ver" /f >/dev/null
wrun reg add "HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\$guid"     /v pv /t REG_SZ /d "$ver" /f >/dev/null
wrun reg add 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' /v Version /t REG_SZ /d 'win7' /f >/dev/null

wsrv -k
ok "Fonts, WPF software rendering, and WebView2 configured"

# -----------------------------------------------------------------------------
# 8. Install ETS5 / ETS6 & Compatibility Fixes
# -----------------------------------------------------------------------------
info "Step 7/8: Installing KNX $APP_NAME into bottle '$BOTTLE_NAME'..."
ets_dir="$WINEPREFIX/drive_c/Program Files (x86)/ETS$ETS_MAJOR"
log="$WINEPREFIX/drive_c/ets$ETS_MAJOR-install.log"

ets_installed() {
  [ -f "$ets_dir/ETS${ETS_MAJOR}N.exe" ] || [ -f "$ets_dir/ETS${ETS_MAJOR}.exe" ]
}

# Fallback when the installer's managed (.NET) setup UI fails to load under Wine:
# Burn then runs only its prerequisite UI and exits 0 without installing ETS.
# Unpack the MSI packages embedded in the Burn bundle and install them with msiexec.
install_via_embedded_msis() {
  local work="$WINEPREFIX/drive_c/ets-msi"
  rm -rf "$work"
  mkdir -p "$work"
  info "Unpacking MSI packages embedded in $(basename "$SETUP_EXE")..."
  local plan
  plan=$(python3 - "$SETUP_EXE" "$work" "$SEVENZIP" <<'PY'
import os, shutil, struct, subprocess, sys
import xml.etree.ElementTree as ET

exe, work, sevenzip = sys.argv[1:]
data = open(exe, "rb").read()

# Burn appends its UX and attached containers as CAB files after the engine
cab_dirs, i = [], 0
while True:
    i = data.find(b"MSCF\x00\x00\x00\x00", i)
    if i < 0:
        break
    size = struct.unpack_from("<I", data, i + 8)[0]
    if 0 < size <= len(data) - i:
        n = len(cab_dirs)
        cab = os.path.join(work, f"c{n}.cab")
        out = os.path.join(work, f"c{n}")
        open(cab, "wb").write(data[i:i + size])
        if subprocess.run([sevenzip, "x", "-y", f"-o{out}", cab], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            cab_dirs.append(out)
        os.remove(cab)
        i += size
    else:
        i += 4

def find(name):
    for d in cab_dirs:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p
    return None

manifest = None
for d in cab_dirs:
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.isfile(p) and b"<BurnManifest" in open(p, "rb").read(4096):
            manifest = p
if not manifest:
    sys.exit("no BurnManifest found in bundle")

def local(tag):
    return tag.rsplit("}", 1)[-1]

root = ET.parse(manifest).getroot()
payloads = {e.get("Id"): e for e in root.iter() if local(e.tag) == "Payload"}
chain = next((e for e in root.iter() if local(e.tag) == "Chain"), None)
if chain is None:
    sys.exit("no Chain in BurnManifest")

for pkg in chain:
    if local(pkg.tag) != "MsiPackage":
        continue
    pid = pkg.get("Id")
    pdir = os.path.join(work, "pkg", pid)
    msi = None
    for ref in pkg:
        if local(ref.tag) != "PayloadRef":
            continue
        pl = payloads.get(ref.get("Id"))
        if pl is None:
            continue
        src = find(pl.get("SourcePath", ""))
        if not src:
            sys.exit(f"payload {pl.get('FilePath')} of {pid} not found in bundle (not embedded?)")
        dst = os.path.join(pdir, pl.get("FilePath").replace("\\", "/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        if msi is None and dst.lower().endswith(".msi"):
            msi = dst
    if msi:
        props = " ".join(
            f'{p.get("Id")}="{p.get("Value")}"'
            for p in pkg if local(p.tag) == "MsiProperty" and "[" not in (p.get("Value") or "")
        )
        print(f"{pid}\t{os.path.relpath(msi, work)}\t{props}")
PY
  ) || { warn "Could not unpack MSI packages from the installer"; return 1; }

  [ -n "$plan" ] || { warn "No MSI packages found in the installer"; return 1; }
  local pid rel props win_msi
  while IFS=$'\t' read -r pid rel props; do
    win_msi="C:\\ets-msi\\$(printf '%s' "$rel" | tr '/' '\\')"
    info "Installing package $pid via msiexec..."
    # shellcheck disable=SC2086
    wrun msiexec /i "$win_msi" /qn /norestart ALLUSERS=1 $props /l*v "C:\\ets-msi-$pid.log" || \
      warn "msiexec returned non-zero for $pid (log: $WINEPREFIX/drive_c/ets-msi-$pid.log)"
    wsrv -w
  done <<< "$plan"
}

if ets_installed && [ "$REINSTALL" != "1" ]; then
  ok "$APP_NAME already installed (use --reinstall to run the installer again)"
else
  if [ "$INTERACTIVE" = "1" ]; then
    wrun "$SETUP_EXE" /log "c:\\ets$ETS_MAJOR-install.log" || true
  else
    wrun "$SETUP_EXE" /quiet /norestart /log "c:\\ets$ETS_MAJOR-install.log" || true
  fi
  wsrv -w

  if ! ets_installed; then
    warn "The ETS setup program exited without installing $APP_NAME."
    if [ -f "$log" ]; then
      warn "Errors reported by the setup program:"
      grep -aE '\]e[0-9]{3}:|Failed|failed|0x8[0-9a-fA-F]{7}' "$log" | grep -v 'result: 0x0' | head -20 >&2 || true
    fi
    install_via_embedded_msis || true
  fi
fi

if ! ets_installed; then
  die "$APP_NAME installation failed; see $log and $WINEPREFIX/drive_c/ets-msi-*.log"
fi

if [ -f "$ets_dir/ETS${ETS_MAJOR}N.exe" ]; then
  ETS_EXE_NAME="ETS${ETS_MAJOR}N.exe"
else
  ETS_EXE_NAME="ETS${ETS_MAJOR}.exe"
fi
ETS_EXE_WIN="C:\\Program Files (x86)\\ETS${ETS_MAJOR}\\${ETS_EXE_NAME}"

# Inject .NET runtime switches into ETS6N.exe.config / ETS6C.exe.config
if [ "$ETS_MAJOR" = "6" ]; then
  for cfg in "$ets_dir/ETS6N.exe.config" "$ets_dir/ETS6C.exe.config"; do
    [ -f "$cfg" ] || continue
    python3 - "$cfg" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()
if "legacyCorruptedStateExceptionsPolicy" not in text and "<runtime>" in text:
    inject = (
        "<runtime>\n"
        '    <legacyCorruptedStateExceptionsPolicy enabled="true" />\n'
        '    <AppContextSwitchOverrides value="Switch.System.Windows.Controls.Grid.StarDefinitionsCanExceedAvailableSpace=true" />'
    )
    open(path + ".orig", "w", encoding="utf-8").write(text)
    open(path, "w", encoding="utf-8").write(text.replace("<runtime>", inject, 1))
PY
  done
fi

# Extract EIBAsc compatibility layer (fixes 0x80070716 / "Value cannot be null" on import of plugin devices)
installer_dir="$WINEPREFIX/drive_c/windows/Installer"
eiba_dir="$WINEPREFIX/drive_c/Program Files (x86)/Common Files/EIBA sc"
if [ -d "$installer_dir" ]; then
  compat_msi=""
  for cand in "$installer_dir"/*.msi; do
    [ -f "$cand" ] || continue
    name=$(msiinfo export "$cand" Property 2>/dev/null | strip_cr | awk -F'\t' '$1 == "ProductName" { print $2 }')
    case "$name" in
      *'Compatibility Components'*) compat_msi="$cand"; break ;;
    esac
  done
  if [ -n "$compat_msi" ]; then
    eiba_extract="$ETS_CACHE/eibasc-files"
    rm -rf "$eiba_extract"
    mkdir -p "$eiba_extract"
    msiextract --directory "$eiba_extract" "$compat_msi" >/dev/null 2>&1 || true
    if [ -d "$eiba_extract/Common Files/EIBA sc" ]; then
      mkdir -p "$eiba_dir"
      cp -f "$eiba_extract/Common Files/EIBA sc"/EIBA.*.dll "$eiba_dir/" 2>/dev/null || true
      cp -f "$eiba_dir"/EIBA.Interop.*.dll "$eiba_dir"/EIBA.DownloadImageHelper.dll "$ets_dir/" 2>/dev/null || true
    fi
  fi
fi

if [ -f "$ets_dir/EtecRedirect.dll" ]; then
  cat > "$ets_dir/EtecRedirect.dll.manifest" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity name="EtecRedirect" version="1.0.0.0" type="win32"/>
  <dependency><dependentAssembly><assemblyIdentity name="EtecFwk" type="win32" version="5.1.0.0"/></dependentAssembly></dependency>
  <dependency><dependentAssembly><assemblyIdentity name="EtecDom" type="win32" version="5.1.0.0"/></dependentAssembly></dependency>
  <dependency><dependentAssembly><assemblyIdentity name="Hawk" type="win32" version="5.1.0.0"/></dependentAssembly></dependency>
  <dependency><dependentAssembly><assemblyIdentity name="EtecCtrl" type="win32" version="5.1.0.0"/></dependentAssembly></dependency>
  <dependency><dependentAssembly><assemblyIdentity name="Falcon" type="win32" version="5.1.0.0"/></dependentAssembly></dependency>
</assembly>
EOF
fi

# EtecDOM.dll ATL object-map init fix (only applied to the exact ETS 5.7.1428 build; no-op otherwise)
if [ -f "$ets_dir/EtecDOM.dll" ]; then
  python3 - "$ets_dir/EtecDOM.dll" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
call_off, cave_off = 0x400 + (0x2D293 - 0x1000), 0x400 + (0x895B0 - 0x1000)
hook, orig = bytes.fromhex("e818c30500"), bytes.fromhex("e8b0fafeff")
cave = bytes.fromhex(
    "e800000000582db595080083b8f4631400007537c780f46314002c000000"
    "8980f86314008d88444f12008988fc6314008d8810511200898800641400"
    "8d88046414006a0051ff909cb00800e94837f9ff"
)
if len(data) >= cave_off + len(cave) and bytes(data[call_off:call_off+5]) == orig and not any(data[cave_off:cave_off+len(cave)]):
    open(path + ".orig", "wb").write(data)
    data[cave_off:cave_off+len(cave)] = cave
    data[call_off:call_off+5] = hook
    open(path, "wb").write(data)
    print("Patched EtecDOM.dll ATL object map initialization")
PY
fi

# App-local msi.dll fix for KNX-Secure project passwords (Wine bug 60062:
# Installer.OpenDatabase numeric open mode coerced to a string).
# The runtime's own msi.dll is copied, patched, and placed next to the ETS exe
# only; a DLL override is set for the ETS exe only. Installers keep using the
# untouched builtin msi.dll. Skipped unless the patch site is found exactly once.
if [ "$SKIP_MSI_FIX" != "1" ]; then
  msi_arch=$(pe_tool arch "$ets_dir/$ETS_EXE_NAME" 2>/dev/null || echo i386)
  msi_src=$(find "$RUNTIME_ROOT/lib" "$RUNTIME_ROOT/lib64" -maxdepth 4 -path "*${msi_arch}-windows/msi.dll" -type f 2>/dev/null | head -n 1 || true)
  if [ -n "$msi_src" ] && python3 - "$msi_src" "$ets_dir/msi.dll" "$msi_arch" <<'PY'
import re, sys
src, dst, arch = sys.argv[1:]
data = bytearray(open(src, "rb").read())
if arch == "x86_64":
    # DispGetParam(pDispParams, 1 [edx], VT_BSTR=8 [r8d], ...) followed by V_VT(result)=VT_DISPATCH(9)
    pat = re.compile(rb"\xba\x01\x00\x00\x00.{0,16}?\x41\xb8\x08\x00\x00\x00.{4,48}?\x66\xc7.{1,4}\x09\x00", re.DOTALL)
    needle, off = b"\x41\xb8\x08\x00\x00\x00", 2
else:
    # push 8 (VT_BSTR); push 1 (index) ... VT_DISPATCH(9) store
    pat = re.compile(rb"\x6a\x08\x6a\x01.{4,48}?\x66\xc7.{1,4}\x09\x00", re.DOTALL)
    needle, off = b"\x6a\x08\x6a\x01", 1
matches = list(pat.finditer(data))
if len(matches) != 1:
    sys.exit(1)
m = matches[0]
idx = m.start() + m.group(0).find(needle) + off
data[idx] = 0x03  # VT_BSTR -> VT_I4
sig = data.find(b"Wine builtin DLL")
if 0 <= sig < 0x100:
    data[sig:sig + 16] = b"\x00" * 16  # load as a native DLL from the app directory
open(dst, "wb").write(data)
PY
  then
    wrun reg add "HKCU\\Software\\Wine\\AppDefaults\\$ETS_EXE_NAME\\DllOverrides" /v msi /t REG_SZ /d 'native,builtin' /f >/dev/null
    ok "Applied app-local msi.dll fix for KNX-Secure project passwords"
  else
    rm -f "$ets_dir/msi.dll"
    warn "Could not safely locate the msi.dll patch site in this Wine build; skipped. Setting a password on KNX-Secure projects may crash ETS (Wine bug 60062)."
  fi
fi
ok "KNX $APP_NAME installed at $ets_dir"

# -----------------------------------------------------------------------------
# 9. Register the ETS Launcher
# -----------------------------------------------------------------------------
if [ "$RUNTIME" = crossover ]; then
  info "Step 8/8: Registering $APP_NAME in the CrossOver application list..."

  # Only create our own Start Menu shortcut if the ETS installer did not create one
  existing_lnk=$(find "$WINEPREFIX/drive_c/ProgramData/Microsoft/Windows/Start Menu" \
                      "$WINEPREFIX/drive_c/users" -iname "*ETS*${ETS_MAJOR}*.lnk" 2>/dev/null | head -n 1 || true)
  if [ -z "$existing_lnk" ]; then
    wrun --wl-app cxmklnk -- \
      --startmenu "Programs/${APP_NAME}.lnk" \
      --target "$ETS_EXE_WIN" \
      --workdir "C:\\Program Files (x86)\\ETS${ETS_MAJOR}" >/dev/null 2>&1 \
      || warn "cxmklnk failed; create the launcher manually via CrossOver > Run Command > Save Command as Launcher"
    wsrv -w
  fi

  # Sync CrossOver menus so ETS shows up in the bottle's program list and host menus
  "$CX_MENU_TOOL" --bottle "$BOTTLE_NAME" --sync --mode install >/dev/null 2>&1 \
    || warn "cxmenu --sync failed; use CrossOver > Bottle > Refresh/Rebuild Programs Menu"
  ok "$APP_NAME registered in CrossOver bottle '$BOTTLE_NAME'"
  LAUNCH_HINT="CrossOver -> bottle \"$BOTTLE_NAME\" -> $APP_NAME"
else
  info "Step 8/8: Creating $APP_NAME launcher..."
  launcher="$WINEPREFIX/launch-$APP_NAME.sh"
  {
    echo '#!/usr/bin/env bash'
    printf 'export WINEPREFIX=%q\n' "$WINEPREFIX"
    printf 'export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=%q\n' "$WEBVIEW2_ARGS"
    echo '# Log to a file when started from the desktop / Finder instead of a terminal'
    printf '[ -t 1 ] || exec >>%q 2>&1\n' "$WINEPREFIX/$APP_NAME.log"
    printf 'cd %q || exit 1\n' "$ets_dir"
    printf 'exec %q %q "$@"\n' "$WINE_BIN" "$ETS_EXE_WIN"
  } > "$launcher"
  chmod +x "$launcher"

  icon=$(pe_tool icon "$ets_dir/$ETS_EXE_NAME" "$WINEPREFIX/$APP_NAME-icon" 2>/dev/null || true)
  display_name="KNX $APP_NAME"
  [ "$BOTTLE_NAME" = "$APP_NAME" ] || display_name="KNX $APP_NAME ($BOTTLE_NAME)"

  if [ "$HOST_OS" = macos ]; then
    app="$HOME/Applications/$display_name.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    printf '#!/bin/sh\nexec %q "$@"\n' "$launcher" > "$app/Contents/MacOS/launcher"
    chmod +x "$app/Contents/MacOS/launcher"
    icon_key=""
    if [ -n "$icon" ] && sips -s format icns "$icon" --out "$app/Contents/Resources/icon.icns" >/dev/null 2>&1; then
      icon_key="<key>CFBundleIconFile</key><string>icon</string>"
    fi
    bundle_id="com.ets-on-crossover.wine.$(printf '%s' "$BOTTLE_NAME" | tr -c 'A-Za-z0-9.-' '-')"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$display_name</string>
  <key>CFBundleDisplayName</key><string>$display_name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  $icon_key
</dict>
</plist>
EOF
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "$app" >/dev/null 2>&1 || true
    ok "Created $app"
    LAUNCH_HINT="Launchpad / Spotlight / Finder: \"$display_name\" (~/Applications)"
  else
    apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$apps_dir"
    desktop_file="$apps_dir/ets-on-wine-$(printf '%s' "$BOTTLE_NAME" | tr -c 'A-Za-z0-9_-' '_').desktop"
    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=$display_name
Comment=KNX Engineering Tool Software (Wine)
Exec="$launcher"
Icon=${icon:-wine}
Terminal=false
Categories=Development;Engineering;
StartupWMClass=$(printf '%s' "$ETS_EXE_NAME" | tr 'A-Z' 'a-z')
EOF
    update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
    ok "Created $desktop_file"
    LAUNCH_HINT="Application menu: \"$display_name\" (or run $launcher)"
  fi
fi

# Quick verification of the .NET 4.8 CLR and ETS6 PBKDF2-HMAC-SHA256 project password derivation
csc32="$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"
if [ -f "$csc32" ]; then
  cat > "$WINEPREFIX/drive_c/clrtest.cs" <<'CS'
using System;
using System.Text;
using System.Security;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
class ClrTest {
    static void Main() {
        var s = new SecureString();
        foreach (char c in "1234") s.AppendChar(c);
        IntPtr b = Marshal.SecureStringToBSTR(s);
        string p = Marshal.PtrToStringBSTR(b);
        Marshal.ZeroFreeBSTR(b);
        var k = new Rfc2898DeriveBytes(Encoding.Unicode.GetBytes(p), Encoding.ASCII.GetBytes("21.project.ets.knx.org"), 65536, HashAlgorithmName.SHA256);
        string d = Convert.ToBase64String(k.GetBytes(32));
        if (d != "IzjWnFxCJArhBgkJix0BVpjKp5JRnxZoF3nW4XMfWbk=") Environment.Exit(1);
        Console.WriteLine("CLR_PBKDF2_OK");
    }
}
CS
  if wrun "$csc32" /nologo /noconfig /r:mscorlib.dll /out:C:\\clrtest.exe C:\\clrtest.cs >/dev/null 2>&1 \
     && wrun C:\\clrtest.exe 2>/dev/null | grep -q 'CLR_PBKDF2_OK'; then
    ok "Verified .NET 4.8 CLR, SecureString and ETS6 project password derivation"
  else
    warn ".NET self-test failed; ETS may not start or may reject project passwords"
  fi
  rm -f "$WINEPREFIX/drive_c/clrtest.cs" "$WINEPREFIX/drive_c/clrtest.exe"
fi

printf '\n\033[1;32m=============================================================================\033[0m\n'
if [ "$RUNTIME" = crossover ]; then
  printf '\033[1;32mSUCCESS: KNX %s is installed in CrossOver\033[0m\n' "$APP_NAME"
  printf '  • CrossOver bottle:  %s\n' "$BOTTLE_NAME"
else
  printf '\033[1;32mSUCCESS: KNX %s is installed in Wine\033[0m\n' "$APP_NAME"
  printf '  • Wine prefix:       %s\n' "$WINEPREFIX"
  printf '  • Terminal launch:   %s\n' "$launcher"
fi
printf '  • Launch:            %s\n' "$LAUNCH_HINT"
if [ "$CASE_STORE" = "1" ]; then
  printf '  • ProjectStore:      %s/KNX (Case-sensitive APFS, auto-mounted at login)\n' "$ETS_STORE_VOLUME"
fi
printf '\033[1;32m=============================================================================\033[0m\n'
