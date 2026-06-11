# Changelog

All notable changes to the Windows Network Optimizer project are documented in this file.

---

## [3.0] — 2026-06-11

### 🐛 Bug Fixes

#### Critical
- **Exit-code-based MTU detection** — Replaced locale-dependent `'Reply from'` string matching with `$LASTEXITCODE` check in `Test-OptimalMtu()` (line 1299). The old approach failed on non-English Windows (e.g., Polish: `'Odpowiedz od'`). The binary-search ICMP ping test now works on any locale.
- **Dot-source guard** — Wrapped main execution flow in `if ($MyInvocation.InvocationName -ne '.')` (line 1466). Previously, importing the script with `. .\Optimize-NetworkAdapter.ps1` would execute the full optimization run as a side effect. Now functions and constants can be safely dot-sourced for library use without running the main block.
- **`exit` → `return`** — Replaced all `exit` statements inside functions and the dot-source-guarded block with `return`. Using `exit` in a non-module script kills the entire PowerShell host process; `return` exits the script gracefully while keeping the shell alive for follow-up commands.

#### Moderate
- **Adapter backup failure handling** — `Optimize-Adapter` now checks if `Backup-AdapterSettings` returns a valid path (line 803). If the backup write fails (e.g., permission denied on Desktop), the adapter optimization is aborted with a clear error instead of proceeding blindly with no rollback safety net.
- **DNS provider validation** — `Resolve-DnsProvider` now properly handles `$null`, empty string, and case-insensitive `'skip'` (line 573). Previously, passing an empty string could trigger unintended behavior.
- **Backup file parsing robustness** — `Backup-AdapterSettings` now validates `Test-Path` after writing (line 784). `Restore-FromBackup` handles both new-format JSON (with `AdapterName` field) and legacy-format backups (adapter name in filename) with a clear warning on old format (line 1397).

#### Minor
- **`Read-Host` with `-Silent` guard** — All `Read-Host` prompts now check `-not $Silent` before pausing (lines 358, 368, 376, 1549, etc.). Silent mode exits cleanly in CI/CD pipelines without hanging on invisible prompts.
- **Error summary at script end** — Added final `$Error.Count` check (line 1730) that warns the user about silently-recorded non-terminating errors (`$ErrorActionPreference = 'Continue'`), directing them to review `[!!]` and `[XX]` markers in output.

---

### 🎨 Visual Enhancements

#### Full ANSI Truecolor Banner
- Replaced plain-text header with a **Claude Code-style ANSI truecolor box** (lines 1472–1525) showing:
  - `╭──╮` / `╰──╯` box borders in bold blue (`RGB 59,130,246`)
  - "WINDOWS NETWORK OPTIMIZER v3.0" title in **bold white**
  - Subtitle in **gold** (`RGB 245,158,11`)
  - System info lines (OS, Build, PowerShell, Architecture) in bold white
  - Mode, Telemetry-off, Skip-registry, Skip-MTU, Silent-mode status with color-coded values

#### Mode-Aware ASCII Art
- `Write-AsciiArt` function (line 1433) renders distinct colored art per mode:
  - **Throughput**: lightning bolts (⚡) and bold frame in **green**
  - **LowLatency**: solid-block shield design in **magenta**
  - **Balanced**: scale icon (⚖) in **yellow**

#### 7 Unicode Symbol Message Types
- Replaced the old `[ OK ]`, `[ +> ]`, `[ !! ]`, `[ XX ]`, `[ .. ]`, `[ -- ]`, `[ ?? ]` bracket tags with visually distinctive Unicode symbols:
  - `●` green = success (`Write-OK`)
  - `○` cyan = applying change (`Write-Apply`)
  - `◆` yellow = warning (`Write-Warn`)
  - `●` red = error (`Write-Err`)
  - `◉` dark gray = informational (`Write-Info`)
  - `◌` dark gray = skipped/disabled (`Write-Skip`)
  - `✦` magenta = tip/suggestion (`Write-Tip`)

#### Section Headers with Unicode Boxes
- `Write-Section` (line 145) renders bold cyan Unicode boxes:
  ```
  ╭──────────────────────────────────────────────────────────╮
  │             PHASE 1: PER-ADAPTER OPTIMIZATION            │
  ╰──────────────────────────────────────────────────────────╯
  ```
  Title is rendered with the gradient text effect via `Write-GradientText`.

#### Gradient Text
- `Write-GradientText` (line 290) renders text with **per-character RGB color interpolation** (warm orange → bright orange by default). Used in section titles and the mode display.

#### Animated Spinner
- `Write-Spinner` (line 188) shows a rotating 6-frame Unicode animation (`· ✻ ✽ ✶ ✳ ✢`) at 80ms intervals during long phases. Clears the line on completion so output remains clean.

#### Pulse Dot Animation
- `Write-PulseDot` (line 209) shows a growing/shrinking dot pattern (`·`, `· ·`, `· · ·`) during the MTU binary search phase (~30s), providing real-time feedback on progress.

#### Multi-Adapter Progress Bar
- `Write-ProgressBar` (line 310) renders a gradient-filled `█`/`░` progress bar during multi-adapter optimization loops, showing percentage completion.

