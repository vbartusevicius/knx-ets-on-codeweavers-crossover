# KNX ETS5 & ETS6 on macOS (CodeWeavers CrossOver)

Single-command installer for **KNX ETS 5.7.7** and **KNX ETS 6.3.1 / 6.4.1** on macOS (Apple Silicon & Intel) using **CodeWeavers CrossOver**.

No Wine source patching or compilation is required. You provide your `Ets6Setup.exe` or `Ets5Setup.exe` (or the `.zip` archive from MyKNX), and `install-ets-crossover.sh` prepares the bottle, installs all runtimes/fonts/fixes, installs ETS, and adds the ETS launcher directly to CrossOver's application list.

---

## Usage

```bash
./install-ets-crossover.sh ~/Downloads/Ets6Setup.exe
# or for ETS5:
./install-ets-crossover.sh ~/Downloads/Ets5Setup.exe
```

Options:

| Option | Description |
|---|---|
| `--bottle <Name>` | CrossOver bottle name (default: `ETS5` / `ETS6`) |
| `--ets-version <5\|6>` | Force ETS major version (default: detected from the installer) |
| `--crossover <App>` | Path to `CrossOver.app` (default: auto-detect, CrossOver Preview preferred) |
| `--dpi <N>` | Display DPI: `96`=100%, `120`=125%, `144`=150% (default: `96`) |
| `--interactive` | Run the ETS installer with its GUI instead of quiet mode |
| `--reinstall` | Run the ETS installer even if ETS is already installed |
| `--skip-msi-fix` | Don't apply the app-local `msi.dll` KNX-Secure fix |
| `--case-store` | Keep project data on a Case-sensitive APFS disk image (only if saved projects fail to reopen with checksum errors) |

Example:
```bash
./install-ets-crossover.sh ~/Downloads/Ets6Setup.exe --bottle "KNX-ETS6" --dpi 144 --interactive
```

---

## What `install-ets-crossover.sh` Does

| Step | Problem Fixed | How It Works |
|---|---|---|
| **1. Host Prerequisites** | Missing archive/MSI/font extraction tools on macOS | Installs `sevenzip` (`7zz`), `msitools` (`msiextract`, `msiinfo`), and Python `fonttools` if not present. |
| **2. Case-Sensitive APFS `ProjectStore` (opt-in, `--case-store`)** | One user reported saved projects failing to reopen with checksum errors under Wine on macOS (cause unconfirmed; APFS case-insensitivity is suspected) | Creates a Case-sensitive APFS sparsebundle (`~/Library/Application Support/ETSStore.sparsebundle` at `/Volumes/ETSStore/KNX`), symlinks `drive_c/ProgramData/KNX` to it, and adds a LaunchAgent that remounts it at login. Off by default. |
| **3. Native CrossOver Bottle** | Bottle metadata and environment variables must integrate with CrossOver GUI | Creates the bottle (`ETS6` or `ETS5`) via CrossOver's native `cxbottle` tool and configures `cxbottle.conf`. |
| **4. `.NET Framework 4.8` & `VC++ 2022`** | Microsoft's `.NET 4.8` installer exits `0` without installing anything if the bottle reports Windows 10 | Switches the bottle to **Windows 7**, installs `.NET 4.8` (`NDP48-x86-x64-AllOS-ENU.exe`), verifies `Release >= 528049`, switches back to **Windows 10**, and installs `VC++ 2015–2022` (x86 & x64). |
| **5. Native `mscoree.dll` & `.NET 4.0` COM** | Wine's builtin `mscoree.dll` points to Wine Mono, and `.NET 4.8` omits `.NET 4.0` COM keys (`REGDB_E_KEYMISSING` / `REGDB_E_CLASSNOTREG`) | Extracts Microsoft's 32/64-bit `mscoree.dll` from `.NET 4.0` and imports all missing `.NET 4.0` COM class registrations into the bottle registry. |
| **6. Fonts, WPF Software Rendering, & `msi.dll`** | Main window/menus render solid black (`Avalon.Graphics`), missing `Segoe UI` / `Segoe MDL2 Assets` crashes WPF (`Environment.FailFast`), and `msi!Installer.OpenDatabase` crashes when setting KNX-Secure passwords ([WineHQ Bug 60062](https://bugs.winehq.org/show_bug.cgi?id=60062)) | Copies macOS Supplemental Windows fonts, generates `segmdl2.ttf`, sets `DisableHWAcceleration=1`, configures WebView2 (`--no-sandbox --disable-gpu`), and binary-patches the bottle's local `msi.dll` copy (`VT_BSTR` -> `VT_I4`). |
| **7. ETS Setup & `EIBAsc` Compatibility Layer** | Importing password-protected projects with device plugins fails at the end with `"Value cannot be null"` ([WineHQ Bug 60377](https://bugs.winehq.org/show_bug.cgi?id=60377)) or `0x80070716` | Runs `Ets6Setup.exe` / `Ets5Setup.exe`, adds `<runtime>` switches to `ETS6N.exe.config`, extracts `EIBA.*.dll` to `Common Files\EIBA sc`, writes `EtecRedirect.dll.manifest`, and patches `EtecDOM.dll`'s ATL object map initializer. |
| **8. CrossOver App List Registration** | ETS must appear as a clickable app in CrossOver GUI and Finder | Uses CrossOver's `cxmklnk`, `cxmenu --sync --mode install`, and `cxbottle --install` to register `ETS6` / `ETS5` in the CrossOver bottle's application list and `~/Applications/CrossOver/`. |

> **Note on KNX USB Dongles (`2a07:0102`):** Standard CrossOver 26.x ships Wine 11.0 (which works for ETS6 Cloud Licenses). For physical KNX USB License Dongles, use **CrossOver Preview** (which includes Wine 11.15+ with the `CM_Get_Parent` USB HID parent-device fix from [WineHQ Bug 59604](https://bugs.winehq.org/show_bug.cgi?id=59604)).
