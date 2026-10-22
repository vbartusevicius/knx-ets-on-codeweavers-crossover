#!/usr/bin/env bash
# =============================================================================
# install-ets-crossover.sh
#
# Automated installer for KNX ETS5 and ETS6 on macOS via CodeWeavers CrossOver.
#
# What it does:
#   1. Creates a dedicated CrossOver bottle (ETS5 or ETS6) via cxbottle.
#   2. Optional (--case-store): puts ProgramData/KNX on a Case-sensitive APFS
#      sparsebundle (remounted at login) in case projects fail to reopen with
#      checksum errors on macOS.
#   3. Installs .NET 4.8 (in Win7 mode before switching to Win10), VC++ 2022,
#      native Microsoft mscoree.dll, and missing .NET 4.0 COM registrations.
#   4. Configures Windows fonts, generates segmdl2.ttf, forces WPF software
#      rendering (fixes black windows/menus), and sets WebView2 options.
#   5. Installs ETS5/ETS6, applies ETS6N.exe.config runtime switches, extracts
#      the EIBAsc plugin compatibility layer, applies an app-local msi.dll fix
#      for KNX-Secure project passwords, and registers the app launcher in
#      CrossOver's GUI.
#
# Usage:
#   ./install-ets-crossover.sh <Ets5Setup.exe|Ets6Setup.exe|zip> [options]
#   Run with --help for the list of options.
# =============================================================================
set -euo pipefail

# Ensure Homebrew paths (Apple Silicon, Workbrew, Intel) are on PATH
for brew_dir in /opt/homebrew/bin /opt/workbrew/bin /usr/local/bin; do
  if [ -d "$brew_dir" ]; then
    case ":$PATH:" in
      *":$brew_dir:"*) ;;
      *) export PATH="$brew_dir:$PATH" ;;
    esac
  fi
done

die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  ./install-ets-crossover.sh <Ets5Setup.exe|Ets6Setup.exe|zip> [options]

Options:
  --bottle <Name>        CrossOver bottle name (default: ETS5 / ETS6)
  --ets-version <5|6>    Force ETS major version (default: detected from installer)
  --crossover <App>      Path to CrossOver.app (default: auto-detect, Preview preferred)
  --dpi <N>              Display DPI: 96=100%, 120=125%, 144=150% (default: 96)
  --interactive          Run the ETS installer with its GUI instead of /quiet
  --reinstall            Run the ETS installer even if ETS is already installed
  --skip-msi-fix         Do not apply the app-local msi.dll KNX-Secure fix
  --case-store           Keep ProgramData/KNX on a Case-sensitive APFS disk image
                         (only if projects fail to reopen with checksum errors)
  -h, --help             Show this help

Examples:
  ./install-ets-crossover.sh ~/Downloads/Ets6Setup.exe
  ./install-ets-crossover.sh ~/Downloads/Ets5Setup.exe --dpi 144
  ./install-ets-crossover.sh ~/Downloads/ETS6.zip --bottle "KNX-ETS6" --interactive
EOF
  exit 1
}

# -----------------------------------------------------------------------------
# 0. Parse arguments & validate ETS installer binary
# -----------------------------------------------------------------------------
INPUT_PATH=""
BOTTLE_NAME=""
ETS_MAJOR=""
CROSSOVER_APP=""
ETS_DPI=96
INTERACTIVE=0
REINSTALL=0
SKIP_MSI_FIX=0
CASE_STORE=0

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --bottle)       need_value "$@"; BOTTLE_NAME="$2";   shift 2 ;;
    --ets-version)  need_value "$@"; ETS_MAJOR="$2";     shift 2 ;;
    --crossover)    need_value "$@"; CROSSOVER_APP="$2"; shift 2 ;;
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
[ -z "$CROSSOVER_APP" ] || [ -d "$CROSSOVER_APP/Contents/SharedSupport/CrossOver" ] \
  || die "--crossover: not a CrossOver app bundle: $CROSSOVER_APP"

ETS_CACHE="$HOME/Library/Caches/ets-on-crossover"
mkdir -p "$ETS_CACHE"

