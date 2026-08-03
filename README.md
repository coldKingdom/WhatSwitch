# What Switch? for PowerShell 7.6

**What Switch?** is the native PowerShell 7.6 port of SwitchHunt's static installer analysis. It
reads a local Windows installer, identifies its engine, and returns silent install, repair,
uninstall, and extraction commands without executing or uploading the file.

The original Astro/TypeScript web application remains in `src/` as the upstream implementation
and behavior reference. The PowerShell entry points are:

- `WhatSwitch.psd1` / `WhatSwitch.psm1` - reusable script module
- `Start-WhatSwitchGui.cmd` / `Start-WhatSwitchGui.ps1` - Windows GUI with file drag-and-drop
- `Invoke-WhatSwitch.ps1` - human-readable command-line interface
- `tests/run-tests.ps1` - dependency-free test suite
- `tests/WhatSwitch.Deployment.Tests.ps1` - Pester coverage for deployment profiles and exports

## Requirements

- PowerShell 7.6 or newer
- Windows 10/11 or Windows Server with WPF for the graphical interface
- Windows for deep MSI property analysis through the read-only Windows Installer database API
  (signature detection and command generation also work where that API is unavailable)
- Windows Sandbox for isolated install/uninstall verification (optional)
- PSAppDeployToolkit 4.1.8 for complete or script-only PSADT export

## PowerShell usage

### GUI

Double-click `Start-WhatSwitchGui.cmd`, then drag an installer onto the drop area. The GUI displays
the detected engine, metadata, catalog match, MSI properties, and PowerShell- or CMD-form commands
with individual copy buttons. Every runnable command also has **Test in Sandbox**, which creates a
fresh Windows Sandbox, stages only the selected installer through a read-only mapped folder, and
runs the command after a three-second cancellation window.

Use **Deploymentguide…** for a six-step Intune workflow. It collects app metadata, install and
uninstall commands, execution context, detection, requirements, return codes, and output mode. Each
export produces a complete deployment folder with an encrypted `.intunewin`, `Intune-Settings.json`,
a Swedish portal guide, analysis and Sandbox evidence, and SHA-256 checksums.

The guide supports three output modes per export:

- **Direct** packages the analyzed installer and commands without a wrapper.
- **PSADT script-only** includes the v4 frontend and a minimally customized official template but expects the toolkit module
  to be installed on the target.
- **Complete PSADT 4.1.8** includes the official v4 frontend, module, assets, and LGPL license. What Switch?
  preserves the complete `Invoke-AppDeployToolkit.ps1` template and only changes app metadata plus
  the marked installation and uninstallation task blocks. MSI deployments use the defaults from
  PSADT `Config/config.psd1`; custom public properties are appended with `AdditionalArgumentList`,
  while `ArgumentList` is used only when the user explicitly overrides UI, restart, or logging behavior.

The selected installer is packaged by default. Enable the source-folder option only when the
installer depends on adjacent files, and keep the deployment output outside that source folder.

When a usable uninstall command is known, the same Sandbox session keeps listening after the
installation. What Switch? snapshots uninstall registry entries and top-level program directories,
then combines those results with MSI ProductCode and catalog rules. A successful exit code alone is
therefore not treated as verified installation. The uninstall card's existing **Test in Sandbox**
button becomes enabled when the active session is ready. Click it—or
press `U` in the Sandbox console—to test uninstall without losing the installed state in a second
disposable session. The chosen detection rule is checked again after uninstall and must no longer
match for the removal to be marked verified.

If the same What Switch? test session is already open, its original installation command can be run
again after it has been uninstalled, without opening a second Sandbox. What Switch? prevents the same
package from being installed twice in succession because MSI maintenance/reinstall behavior varies
between packages. A Sandbox started outside the current What Switch? session
cannot receive mapped folders retroactively, so What Switch? detects it before launch and asks that it
be closed instead of attempting a second instance.

Sandbox networking, clipboard sharing, device redirection, and vGPU are disabled by default. Enable
the GUI's **Allow network in Sandbox** option only for web/bootstrap installers that must download
their payload. Windows Sandbox must first be enabled in Windows Features.

You can also launch it from a terminal, optionally with a file already selected:

```powershell
./Start-WhatSwitchGui.ps1
./Start-WhatSwitchGui.ps1 -Path C:\Installers\setup.exe
```

The launcher automatically starts an STA PowerShell process, which WPF and the Windows Clipboard
require.

### Command line

```powershell
# Friendly terminal output (PowerShell-ready commands by default)
./Invoke-WhatSwitch.ps1 -Path C:\Installers\setup.exe

# Machine-readable output
./Invoke-WhatSwitch.ps1 -Path C:\Installers\app.msi -AsJson

# Opt in to a noisy switch scan for unknown/custom executables
./Invoke-WhatSwitch.ps1 -Path C:\Installers\custom.exe -BestEffort

# Use it as a normal PowerShell module
Import-Module ./WhatSwitch.psd1
$result = Get-WhatSwitchResult -Path C:\Installers\app.msi
$result.Commands | Format-Table Label, PowerShellCommand
$result.Msi.PublicProperties | Format-Table Name, Value, IsSecret
```

Run the self-contained test suite with:

```powershell
pwsh -NoProfile -File ./tests/run-tests.ps1

# Optional Pester suite (compatible with the locally installed Pester 3.4+)
Invoke-Pester ./tests/WhatSwitch.Deployment.Tests.ps1
```

The analyzer is deliberately static. A detected or curated command must still be tested in a
disposable VM before deployment.

