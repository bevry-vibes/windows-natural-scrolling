# windows-natural-scrolling

Enables, disables, or removes natural scrolling for USB and Bluetooth scrolling devices (mice and trackpads) under Windows 10 and Windows 11 — through an interactive arrow-key TUI, or non-interactively with `list` / `set` subcommands. Changes are written to per-device registry values (`FlipFlopWheel` / `FlipFlopHScroll`), so they persist across reboots and no background process is needed. (On Windows 11 24H2+ this is built into Settings — see [Non-registry alternatives](#non-registry-alternatives).)

## What "natural scrolling" means

- **Natural scroll** — pulling the mouse wheel *down* moves the page *down* (the text above comes into view), like a trackpad / macOS.
- **Unnatural / Microsoft default** — pulling the wheel *down* moves the page *up* (the text below comes into view).

The direction is controlled by two per-device registry values under `HKLM:\SYSTEM\CurrentControlSet\Enum\<instance>\Device Parameters`:

| Value | `1` | `0` |
| --- | --- | --- |
| `FlipFlopWheel` (vertical scroll) | natural | unnatural |
| `FlipFlopHScroll` (horizontal scroll) | natural | unnatural |

> **Why "Wheel" but "HScroll" — and not `FlipFlopHWheel` or `FlipFlopYScroll`? The names aren't a symmetric X/Y axis scheme. The vertical value is `FlipFlopWheel`, named after the physical wheel on a mouse (the one rotating wheel is the vertical scroller). The horizontal value is `FlipFlopHScroll`, named after the *action* — horizontal scroll — not after a wheel. The symmetric alternatives `FlipFlopHWheel` and `FlipFlopYScroll` are not used: `FlipFlopHWheel` would imply a second, horizontally-rotating wheel, which most mice don't have (horizontal input comes from tilting the wheel); `FlipFlopYScroll` was never needed because vertical is the unmarked default — single-wheel mice only scrolled vertically, so the wheel predates horizontal scroll, and only the later horizontal behavior got a direction qualifier ("H" + "Scroll"). This shows up on trackpads too, which do two-finger vertical and horizontal scrolling with *no wheel at all*: `FlipFlopHScroll` ("scroll") fits them, while `FlipFlopWheel` ("wheel") is really just the historical name carried over from mice. So one axis is named for the device ("Wheel") and the other for the behavior ("HScroll").

When a value is absent (not set), it resolves to the Microsoft default (unnatural); `delete` therefore behaves like `disable` in effect, but leaves no explicit value behind.

## Requirements

- **PowerShell 7.6 or later** (`pwsh`) — install with `winget install Microsoft.PowerShell`, from the Microsoft Store, or from the [PowerShell releases](https://github.com/PowerShell/PowerShell/releases) page. The Windows in-box PowerShell 5.1 (`powershell.exe`) is not supported: the script refuses to start on it (`#Requires -Version 7.6`).
- **Administrator rights** — the registry values live under `HKLM`, and the script refuses to run unelevated (`#Requires -RunAsAdministrator`).

## Files

- `adjust-natural-scroll.ps1` — the main script (TUI + `list`/`set`).
- `menu.ps1` — the reusable arrow-key menu it dot-sources; keep it next to the main script. You can use it standalone in your own scripts: `. "$PSScriptRoot\menu.ps1"`, then `Read-MenuChoice -Rows @('Alpha', 'Beta', 'Quit')` (returns the 0-based index, `-1` for Esc, `-2` for Ctrl+C). Running `pwsh menu.ps1` directly shows a demo. Same requirement: PowerShell 7.6+.
- `menu-test.ps1` / `adjust-natural-scroll-test.ps1` — per-file function-level tests: the real functions are AST-extracted and exercised against a scratch registry key (`pwsh ./menu-test.ps1`, `pwsh ./adjust-natural-scroll-test.ps1`).
- `PSScriptAnalyzerSettings.psd1` — analyzer configuration (the Write-Host rule is excluded repo-wide: styled host output is the intended interface here). Lint with `Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1`.

## Opening an elevated shell

Any of these works — no Ctrl+clicking required:

- **From an existing shell (CLI):** `Start-Process pwsh -Verb RunAs` — accept the UAC prompt and a new elevated `pwsh` window opens.
- **Start menu:** type `pwsh`, right-click **PowerShell 7** → **Run as administrator**. Or press **Win+X** and choose **Terminal (Admin)** / **Windows PowerShell (Admin)**.
- **Windows Terminal:** enable **Run as administrator** on the profile (Settings → your `pwsh` profile → **Run as administrator**, or `"elevate": true` in `settings.json`), or launch Windows Terminal itself as administrator (all of its tabs are then elevated).
- **Windows 11 24H2+:** enable **Sudo for Windows** (Settings → System → For developers → **Enable sudo**), then `sudo pwsh` — in "inline" mode it elevates within the same window.
- **gsudo** (third party): `winget install gerardog.gsudo`, then `gsudo pwsh` elevates in place.

## Usage

### Interactive (TUI)

From an elevated `pwsh`, run the script with no arguments:

```
.\adjust-natural-scroll.ps1
```

Pick a device from the arrow-key menu, then an axis (vertical / horizontal), then the action:

- **Up/Down** move the highlight (with wrap-around), **Enter** confirms, **number keys** select a row directly, **Esc** backs out one level, **Ctrl+C** quits gracefully from anywhere (exit code 130).
- Devices and their states are re-enumerated every time the device menu renders, so plug/unplug events and changes are visible immediately.
- The highlight always starts on the option matching the current state, marked `[already the case]` — browsing and backing out changes nothing, so the TUI doubles as an inspector.
- The reconnect reminder is only printed when a change was actually applied.

### Command line: `list`

```
.\adjust-natural-scroll.ps1 list
```

Non-interactively prints every compatible scrolling device with its instance ID and current vertical/horizontal state — the instance IDs are what `set` needs. On a console the output is styled for humans; when stdout is redirected it instead emits structured objects (`Number`, `InstanceId`, `Descriptor`, `Vertical`, `Horizontal`), e.g. `.\adjust-natural-scroll.ps1 list | ConvertTo-Json`.

Example:

```
> .\adjust-natural-scroll.ps1 list

Detected scrolling devices:
  [1] Apple built-in trackpad (USB)
      HID\VID_05AC&PID_0278&...    vertical: natural OFF, horizontal: absent
```

### Command line: `set`

```
.\adjust-natural-scroll.ps1 set <device-id> <vertical|horizontal> <enable|disable|delete>
```

- `<device-id>` — the device instance ID from `list`. An exact match is tried first, then a unique substring (e.g. `05ac`); zero or multiple matches produce an error listing the candidates.
- `enable` sets the value to `1` (natural), `disable` sets it to `0` (Microsoft default), `delete` removes the registry value entirely.

Example:

```
> .\adjust-natural-scroll.ps1 set 05ac vertical enable

Apple built-in trackpad (USB)
    HID\VID_05AC&PID_0278&...
Vertical scroll: natural OFF -> natural ON
Reconnect the device (or restart Windows) for the change to take effect.
```

### If Windows blocks script execution

The error "running scripts is disabled on this system" comes from the execution policy, which PowerShell enforces **before the script file is even read** — so no directive inside a script can exempt it (there is no `#Requires` for it, by design). Your options:

- **One run:** `pwsh -ExecutionPolicy Bypass -File .\adjust-natural-scroll.ps1`
- **Persistent (current user):** `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` — scripts you create locally then run freely; files downloaded from the internet also need `Unblock-File` once (on both files — dot-sourcing loads `menu.ps1` as a script too).

## Sample session (TUI)

```
Detected scrolling devices: (up/down + Enter, digits jump, Esc = back, Ctrl+C = quit)
> Apple built-in trackpad (USB)  vertical: natural OFF, horizontal: absent
  Quit

Apple built-in trackpad (USB)
    HID\VID_05AC&PID_0278&...

> Vertical scroll    (current: natural OFF)
  Horizontal scroll  (current: absent)
  Back to devices

[Vertical scroll] current: natural OFF
  (1) Enable natural scroll
> (2) Disable natural scroll  [already the case]
  (3) Remove the registry entry
  (4) Back
Vertical scroll: no change needed - already natural OFF
```

In a real terminal the output is color-coded: headers in cyan, axis states green (`natural ON`), yellow (`natural OFF`), or dimmed (`absent`), the highlighted row is reversed, and errors are red.

## Supported devices

Any scrolling device reported by `Get-PnpDevice -Class Mouse` whose instance ID starts with `HID\` is handled (the `Mouse` PnP class covers trackpads as well as mice). This includes:

- USB mice — `HID\VID_xxxx&PID_xxxx...`
- Bluetooth mice / trackpads — `HID\{00001812-...}...`

Non-HID devices (e.g. legacy PS/2 devices, `ACPI\...`) are skipped because they do not carry these registry values.

## Applying changes

Changes only take effect after the scrolling device is **disconnected and reconnected** to the same port, or after **Windows is restarted**.

## Comparison with other approaches

### Non-registry alternatives

- **Windows 11 24H2+ native setting** — added a built-in scrolling-direction toggle under **Settings > Bluetooth & devices > Mouse** ([build 26257 announcement](https://blogs.windows.com/windows-insider/2024/07/24/announcing-windows-11-insider-preview-build-26257-canary-channel/)). If you have it, use it; this script is unnecessary there.
- **[SmoothScroll](https://github.com/quangtruong2003/SmoothScroll)** — a low-level `WH_MOUSE_LL` hook (Rust / Tauri) that intercepts wheel events live and adds easing/inertia, with per-app exclusions. Choose this if you want smooth scrolling, not just a reversed direction.
- **[natural-scrolling-Fix](https://github.com/ZacharyHu0/natural-scrolling-Fix)** — an AutoHotkey v2 script that swaps `WheelUp`/`WheelDown` while preserving Ctrl+zoom. Instant, admin-free, suspendable.

The hook-based tools apply instantly and need no admin rights, but they must keep a background process running and act per user session. The registry approach used here is persistent across reboots and users and needs no background process — at the cost of admin rights and a device reconnect (or restart) before the change takes effect.

### Registry-based implementations

All the tools below flip the same per-device `FlipFlopWheel` (and, here, `FlipFlopHScroll`) registry value. The technique itself is a long-standing documented Windows behavior (the [Microsoft Answers thread](https://answers.microsoft.com/en-us/windows/forum/all/reverse-mouse-wheel-scroll/657c4537-f346-4b8b-99f8-9e1f52cd94c2) is the usual source) — it is not owned by any one project.

| Implementation | Mechanism | Runtime | Per-device | Both axes | Enable / Disable / Remove | License |
| --- | --- | --- | --- | --- | --- | --- |
| This project | Registry `FlipFlopWheel`/`FlipFlopHScroll`, interactive TUI + `list`/`set` CLI | PowerShell 7.6+ | Yes | Yes | enable / disable / remove | RPL-1.5 |
| [jm33-m0/win10-mouse-natural-scroll](https://github.com/jm33-m0/win10-mouse-natural-scroll) | Registry `FlipFlopWheel`, enable/reverse args | PowerShell | No | No | enable / disable | GPL-3.0 |
| [Microtribute/win-mouse-natural-scroll](https://github.com/Microtribute/win-mouse-natural-scroll) | Registry `FlipFlopWheel`, enable/disable (fork of jm33-m0) | PowerShell | No | No | enable / disable | GPL-3.0 |
| [luoling8192/windows-natural-scrolling](https://github.com/luoling8192/windows-natural-scrolling) | Registry `FlipFlopWheel`, batch all USB mice | PowerShell 7+ | No | No | enable | MIT |
| [Uplink03 gist](https://gist.github.com/Uplink03/d86329d0c538a493e889b1249cc6c4df) | Registry `FlipFlopWheel`, pick device by index | PowerShell | Yes | No | enable | none (gist) |
| [gagarine gist](https://gist.github.com/gagarine/d313ee6510009b3f3973c6e0929b1e1c) | Registry `FlipFlopWheel`, `Get-PnpDevice` one-liner (cites MS Answers) | PowerShell | No | No | enable / disable (0/1) | none (gist) |
| [jordanilchev gist](https://gist.github.com/jordanilchev/c56548e1ef2b432b2e75a8dad20875b3) | Verbatim copy of gagarine's one-liner | PowerShell | No | No | enable / disable (0/1) | none (gist) |
| [ammunoz gist](https://gist.github.com/ammunoz/0e01350617ecee89cbc1b1abb039a50d) | Registry `FlipFlopWheel`, `HID\*\*` wildcard one-liner | PowerShell | No | No | enable | none (gist) |
| [101v gist](https://gist.github.com/101v/4ded69398369f78962681e8ff00a5d1d) | `HID\*\*` wildcard one-liner, enable + restore | PowerShell | No | No | enable / disable | none (gist) |
| [imambux gist](https://gist.github.com/imambux/43cc894288898a37f64e366b6d3b78d4) | Byte-identical copy of 101v's one-liner | PowerShell | No | No | enable / disable | none (gist) |
| [ttaranto gist](https://gist.github.com/ttaranto/2a798db26500c8d4ad0e1c0e3708b9c7) | Shorter copy of the `HID\*\*` one-liner (enable) | PowerShell | No | No | enable | none (gist) |
| [Wintus gist](https://gist.github.com/Wintus/c650141472e06d09f9b56b71213f0d68) | `HID\*\*` wildcard one-liner, restore to 0 | PowerShell | No | No | disable | none (gist) |
| [ghacupha gist](https://gist.github.com/ghacupha/eafd176a20fcd04a45bf312db70dd42e) | Manual Device Manager + Registry Editor steps | — (manual) | Yes | No | manual | none (gist, ChatGPT) |

### Provenance notes

- **This project is an independent implementation**, designed from a survey of the approaches above; it is not a fork, port, or rewrite of any of them.
- Where *other* implementations are forks or copies of each other, that is noted in the table: Microtribute is a GitHub fork of jm33-m0; jordanilchev is a verbatim copy of gagarine's gist; 101v and imambux are byte-identical copies of the same one-liner; ammunoz, ttaranto, and Wintus are variants of a common `HID\*\*` wildcard one-liner; ghacupha documents manual steps (acknowledged as ChatGPT-generated).
- None of the gists declares a license, so they remain the copyright of their respective authors and are referenced here for comparison only.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->