# If the user passed a .zip archive downloaded from MyKNX, extract the .exe from it
SETUP_EXE="$INPUT_PATH"
case "$(basename "$INPUT_PATH")" in
  *.[Zz][Ii][Pp])
    info "Extracting installer archive: $(basename "$INPUT_PATH")"
    unzip_dir="$ETS_CACHE/unzipped-installer"
    rm -rf "$unzip_dir"
    mkdir -p "$unzip_dir"
    unzip -q "$INPUT_PATH" -d "$unzip_dir"
    SETUP_EXE=$(find "$unzip_dir" -type f \( -iname '*Ets*Setup*.exe' -o -iname 'ETS*.exe' \) | head -n 1)
    [ -n "$SETUP_EXE" ] && [ -f "$SETUP_EXE" ] || die "Could not find Ets5Setup.exe / Ets6Setup.exe inside $INPUT_PATH"
    ok "Found installer inside archive: $(basename "$SETUP_EXE")"
    ;;
esac

# Detect ETS5 vs ETS6 from filename or binary strings (unless --ets-version was given)
if [ -z "$ETS_MAJOR" ]; then
  case "$(basename "$SETUP_EXE")" in
    *[Ee][Tt][Ss]5*) ETS_MAJOR=5 ;;
    *[Ee][Tt][Ss]6*) ETS_MAJOR=6 ;;
    *)
      if strings "$SETUP_EXE" 2>/dev/null | grep -qi 'ETS6'; then
        ETS_MAJOR=6
      elif strings "$SETUP_EXE" 2>/dev/null | grep -qi 'ETS5'; then
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
CX_BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles"
WINEPREFIX="$CX_BOTTLE_DIR/$BOTTLE_NAME"
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

# -----------------------------------------------------------------------------
# 1. Locate CodeWeavers CrossOver.app / CrossOver Preview.app
# -----------------------------------------------------------------------------
find_crossover_app() {
  local cand
  for cand in \
    "$CROSSOVER_APP" \
    "/Applications/CrossOver Preview.app" \
    "$HOME/Applications/CrossOver Preview.app" \
    "/Applications/CrossOver.app" \
    "$HOME/Applications/CrossOver.app"; do
    if [ -n "$cand" ] && [ -d "$cand/Contents/SharedSupport/CrossOver" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  # Fallback via Spotlight if installed in a custom folder
  local mdf
  mdf=$(mdfind "kMDItemCFBundleIdentifier == 'com.codeweavers.CrossOver*'" 2>/dev/null | head -n 1 || true)
  if [ -n "$mdf" ] && [ -d "$mdf/Contents/SharedSupport/CrossOver" ]; then
    printf '%s\n' "$mdf"
    return 0
  fi
  return 1
}

CROSSOVER_APP=$(find_crossover_app || true)
[ -n "$CROSSOVER_APP" ] || die "CodeWeavers CrossOver.app (or CrossOver Preview.app) was not found. Please install CrossOver first."

CX_ROOT="$CROSSOVER_APP/Contents/SharedSupport/CrossOver"
CX_BIN="$CX_ROOT/bin"
CX_WINE="$CX_BIN/wine"
CX_WINESERVER="$CX_BIN/wineserver"
CX_BOTTLE_TOOL="$CX_BIN/cxbottle"
CX_MENU_TOOL="$CX_BIN/cxmenu"

[ -x "$CX_WINE" ] || die "CrossOver wine binary not found at $CX_WINE"
[ -x "$CX_BOTTLE_TOOL" ] || die "CrossOver cxbottle tool not found at $CX_BOTTLE_TOOL"
[ -x "$CX_MENU_TOOL" ] || die "CrossOver cxmenu tool not found at $CX_MENU_TOOL"

export WINEPREFIX
export CX_BOTTLE="$BOTTLE_NAME"
export CX_BOTTLE_PATH="$CX_BOTTLE_DIR"

cx_wine() {
  "$CX_WINE" --bottle "$BOTTLE_NAME" "$@"
}

cx_wineserver() {
  "$CX_WINESERVER" "$@" 2>/dev/null || true
}

strip_cr() { tr -d '\r'; }

# True if the file is a Wine builtin or placeholder DLL (not a real Microsoft DLL)
is_wine_dll() {
  [ -f "$1" ] || return 0
  head -c 512 "$1" | LC_ALL=C grep -aqE 'Wine (builtin|placeholder) DLL'
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
  shasum -a 256 "$1" | awk '{print $1}'
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
info "CrossOver:   $CROSSOVER_APP"
info "Bottle:      $BOTTLE_NAME ($WINEPREFIX)"
case "$CROSSOVER_APP" in
  *Preview*) ;;
  *) warn "Stable CrossOver may lack the Wine 11.10 USB fix (CM_Get_Parent); KNX USB license dongles may not be detected. Cloud licenses work. Use CrossOver Preview for dongles." ;;