#### Color-coded DNS Menu
- `Show-DnsMenu` groups 21 DNS providers by category with category-specific icons (`[FAST]`, `[SEC ]`, `[FAM ]`, `[ADB ]`, `[PRIV]`, `[EU  ]`, `[CN  ]`) and per-category colors.

---

### 🔌 New NIC Vendor Patterns

Added advanced property regex patterns for previously uncovered NIC hardware:

| Pattern | Description |
|---------|-------------|
| `Power Down PHY\|Shutdown Wake\.On\.Lan` | Marvell/Aquantia PHY power-down feature |
| `Auto Disable Gigabit` | Killer/Realtek auto-speed-downgrade |
| `Selective Suspend` | USB NIC selective suspend |
| `System Idle Power Saver` | Intel idle power saver |
| `Reduce Speed On Power Down` | Realtek speed reduction on power transition |
| `Idle Power Saving` | Realtek idle power saving (always disable) |
| `Auto Disable PCIe\|Auto Disable PCI Express` | Realtek PCIe link auto-disable |
| `Advanced Stream Detect` | Killer Networking QoS feature (disable — causes lag) |
| `GameFast` | Killer proprietary fast-path |
| `Virtualization\|VMQ\|Virtual Machine Queues` | Broadcom/Intel server NIC VMQ |
| `SR-IOV` | Single Root I/O Virtualization |
| `Gigabit Master Slave Mode` | Intel gigabit master/slave role negotiation |
| `Interrupt Moderation Mode` | Additional Intel interrupt moderation variant |
| `ITR\|Interrupt Throttle Rate` | Intel I210/I225/I226 ITR settings |
| `Adaptive Interrupt Moderation` | Intel adaptive interrupt coalescing |
| `Gigabit Lite` | Realtek low-power gigabit mode |
| `Advanced EEE` | Advanced Energy Efficient Ethernet (beyond basic EEE) |

---

### 🏗 Infrastructure Improvements

#### Safe Dot-Sourcing
- Main execution block gated by `$MyInvocation.InvocationName -ne '.'` check (line 1466). The script can now be dot-sourced (`. .\Optimize-NetworkAdapter.ps1`) to import all functions, variables, and the DNS providers database into a PowerShell session without triggering the optimization run. This enables library-style usage, testing, and composition.

#### Error Handling Strategy
- `$ErrorActionPreference = 'Continue'` (line 132) ensures a single failed NIC setting (e.g., unsupported by a specific vendor) does not abort the entire optimization run. Each phase is independently try/catch wrapped.
- Final `$Error.Count` check warns about silently accumulated non-terminating errors.

#### Multi-Language Polish Support
- NIC property patterns include Polish display name variants alongside English:
  - `Speed.+Duplex` / `Szybkosc.+Dupleks`
  - `Flow Control` / `Sterowanie przeplywem`
  - `Receive Buffers` / `Bufory odbioru`
  - `Transmit Buffers` / `Bufory wysylania` / `Send Buffers`

#### Enhanced DNS Options
- DNS provider database expanded to 21 providers (was 18) with new entries:
  - ControlD Free (AdBlock category)
  - Mullvad AdBlock (AdBlock category)
  - Mullvad DNS (Privacy category)
  - DNS4EU Child Protect (EU category)
- Chinese DNS providers moved to their own `China` category with dedicated category icon `[CN  ]`
- Custom DNS IP parsing improved to accept semicolons (`;`) and commas (`,`) as delimiters

#### Backup/Restore Resilience
- JSON backup now includes `AdapterName` field for unambiguous restore (line 779)
- Restore function supports both new format (with AdapterName) and legacy format (filename-encoded), with clear warning on old format (line 1401)
- Adapter name sanitization for filename safety: `-replace '[\\/:*?"<>|]', '_'` (line 770)

---

### 📝 Documentation Updates

- README.md: Updated line count from 1454 → 1733 (two locations)
- README.md: Updated Console Output section from old `[ OK ]`/`[ +> ]` format to new Unicode symbol format
- README.md: Updated compatibility table to include all Windows versions
- .gitattributes: Added with correct line-ending rules (CRLF for .bat/.ps1, LF for .md)
- .gitignore: Expanded with comprehensive patterns (backups, OS files, IDE configs, private files, binaries, PowerShell transcripts)

---

### 📦 Repository Hygiene

- Removed `Optimize-NetworkAdapter.ps1.broken` leftover conflict file from development
- Added `.gitattributes` with line-ending enforcement

---

## [2.0] — 2025

### Added
- Initial 18 DNS providers with interactive selection menu
- Three optimization modes: Throughput, LowLatency, Balanced
- JSON backup and rollback support
- MTU auto-detection via ICMP fragmentation test
- MMCSS multimedia scheduler tweaks
- Power management (powercfg + Ultimate Performance plan)
- Telemetry off (opt-in)

### Fixed
- Locale-dependent `'Reply from'` string matching in MTU detection (fixed in v3.0)
- `exit` statements in non-module scripts replaced with `return` (fixed in v3.0)

---

## [1.0] — 2025

### Added
- Initial release
- Per-adapter advanced property optimization (~30 settings)
- TCP/IP global netsh tuning
- Registry TCP/IP stack tweaks
- Basic .bat launcher with UAC auto-elevation
