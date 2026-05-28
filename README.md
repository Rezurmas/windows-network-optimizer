# 🚀 Windows Network Optimizer

> Universal PowerShell script for maximum Windows network performance.
> Works on **Windows 8.1, 10, 11** and **Server 2012 R2+**.

[🇵🇱 Polski](#polski) | [🇬🇧 English](#english)

---

## English

### ✨ Features

- 🎯 **Three modes**: `Throughput` (download/streaming) / `LowLatency` (gaming) / `Balanced`
- ⚡ **~40 NIC settings** automatically tuned (offload, buffers, EEE off, etc.)
- 🔧 **24 TCP/IP global tweaks** via `netsh` (autotuning, RSS, ECN, CUBIC, HyStart, PRR)
- 📝 **16 registry TCP/IP optimizations** (Tcp1323Opts, MaxUserPort, SackOpts, etc.)
- 🎮 **MMCSS gaming priority** (NetworkThrottlingIndex disable, Games task boost)
- 🔋 **Power management** (USB Suspend off, PCIe LSPM off, CPU 100%, Ultimate plan)
- 🛡️ **DNS chooser** — 20+ providers (Cloudflare, AdGuard, DNS4EU, Quad9, Mullvad, AliDNS)
- 📦 **Backup & rollback** (JSON, one command to restore)
- 🔒 **Telemetry off** (optional, opt-in only)
- 📐 **MTU auto-detection** via ICMP fragmentation test
- 🌐 **Multi-language** support (PL UI, but works on any Windows locale)
- 🐧 **PowerShell 5.0+** compatible (works with default Windows PowerShell)

### 📥 Installation

#### Option 1: Direct download
```powershell
# In an elevated PowerShell window
iwr -Uri 'https://raw.githubusercontent.com/<USER>/<REPO>/main/Optimize-NetworkAdapter.ps1' -OutFile 'Optimize-NetworkAdapter.ps1'
.\Optimize-NetworkAdapter.ps1
```

#### Option 2: Git clone
```bash
git clone https://github.com/<USER>/<REPO>.git
cd <REPO>
# Right-click Run-NIC-Optimizer.bat → "Run as administrator"
```

### 🎮 Usage

#### Interactive (recommended for first time)
```powershell
.\Optimize-NetworkAdapter.ps1
# Pick adapter → optional DNS → done
```

#### One-click via .bat (auto-elevates)
Just **double-click `Run-NIC-Optimizer.bat`** — it auto-elevates via UAC and shows a menu.

#### CLI examples
```powershell
# Max throughput for all Ethernet adapters
.\Optimize-NetworkAdapter.ps1 -Mode Throughput -All

# Gaming low-latency + Cloudflare DNS
.\Optimize-NetworkAdapter.ps1 -Mode LowLatency -DnsProvider 1

# Full automation (CI / scripted deployment)
.\Optimize-NetworkAdapter.ps1 -Mode Throughput -All -DnsProvider 11 -DisableTelemetry -Silent

# Custom DNS
.\Optimize-NetworkAdapter.ps1 -DnsProvider "1.1.1.1,9.9.9.9"

# Rollback (restore from backup)
.\Optimize-NetworkAdapter.ps1 -Restore
```

### 🌐 DNS Providers (built-in)

| Category | ID | Provider | IPs | Notes |
|---------|----|---------|----|-------|
| **Speed** | 1 | Cloudflare | `1.1.1.1`, `1.0.0.1` | Fastest globally (DNSPerf) |
| **Speed** | 2 | Google | `8.8.8.8`, `8.8.4.4` | Stable, ECS support |
| **Speed** | 3 | Quad9 Unsecured | `9.9.9.10` | Quad9 without security filter |
| **Speed** | 4 | OpenDNS Home | `208.67.222.222` | Basic phishing block |
| **Security** | 5 | Cloudflare Malware | `1.1.1.2`, `1.0.0.2` | Cloudflare + malware block |
| **Security** | 6 | **Quad9 Secure** ⭐ | `9.9.9.9` | Swiss, no-log, DNSSEC |
| **Security** | 7 | CleanBrowsing Security | `185.228.168.9` | Security filter |
| **Family** | 8 | Cloudflare Family | `1.1.1.3`, `1.0.0.3` | + adult content block |
| **Family** | 9 | OpenDNS FamilyShield | `208.67.222.123` | Adult auto-block |
| **Family** | 10 | CleanBrowsing Family | `185.228.168.168` | Family-friendly |
| **AdBlock** | 11 | **AdGuard DNS** ⭐ | `94.140.14.14` | Blocks ads + trackers |
| **AdBlock** | 12 | AdGuard Family | `94.140.14.15` | AdGuard + adult block |
| **AdBlock** | 13 | ControlD Free | `76.76.2.0` | Customizable ad block |
| **AdBlock** | 14 | Mullvad AdBlock | `194.242.2.3` | Privacy + adblock |
| **Privacy** | 15 | AdGuard Unfiltered | `94.140.14.140` | No log, no filter |
| **Privacy** | 16 | Mullvad DNS | `194.242.2.2` | Sweden, max privacy |
| **EU** | 17 | **DNS4EU Protective** ⭐ | `86.54.11.1` | EU-funded, GDPR |
| **EU** | 18 | DNS4EU Unfiltered | `86.54.11.100` | DNS4EU no-filter |
| **EU** | 19 | DNS4EU Child Protect | `86.54.11.13` | EU + child protection |
| **China** | 20 | AliDNS | `223.5.5.5` | Alibaba (mainland China) |
| **China** | 21 | DNSPod (Tencent) | `119.29.29.29` | Tencent (mainland China) |
| Reset | 99 | Back to DHCP | (router) | Reset to ISP/router DNS |

### 🎯 Mode comparison

| Setting | Throughput | LowLatency | Balanced |
|---------|-----------|------------|----------|
| TCP autotuning | `experimental` | `normal` | `normal` |
| Congestion provider | `cubic` | `ctcp` | `cubic` |
| LSO/RSC | ✅ ON | ❌ OFF | ✅ ON |
| Interrupt Moderation | Adaptive | OFF | Adaptive |
| Nagle's algorithm | Default | **OFF** | **OFF** |
| MMCSS Responsiveness | 10 | 0 | 10 |
| Best for | Streaming, downloads | CS2/Valorant/FPS | Daily use |

### 🛠️ Requirements

- **OS**: Windows 8.1 / 10 / 11 (or Server 2012 R2+)
- **PowerShell**: 5.0 or higher (default on Win 10+)
- **Privileges**: Administrator (script auto-elevates via .bat)
- **Architecture**: x86 or x64

### 📂 Project Structure

```
windows-network-optimizer/
├── Optimize-NetworkAdapter.ps1    # Main script (~1100 lines)
├── Run-NIC-Optimizer.bat          # One-click launcher with UAC elevation
├── README.md                      # This file
├── LICENSE                        # MIT
└── .gitignore                     # Excludes NIC-Backup/*.json
```

### 🔄 Rollback

The script auto-backups all adapter settings before any change to `Desktop\NIC-Backup\*.json`.

```powershell
.\Optimize-NetworkAdapter.ps1 -Restore
```

### ⚠️ Warnings

- **Reboot required** after first run (TCP global + registry tweaks)
- **Some VPN clients** with LSPs may have temporary glitches → reconnect VPN after reboot
- **AdBlock router users**: don't pick DNS provider → keep DHCP-assigned router DNS
- **MTU test** sends ICMP packets → may show warnings if firewall blocks them
- `winsock reset` is **intentionally NOT** applied automatically (can break VPN clients)

### 📚 Sources / Credits

Research compiled from:
- **Microsoft Learn** — official `netsh` and TCP/IP documentation
- **Reddit** — r/pcmasterrace, r/dns, r/networking, r/PowerShell
- **Atlas-OS** — open-source Windows performance modification
- **ChrisTitusTech/winutil** — Windows utility script
- **DNSPerf** — DNS performance benchmarks (2025)
- **guru3D Forums**, **BlurBusters**, **Windows Forum**
- **DNS4EU project** — European Union DNS resolver
- **CSDN, blog.csdn.net** — Chinese forums for AliDNS / DNSPod info

### 🤝 Contributing

PRs welcome! Especially for:
- Additional NIC vendor advanced property patterns
- New DNS providers (worth adding to default list)
- Translations (i18n)
- Windows Server-specific tweaks
- Testing on more hardware (Intel I225, Realtek 2.5G, etc.)

### 📜 License

MIT — see [LICENSE](LICENSE)

---

## Polski

### ✨ Funkcje

- 🎯 **Trzy tryby**: `Throughput` (pobieranie/streaming) / `LowLatency` (gry) / `Balanced`
- ⚡ **~40 ustawień karty sieciowej** automatycznie (offload, buffers, EEE off)
- 🔧 **24 globalne tweaks TCP/IP** przez `netsh`
- 📝 **16 optymalizacji rejestru TCP/IP**
- 🎮 **Priorytety MMCSS dla gier** (NetworkThrottlingIndex off, Games boost)
- 🔋 **Zarządzanie energią** (USB Suspend off, PCIe LSPM off, CPU 100%)
- 🛡️ **Wybór DNS** — 20+ dostawców (Cloudflare, AdGuard, DNS4EU, Quad9, Mullvad)
- 📦 **Backup & rollback** (JSON, jedna komenda do przywrócenia)
- 🔒 **Wyłączenie telemetrii** (opcjonalne)
- 📐 **Auto-detekcja MTU**
- 🌐 **Wieloplatformowy** (PL UI, działa na każdym Windows)

### 📥 Instalacja

#### Najprostszy sposób:
1. Pobierz folder z GitHub (lub `git clone`)
2. **Klik prawy** na `Run-NIC-Optimizer.bat` → **Uruchom jako administrator**
3. Wybierz tryb z menu

#### Z PowerShell:
```powershell
# Tryb interaktywny (wybierasz wszystko z menu)
.\Optimize-NetworkAdapter.ps1

# Max przepustowość dla wszystkich kart Ethernet
.\Optimize-NetworkAdapter.ps1 -Mode Throughput -All

# Tryb gamingowy + DNS Cloudflare
.\Optimize-NetworkAdapter.ps1 -Mode LowLatency -DnsProvider 1

# Pełna automatyzacja (cicho, bez promptów)
.\Optimize-NetworkAdapter.ps1 -Mode Throughput -All -DnsProvider 11 -DisableTelemetry -Silent

# Cofnij zmiany (z backupu)
.\Optimize-NetworkAdapter.ps1 -Restore
```

### 🌐 Lista DNS (wbudowana)

Polskim użytkownikom polecam:
- **`1` Cloudflare** — najszybszy globalnie
- **`11` AdGuard DNS** — blokuje reklamy w całej sieci
- **`17` DNS4EU Protective** — EU-finansowany, GDPR, blokada malware
- **`6` Quad9 Secure** — Szwajcaria, no-log, DNSSEC

⚠️ **Jeśli masz AdBlock na routerze (OpenWrt/Pi-hole) — NIE ustawiaj DNS!** Wybierz „Skip" w menu.

### 🎯 Który tryb wybrać?

| Sytuacja | Tryb |
|----------|------|
| Pobieranie plików, Netflix, YouTube 4K | **Throughput** |
| Gry FPS (CS2, Valorant, Apex) | **LowLatency** |
| Mixed use, codzienna praca | **Balanced** |

### 🔄 Cofanie zmian

Skrypt automatycznie robi backup przed zmianami → `Pulpit\NIC-Backup\*.json`.

```powershell
.\Optimize-NetworkAdapter.ps1 -Restore
```

### ⚠️ Ważne uwagi

- **Wymagany restart** po pierwszym uruchomieniu
- Klienci **VPN** z LSP-ami mogą wymagać reconnectu
- Jeśli masz **AdBlock na routerze** → nie ruszaj DNS (wybierz „Skip" w menu)

### 📚 Źródła

Research zebrany z: Microsoft Learn, Reddit (r/pcmasterrace, r/dns, r/networking), Atlas-OS, ChrisTitusTech, DNSPerf, guru3D, BlurBusters, Windows Forum, DNS4EU, CSDN (chińskie fora dla AliDNS/DNSPod).

### 📜 Licencja

MIT — zobacz plik [LICENSE](LICENSE)