esac

# -----------------------------------------------------------------------------
# 2. Ensure macOS Host Extraction & Font Prerequisites
# -----------------------------------------------------------------------------
info "Step 1/8: Checking macOS host prerequisites..."
if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  info "Installing Rosetta 2 (required for CrossOver on Apple Silicon)..."
  softwareupdate --install-rosetta --agree-to-license || true
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required (install Xcode Command Line Tools: xcode-select --install)"

# Homebrew's "sevenzip" installs the binary as 7zz; p7zip and others provide 7z
find_7z() { command -v 7zz 2>/dev/null || command -v 7z 2>/dev/null || true; }

missing_brew=()
[ -n "$(find_7z)" ]                   || missing_brew+=(sevenzip)
command -v msiextract >/dev/null 2>&1 || missing_brew+=(msitools)
command -v msiinfo >/dev/null 2>&1    || missing_brew+=(msitools)

if [ "${#missing_brew[@]}" -gt 0 ]; then
  command -v brew >/dev/null 2>&1 || die "Homebrew is required to install: ${missing_brew[*]}"
  info "Installing Homebrew tools: ${missing_brew[*]}"
  brew install $(printf '%s\n' "${missing_brew[@]}" | sort -u)
fi
SEVENZIP=$(find_7z)
[ -n "$SEVENZIP" ] || die "7-Zip (7zz or 7z) not found after installing sevenzip"

if ! python3 -c "import fontTools" >/dev/null 2>&1; then
  info "Installing Python package fonttools..."
  python3 -m pip install --user --quiet fonttools 2>/dev/null \
    || python3 -m pip install --break-system-packages --user --quiet fonttools
fi
ok "Host prerequisites ready"

# -----------------------------------------------------------------------------
# 3. Optional: Case-Sensitive APFS Sparsebundle for KNX ProjectStore
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
  info "Step 2/8: Case-sensitive ProjectStore volume not requested (use --case-store to enable)"
fi

# -----------------------------------------------------------------------------
# 4. Create Native CrossOver Bottle
# -----------------------------------------------------------------------------
info "Step 3/8: Creating / preparing CrossOver bottle '$BOTTLE_NAME'..."
mkdir -p "$CX_BOTTLE_DIR"
if [ ! -f "$WINEPREFIX/system.reg" ]; then
  "$CX_BOTTLE_TOOL" --bottle "$BOTTLE_NAME" --create --template win10_64 --install \
    --param "EnvironmentVariables:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox --disable-gpu" \
    || die "cxbottle failed to create bottle '$BOTTLE_NAME'"
  cx_wineserver -k
  sleep 1
fi
[ -f "$WINEPREFIX/system.reg" ] || die "Bottle '$BOTTLE_NAME' was not created at $WINEPREFIX"

# Make sure WebView2 args are present for bottles created earlier
if [ -f "$WINEPREFIX/cxbottle.conf" ] && ! grep -q WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS "$WINEPREFIX/cxbottle.conf"; then
  python3 - "$WINEPREFIX/cxbottle.conf" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()
line = '"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS" = "--no-sandbox --disable-gpu"'
if "[EnvironmentVariables]" in text:
    text = text.replace("[EnvironmentVariables]", "[EnvironmentVariables]\n" + line, 1)
else:
    text += "\n[EnvironmentVariables]\n" + line + "\n"
open(path, "w", encoding="utf-8").write(text)
PY
fi

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
ok "CrossOver bottle '$BOTTLE_NAME' ready"

# -----------------------------------------------------------------------------
# 5. Install .NET Framework 4.8 + Visual C++ 2015-2022 Runtime
# -----------------------------------------------------------------------------
info "Step 4/8: Installing Microsoft .NET Framework 4.8 & Visual C++ 2022 Runtime..."