### Port scope

The PowerShell port covers engine detection, PE metadata, curated catalog matching, CMD-to-
PowerShell command conversion, best-effort switch harvesting, read-only MSI property analysis,
Sandbox detection verification, local `.intunewin` packaging, Intune deployment profiles, and
PSAppDeployToolkit v4 export. The browser-only WiX Burn inner-CAB X-ray remains in the original
web app; it is not invoked by the PowerShell module.

---

## Original web application

**Drop a Windows installer in your browser → get its silent-install switches.** No upload, no signup, no agent. The file you drop is read **entirely in your browser** - it never touches a server.

**Use it now (hosted):** https://getrff.com/switchhunt

Works on ~85% of installers out of the box, plus a curated catalog for the painful vendor one-offs.

---

## What it does

Drop an `.exe` or `.msi` and SwitchHunt identifies the installer engine from its bytes, then hands you:

- **The full command set** - install / repair / uninstall / extract, not just a single silent flag - with the modifier switches for each.
- **CMD ⇄ PowerShell** toggle (rewrites `.\`, the `&` call operator, `$env:` paths) and an **interactive command builder** (operation, UI level, INSTALLDIR, properties).
- **Deep MSI analysis** - a from-scratch in-browser MS-CFB (compound-file) reader decodes the `Property`, `Control`, `LaunchCondition` and `CustomAction` tables to surface a tiered "**properties you probably need to set**" list (required / likely / sensitive / optional), a full property dump, and an **uninstall-replay** warning (MSI properties are transaction-scoped, so secrets set at install must be passed again at `/x`).
- **Package for deployment, client-side:**
  - a **PSAppDeployToolkit v4** wrapper (`Invoke-AppDeployToolkit.ps1`) with the right `Start-ADTMsiProcess` / `Start-ADTProcess` calls, plus DeployMode / suppress-reboot / Terminal-Server options;
  - a real **`.intunewin`** built in the browser (STORE zip + AES-256-CBC + HMAC-SHA256 + `Detection.xml`, exactly like `IntuneWinAppUtil.exe`) - uploadable straight to Intune, no toolchain to install.

### Engines detected

MSI · WiX Burn · Advanced Installer · Inno Setup · NSIS · InstallShield · InstallAware · BitRock InstallBuilder · Wise · MSIX/AppX · Squirrel · 7-Zip/WinRAR self-extractors - with a best-effort switch *harvest* for the packed/custom long tail.

### The catalog (the weird stuff)

Signature detection can't derive a custom CLI's flags (Citrix, Teams machine-wide, AnyDesk, Docker Desktop, CrowdStrike, GlobalProtect…). Those live in [`src/lib/catalog.ts`](src/lib/catalog.ts) as **hand-verified known strings**, clearly labeled in the UI as "from catalog, not read from your file." For well-known apps the catalog also carries the real **uninstall** command and a **detection** path (the install dir an EXE installer never records).

- **Browse the catalog:** [CATALOG.md](CATALOG.md) (readable table) - or the machine-readable [`catalog/catalog.json`](catalog/catalog.json).
- **Add one - no coding:** [open a submission issue](https://github.com/deadarcher/SwitchHunt/issues/new?template=silent-install-string.yml) (a quick form), or PR `src/lib/catalog.ts` ([CONTRIBUTING](CONTRIBUTING.md)).

This is where the project most needs help. `CATALOG.md` + `catalog/catalog.json` are generated from the `.ts` - run `npm run gen:catalog`, don't hand-edit them.

---

## Why client-side?

Feeding a community-sourced "install command" into a tool that runs it as SYSTEM across a fleet is a supply-chain attack surface. SwitchHunt deliberately **does not run anything** - it only reads bytes and looks up strings. Nothing is uploaded; you can pull your network cable and it still works. Open the devtools Network tab and watch: zero requests with your file.

## Run it locally

```bash
npm install
npm run dev      # http://localhost:4321
npm run build    # static output in dist/ - deploy anywhere
```

No backend. `dist/` is plain static files; host it on GitHub Pages, Cloudflare Pages, Netlify, or `npx serve dist`.

### Docker

No clone, no Node - a prebuilt image is published to GHCR on every push to `main`:

```bash
docker run -d --name switchhunt -p 4321:80 ghcr.io/deadarcher/switchhunt
```

Or build it yourself from a clone (`nginx` serving the static `dist/`):

```bash
docker compose up -d --build   # http://localhost:4321
```

```bash
docker build -t switchhunt .
docker run -d --name switchhunt -p 4321:80 switchhunt
```

Same 100% client-side guarantee - the container only serves static files; installers you drop still never leave your browser.

Thanks to [timwelchnz](https://www.reddit.com/user/timwelchnz/) for suggesting this install option.

## How it works (short version)

- **Engine detection** (`src/lib/installerDetect.ts`): byte signatures + PE version-resource parsing for metadata. `.NET` requires the `_CorExeMain` stub (not just an `mscoree.dll` string) to avoid false positives, etc.
- **MSI parsing** (`src/lib/msi.ts`): a hand-rolled MS-CFB reader (the `cfb` npm package chokes on the 4096-byte-sector MSIs large enterprise packages use) that decodes the table streams.
- **Packaging** (`src/lib/psadt.ts`, `src/lib/intunewin.ts`): pure string-templating + WebCrypto. No native deps.

## License

MIT - see [LICENSE](LICENSE).

Built by [RFF](https://getrff.com) - Really Freakin' Fast Windows endpoint deployment.
