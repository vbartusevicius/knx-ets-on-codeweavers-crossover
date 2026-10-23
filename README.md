# KNX ETS5 & ETS6 on macOS and Linux (CrossOver or Wine)

Single-command installer for **KNX ETS5** and **KNX ETS6** on **macOS** (Apple Silicon & Intel) and **Linux** (x86_64), using either **CodeWeavers CrossOver** or **vanilla Wine (>= 11.0)**.

No Wine source patching or compilation is required. You provide your `Ets6Setup.exe` or `Ets5Setup.exe` (or the `.zip` archive from MyKNX), and `install-ets.sh` prepares the bottle/prefix, installs all runtimes/fonts/fixes, installs ETS, and registers an ETS launcher.

| | CrossOver | Wine |
|---|---|---|
| **macOS** | Bottle in `~/Library/Application Support/CrossOver/Bottles`, ETS in CrossOver's app list | Prefix in `~/.local/share/wineprefixes/<name>`, app bundle in `~/Applications` |
| **Linux** | Bottle in `~/.cxoffice`, ETS in CrossOver's app list and desktop menu | Prefix in `~/.local/share/wineprefixes/<name>`, `.desktop` entry in the application menu |

---

## Usage

```bash
./install-ets.sh ~/Downloads/Ets6Setup.exe                 # CrossOver if installed, otherwise Wine
./install-ets.sh ~/Downloads/Ets5Setup.exe --runtime wine   # force vanilla Wine
```

Options:

| Option | Description |
|---|---|
| `--runtime <crossover\|wine>` | Engine to use (default: CrossOver if installed, otherwise Wine) |
| `--crossover <Path>` | CrossOver install: `CrossOver.app` (macOS) or `/opt/cxoffice` (Linux) (default: auto-detect, CrossOver Preview preferred on macOS) |
| `--wine <Path>` | `wine` binary (default: `wine` on `PATH`, then `/Applications/Wine *.app`, `/opt/wine-*`) |
| `--prefix <Dir>` | Wine prefix directory (default: `~/.local/share/wineprefixes/<name>`) |
| `--bottle <Name>` | Bottle / prefix name (default: `ETS5` / `ETS6`) |
| `--ets-version <5\|6>` | Force ETS major version (default: detected from the installer) |
| `--dpi <N>` | Display DPI: `96`=100%, `120`=125%, `144`=150% (default: `96`) |
| `--interactive` | Run the ETS installer with its GUI instead of quiet mode |
| `--reinstall` | Run the ETS installer even if ETS is already installed |
| `--skip-msi-fix` | Don't apply the app-local `msi.dll` KNX-Secure fix |
| `--case-store` | macOS only: keep project data on a Case-sensitive APFS disk image (only if saved projects fail to reopen with checksum errors) |

Example:
```bash
./install-ets.sh ~/Downloads/Ets6Setup.exe --bottle "KNX-ETS6" --dpi 144 --interactive
```

---

## Requirements

**CrossOver:** CrossOver 26 or newer (macOS or Linux). Use **CrossOver Preview** for KNX USB license dongles (see below).