set_windows_version() {
  run_timeout 60 "$CX_WINE" --bottle "$BOTTLE_NAME" winecfg -v "$1" >/dev/null 2>&1 || true
  cx_wineserver -k
  sleep 1
}

windows_product_name() {
  cx_wine reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v ProductName 2>/dev/null \
    | strip_cr | awk -F'REG_SZ' '/ProductName/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}'
}

dotnet_release() {
  local raw
  raw=$(cx_wine reg query "$1" /v Release 2>/dev/null | strip_cr | awk '/Release/ {print $NF}' || true)
  if [ -n "$raw" ]; then printf '%s\n' "$((raw))"; else printf '0\n'; fi
}

# Remove Wine Mono if CrossOver installed it into the bottle (it intercepts .NET)
cx_wine uninstaller --list 2>/dev/null | strip_cr | grep -i 'Wine Mono' | grep -oE '\{[0-9A-Fa-f-]{36}\}' | while read -r guid; do
  info "Removing Wine Mono ($guid)..."
  cx_wine uninstaller --remove "$guid" >/dev/null 2>&1 || true
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
      cx_wine reg delete "$node" /f >/dev/null 2>&1 || true
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
  cx_wine "$ETS_CACHE/NDP48-x86-x64-AllOS-ENU.exe" /q /norestart || true
  cx_wineserver -w
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
  cx_wine "$ETS_CACHE/vc_redist.x86.exe" /install /quiet /norestart || true
  cx_wineserver -w
  cx_wine "$ETS_CACHE/vc_redist.x64.exe" /install /quiet /norestart || true
  cx_wineserver -w
fi

for dll in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait \
           msvcp140_codecvt_ids vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1; do
  cx_wine reg add 'HKCU\Software\Wine\DllOverrides' /v "*$dll" /t REG_SZ /d 'native,builtin' /f >/dev/null
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
  case "$(file -b "$dll")" in
    PE32+*) cp -f "$dll" "$sys32/mscoree.dll" ;;
    PE32*)  cp -f "$dll" "$syswow/mscoree.dll" ;;
  esac
done < <(find "$files" -iname 'mscoree.dll' -type f)
is_wine_dll "$sys32/mscoree.dll" && die "Failed to install native 64-bit mscoree.dll"
is_wine_dll "$syswow/mscoree.dll" && die "Failed to install native 32-bit mscoree.dll"

cx_wine reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree  /t REG_SZ /d 'native,builtin' /f >/dev/null
cx_wine reg add 'HKCU\Software\Wine\DllOverrides' /v '*mscoree' /t REG_SZ /d 'native,builtin' /f >/dev/null
cx_wine reg add 'HKLM\SOFTWARE\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ \
  /d 'C:\windows\Microsoft.NET\Framework64\' /f >/dev/null
cx_wine reg add 'HKLM\SOFTWARE\Wow6432Node\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ \
  /d 'C:\windows\Microsoft.NET\Framework\' /f >/dev/null
# Wine registers a fake .NET 2.0 runtime (policy v2.0 + stub mscorwks.dll). The native shim then
# picks "v2.0" for legacy hosts (MSI custom actions) and crashes in mscorwks.DllGetClassObjectInternal.
# Force all legacy activation onto the real .NET 4 runtime.
for node in 'HKLM\SOFTWARE\Microsoft\.NETFramework' 'HKLM\SOFTWARE\Wow6432Node\Microsoft\.NETFramework'; do
  cx_wine reg add "$node" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f >/dev/null
  cx_wine reg delete "$node\\Policy\\v2.0" /f >/dev/null 2>&1 || true
done

cx_wineserver -k
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

cx_wine regedit /s "$regfile"
cx_wineserver -k
sleep 1
ok "Native Microsoft mscoree.dll and .NET 4.0 COM registrations imported"

# -----------------------------------------------------------------------------
# 7. Fonts, WPF Software Rendering & WebView2
# -----------------------------------------------------------------------------
info "Step 6/8: Configuring fonts, WPF software rendering & WebView2..."
fontsdir="$WINEPREFIX/drive_c/windows/Fonts"
mkdir -p "$fontsdir"

