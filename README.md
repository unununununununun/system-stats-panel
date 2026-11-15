# StatsPanel — macOS floating system monitor

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5-app+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**StatsPanel** is a lightweight, always-on-top desktop panel for Apple Silicon and Intel Macs. It shows CPU and GPU load, memory and disk usage, SMC sensor temperatures, and battery stats — updated every second, with no menu bar icon and no background daemons.

Default UI language is **English**; **Russian** is available in Settings. The app is a single Swift file plus a build script — easy to audit and customize.

---

## Features

| Area | Metrics |
|------|---------|
| **CPU** | Utilization (%), core temperature (SMC) |
| **GPU** | Device utilization (`IOAccelerator`), temperature (SMC) |
| **Memory** | Used / total (wired + compressor + active) |
| **Disk** | Used / total on the boot volume |
| **Battery** | Charge %, status, cycles & temperature (tooltips) |

**UI**

- Floating panel over all spaces (including full-screen apps)
- Frosted-glass look (`NSVisualEffectView` + SwiftUI)
- Full and **compact** layout with live metric chips
- **Settings** slide-over (visibility toggles per metric)
- Theme: System / Light / Dark
- Drag anywhere on the window background to move

**Privacy**

- No network access, no analytics, no accounts
- Settings stored in local `UserDefaults` (`panel.*` keys)

---

## Screenshots

After install, the panel appears at the top-right of the main display. Build from source and run `./build.sh` to try it locally.

---

## Requirements

- macOS **13.0** or later (developed and tested on recent Apple Silicon / macOS 26)
- Xcode command-line tools (`swiftc`, `codesign`)
- No root required for CPU, GPU load, memory, disk, or battery

SMC temperature reads use the user-space **AppleSMC** client. On some systems, heavy SMC contention after rapid rebuilds can briefly return empty samples; the app reconnects automatically after a few empty reads.

---

## Quick start

```bash
git clone https://github.com/unununununununun/system-stats-panel.git
cd system-stats-panel
./build.sh
```

`build.sh` will:

1. Compile `main.swift` into `StatsPanel.app`
2. Ad-hoc code-sign the bundle
3. Install to `/Applications` (or `~/Applications` if needed)
4. Register with LaunchServices and launch the app

The app is an **accessory** (`LSUIElement`): it does not appear in the Dock.

### Login item (optional)

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/StatsPanel.app", hidden:true}'
```

Or: **System Settings → General → Login Items** → add `StatsPanel.app`.

---

## Controls

| Control | Action |
|---------|--------|
| Gear | Open settings |
| Compress | Compact mode |
| Chevron left (in settings) | Back to monitor |
| X | Quit |

In **compact mode**, use expand / gear / close in the mini toolbar. Tap metric chips mirror the full view.

---

## Architecture

```
main.swift          # App, UI (SwiftUI), SMC, IOKit monitors, window chrome
build.sh            # Build, install, launch
Info.plist          # Bundle metadata
tools/
  make_icon.swift   # Liquid-glass style app icon generator
  build_icons.sh    # Produce AppIcon.icns + iconset
  probe.swift       # Optional sensor probe helper
```

**Data sources**

- **CPU %** — `host_processor_info` tick deltas
- **GPU %** — `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`
- **Temperatures** — AppleSMC (`IOConnectCallStructMethod`, selector `2`, commands in `data8`; `flt ` types on Apple Silicon)
- **Memory** — `host_statistics64` + `HOST_BASIC_INFO`
- **Disk** — `URLResourceValues` on `/`
- **Battery** — `IOPowerSources` + `AppleSmartBattery` registry

---

## Configuration

Keys in `UserDefaults` (defaults registered at launch):

| Key | Meaning |
|-----|---------|
| `panel.cpu`, `panel.cpuTemp`, `panel.gpu`, `panel.gpuTemp`, … | Show/hide rows |
| `panel.compact` | Compact layout |
| `panel.theme` | `0` system, `1` light, `2` dark |
| `panel.lang` | `0` English, `1` Russian |

---

## Icon

Regenerate the app icon:

```bash
./tools/build_icons.sh
```

---

## Debug

Runtime log (append): `/tmp/stats_panel_debug.log`

Render check (writes PNGs to `/tmp`):

```bash
/Applications/StatsPanel.app/Contents/MacOS/StatsPanel --render-check
```

---

## Contributing

Issues and PRs welcome. Please keep changes focused — this project intentionally stays in one main source file for clarity.

---

## License

[MIT](LICENSE) — Copyright (c) 2026 [unununununununun](https://github.com/unununununununun).

---

## Русский (кратко)

Плавающая панель мониторинга: ЦП, GPU, память, диск, температуры SMC, батарея. Установка: `./build.sh`. Язык интерфейса — English по умолчанию, Русский в настройках.