**Wine:** Wine **11.0 or newer** (11.10+ recommended for USB dongles). The script uses an existing Wine; it does not install one.
- macOS: [Gcenx Wine Devel builds](https://github.com/Gcenx/macOS_Wine_builds/releases). Move `Wine Devel.app` to `/Applications` and remove the quarantine flag: `xattr -dr com.apple.quarantine "/Applications/Wine Devel.app"`. (The Homebrew `wine@devel` cask is disabled.)
- Linux: [WineHQ](https://gitlab.winehq.org/wine/wine/-/wikis/Download) `wine-devel` or `wine-staging` packages. Distribution Wine packages are often too old.

**Host tools:**
- macOS: missing `7zz`, `msitools` and Python `fonttools` are installed automatically via Homebrew / pip.
- Linux: install them yourself, e.g. `sudo apt install 7zip msitools curl python3-fonttools fontconfig` (use `p7zip-full` on older Debian/Ubuntu; `dnf`, `pacman` and `zypper` package names are printed by the script).

**Fonts (Linux):** Microsoft core fonts (`ttf-mscorefonts-installer`, `msttcore-fonts`) are used if installed; otherwise fontconfig substitutes such as Liberation Sans/Mono are copied and mapped to Arial / Segoe UI / Consolas.

---

## What `install-ets.sh` Does

| Step | Problem Fixed | How It Works |
|---|---|---|
| **1. Host Prerequisites** | Missing archive/MSI/font tools | Checks for `7zz`/`7z`, `msitools` (`msiextract`, `msiinfo`), `curl` and Python `fonttools`; installs them on macOS, prints the package command on Linux. Installs Rosetta 2 on Apple Silicon. |
| **2. Case-Sensitive APFS `ProjectStore` (opt-in, `--case-store`, macOS)** | One user reported saved projects failing to reopen with checksum errors under Wine on macOS (cause unconfirmed; APFS case-insensitivity is suspected) | Creates a Case-sensitive APFS sparsebundle (`~/Library/Application Support/ETSStore.sparsebundle` at `/Volumes/ETSStore/KNX`), symlinks `drive_c/ProgramData/KNX` to it, and adds a LaunchAgent that remounts it at login. Off by default. |
| **3. Bottle / Prefix** | CrossOver GUI integration; Wine Mono/Gecko intercepting .NET | CrossOver: creates the bottle with `cxbottle` (`win10_64`). Wine: creates a 64-bit prefix with Wine Mono, Gecko and `winemenubuilder` disabled. Both: sets `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox --disable-gpu`. |
| **4. `.NET Framework 4.8` & `VC++ 2022`** | The `.NET 4.8` installer exits `0` without installing on Windows 10; CrossOver/Wine Mono pre-register a fake `.NET 4.8.1` | Checks the real runtime files (`clr.dll`, `mscoreei.dll`, `mscorlib.dll`), removes fake registrations, switches to **Windows 7**, installs `.NET 4.8`, verifies it, switches back to **Windows 10**, and installs `VC++ 2015–2022` (x86 & x64). |
| **5. Native `mscoree.dll` & `.NET 4.0` COM** | Wine's builtin `mscoree.dll` points to Wine Mono; `.NET 4.8` omits `.NET 4.0` COM keys (`REGDB_E_KEYMISSING` / `REGDB_E_CLASSNOTREG`); Wine's fake .NET 2.0 crashes MSI custom actions | Installs Microsoft's 32/64-bit `mscoree.dll` from `.NET 4.0`, imports the missing COM registrations, and sets `OnlyUseLatestCLR=1`. |
| **6. Fonts & WPF Software Rendering** | Black main window/menus (`Avalon.Graphics`); missing `Segoe UI` / `Segoe MDL2 Assets` crashes WPF (`Environment.FailFast`) | Copies host Windows-compatible fonts, generates `segmdl2.ttf`, registers font replacements, sets `DisableHWAcceleration=1`, DPI and WebView2 stubs. |
| **7. ETS Setup & Compatibility Fixes** | Burn's .NET setup UI may fail under Wine; `"Value cannot be null"` / `0x80070716` on project import ([WineHQ Bug 60377](https://bugs.winehq.org/show_bug.cgi?id=60377)); crash when setting KNX-Secure passwords ([WineHQ Bug 60062](https://bugs.winehq.org/show_bug.cgi?id=60062)) | Runs `Ets6Setup.exe` / `Ets5Setup.exe` (falls back to installing the embedded MSIs with `msiexec`), adds `<runtime>` switches to `ETS6N.exe.config`, extracts `EIBA.*.dll`, writes `EtecRedirect.dll.manifest`, patches `EtecDOM.dll` (ETS 5.7.1428 only), and places a patched `msi.dll` next to the ETS exe when the patch site is found unambiguously. |
| **8. Launcher** | ETS must be startable like a normal app | CrossOver: `cxmklnk` + `cxmenu --sync` (CrossOver app list). Wine: `launch-ETS6.sh` in the prefix, plus `~/Applications/KNX ETS6.app` (macOS) or `~/.local/share/applications/ets-on-wine-ETS6.desktop` (Linux), with the icon extracted from the ETS exe. |

> **Note on KNX USB Dongles (`2a07:0102`):** Wine < 11.10 (including standard CrossOver 26.x, based on Wine 11.0) lacks the `CM_Get_Parent` USB HID parent-device fix ([WineHQ Bug 59604](https://bugs.winehq.org/show_bug.cgi?id=59604)), so physical license dongles may not be detected. Cloud licenses work. Use **CrossOver Preview** or Wine **11.10+** for dongles. On Linux the HID device must also be accessible to your user (udev rule for `2a07:0102`).