mac_supp="/System/Library/Fonts/Supplemental"
for ttf in \
  "Arial.ttf" "Arial Bold.ttf" "Arial Italic.ttf" "Arial Bold Italic.ttf" \
  "Tahoma.ttf" "Tahoma Bold.ttf" \
  "Verdana.ttf" "Verdana Bold.ttf" \
  "Courier New.ttf" "Courier New Bold.ttf" \
  "Microsoft Sans Serif.ttf" "Trebuchet MS.ttf" "Times New Roman.ttf"; do
  if [ -f "$mac_supp/$ttf" ]; then cp -f "$mac_supp/$ttf" "$fontsdir/$ttf"; fi
done

if [ ! -f "$fontsdir/segoeui.ttf" ]; then
  [ -f "$mac_supp/Arial.ttf" ] || die "Arial.ttf not found in $mac_supp (needed as Segoe UI substitute)"
  cp -f "$mac_supp/Arial.ttf" "$fontsdir/segoeui.ttf"
fi

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

cx_wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' /v 'Segoe UI (TrueType)' /t REG_SZ /d 'segoeui.ttf' /f >/dev/null
cx_wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' /v 'Segoe MDL2 Assets (TrueType)' /t REG_SZ /d 'segmdl2.ttf' /f >/dev/null

for pair in "Segoe UI:Arial" "Segoe UI Symbol:Arial" "Segoe UI Emoji:Arial" "Segoe UI Historic:Arial" "Consolas:Courier New"; do
  cx_wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v "${pair%%:*}" /t REG_SZ /d "${pair#*:}" /f >/dev/null
done

for face in "Microsoft Sans Serif" "Segoe UI" "Arial" "Tahoma"; do
  cx_wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink' /v "$face" /t REG_MULTI_SZ /d 'Arial.ttf,Arial' /f >/dev/null
done

desktop='HKCU\Control Panel\Desktop'
cx_wine reg add "$desktop" /v FontSmoothing /d 2 /f >/dev/null
cx_wine reg add "$desktop" /v FontSmoothingType /t REG_DWORD /d 2 /f >/dev/null
cx_wine reg add "$desktop" /v FontSmoothingGamma /t REG_DWORD /d 1400 /f >/dev/null
cx_wine reg add "$desktop" /v FontSmoothingOrientation /t REG_DWORD /d 1 /f >/dev/null
cx_wine reg add "$desktop" /v LogPixels /t REG_DWORD /d "$ETS_DPI" /f >/dev/null

rm -rf "$WINEPREFIX"/drive_c/users/*/AppData/Local/Microsoft/FontCache \
       "$WINEPREFIX"/drive_c/users/*/AppData/Local/FontCache 2>/dev/null || true

# Force WPF onto the CPU software rasterizer (fixes black main window & black menus)
cx_wine reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >/dev/null

# WebView2 registry stubs checked by ETS6 at startup
guid='{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
ver='109.0.1518.140'
cx_wine reg add "HKCU\\Software\\Microsoft\\EdgeUpdate\\ClientState\\$guid" /v pv /t REG_SZ /d "$ver" /f >/dev/null
cx_wine reg add "HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\$guid"     /v pv /t REG_SZ /d "$ver" /f >/dev/null
cx_wine reg add 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' /v Version /t REG_SZ /d 'win7' /f >/dev/null

cx_wineserver -k
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
    cx_wine msiexec /i "$win_msi" /qn /norestart ALLUSERS=1 $props /l*v "C:\\ets-msi-$pid.log" || \
      warn "msiexec returned non-zero for $pid (log: $WINEPREFIX/drive_c/ets-msi-$pid.log)"
    cx_wineserver -w
  done <<< "$plan"
}

if ets_installed && [ "$REINSTALL" != "1" ]; then
  ok "$APP_NAME already installed (use --reinstall to run the installer again)"
else
  if [ "$INTERACTIVE" = "1" ]; then
    cx_wine "$SETUP_EXE" /log "c:\\ets$ETS_MAJOR-install.log" || true
  else
    cx_wine "$SETUP_EXE" /quiet /norestart /log "c:\\ets$ETS_MAJOR-install.log" || true
  fi
  cx_wineserver -w

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
# CrossOver's own msi.dll is copied, patched, and placed next to the ETS exe
# only; a DLL override is set for the ETS exe only. Installers keep using the
# untouched builtin msi.dll. Skipped unless the patch site is found exactly once.
if [ "$SKIP_MSI_FIX" != "1" ]; then
  if [ "$ETS_MAJOR" = "6" ] && [ "$ETS_EXE_NAME" = "ETS6N.exe" ]; then msi_arch="x86_64"; else msi_arch="i386"; fi
  msi_src=$(find "$CX_ROOT" -path "*${msi_arch}-windows/msi.dll" -type f 2>/dev/null | head -n 1 || true)
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
    cx_wine reg add "HKCU\\Software\\Wine\\AppDefaults\\$ETS_EXE_NAME\\DllOverrides" /v msi /t REG_SZ /d 'native,builtin' /f >/dev/null
    ok "Applied app-local msi.dll fix for KNX-Secure project passwords"
  else
    rm -f "$ets_dir/msi.dll"
    warn "Could not safely locate the msi.dll patch site in this CrossOver build; skipped. Setting a password on KNX-Secure projects may crash ETS (Wine bug 60062)."
  fi
fi
ok "KNX $APP_NAME installed at $ets_dir"

# -----------------------------------------------------------------------------
# 9. Register ETS in CrossOver Application List
# -----------------------------------------------------------------------------
info "Step 8/8: Registering $APP_NAME in the CrossOver application list..."

# Only create our own Start Menu shortcut if the ETS installer did not create one
existing_lnk=$(find "$WINEPREFIX/drive_c/ProgramData/Microsoft/Windows/Start Menu" \
                    "$WINEPREFIX/drive_c/users" -iname "*ETS*${ETS_MAJOR}*.lnk" 2>/dev/null | head -n 1 || true)
if [ -z "$existing_lnk" ]; then
  cx_wine --wl-app cxmklnk -- \
    --startmenu "Programs/${APP_NAME}.lnk" \
    --target "C:\\Program Files (x86)\\ETS${ETS_MAJOR}\\${ETS_EXE_NAME}" \
    --workdir "C:\\Program Files (x86)\\ETS${ETS_MAJOR}" >/dev/null 2>&1 \
    || warn "cxmklnk failed; create the launcher manually via CrossOver > Run Command > Save Command as Launcher"
  cx_wineserver -w
fi

# Sync CrossOver menus so ETS shows up in the bottle's program list and ~/Applications/CrossOver
"$CX_MENU_TOOL" --bottle "$BOTTLE_NAME" --sync --mode install >/dev/null 2>&1 \
  || warn "cxmenu --sync failed; use CrossOver > Bottle > Refresh/Rebuild Programs Menu"
ok "$APP_NAME registered in CrossOver bottle '$BOTTLE_NAME'"

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
  if cx_wine "$csc32" /nologo /noconfig /r:mscorlib.dll /out:C:\\clrtest.exe C:\\clrtest.cs >/dev/null 2>&1 \
     && cx_wine C:\\clrtest.exe 2>/dev/null | grep -q 'CLR_PBKDF2_OK'; then
    ok "Verified .NET 4.8 CLR, SecureString and ETS6 project password derivation"
  else
    warn ".NET self-test failed; ETS may not start or may reject project passwords"
  fi
  rm -f "$WINEPREFIX/drive_c/clrtest.cs" "$WINEPREFIX/drive_c/clrtest.exe"
fi

printf '\n\033[1;32m=============================================================================\033[0m\n'
printf '\033[1;32mSUCCESS: KNX %s is installed in CrossOver\033[0m\n' "$APP_NAME"
printf '  • CrossOver bottle:  %s\n' "$BOTTLE_NAME"
printf '  • Launch:            CrossOver -> bottle "%s" -> %s\n' "$BOTTLE_NAME" "$APP_NAME"
if [ "$CASE_STORE" = "1" ]; then
  printf '  • ProjectStore:      %s/KNX (Case-sensitive APFS, auto-mounted at login)\n' "$ETS_STORE_VOLUME"
fi
printf '\033[1;32m=============================================================================\033[0m\n'
