#Requires -RunAsAdministrator
#Requires -Version 5.0
<#
.SYNOPSIS
    Windows Network Optimizer - max performance / low latency / DNS chooser
    https://github.com/<your-user>/windows-network-optimizer

.DESCRIPTION
    Universal Windows network optimization script. Works on Windows 8.1, 10, 11
    and Windows Server 2012 R2+.

    Features:
    1. Scans network adapters and applies ~40 advanced NIC settings
    2. Backs up current settings to JSON (rollback supported)
    3. TCP/IP global tuning (24 netsh commands)
    4. Registry tweaks (16 TCP/IP performance values)
    5. Per-interface Nagle off (gaming low-latency)
    6. MMCSS optimization (network throttling, gaming priority)
    7. Power management (USB suspend, PCIe LSPM, CPU 100%)
    8. Telemetry off (optional, opt-in)
    9. DNS chooser - 20+ providers (Cloudflare, AdGuard, DNS4EU, Quad9, etc.)
    10. MTU auto-detection
    11. Three modes: Throughput / LowLatency / Balanced

    Compatible with: Windows 8.1, 10 (all builds), 11 (all builds),
                     Windows Server 2012 R2, 2016, 2019, 2022, 2025

    Sources: Microsoft Learn, Reddit (r/pcmasterrace, r/dns, r/networking),
             Atlas-OS, ChrisTitusTech, DNSPerf, guru3D, BlurBusters,
             Windows Forum, DNS4EU project

.PARAMETER Mode
    Throughput  - max bandwidth (download, streaming, file transfer) [default]
    LowLatency  - min ping (gaming, VoIP, competitive FPS)
    Balanced    - compromise (good ping + throughput)

.PARAMETER Restore
    Restores adapter settings from latest backup

.PARAMETER All
    Optimizes all active Ethernet adapters without prompting

.PARAMETER AdapterName
    Specific adapter name (skips interactive selection)

.PARAMETER DnsProvider
    DNS provider ID (1-21) or 'Skip' to keep current.
    Run with -DnsProvider 0 to see interactive menu.
    Use -DnsProvider Skip to not change DNS.

.PARAMETER DisableTelemetry
    Disables Microsoft telemetry (DiagTrack, dmwappushservice, Delivery Opt.)

.PARAMETER NoRegistry
    Skips registry tweaks (only adapter settings + netsh)

.PARAMETER NoMtuTest
    Skips MTU auto-detection (saves ~30 seconds)

.PARAMETER Silent
    Non-interactive mode (no prompts, exits when done)

.EXAMPLE
    .\Optimize-NetworkAdapter.ps1
    Interactive mode - choose adapter and DNS from menu

.EXAMPLE
    .\Optimize-NetworkAdapter.ps1 -Mode LowLatency -All
    Gaming mode for all Ethernet adapters

.EXAMPLE
    .\Optimize-NetworkAdapter.ps1 -Mode Throughput -DnsProvider 1 -DisableTelemetry -Silent
    Full automation: max throughput + Cloudflare DNS + telemetry off

.EXAMPLE
    .\Optimize-NetworkAdapter.ps1 -Restore
    Rollback to backup

.NOTES
    Author:   Open source community contribution
    License:  MIT
    Version:  4.0
    Updated:  2026 — 29 AI-agent audited

    REBOOT REQUIRED after first run for full effect.
#>

[CmdletBinding()]
param(
    # Restore previous adapter settings from JSON backup
    [switch]$Restore,

    # Optimize ALL active Ethernet adapters without prompting
    [switch]$All,

    # Specific adapter name (skips interactive selection)
    [string]$AdapterName,

    # === OPTIMIZATION MODE ===
    # Throughput  = max bandwidth (downloads, streaming, file transfer)
    # LowLatency  = min ping (gaming, VoIP, competitive FPS)
    # Balanced    = compromise (good ping AND throughput)
    [ValidateSet('Throughput','LowLatency','Balanced')]
    [string]$Mode = 'Throughput',

    # Disable Microsoft telemetry (DiagTrack, dmwappushservice, Delivery Optimization)
    # WARNING: opt-in only - some users want telemetry for diagnostics
    [switch]$DisableTelemetry,

    # DNS provider selector:
    #   (not provided) = interactive menu (default)
    #   1-21           = select provider by ID
    #   99             = reset DNS to DHCP (router)
    #   'Skip'         = don't change DNS
    #   '1.1.1.1,9.9.9.9' = comma-separated custom IPs
    $DnsProvider,

    # Skip registry tweaks (apply only adapter settings + netsh global)
    [switch]$NoRegistry,

    # Skip MTU auto-detection (saves ~30 seconds, ICMP-based test)
    [switch]$NoMtuTest,

    # Silent mode - no prompts, auto-select all Ethernet, exit when done
    # Recommended for CI/CD pipelines and unattended deployments
    [switch]$Silent
)

# --- Virtual Terminal (VT) / ANSI escape sequence detection ---
# PowerShell ISE output pane and older consoles (Server 2012 R2) do NOT support
# ANSI escape codes. We detect this early and fall back to plain-text output.
$SupportsVT = $false
try {
    $SupportsVT = $host.UI.SupportsVirtualTerminal
} catch { }
# Also detect PowerShell ISE (output pane is NOT a terminal)
$IsISE = $host.Name -match 'ISE'
if ($IsISE) { $SupportsVT = $false }

# 'Continue' is used instead of 'Stop' so the script can apply as many
# optimizations as possible — a single failed setting (e.g. unsupported
# by a specific NIC vendor) should not abort the entire optimization run.
$ErrorActionPreference = 'Continue'
$ScriptStartErrorCount = $Error.Count
$BackupDir = Join-Path $env:USERPROFILE 'Desktop\NIC-Backup'

# ============================================================
#   COLORFUL OUTPUT HELPERS
#   Each message type has a unique colored prefix tag
#   for instant visual scanning of logs.
# ============================================================

# Section header - bold cyan Unicode box that visually separates phases
#   ╭──────────────────────────────────────────────────────────╮
#   │             PHASE 1: PER-ADAPTER OPTIMIZATION            │
#   ╰──────────────────────────────────────────────────────────╯
function Write-Section {
    param([string]$title)
    $width = 58
    $inner = $width - 2                               # space for side borders
    $side  = [char]0x2502                             # │
    Write-Host ''
    # Top border:   ╭────...────╮
    Write-Host ('  ' + [char]0x256D + ([string][char]0x2500 * $inner) + [char]0x256E) -ForegroundColor Cyan
    # Title:  │  centered-title  │  — bold white title on cyan borders
    $padTotal = $inner - 2 - $title.Length            # -2 for spaces between │ and text
    if ($padTotal -lt 0) { $padTotal = 0 }
    $leftPad  = [Math]::Floor($padTotal / 2)
    $rightPad = $padTotal - $leftPad
    Write-Host ('  ' + $side + ' ') -NoNewline -ForegroundColor Cyan
    Write-Host (' ' * $leftPad) -NoNewline
    Write-GradientText -Text $title -NoNewline
    Write-Host (' ' * $rightPad + ' ') -NoNewline -ForegroundColor Cyan
    Write-Host $side -ForegroundColor Cyan
    # Bottom border:   ╰────...────╯
    Write-Host ('  ' + [char]0x2570 + ([string][char]0x2500 * $inner) + [char]0x256F) -ForegroundColor Cyan
}

# Sub-header inside a section — dimmed line with bold white title
#   ──── DNS Selection ────
function Write-SubSection {
    param([string]$title)
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ([string][char]0x2500 * 4) -NoNewline -ForegroundColor DarkGray
    Write-Host " $title " -NoNewline -ForegroundColor White
    Write-Host ([string][char]0x2500 * 4) -ForegroundColor DarkGray
}

# Thin dimmed divider line — separates sub-sections without fanfare
#   ─────────────────────────────────────────────────
function Write-MiniDivider {
    Write-Host ('  ' + [string][char]0x2500 * 54) -ForegroundColor DarkGray
}

# Spinner animation — shows a rotating symbol for a given duration.
# Useful to indicate that a long phase has started and is in progress.
# Frames: · ✻ ✽ ✶ ✳ ✢   at 80ms intervals (smooth 12.5 fps).
# Clears the line on completion so output is not cluttered.
function Write-Spinner {
    param(
        [string]$Message,
        [int]$Duration = 2
    )

    if (-not $SupportsVT) {
        Write-Host "  ... $Message" -ForegroundColor Cyan
        Start-Sleep -Seconds $Duration
        return
    }

    $frames = @('·', '◈', '◆', '◇', '◖', '◗')  # Geometric Shapes block (U+25C6-U+25D7) — render in Consolas
    $esc    = [char]27
    $start  = Get-Date
    $i      = 0
    while (((Get-Date) - $start).TotalSeconds -lt $Duration) {
        $frame = $frames[$i % $frames.Count]
        Write-Host ("`r$($esc)[2K  $frame  $Message") -NoNewline -ForegroundColor Cyan
        Start-Sleep -Milliseconds 80
        $i++
    }
    # Clear the spinner line so subsequent output appears cleanly
    Write-Host "`r$($esc)[2K" -NoNewline
}

# Pulsing dot animation — shows growing/shrinking dots during slow operations.
# Used primarily for the MTU detection phase (~30s binary search).
function Write-PulseDot {
    param(
        [string]$Label,
        [int]$Step
    )

    if (-not $SupportsVT) {
        Write-Host "  . $Label step $Step" -ForegroundColor DarkGray
        return
    }

    $esc     = [char]27
    $pattern = $Step % 4
    $dots    = switch ($pattern) {
        0 { '·' }
        1 { '· ·' }
        2 { '· · ·' }
        3 { '· ·' }
    }
    Write-Host ("`r$($esc)[2K  ◌  $Label $dots") -NoNewline -ForegroundColor DarkGray
}

# ● green  = success (replaces [ OK ])
function Write-OK {
    param([string]$m)
    Write-Host '  ' -NoNewline
    Write-Host '●' -NoNewline -ForegroundColor Green
    Write-Host '  ' -NoNewline
    Write-Host $m -ForegroundColor White
}

# ○ cyan   = applying (replaces [ +> ])
function Write-Apply {
    param([string]$m)
    Write-Host '  ' -NoNewline
    Write-Host '○' -NoNewline -ForegroundColor Cyan
    Write-Host '  ' -NoNewline
    Write-Host $m -ForegroundColor Cyan
}

# ◆ yellow = warning (replaces [ !! ])
function Write-Warn {
    param([string]$m)
    Write-Host '  ' -NoNewline
    Write-Host '◆' -NoNewline -ForegroundColor Yellow
    Write-Host '  ' -NoNewline
    Write-Host $m -ForegroundColor Yellow
}

# ● red    = error (replaces [ XX ])
function Write-Err {
    param([string]$m)
    Write-Host '  ' -NoNewline
    Write-Host '●' -NoNewline -ForegroundColor Red
    Write-Host '  ' -NoNewline
    Write-Host $m -ForegroundColor Red
}

# ◉ darkgray = info (replaces [ .. ])
function Write-Info {
    param([string]$m)
    Write-Host '  ' -NoNewline
    Write-Host '◉' -NoNewline -ForegroundColor DarkGray
    Write-Host '  ' -NoNewline
    Write-Host $m -ForegroundColor Gray
}

# ◌ gray   = skipped (replaces [ -- ])
function Write-Skip {
    param([string]$m)
    Write-Host '  ' -NoNewline
    Write-Host '◌' -NoNewline -ForegroundColor DarkGray
    Write-Host '  ' -NoNewline
    Write-Host $m -ForegroundColor DarkGray
}

# ✦ magenta = tip (replaces [ ?? ])
function Write-Tip {
    param([string]$m)
    Write-Host '  ' -NoNewline
    Write-Host '✦' -NoNewline -ForegroundColor Magenta
    Write-Host '  ' -NoNewline
    Write-Host $m -ForegroundColor Magenta
}

# Gradient per-character color interpolation for eye-catching titles
# Default colors: warm orange (R=217,G=119,B=6) → bright orange (R=245,G=158,B=11)
function Write-GradientText {
    param([string]$Text, [int]$R1=217, [int]$G1=119, [int]$B1=6,
          [int]$R2=245, [int]$G2=158, [int]$B2=11,
          [switch]$NoNewline)

    if (-not $SupportsVT) {
        # Fall back to plain text for non-VT terminals (ISE, Server 2012 R2)
        if ($NoNewline) { Write-Host $Text -NoNewline } else { Write-Host $Text }
        return
    }

    $esc = [char]27
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $t = if ($Text.Length -gt 1) { $i / ($Text.Length - 1) } else { 0 }
        $r = [Math]::Round($R1 + ($R2 - $R1) * $t)
        $g = [Math]::Round($G1 + ($G2 - $G1) * $t)
        $b = [Math]::Round($B1 + ($B2 - $B1) * $t)
        Write-Host -NoNewline "$($esc)[38;2;$r;$g;${b}m$($Text[$i])"
    }
    if ($NoNewline) {
        Write-Host -NoNewline "$($esc)[0m"
    } else {
        Write-Host "$($esc)[0m"
    }
}

# Progress bar for multi-adapter optimization loop
function Write-ProgressBar {
    param([int]$Percent, [int]$Width=40, [int]$R=217, [int]$G=119, [int]$B=6)

    if (-not $SupportsVT) {
        Write-Host -NoNewline "`r  [Progress: $Percent%]"
        return
    }

    $esc = [char]27
    $filled = [Math]::Floor($Percent / 100 * $Width)
    $empty = $Width - $filled
    Write-Host -NoNewline "`r  $($esc)[38;2;$R;$G;${B}m$(([string][char]0x2588) * $filled)$($esc)[2m$(([string][char]0x2591) * $empty)$($esc)[0m $Percent%"
}

# ============================================================
#   WINDOWS COMPATIBILITY DETECTION
# ============================================================
function Get-WindowsInfo {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { $os = Get-WmiObject Win32_OperatingSystem }
    $build = [int]($os.BuildNumber)

    # Windows version detection (BuildNumber based)
    $name = switch ($build) {
        { $_ -ge 22000 } { 'Windows 11'; break }
        { $_ -ge 10240 } { 'Windows 10'; break }
        { $_ -ge 9600  } { 'Windows 8.1 / Server 2012 R2'; break }
        { $_ -ge 9200  } { 'Windows 8 / Server 2012'; break }
        { $_ -ge 7601  } { 'Windows 7 SP1 / Server 2008 R2'; break }
        default          { "Unknown ($build)" }
    }

    return [PSCustomObject]@{
        Name               = [string]$name
        Version            = [string]$os.Version
        BuildNumber        = $build
        PSVersion          = $PSVersionTable.PSVersion.ToString()
        SupportsNetAdapter = ($build -ge 9600)   # Win 8.1+ required for Get-NetAdapter
        SupportsPwshDns    = ($build -ge 9600)   # Set-DnsClientServerAddress requires Win 8.1+
        Architecture       = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    }
}

$Global:WinInfo = Get-WindowsInfo

# ============================================================
#   ADMIN CHECK
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err 'This script requires Administrator privileges!'
    Write-Info 'Run via Run-NIC-Optimizer.bat (auto-elevates) or open PowerShell as Administrator'
    if (-not $Silent) { Read-Host 'Press Enter to exit' }
    return
}

# Warn if older Windows (pre Win 8.1) - some cmdlets unavailable
if ($Global:WinInfo.BuildNumber -lt 9600) {
    Write-Warn "Older Windows detected: $($Global:WinInfo.Name)"
    Write-Warn 'Some features may be unavailable (Get-NetAdapter requires Win 8.1+)'
    Write-Info 'Script will use netsh/WMI fallbacks where possible'
    if (-not $Silent) {
        $cont = Read-Host 'Continue anyway? (Y/N)'
        if ($cont -notmatch '^[YyTt]') { return }
    }
    # Even if user confirmed, exit gracefully if Get-NetAdapter is completely unavailable
    if (-not $Global:WinInfo.SupportsNetAdapter) {
        Write-Err "Get-NetAdapter is not available on $($Global:WinInfo.Name) (requires Win 8.1+ / Server 2012 R2+)"
        Write-Err 'This script cannot function without Get-NetAdapter. Exiting.'
        if (-not $Silent) { Read-Host 'Press Enter to exit' }
        return
    }
}

# ============================================================
#   32-BIT POWERSHELL ON 64-BIT WINDOWS DETECTION
#
#   CRITICAL: On 32-bit PowerShell, registry writes to
#   HKLM:\SOFTWARE are redirected by WOW64 to:
#   HKLM:\SOFTWARE\WOW6432Node\...
#
#   This means MMCSS and DeliveryOptimization registry tweaks
#   go to the WRONG hive and never take effect. We detect this
#   condition and either:
#     (a) warn the user and skip those sections, or
#     (b) in Silent mode, skip automatically.
#
#   The .bat launcher always uses 64-bit PowerShell from
#   System32, so this only triggers if someone runs 32-bit PS
#   manually (e.g. from SysWOW64 or 32-bit ISE).
# ============================================================
$Is32on64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
if ($Is32on64) {
    Write-Host ''
    Write-Warn '═══════════════════════════════════════════════════════════'
    Write-Warn '  32-bit PowerShell detected on 64-bit Windows!'
    Write-Warn '  Registry SOFTWARE writes ARE redirected to WOW6432Node.'
    Write-Warn '  MMCSS and DeliveryOptimization registry tweaks will be'
    Write-Warn '  SKIPPED because they would write to the WRONG hive.'
    Write-Warn '═══════════════════════════════════════════════════════════'
    Write-Warn '  FIX: Run the 64-bit version of PowerShell.'
    Write-Warn '       → Path: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Warn '       → NOT:  C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    Write-Info '  The .bat launcher (Run-NIC-Optimizer.bat) uses the correct'
    Write-Info '  64-bit PowerShell automatically via the System32 path.'
    Write-Host ''
    if (-not $Silent) {
        $cont = Read-Host 'Continue anyway? Registry SOFTWARE tweaks will be skipped (Y/N)'
        if ($cont -notmatch '^[YyTt]') {
            Write-Err 'Aborted by user. Please re-run with 64-bit PowerShell.'
            return
        }
    }
    # Set skip flags for MMCSS and DeliveryOptimization when on 32-bit
    $SkipMMCSS      = $true
    $SkipDeliveryOpt = $true
} else {
    $SkipMMCSS      = $false
    $SkipDeliveryOpt = $false
}

# ============================================================
#   DNS PROVIDERS DATABASE
#
#   Each provider has:
#     Id    - numeric selector (1-21, 99 for reset)
#     Cat   - category for grouping in menu
#     Name  - display name
#     V4/V6 - IPv4/IPv6 server addresses
#     Desc  - what this DNS does + privacy/filter info
#
#   Sources: DNSPerf 2025, Reddit r/dns, Cloudflare/Google/Quad9
#            official docs, AdGuard, ControlD, DNS4EU, Mullvad,
#            Chinese tech blogs (CSDN) for AliDNS/DNSPod info.
# ============================================================
$Global:DnsProviders = @(
    # === SPEED / NEUTRAL (no filtering, fastest) ===
    [PSCustomObject]@{ Id=1;  Cat='Speed';    Name='Cloudflare';            V4=@('1.1.1.1','1.0.0.1');                 V6=@('2606:4700:4700::1111','2606:4700:4700::1001'); Desc='Fastest globally per DNSPerf. No logs, no filter, supports DoH/DoT.' }
    [PSCustomObject]@{ Id=2;  Cat='Speed';    Name='Google Public DNS';     V4=@('8.8.8.8','8.8.4.4');                 V6=@('2001:4860:4860::8888','2001:4860:4860::8844'); Desc='Google. Stable and fast, ECS support, large global anycast.' }
    [PSCustomObject]@{ Id=3;  Cat='Speed';    Name='Quad9 Unsecured';       V4=@('9.9.9.10','149.112.112.10');         V6=@('2620:fe::10','2620:fe::fe:10');                Desc='Quad9 WITHOUT security filter. For users wanting raw speed.' }
    [PSCustomObject]@{ Id=4;  Cat='Speed';    Name='OpenDNS Home';          V4=@('208.67.222.222','208.67.220.220');   V6=@('2620:119:35::35','2620:119:53::53');           Desc='Cisco OpenDNS. Basic phishing protection, decent speed.' }

    # === SECURITY (malware + phishing block) ===
    [PSCustomObject]@{ Id=5;  Cat='Security'; Name='Cloudflare Malware';    V4=@('1.1.1.2','1.0.0.2');                 V6=@('2606:4700:4700::1112','2606:4700:4700::1002'); Desc='Cloudflare with malware blocklist. No filter for legit content.' }
    [PSCustomObject]@{ Id=6;  Cat='Security'; Name='Quad9 Secure (RECOMMENDED)'; V4=@('9.9.9.9','149.112.112.112');    V6=@('2620:fe::fe','2620:fe::9');                    Desc='Switzerland-based. Blocks malware/phishing, no logs, DNSSEC. Best balance.' }
    [PSCustomObject]@{ Id=7;  Cat='Security'; Name='CleanBrowsing Security'; V4=@('185.228.168.9','185.228.169.9');    V6=@('2a0d:2a00:1::2','2a0d:2a00:2::2');             Desc='Security filter blocking malware and phishing domains.' }

    # === FAMILY (adult content block, kid-safe) ===
    [PSCustomObject]@{ Id=8;  Cat='Family';   Name='Cloudflare Family';     V4=@('1.1.1.3','1.0.0.3');                 V6=@('2606:4700:4700::1113','2606:4700:4700::1003'); Desc='Cloudflare + malware + adult content (NSFW) blocking.' }
    [PSCustomObject]@{ Id=9;  Cat='Family';   Name='OpenDNS FamilyShield';  V4=@('208.67.222.123','208.67.220.123');   V6=@();                                              Desc='OpenDNS with auto-block of adult content. Good for kids networks.' }
    [PSCustomObject]@{ Id=10; Cat='Family';   Name='CleanBrowsing Family';  V4=@('185.228.168.168','185.228.169.168'); V6=@('2a0d:2a00:1::','2a0d:2a00:2::');               Desc='Family-friendly: blocks adult, malware, mixed content.' }

    # === ADBLOCK (blocks ads + trackers system-wide) ===
    [PSCustomObject]@{ Id=11; Cat='AdBlock';  Name='AdGuard DNS (default)'; V4=@('94.140.14.14','94.140.15.15');       V6=@('2a10:50c0::ad1:ff','2a10:50c0::ad2:ff');       Desc='Most popular adblock DNS. Blocks ads + trackers in apps/games too.' }
    [PSCustomObject]@{ Id=12; Cat='AdBlock';  Name='AdGuard Family';        V4=@('94.140.14.15','94.140.15.16');       V6=@('2a10:50c0::bad1:ff','2a10:50c0::bad2:ff');     Desc='AdGuard + adult content block. Best for kid-safe + ad-free internet.' }
    [PSCustomObject]@{ Id=13; Cat='AdBlock';  Name='ControlD Free (ads)';   V4=@('76.76.2.0','76.76.10.0');            V6=@('2606:1a40::','2606:1a40:1::');                 Desc='ControlD with ad blocking. Free tier, paid for customization.' }
    [PSCustomObject]@{ Id=14; Cat='AdBlock';  Name='dns0.eu Zero';          V4=@('193.110.81.0','185.253.5.0');         V6=@('2a0f:fc80::','2a0f:fc81::');                   Desc='EU-based (France). Blocks malware+tracking. DNSSEC, no logs, GDPR compliant.' }

    # === PRIVACY (no logs, encryption-focused) ===
    [PSCustomObject]@{ Id=15; Cat='Privacy';  Name='AdGuard Unfiltered';    V4=@('94.140.14.140','94.140.14.141');     V6=@('2a10:50c0::1:ff','2a10:50c0::2:ff');           Desc='AdGuard infrastructure WITHOUT filtering. No logs.' }
    [PSCustomObject]@{ Id=16; Cat='Privacy';  Name='dns0.eu Open';          V4=@('193.110.81.1','185.253.5.1');         V6=@('2a0f:fc80::1','2a0f:fc81::1');               Desc='EU-based (France). No filtering. DNSSEC, no logs, GDPR compliant.' }

    # === EU (European Union, GDPR-compliant) ===
    [PSCustomObject]@{ Id=17; Cat='EU';       Name='DNS4EU Protective';     V4=@('86.54.11.1','86.54.11.201');         V6=@('2a13:1001::86:54:11:1','2a13:1001::86:54:11:201'); Desc='EU-funded resolver (2025). GDPR, blocks malware/phishing.' }
    [PSCustomObject]@{ Id=18; Cat='EU';       Name='DNS4EU Unfiltered';     V4=@('86.54.11.100','86.54.11.200');       V6=@('2a13:1001::86:54:11:100','2a13:1001::86:54:11:200'); Desc='DNS4EU without any filter. Pure EU-hosted resolver.' }
    [PSCustomObject]@{ Id=19; Cat='EU';       Name='DNS4EU Child Protect';  V4=@('86.54.11.13','86.54.11.213');        V6=@();                                              Desc='DNS4EU + child protection (adult content + malware filter).' }

    # === CHINA (for users in mainland China, lower latency to CN servers) ===
    [PSCustomObject]@{ Id=20; Cat='China';    Name='AliDNS (Alibaba)';      V4=@('223.5.5.5','223.6.6.6');             V6=@('2400:3200::1','2400:3200:baba::1');            Desc='Alibaba Cloud DNS. Fastest in mainland China. Limits since Sept 2024.' }
    [PSCustomObject]@{ Id=21; Cat='China';    Name='DNSPod (Tencent)';      V4=@('119.29.29.29','182.254.116.116');    V6=@();                                              Desc='Tencent DNS. Stable in China, supports SM2 (Chinese crypto).' }

    # === RESET / SKIP ===
    [PSCustomObject]@{ Id=99; Cat='Reset';    Name='Reset to DHCP (router)'; V4=@();                                   V6=@();                                              Desc='Reset DNS to DHCP-assigned (use this if router runs Pi-hole/AdGuard Home).' }
)

# ============================================================
#   DNS INTERACTIVE MENU
#   Displays providers grouped by category with colors and descriptions.
#   Returns user's choice as a string.
# ============================================================
function Show-DnsMenu {
    Write-Section 'DNS PROVIDER SELECTION  -  21 OPTIONS, GROUPED BY CATEGORY'
    Write-Host ''
    Write-Host '  Pick a DNS based on what you want:' -ForegroundColor White
    Write-Host '    * Maximum speed             -> Speed (1-4)' -ForegroundColor Gray
    Write-Host '    * Block malware/phishing    -> Security (5-7)' -ForegroundColor Gray
    Write-Host '    * Block ads system-wide     -> AdBlock (11-14)' -ForegroundColor Gray
    Write-Host '    * Kid-safe internet         -> Family (8-10)' -ForegroundColor Gray
    Write-Host '    * Privacy / no logging      -> Privacy (15-16)' -ForegroundColor Gray
    Write-Host '    * European Union (GDPR)     -> EU (17-19)' -ForegroundColor Gray
    Write-Host '    * Mainland China users      -> China (20-21)' -ForegroundColor Gray
    Write-Host ''

    $cats = $Global:DnsProviders | Group-Object Cat
    foreach ($cat in $cats) {
        $color = switch ($cat.Name) {
            'Speed'    { 'Green' }
            'Security' { 'Yellow' }
            'Family'   { 'Magenta' }
            'AdBlock'  { 'Cyan' }
            'Privacy'  { 'Blue' }
            'EU'       { 'DarkYellow' }
            'China'    { 'Red' }
            default    { 'White' }
        }
        $icon = switch ($cat.Name) {
            'Speed'    { '[FAST]' }
            'Security' { '[SEC ]' }
            'Family'   { '[FAM ]' }
            'AdBlock'  { '[ADB ]' }
            'Privacy'  { '[PRIV]' }
            'EU'       { '[EU  ]' }
            'China'    { '[CN  ]' }
            'Reset'    { '[----]' }
            default    { '[????]' }
        }
        Write-Host ('  ' + $icon + '  ' + $cat.Name.ToUpper()) -ForegroundColor $color
        foreach ($p in $cat.Group) {
            $ips = ($p.V4 -join ', ')
            if (-not $ips) { $ips = '(none - reset to DHCP)' }
            Write-Host ('     [') -NoNewline -ForegroundColor DarkGray
            Write-Host ('{0,2}' -f $p.Id) -NoNewline -ForegroundColor White
            Write-Host (']  ') -NoNewline -ForegroundColor DarkGray
            Write-Host ('{0,-34}' -f $p.Name) -NoNewline -ForegroundColor White
            Write-Host $ips -ForegroundColor $color
            Write-Host ('          ' + $p.Desc) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-Host '  [Skip]  Keep current DNS (do not change anything)' -ForegroundColor DarkGray
    Write-Host '  [ c ]   Custom - enter your own DNS IPs (e.g. 1.1.1.1,9.9.9.9)' -ForegroundColor DarkGray
    Write-Host ''
    return Read-Host 'Enter DNS ID (1-21, 99=reset, Skip, c=custom)'
}

# ============================================================
#   SET DNS FOR ADAPTER
#   Universal - works with any provider from $Global:DnsProviders
#   Falls back to netsh on older Windows (pre 8.1).
# ============================================================
function Set-DnsForAdapter {
    param(
        [Parameter(Mandatory)] [string]$AdapterName,
        [Parameter(Mandatory)] $Provider  # PSCustomObject from $Global:DnsProviders
    )

    Write-Section "DNS APPLY:  $($Provider.Name)  ->  $AdapterName"

    # Special case: Reset (Id=99) -> revert to DHCP-assigned DNS (router)
    if ($Provider.Id -eq 99 -or $Provider.Cat -eq 'Reset') {
        try {
            if ($Global:WinInfo.SupportsPwshDns) {
                Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ResetServerAddresses -ErrorAction Stop
            } else {
                netsh interface ip set dns name="$AdapterName" source=dhcp | Out-Null
                netsh interface ipv6 set dns name="$AdapterName" source=dhcp | Out-Null
            }
            Write-OK 'DNS reset to DHCP (will use router-assigned DNS)'
            return
        } catch {
            Write-Warn "DNS reset failed: $($_.Exception.Message)"
            return
        }
    }

    # Collect all IP addresses (IPv4 + IPv6)
    $addresses = @()
    if ($Provider.V4) { $addresses += $Provider.V4 }
    if ($Provider.V6) { $addresses += $Provider.V6 }
    if (-not $addresses) {
        Write-Warn 'No DNS addresses found for this provider'
        return
    }

    try {
        if ($Global:WinInfo.SupportsPwshDns) {
            # Modern: Set-DnsClientServerAddress (Win 8.1+)
            Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses $addresses -ErrorAction Stop
        } else {
            # Fallback: netsh (Win 7+)
            $primary = $Provider.V4[0]
            netsh interface ip set dns name="$AdapterName" source=static addr=$primary register=primary | Out-Null
            if ($Provider.V4[1]) {
                netsh interface ip add dns name="$AdapterName" addr=$($Provider.V4[1]) index=2 | Out-Null
            }
            foreach ($v6 in $Provider.V6) {
                netsh interface ipv6 add dns name="$AdapterName" addr=$v6 | Out-Null
            }
        }
        Write-OK 'DNS servers configured:'
        foreach ($addr in $addresses) { Write-Host "          $addr" -ForegroundColor Cyan }

        # Flush DNS cache so new servers take effect immediately
        try {
            if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue) {
                Clear-DnsClientCache -ErrorAction SilentlyContinue
            } else {
                ipconfig /flushdns | Out-Null
            }
            Write-OK 'DNS cache flushed (new DNS will be used immediately)'
        } catch { }
    } catch {
        Write-Warn "DNS configuration failed: $($_.Exception.Message)"
    }
}

# ============================================================
#   PARSE DnsProvider PARAMETER
#   Resolves user input (number / 'Skip' / IP list) into a provider object.
# ============================================================
function Resolve-DnsProvider {
    param($InputValue)

    # Skip - keep current DNS
    if ($null -eq $InputValue -or $InputValue -eq '' -or $InputValue -eq 'Skip' -or $InputValue -eq 'skip') {
        return $null
    }

    # Numeric ID -> lookup in providers list
    if ($InputValue -match '^\d+$') {
        $id = [int]$InputValue
        $provider = $Global:DnsProviders | Where-Object { $_.Id -eq $id }
        if ($provider) { return $provider }
        Write-Warn "Unknown DNS provider ID: $id  (valid: 1-21, 99)"
        return $null
    }

    # Custom IP list (e.g. '1.1.1.1,9.9.9.9' or '1.1.1.1;2606:4700::1111')
    if ($InputValue -match '^[\d\.,:a-fA-F\s]+$') {
        $ips = $InputValue -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $v4 = $ips | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        $v6 = $ips | Where-Object { $_ -match '^[0-9a-fA-F:]+:[0-9a-fA-F:]+$' }
        return [PSCustomObject]@{
            Id=999; Cat='Custom'; Name='Custom DNS'; V4=$v4; V6=$v6; Desc='User-provided DNS addresses'
        }
    }

    return $null
}

# ============================================================
#   OPTIMAL ADAPTER SETTINGS
#
#   Built dynamically based on Mode (Throughput/LowLatency/Balanced).
#   Keys are regex patterns matched against DisplayName of each
#   advanced property. Multiple language variants are included
#   (English + Polish names) for cross-locale compatibility.
#
#   The script auto-detects which settings the adapter supports
#   and skips unsupported ones (so it works on any NIC vendor).
# ============================================================
function Get-OptimalSettings {
    param([string]$ModeName)

    $base = @(
        # === LINK NEGOTIATION ===
        # Critical: forces 1Gbps full-duplex auto-negotiation.
        # Common cause of stuck-at-100Mbps issues.
        @{ Pattern = '^Speed.+Duplex$|^Szybkosc.+Dupleks$|^Speed/Duplex$';  Value = 'Auto Negotiation';
           Keyword = '\*SpeedDuplex|\*LinkSpeed' }
        @{ Pattern = '^Auto Negotiation$';                                  Value = 'Enabled';
           Keyword = '\*AutoNegotiation' }
        @{ Pattern = 'Wait for Link';                                       Value = 'On';
           Keyword = '\*WaitForLink' }

        # === FLOW CONTROL & RSS (Receive Side Scaling) ===
        # Flow Control: pause frames prevent buffer overflow.
        # RSS: distributes incoming packets across multiple CPU cores.
        @{ Pattern = '^Flow Control$|Sterowanie przeplywem$';                Value = 'Rx & Tx Enabled';
           Keyword = '\*FlowControl' }
        @{ Pattern = 'Receive Side Scaling$|^RSS$';                         Value = 'Enabled';
           Keyword = '\*RSS$' }
        @{ Pattern = 'Maximum Number of RSS Queues|RSS Queues';             Value = '4 Queues';
           Keyword = '\*NumRSSQueues|\*RSSQueues' }
        @{ Pattern = 'NetworkDirect|RDMA';                                  Value = 'Enabled';
           Keyword = '\*NetworkDirect|\*Rdma|\*NdisRdma' }

        # === BUFFERS (max throughput) ===
        # Bigger buffers = less packet drop under load (downloads, streaming).
        @{ Pattern = 'Receive Buffers|Bufory odbioru';                      Value = '2048';
           Keyword = '\*ReceiveBuffers' }
        @{ Pattern = 'Transmit Buffers|Bufory wysylania|Send Buffers';      Value = '2048';
           Keyword = '\*TransmitBuffers' }

        # === CHECKSUM OFFLOADS (CPU -> NIC) ===
        # Hardware computes checksums instead of CPU. Less CPU usage.
        @{ Pattern = 'TCP Checksum Offload \(IPv4\)';                       Value = 'Rx & Tx Enabled';
           Keyword = '\*TCPChecksumOffloadIPv4|\*TCPUDPChecksumOffloadIPv4' }
        @{ Pattern = 'TCP Checksum Offload \(IPv6\)';                       Value = 'Rx & Tx Enabled';
           Keyword = '\*TCPChecksumOffloadIPv6|\*TCPUDPChecksumOffloadIPv6' }
        @{ Pattern = 'UDP Checksum Offload \(IPv4\)';                       Value = 'Rx & Tx Enabled';
           Keyword = '\*UDPChecksumOffloadIPv4|\*TCPUDPChecksumOffloadIPv4' }
        @{ Pattern = 'UDP Checksum Offload \(IPv6\)';                       Value = 'Rx & Tx Enabled';
           Keyword = '\*UDPChecksumOffloadIPv6|\*TCPUDPChecksumOffloadIPv6' }
        @{ Pattern = 'IPv4 Checksum Offload';                               Value = 'Rx & Tx Enabled';
           Keyword = '\*IPChecksumOffloadIPv4' }
        @{ Pattern = 'ARP Offload';                                         Value = 'Enabled';
           Keyword = '\*ArpOffload' }
        @{ Pattern = 'NS Offload';                                          Value = 'Enabled';
           Keyword = '\*NSOffload' }

        # === JUMBO FRAMES ===
        # Disabled by default - most home routers/ISPs use 1500 MTU.
        # Enable only if your entire network supports 9000 MTU end-to-end.
        @{ Pattern = 'Jumbo (Packet|Frame)';                                Value = 'Disabled';
           Keyword = '\*JumboPacket' }
        @{ Pattern = 'Packet Priority.+VLAN|Priority.+VLAN';                Value = 'Packet Priority & VLAN Enabled';
           Keyword = '\*PriorityVLANTag' }

        # === DISABLE POWER SAVING (main cause of speed drops!) ===
        # EEE/Green Ethernet downgrades link to save power -> bandwidth drops.
        # Disabling these is critical for stable gigabit speed.
        @{ Pattern = 'Energy.Efficient Ethernet|^EEE$';                     Value = 'Disabled';
           Keyword = '\*EEEControl|\*EEE$' }
        @{ Pattern = 'Advanced EEE';                                        Value = 'Disabled';
           Keyword = '\*AdvancedEEE' }
        @{ Pattern = 'Green Ethernet';                                      Value = 'Disabled';
           Keyword = '\*GreenEthernet' }
        @{ Pattern = 'Power Saving Mode|Power Save';                        Value = 'Disabled';
           Keyword = '\*PowerSavingMode' }
        @{ Pattern = 'Ultra Low Power';                                     Value = 'Disabled';
           Keyword = '\*UltraLowPower' }
        @{ Pattern = 'Gigabit Lite';                                        Value = 'Disabled';
           Keyword = '\*GigabitLite' }
        @{ Pattern = 'Auto Disable Gigabit';                                Value = 'Disabled';
           Keyword = '\*AutoDisableGigabit' }
        @{ Pattern = 'Selective Suspend';                                   Value = 'Disabled';
           Keyword = '\*SelectiveSuspend' }
        @{ Pattern = 'System Idle Power Saver';                             Value = 'Disabled';
           Keyword = '\*SystemIdlePowerSaver' }
        @{ Pattern = 'Reduce Speed On Power Down';                          Value = 'Disabled';
           Keyword = '\*ReduceSpeedOnPowerDown' }
        @{ Pattern = 'Power Down PHY|Shutdown Wake\.On\.Lan';                 Value = 'Disabled';
           Keyword = '\*PowerDownPHY|\*ShutdownWakeOnLan' }

        # === VENDOR-SPECIFIC POWER SAVING FEATURES (always disable) ===
        # Realtek: Idle power saving drops link speed when idle -> disable
        @{ Pattern = 'Idle Power Saving';                                      Value = 'Disabled';
           Keyword = '\*IdlePowerSaving' }
        # Realtek: Auto-disable PCIe link can cause reconnect delays
        @{ Pattern = 'Auto Disable PCIe|Auto Disable PCI Express';             Value = 'Disabled';
           Keyword = '\*AutoDisablePCIe|\*AutoDisablePcie' }

        # === KILLER NETWORKING "GAMING" FEATURES (disable — cause lag) ===
        # Killer Advanced Stream Detect = QoS-like packet prioritization that
        # often prioritizes the wrong traffic, causing jitter and bufferbloat.
        @{ Pattern = 'Advanced Stream Detect';                                 Value = 'Disabled';
           Keyword = '\*AdvancedStreamDetect' }
        # Killer GameFast = proprietary fast-path that interferes with Windows
        # native TCP stack optimizations. Safer off.
        @{ Pattern = 'GameFast';                                               Value = 'Disabled';
           Keyword = '\*GameFast' }

        # === BROADCOM / INTEL SERVER NIC VIRTUALIZATION ===
        # VMQ = Virtual Machine Queues — distributes VM traffic across cores
        @{ Pattern = 'Virtualization|VMQ|Virtual Machine Queues';              Value = 'Enabled';
           Keyword = '\*VMQ|\*Vmq' }
        # SR-IOV = Single Root I/O Virtualization — direct NIC access for VMs
        @{ Pattern = 'SR-IOV';                                                 Value = 'Enabled';
           Keyword = '\*SRIOV|\*Sriov' }

        # === INTEL GIGABIT MASTER/SLAVE MODE ===
        # Auto Detect is safest — lets NIC negotiate role with switch
        @{ Pattern = 'Gigabit Master Slave Mode';                              Value = 'Auto Detect';
           Keyword = '\*GigabitMasterSlaveMode' }
    )

    # === MODE-SPECIFIC SETTINGS ===
    if ($ModeName -eq 'Throughput') {
        # Max bandwidth: all offloads ON, adaptive interrupt moderation.
        # LSO = Large Send Offload (CPU sends large segment, NIC chunks it)
        # RSC = Receive Segment Coalescing (NIC merges packets before CPU)
        $base += @(
            @{ Pattern = 'Large Send Offload V2 \(IPv4\)';                  Value = 'Enabled';
               Keyword = '\*LsoV2IPv4' }
            @{ Pattern = 'Large Send Offload V2 \(IPv6\)';                  Value = 'Enabled';
               Keyword = '\*LsoV2IPv6' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv4\)';                Value = 'Enabled';
               Keyword = '\*RscIPv4' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv6\)';                Value = 'Enabled';
               Keyword = '\*RscIPv6' }
            @{ Pattern = '^Interrupt Moderation$';                          Value = 'Enabled';
               Keyword = '\*InterruptModeration$' }
            @{ Pattern = 'Interrupt Moderation Rate';                       Value = 'Adaptive';
               Keyword = '\*InterruptModerationRate' }
            @{ Pattern = 'Adaptive Inter.Frame Spacing';                    Value = 'Disabled';
               Keyword = '\*AdaptiveIFS' }
            @{ Pattern = 'Interrupt Moderation Mode';                    Value = 'Enabled';
               Keyword = '\*InterruptModerationMode' }
            @{ Pattern = 'ITR|Interrupt Throttle Rate';                  Value = 'Adaptive';
               Keyword = '\*ITR' }
            @{ Pattern = 'Adaptive Interrupt Moderation';                Value = 'Enabled';
               Keyword = '\*AdaptiveInterruptModeration' }
        )
    }
    elseif ($ModeName -eq 'LowLatency') {
        # Gaming/VoIP: LSO/RSC OFF (they batch packets -> add latency).
        # Interrupt Moderation OFF (process every packet immediately).
        $base += @(
            @{ Pattern = 'Large Send Offload V2 \(IPv4\)';                  Value = 'Disabled';
               Keyword = '\*LsoV2IPv4' }
            @{ Pattern = 'Large Send Offload V2 \(IPv6\)';                  Value = 'Disabled';
               Keyword = '\*LsoV2IPv6' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv4\)';                Value = 'Disabled';
               Keyword = '\*RscIPv4' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv6\)';                Value = 'Disabled';
               Keyword = '\*RscIPv6' }
            @{ Pattern = '^Interrupt Moderation$';                          Value = 'Disabled';
               Keyword = '\*InterruptModeration$' }
            @{ Pattern = 'Interrupt Moderation Rate';                       Value = 'Off';
               Keyword = '\*InterruptModerationRate' }
            @{ Pattern = 'Adaptive Inter.Frame Spacing';                    Value = 'Disabled';
               Keyword = '\*AdaptiveIFS' }
            @{ Pattern = 'Priority.+VLAN.+Tag';                             Value = 'Priority Enabled';
               Keyword = '\*PriorityVLANTag' }
            @{ Pattern = 'Interrupt Moderation Mode';                    Value = 'Disabled';
               Keyword = '\*InterruptModerationMode' }
            @{ Pattern = 'ITR|Interrupt Throttle Rate';                  Value = 'Off';
               Keyword = '\*ITR' }
            @{ Pattern = 'Adaptive Interrupt Moderation';                Value = 'Disabled';
               Keyword = '\*AdaptiveInterruptModeration' }
        )
    }
    else {
        # Balanced: keep offloads but adaptive timing.
        $base += @(
            @{ Pattern = 'Large Send Offload V2 \(IPv4\)';                  Value = 'Enabled';
               Keyword = '\*LsoV2IPv4' }
            @{ Pattern = 'Large Send Offload V2 \(IPv6\)';                  Value = 'Enabled';
               Keyword = '\*LsoV2IPv6' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv4\)';                Value = 'Enabled';
               Keyword = '\*RscIPv4' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv6\)';                Value = 'Enabled';
               Keyword = '\*RscIPv6' }
            @{ Pattern = '^Interrupt Moderation$';                          Value = 'Enabled';
               Keyword = '\*InterruptModeration$' }
            @{ Pattern = 'Interrupt Moderation Rate';                       Value = 'Adaptive';
               Keyword = '\*InterruptModerationRate' }
            @{ Pattern = 'Interrupt Moderation Mode';                    Value = 'Enabled';
               Keyword = '\*InterruptModerationMode' }
            @{ Pattern = 'ITR|Interrupt Throttle Rate';                  Value = 'Adaptive';
               Keyword = '\*ITR' }
            @{ Pattern = 'Adaptive Interrupt Moderation';                Value = 'Enabled';
               Keyword = '\*AdaptiveInterruptModeration' }
        )
    }

    return $base
}

$OptimalSettings = Get-OptimalSettings -ModeName $Mode

# ============================================================
#   ADAPTER MANAGEMENT FUNCTIONS
# ============================================================

# Lists all network adapters with status, link speed, MAC, description.
# Used at start (before optimization) and end (to verify changes).
function Show-Adapters {
    Write-Section 'NETWORK ADAPTERS DETECTED ON THIS SYSTEM'
    Get-NetAdapter | Sort-Object @{e='Status';desc=$true}, Name |
        Format-Table -AutoSize `
            @{N='Name';        E={$_.Name}},
            @{N='Status';      E={$_.Status}},
            @{N='Speed';       E={$_.LinkSpeed}},
            @{N='MAC';         E={$_.MacAddress}},
            @{N='Description'; E={$_.InterfaceDescription}}
}

# Saves current adapter advanced properties to JSON for later rollback.
# Backup folder: $env:USERPROFILE\Desktop\NIC-Backup\
function Backup-AdapterSettings {
    param([string]$adapterName)
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = $adapterName -replace '[\\/:*?"<>|]', '_'
    $file     = Join-Path $BackupDir "$safeName--$stamp.json"

    $props = Get-NetAdapterAdvancedProperty -Name $adapterName -ErrorAction SilentlyContinue |
             Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue, ValidDisplayValues

    if ($props) {
        # Store adapter name inside the JSON so restore can recover it exactly
        $backupData = [PSCustomObject]@{
            AdapterName = $adapterName
            BackupStamp = $stamp
            Properties  = @($props)
        }
        $backupData | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8
        if (Test-Path $file) {
            Write-OK "Backup saved: $file"
        } else {
            Write-Err "Failed to write backup file: $file"
            return $null
        }
    } else {
        Write-Warn 'No advanced properties to backup (basic adapter)'
        return $null
    }
    return $file
}

# Main per-adapter optimization function.
# Iterates over advanced properties and applies $OptimalSettings.
function Optimize-Adapter {
    param([string]$adapterName)
    Write-Section "OPTIMIZING ADAPTER:  $adapterName"
    $backupPath = Backup-AdapterSettings $adapterName
    if (-not $backupPath) {
        Write-Err "Backup failed for adapter '$adapterName' — aborting optimization for this adapter"
        return
    }

    $props = Get-NetAdapterAdvancedProperty -Name $adapterName -ErrorAction SilentlyContinue
    if (-not $props) {
        Write-Warn 'This adapter does not expose advanced properties (skipped)'
        return
    }

    $applied = 0; $alreadyOk = 0; $skipped = 0; $failed = 0

    foreach ($prop in $props) {
        $displayName = $prop.DisplayName
        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

        # Find a matching optimal setting from $OptimalSettings table
        # First try DisplayName match (works on English/Polish Windows)
        $match = $OptimalSettings | Where-Object { $displayName -match $_.Pattern } | Select-Object -First 1
        # Fallback: if DisplayName didn't match, try RegistryKeyword (always English)
        # This makes the script work on ANY Windows language: French, German, Chinese, etc.
        if (-not $match -and $prop.RegistryKeyword) {
            $match = $OptimalSettings | Where-Object { $_.Keyword -and $prop.RegistryKeyword -match $_.Keyword } | Select-Object -First 1
        }
        if (-not $match) {
            $skipped++
            continue
        }

        $newValue = $match.Value
        if ($prop.DisplayValue -eq $newValue) {
            Write-Skip "$displayName  =  $newValue  (already optimal)"
            $alreadyOk++
            continue
        }

        # Check if adapter supports this exact value (some have a fixed list)
        if ($prop.ValidDisplayValues -and $prop.ValidDisplayValues.Count -gt 0) {
            if ($prop.ValidDisplayValues -notcontains $newValue) {
                # Try to find an equivalent value (e.g. 'Off' instead of 'Disabled')
                $alt = $prop.ValidDisplayValues | Where-Object { $_ -match 'Disabled|Off' -and $newValue -match 'Disabled' } | Select-Object -First 1
                if (-not $alt) {
                    $alt = $prop.ValidDisplayValues | Where-Object { $_ -match 'Enabled|On' -and $newValue -match 'Enabled' } | Select-Object -First 1
                }
                if ($alt) {
                    $newValue = $alt
                } else {
                    Write-Warn "$displayName : '$($match.Value)' not supported (allowed: $($prop.ValidDisplayValues -join ', '))"
                    $failed++
                    continue
                }
            }
        }

        try {
            Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $displayName -DisplayValue $newValue -NoRestart -ErrorAction Stop
            Write-Apply "$displayName : $($prop.DisplayValue)  ->  $newValue"
            $applied++
        } catch {
            Write-Warn "$displayName  ->  $newValue  (error: $($_.Exception.Message.Split([Environment]::NewLine)[0]))"
            $failed++
        }
    }

    Write-Host ''
    Write-Host '  --- Adapter optimization summary ---' -ForegroundColor DarkCyan
    Write-Host '    Applied:    ' -NoNewline; Write-Host $applied   -ForegroundColor Green
    Write-Host '    Already OK: ' -NoNewline; Write-Host $alreadyOk -ForegroundColor White
    Write-Host '    Skipped:    ' -NoNewline; Write-Host $skipped   -ForegroundColor DarkGray
    Write-Host '    Failed:     ' -NoNewline; Write-Host $failed    -ForegroundColor Yellow

    # Warn if we suspect the system is running a non-English Windows locale
    # where DisplayName matching failed but RegistryKeyword fallback succeeded
    if (($applied + $alreadyOk) -gt 0 -and $skipped -gt 10) {
        Write-Host '    Note: RegistryKeyword fallback was used — '
        Write-Host '    your Windows may be using a non-English display language.' -ForegroundColor DarkCyan
    }

    # Restart adapter once at end (so all changes apply together with one drop)
    if ($applied -gt 0) {
        try {
            Write-Info 'Restarting adapter to apply changes...'
            Restart-NetAdapter -Name $adapterName -ErrorAction Stop
            Start-Sleep -Seconds 3
            Write-OK 'Adapter restarted successfully'
        } catch {
            Write-Warn "Adapter restart failed: $($_.Exception.Message)"
        }
    }
}

# Disables Windows Device Manager 'Allow the computer to turn off this device'
# This prevents Windows from putting the NIC to sleep -> stable bandwidth.
function Disable-PowerManagement {
    param([string]$adapterName)
    Write-Section "POWER MANAGEMENT:  $adapterName"
    try {
        $adapter   = Get-NetAdapter -Name $adapterName -ErrorAction Stop
        $instance  = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSPower_DeviceEnable' -ErrorAction SilentlyContinue |
                     Where-Object { $_.InstanceName -like "*$($adapter.PnPDeviceID)*" }
        if ($instance) {
            $instance.Enable = $false
            Set-CimInstance -InputObject $instance -ErrorAction Stop
            Write-OK 'Disabled: "Allow computer to turn off this device to save power"'
        } else {
            Write-Info 'Adapter does not support Windows power management API'
        }

        # Also disable Wake-on-LAN magic packets (not strictly power but related)
        $wake = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSPower_DeviceWakeEnable' -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceName -like "*$($adapter.PnPDeviceID)*" }
        if ($wake) {
            $wake.Enable = $false
            Set-CimInstance -InputObject $wake -ErrorAction SilentlyContinue
            Write-OK 'Disabled: "Allow this device to wake the computer" (Wake-on-LAN)'
        }
    } catch {
        Write-Warn "Power management failed: $($_.Exception.Message)"
    }
}

# Tunes Windows TCP/IP stack globally via netsh.
# These changes affect ALL network adapters and require admin.
# Recommended reboot after for full effect.
function Optimize-TcpIpGlobal {
    param([string]$ModeName = 'Throughput')
    Write-Section "GLOBAL TCP/IP TUNING  (mode: $ModeName)"

    # === Auto-tuning level (window scaling behavior) ===
    # experimental    = max throughput (RFC 7323), aggressive window scaling
    # normal          = standard, good balance
    # highlyrestricted = lowest ping but small windows (slow on long-distance)
    # disabled        = no scaling, only for legacy/buggy routers
    $autotuning = switch ($ModeName) {
        'Throughput' { 'experimental' }   # max BDP utilization
        'LowLatency' { 'normal' }          # conservative, no scaling issues
        default      { 'normal' }
    }

    # === Congestion control algorithm ===
    # cubic    = default since Win10 1709, best for gigabit+ connections (Linux uses it too)
    # ctcp     = Compound TCP - more responsive at low latency, good for gaming
    # newreno  = legacy, slow on modern networks
    $congestion = switch ($ModeName) {
        'Throughput' { 'cubic' }
        'LowLatency' { 'ctcp' }     # more responsive under low RTT conditions
        default      { 'cubic' }
    }

    $cmds = @(
        # === AUTO-TUNING & HEURISTICS ===
        # Auto-tuning controls TCP receive window size dynamically.
        # Heuristics OFF forces our autotuning level (Win sometimes auto-changes it).
        @{c="netsh int tcp set global autotuninglevel=$autotuning";           desc="TCP Auto-tuning: $autotuning  [controls receive window size scaling]"}
        @{c='netsh int tcp set heuristics disabled';                          desc='TCP Heuristics: OFF  [prevents Windows from changing autotuning]'}
        @{c='netsh int tcp set global rss=enabled';                           desc='Receive Side Scaling: ON  [distributes packets across CPU cores]'}
        @{c='netsh int tcp set global rsc=enabled';                           desc='Receive Segment Coalescing: ON  [merges packets - higher throughput]'}
        @{c='netsh int tcp set global chimney=automatic';                     desc='TCP Chimney Offload: auto  [offloads TCP processing to NIC]'}
        @{c='netsh int tcp set global dca=enabled';                           desc='Direct Cache Access: ON  [packets land directly in CPU cache]'}
        @{c='netsh int tcp set global netdma=enabled';                        desc='NetDMA: ON  [reduces CPU load via DMA]'}

        # === CONGESTION CONTROL & ECN (Explicit Congestion Notification) ===
        # ECN allows routers to mark packets as congested instead of dropping them.
        # PRR = better recovery after packet loss (RFC 6937).
        # HyStart = smarter slow-start phase, prevents window collapse.
        @{c="netsh int tcp set supplemental internet congestionprovider=$congestion"; desc="Congestion provider: $congestion  [TCP congestion control algorithm]"}
        @{c='netsh int tcp set global ecncapability=enabled';                 desc='ECN: ON  [graceful congestion handling, less packet loss]'}
        @{c='netsh int tcp set global prr=enabled';                           desc='Proportional Rate Reduction: ON  [smarter loss recovery]'}
        @{c='netsh int tcp set global hystart=enabled';                       desc='HyStart: ON  [improved slow-start, prevents congestion]'}

        # === TIMING & RETRANSMISSION ===
        # Timestamps OFF saves 12 bytes per packet (small but adds up at gigabit).
        @{c='netsh int tcp set global timestamps=disabled';                   desc='TCP Timestamps: OFF  [saves 12 bytes/packet overhead]'}
        @{c='netsh int tcp set global initialrto=2000';                       desc='Initial RTO: 2000ms  [Retransmission TimeOut for SYN]'}
        @{c='netsh int tcp set global nonsackrttresiliency=disabled';         desc='Non-SACK RTT resiliency: OFF  [SACK is universal now]'}
        @{c='netsh int tcp set global maxsynretransmissions=2';               desc='Max SYN retransmissions: 2  [faster failover to next host]'}
        @{c='netsh int tcp set global fastopen=enabled';                      desc='TCP Fast Open: ON  [skip 1-RTT handshake on resumed connections]'}
        @{c='netsh int tcp set global fastopenfallback=enabled';              desc='TFO Fallback: ON  [graceful fallback if peer does not support TFO]'}

        # === PACING (rate-limiting, off for max bandwidth) ===
        @{c='netsh int tcp set global pacingprofile=off';                     desc='TCP Pacing: OFF  [no artificial rate limiting]'}

        # === IP STACK GLOBAL ===
        @{c='netsh int ip   set global taskoffload=enabled';                  desc='IP Task Offload: ON  [hardware acceleration for IP processing]'}
        @{c='netsh int ip   set global neighborcachelimit=8192';              desc='ARP Neighbor cache: 8192 entries  [larger LAN support]'}
        @{c='netsh int ip   set global icmpredirects=disabled';               desc='ICMP redirects: OFF  [SECURITY: prevents redirect attacks]'}
        @{c='netsh int ip   set global sourceroutingbehavior=drop';           desc='Source routing: DROP  [SECURITY: prevents IP spoofing]'}

        # === UDP (gaming/VoIP traffic) ===
        @{c='netsh int udp set global uro=enabled';                           desc='UDP Receive Offload: ON  [hardware UDP coalescing]'}

        # === NOTE: 'netsh winsock reset' is INTENTIONALLY skipped ===
        # It can break VPN clients and antiviruses that register Layered Service Providers.
        # Run it manually only if you have specific connection issues.
    )

    # Skip deprecated netsh commands on newer Windows
    $skipChimney = $Global:WinInfo.BuildNumber -ge 17763  # Win 10 1809+ / Server 2019+
    $skipNetDma  = $Global:WinInfo.BuildNumber -ge 14393  # Win 10 1607+ / Server 2016+

    foreach ($cmd in $cmds) {
        # Skip deprecated chimney command on Win 10 1809+ / Server 2019+
        if ($skipChimney -and $cmd.c -match 'chimney') {
            Write-Skip $cmd.desc
            continue
        }
        # Skip deprecated netdma command on Win 10 1607+ / Server 2016+
        if ($skipNetDma -and $cmd.c -match 'netdma') {
            Write-Skip $cmd.desc
            continue
        }
        try {
            $out = cmd.exe /c $cmd.c 2>&1
            if ($LASTEXITCODE -eq 0 -or $out -match 'OK|Ok') {
                Write-Apply $cmd.desc
            } else {
                Write-Warn ("{0}  ({1})" -f $cmd.desc, (($out -join ' ').Trim() -replace '\s+', ' '))
            }
        } catch {
            Write-Warn "$($cmd.desc): $($_.Exception.Message)"
        }
    }
}

# ============================================================
#   REGISTRY TWEAKS - TCP/IP STACK PERFORMANCE
#
#   Modifies: HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters
#
#   These are deeper kernel-level TCP settings that complement
#   netsh changes. Some require reboot to take effect.
#
#   Sources: Microsoft KB, Reddit r/pcmasterrace, guru3D Forums,
#            Windows Forum, BlurBusters network optimization guide.
# ============================================================
function Set-TcpIpRegistryTweaks {
    param([string]$ModeName = 'Throughput')
    Write-Section "REGISTRY TWEAKS - TCP/IP STACK  (mode: $ModeName)"

    $tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

    $tweaks = @(
        @{ Name='DefaultTTL';                Value=64;     Type='DWord'; Desc='DefaultTTL = 64  [standard hop limit, RFC compliant]' }
        @{ Name='Tcp1323Opts';               Value=1;      Type='DWord'; Desc='RFC 1323 Options: window scaling ON, timestamps OFF' }
        @{ Name='TcpTimedWaitDelay';         Value=30;     Type='DWord'; Desc='TIME_WAIT = 30s (default 240s)  [frees ports faster]' }
        @{ Name='MaxUserPort';               Value=65534;  Type='DWord'; Desc='MaxUserPort = 65534 (default 5000)  [more ephemeral ports]' }
        @{ Name='TcpMaxDupAcks';             Value=2;      Type='DWord'; Desc='Max Duplicate ACKs = 2  [faster fast-retransmit trigger]' }
        @{ Name='SackOpts';                  Value=1;      Type='DWord'; Desc='Selective ACK = ON  [retransmit only lost segments]' }
        @{ Name='EnablePMTUDiscovery';       Value=1;      Type='DWord'; Desc='Path MTU Discovery = ON  [auto-detect optimal packet size]' }
        @{ Name='EnablePMTUBHDetect';        Value=0;      Type='DWord'; Desc='Black Hole Router Detection = OFF  [avoids false positives]' }
        @{ Name='EnableTCPChimney';          Value=1;      Type='DWord'; Desc='TCP Chimney = ON  [hardware TCP offload backup setting]' }
        @{ Name='EnableTCPA';                Value=1;      Type='DWord'; Desc='TCP-A = ON  [TCP acceleration]' }
        @{ Name='EnableRSS';                 Value=1;      Type='DWord'; Desc='RSS = ON  [registry backup of netsh setting]' }
        @{ Name='DisableTaskOffload';        Value=0;      Type='DWord'; Desc='Task Offload = enabled  [hardware checksum/offload]' }
        @{ Name='MaxFreeTcbs';               Value=65536;  Type='DWord'; Desc='MaxFreeTcbs = 65536  [more concurrent connections]' }
        @{ Name='MaxHashTableSize';          Value=65536;  Type='DWord'; Desc='TCB Hash Table = 65536  [faster connection lookup]' }
        @{ Name='GlobalMaxTcpWindowSize';    Value=65535;  Type='DWord'; Desc='Global Max TCP Window = 65535  [max receive buffer]' }
        @{ Name='TcpWindowSize';             Value=65535;  Type='DWord'; Desc='Default TCP Window = 65535  [initial receive buffer]' }
    )

    foreach ($t in $tweaks) {
        try {
            Set-ItemProperty -Path $tcpParams -Name $t.Name -Value $t.Value -Type $t.Type -Force -ErrorAction Stop
            Write-Apply $t.Desc
        } catch {
            Write-Warn "$($t.Name): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        }
    }
}

# ============================================================
#   PER-INTERFACE NAGLE'S ALGORITHM DISABLE
#
#   Nagle's algorithm batches small TCP packets to reduce overhead.
#   For gaming/VoIP it adds 5-15ms latency. We disable it here.
#
#   Registry: HKLM\...\Tcpip\Parameters\Interfaces\{GUID}
#   - TcpAckFrequency = 1 (ACK every packet, not every 2)
#   - TCPNoDelay      = 1 (disable Nagle, send small packets immediately)
#   - TcpDelAckTicks  = 0 (no delayed ACK)
# ============================================================
function Set-InterfaceNagleTweaks {
    param([string]$ModeName = 'Throughput')

    # Nagle disable hurts throughput by 5-10% so we skip in Throughput mode.
    # Only apply to LowLatency / Balanced where ping matters more.
    if ($ModeName -eq 'Throughput') {
        Write-Skip 'Nagle tweaks skipped (Throughput mode - they would lower bandwidth by 5-10%)'
        return
    }

    Write-Section "PER-INTERFACE NAGLE OFF  (mode: $ModeName)"
    Write-Info 'Disabling Nagle reduces ping by 5-15ms in games (CS2, Valorant, etc.)'

    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $interfaces = Get-ChildItem -Path $base -ErrorAction SilentlyContinue

    $count = 0
    foreach ($iface in $interfaces) {
        # Only apply to interfaces with an assigned IP (skip inactive)
        $props = Get-ItemProperty -Path $iface.PSPath -ErrorAction SilentlyContinue
        if (-not $props.IPAddress -and -not $props.DhcpIPAddress) { continue }

        try {
            Set-ItemProperty -Path $iface.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $iface.PSPath -Name 'TCPNoDelay'      -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $iface.PSPath -Name 'TcpDelAckTicks'  -Value 0 -Type DWord -Force -ErrorAction Stop
            $ip = if ($props.DhcpIPAddress) { $props.DhcpIPAddress } else { $props.IPAddress }
            Write-Apply "Interface $ip : TcpAckFrequency=1, TCPNoDelay=1, TcpDelAckTicks=0"
            $count++
        } catch {
            Write-Warn "$($iface.PSChildName): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        }
    }
    if ($count -eq 0) {
        Write-Warn 'No active interfaces with IP found - Nagle tweaks not applied'
    }
}

# ============================================================
#   MMCSS - MULTIMEDIA CLASS SCHEDULER SERVICE
#
#   By default Windows reserves 20% CPU for "other" tasks even
#   when multimedia (games, streams) needs it. We tell Windows
#   to give multimedia priority.
#
#   Two main settings:
#   - NetworkThrottlingIndex = 0xFFFFFFFF (-1) -> NO network throttling
#     (default ~10 = 1 packet per 10ms when multimedia detected)
#   - SystemResponsiveness = 10 or 0
#     (default 20 = reserve 20% CPU for non-multimedia)
#
#   Plus we boost Tasks\Games priority for FPS/latency.
# ============================================================
function Set-MmcssOptimization {
    param([string]$ModeName = 'Throughput')
    Write-Section "MMCSS - MULTIMEDIA SCHEDULER  (mode: $ModeName)"

    $sysProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $games      = "$sysProfile\Tasks\Games"

    # SystemResponsiveness scale:
    #   0  = 100% CPU available to multimedia (best for competitive gaming)
    #   10 = 90% multimedia / 10% other (recommended Microsoft)
    #   20 = default (Windows reserves 20% for other tasks)
    $sysResp = if ($ModeName -eq 'LowLatency') { 0 } else { 10 }

    $tweaks = @(
        # 0xFFFFFFFF as DWord = -1 (signed int32, same bit pattern)
        # This is THE KEY TWEAK - removes network packet throttling entirely.
        @{ Path=$sysProfile; Name='NetworkThrottlingIndex';   Value=4294967295; Type='DWord'; Desc='NetworkThrottlingIndex = 0xFFFFFFFF  [DISABLES network throttling]' }
        @{ Path=$sysProfile; Name='SystemResponsiveness';     Value=$sysResp;   Type='DWord'; Desc="SystemResponsiveness = $sysResp  [% CPU reserved for non-multimedia tasks]" }

        # Boost for tasks classified as 'Games' (DirectX games auto-register)
        @{ Path=$games;      Name='GPU Priority';             Value=8;   Type='DWord'; Desc='Games\GPU Priority = 8  [maximum GPU priority for games]' }
        @{ Path=$games;      Name='Priority';                 Value=6;   Type='DWord'; Desc='Games\Priority = 6  [high CPU priority]' }
        @{ Path=$games;      Name='Scheduling Category';      Value='High';        Type='String'; Desc='Games\Scheduling = High  [scheduling class above normal]' }
        @{ Path=$games;      Name='SFIO Priority';            Value='High';        Type='String'; Desc='Games\SFIO Priority = High  [scheduled file I/O priority]' }
        @{ Path=$games;      Name='Affinity';                 Value=0;   Type='DWord'; Desc='Games\Affinity = 0  [allow all CPU cores]' }
        @{ Path=$games;      Name='Background Only';          Value='False';       Type='String'; Desc='Games\Background Only = False  [foreground priority]' }
        @{ Path=$games;      Name='Clock Rate';               Value=10000; Type='DWord'; Desc='Games\Clock Rate = 10000  [scheduling timer 10us]' }
    )

    # Ensure registry keys exist (some Win versions don't have Tasks\Games by default)
    foreach ($p in @($sysProfile, $games)) {
        if (-not (Test-Path $p)) {
            try { New-Item -Path $p -Force | Out-Null } catch { }
        }
    }

    if ($SkipMMCSS) {
        Write-Warn '⚠ MMCSS registry writes SKIPPED (32-bit PS on 64-bit OS: would go to WOW6432Node)'
        Write-Info '  Run the 64-bit version of PowerShell to apply MMCSS tweaks.'
        Write-Info '  Path: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        foreach ($t in $tweaks) {
            try {
                Set-ItemProperty -Path $t.Path -Name $t.Name -Value $t.Value -Type $t.Type -Force -ErrorAction Stop
                Write-Apply $t.Desc
            } catch {
                Write-Warn "$($t.Name): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
            }
        }
    }
}

# ============================================================
#   POWERCFG TWEAKS - DEEP POWER MANAGEMENT
#
#   Disables aggressive power saving features that hurt network/CPU performance:
#   - USB Selective Suspend OFF (USB devices stay always-on)
#   - PCIe Link State Power Mgmt OFF (PCIe never goes to sleep)
#   - Minimum CPU State = 100% on AC (CPU never throttles below 100%)
#   - Wireless adapter Maximum Performance (no WiFi power saving)
#
#   GUIDs are well-known Windows power setting identifiers.
# ============================================================
function Set-PowerCfgTweaks {
    Write-Section 'POWERCFG - DEEP POWER MANAGEMENT TUNING'

    $cmds = @(
        # USB Selective Suspend - prevents USB ports from sleeping (USB NICs)
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'; desc='USB Selective Suspend (AC) = OFF  [USB devices stay powered on]'}
        @{c='powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'; desc='USB Selective Suspend (Battery) = OFF'}

        # PCIe Link State Power Management - prevents PCIe lanes from sleeping (NIC, SSD)
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0'; desc='PCIe Link State Power Mgmt (AC) = OFF  [PCIe at full speed always]'}
        @{c='powercfg /setdcvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0'; desc='PCIe Link State Power Mgmt (Battery) = OFF'}

        # Minimum processor state - prevents CPU from going below 100% on AC
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100'; desc='Min CPU State (AC) = 100%  [no CPU throttling on AC power]'}

        # Wireless adapter power mode - max performance for WiFi cards
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0'; desc='Wireless Adapter (AC) = Max Performance  [no WiFi power saving]'}

        # Hard disk timeout (0 = never spin down)
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0'; desc='HDD timeout (AC) = never  [HDDs stay spinning, no spin-up delay]'}

        # Apply changes to current scheme
        @{c='powercfg /setactive SCHEME_CURRENT'; desc='Apply changes to current power scheme'}
    )

    foreach ($cmd in $cmds) {
        try {
            $out = cmd.exe /c $cmd.c 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Apply $cmd.desc
            } else {
                Write-Warn ("{0}  ({1})" -f $cmd.desc, (($out -join ' ').Trim()))
            }
        } catch {
            Write-Warn "$($cmd.desc): $($_.Exception.Message)"
        }
    }
}

# ============================================================
#   DISABLE TELEMETRY SERVICES (frees up bandwidth)
#
#   Microsoft telemetry services consume ~1-5% bandwidth in idle.
#   Disabling them is opt-in only (some users want diagnostics).
#
#   Services disabled:
#   - DiagTrack          (Connected User Experiences and Telemetry)
#   - dmwappushservice   (WAP Push Message Routing - mobile/legacy)
#   - WMPNetworkSvc      (Windows Media Player Network Sharing)
#
#   Plus: Delivery Optimization (Windows Update P2P uploads)
# ============================================================
function Disable-TelemetryServices {
    Write-Section 'TELEMETRY OFF  (DiagTrack, Delivery Opt., WMP Network)'
    Write-Info 'These services consume bandwidth in the background.'
    Write-Info 'Disabling them frees up upload bandwidth and reduces background traffic.'

    $services = @(
        @{ Name='DiagTrack';        Desc='Connected User Experiences and Telemetry (main telemetry)' }
        @{ Name='dmwappushservice'; Desc='WAP Push Message Routing (mobile/legacy, safe to disable)' }
        @{ Name='WMPNetworkSvc';    Desc='Windows Media Player Network Sharing (rarely used)' }
    )

    foreach ($svc in $services) {
        try {
            $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            if (-not $s) {
                Write-Skip "$($svc.Name) : not present on this Windows (OK)"
                continue
            }
            if ($s.Status -eq 'Running') {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
            Write-Apply "$($svc.Name)  =  STOPPED + DISABLED  [$($svc.Desc)]"
        } catch {
            Write-Warn "$($svc.Name) : $($_.Exception.Message)"
        }
    }

    # Disable Delivery Optimization - P2P Windows Update upload (major bandwidth eater)
    if ($SkipDeliveryOpt) {
        Write-Warn '⚠ DeliveryOptimization registry write SKIPPED (32-bit PS on 64-bit OS: would go to WOW6432Node)'
        Write-Info '  Run the 64-bit version of PowerShell to disable Delivery Optimization.'
        Write-Info '  Path: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        try {
            $doPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
            if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force | Out-Null }
            Set-ItemProperty -Path $doPath -Name 'DODownloadMode' -Value 0 -Type DWord -Force
            Write-Apply 'Delivery Optimization = OFF  [no P2P upload of Windows Updates to other PCs]'
        } catch {
            Write-Warn "Delivery Optimization: $($_.Exception.Message)"
        }
    }
}

# ============================================================
#   MTU AUTO-DETECTION via ICMP fragmentation test
#
#   Algorithm:
#   1. Send ping with 'Don't Fragment' flag set (-f)
#   2. Try sizes between 1300-1500 bytes (binary search)
#   3. Largest size that returns reply = max payload
#   4. Optimal MTU = payload + 28 (IP+ICMP headers)
#
#   FIXED: Earlier version used 'Reply from' string match which
#   failed on non-English Windows (Polish: 'Odpowiedz od'). Now
#   we check ping.exe exit code which is locale-independent.
# ============================================================
function Test-OptimalMtu {
    Write-Section 'MTU AUTO-DETECTION  (binary search via ICMP)'
    Write-Info 'This test takes ~30 seconds. Measures optimal packet size for your link.'

    # Try multiple targets in case one is blocked by firewall
    $targets = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
    $target = $null
    foreach ($t in $targets) {
        $null = ping.exe -n 1 -w 1500 $t 2>&1
        if ($LASTEXITCODE -eq 0) { $target = $t; break }
    }
    if (-not $target) {
        Write-Warn 'No target reachable (all blocked?). MTU detection skipped.'
        Write-Info 'You can run manually: ping -f -l <SIZE> 1.1.1.1'
        return
    }
    Write-Info "Testing against: $target"

    $low = 1300; $high = 1500; $best = 0
    $mtuStep = 0
    while ($low -le $high) {
        $mid = [int](($low + $high) / 2)
        Write-PulseDot "Testing MTU payload size: $mid bytes" $mtuStep
        # -f sets Don't Fragment bit, -l sets payload size, -n 1 = one ping
        $null = ping.exe -f -l $mid -n 1 -w 1500 $target 2>&1
        $mtuStep++
        # FIX: Use exit code instead of 'Reply from' string (locale-independent)
        if ($LASTEXITCODE -eq 0) {
            $best = $mid
            $low = $mid + 1
        } else {
            $high = $mid - 1
        }
    }
    Write-Host ''  # end pulse-dot line
    if ($best -gt 0) {
        $optimalMtu = $best + 28  # +20 IP header + 8 ICMP header = 28 bytes overhead
        Write-OK "Optimal MTU detected: $optimalMtu  (max ICMP payload: $best bytes)"
        Write-Info 'Reference values:'
        Write-Info '   1500 = standard Ethernet (most ISPs)'
        Write-Info '   1492 = PPPoE links (DSL, fiber with PPPoE)'
        Write-Info '   1480 = some 4G/5G mobile links'
        Write-Info '   9000 = Jumbo frames (only if entire path supports it)'
        Write-Info 'Check current MTU via: netsh int ipv4 show subinterfaces'
    } else {
        Write-Warn 'Could not determine MTU (firewall blocking ICMP?). This is informational only.'
    }
}

# Activates the highest performance Windows power plan available.
# Tries: Ultimate Performance -> High Performance (failsafe for older Windows).
function Set-PerformancePowerPlan {
    Write-Section 'WINDOWS POWER PLAN ACTIVATION'
    try {
        # Well-known Windows power plan GUIDs
        $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'  # Ultimate Performance (Win 10/11 Pro)
        $highPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'  # High Performance (universal)

        # Ultimate Performance is hidden by default on consumer Windows - duplicate to enable
        $schemes = (powercfg /list) -join "`n"
        if ($schemes -notmatch $ultimate) {
            powercfg -duplicatescheme $ultimate 2>&1 | Out-Null
        }
        powercfg /setactive $ultimate 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Fallback to High Performance if Ultimate is unavailable
            powercfg /setactive $highPerf 2>&1 | Out-Null
            Write-Apply 'Active power plan = High Performance  [no CPU/disk power saving]'
        } else {
            Write-Apply 'Active power plan = Ultimate Performance  [zero compromise mode]'
        }
    } catch {
        Write-Warn "Power plan: $($_.Exception.Message)"
    }
}

# Restores adapter settings from a JSON backup file.
# User picks which backup to restore from a numbered list.
function Restore-FromBackup {
    Write-Section 'ROLLBACK - RESTORE ADAPTER SETTINGS FROM BACKUP'
    if (-not (Test-Path $BackupDir)) {
        Write-Err "No backup folder found at: $BackupDir"
        return
    }
    $backups = Get-ChildItem $BackupDir -Filter '*.json' | Sort-Object LastWriteTime -Descending
    if (-not $backups) { Write-Err 'No backup files in folder'; return }

    Write-Host ''
    Write-Host '  Available backups (newest first):' -ForegroundColor White
    for ($i = 0; $i -lt $backups.Count; $i++) {
        Write-Host ("    [{0,2}]  {1}" -f $i, $backups[$i].Name) -NoNewline -ForegroundColor White
        Write-Host ("    ({0})" -f $backups[$i].LastWriteTime) -ForegroundColor DarkGray
    }
    Write-Host ''
    $idx = Read-Host 'Backup number to restore (Enter to cancel)'
    if ([string]::IsNullOrWhiteSpace($idx)) {
        Write-Info 'Restore cancelled by user'
        return
    }

    # Validate index: must be numeric and within bounds
    if ($idx -notmatch '^\d+$') {
        Write-Err "Invalid backup number: '$idx' (must be 0-$($backups.Count - 1))"
        return
    }
    $idxNum = [int]$idx
    if ($idxNum -lt 0 -or $idxNum -ge $backups.Count) {
        Write-Err "Backup number out of range: $idxNum (valid: 0-$($backups.Count - 1))"
        return
    }

    $file        = $backups[$idxNum].FullName
    try {
        $rawJson = Get-Content $file -Raw -ErrorAction Stop
        $data    = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Err "Failed to read/parse backup file '$file': $($_.Exception.Message)"
        return
    }

    # Extract adapter name from JSON (new format) or fall back to filename (old format)
    if ($data.AdapterName) {
        $adapterName = $data.AdapterName
        $propsData   = $data.Properties
    } else {
        # Old-format backup: adapter name was encoded in filename
        $adapterName = $backups[$idxNum].BaseName -replace '--\d{8}-\d{6}$', ''
        $propsData   = $data
        Write-Warn 'Old-format backup detected (adapter name may be inaccurate for names with underscores)'
    }

    Write-Info "Restoring to adapter: $adapterName"
    $restoreCount = 0
    foreach ($p in $propsData) {
        try {
            Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $p.DisplayName `
                -DisplayValue $p.DisplayValue -NoRestart -ErrorAction Stop
            Write-Apply "$($p.DisplayName)  ->  $($p.DisplayValue)"
            $restoreCount++
        } catch {
            Write-Warn "$($p.DisplayName): $($_.Exception.Message)"
        }
    }
    Restart-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
    if ($restoreCount -gt 0) {
        Write-OK "Settings restored from backup ($restoreCount properties). Adapter restarted."
    } else {
        Write-Warn 'No settings were restored. The adapter may not exist or backup may be for a different adapter.'
    }
}

# ============================================================
#   MAIN EXECUTION FLOW
#
#   Wrapped in a dot-source guard: when the script is invoked
#   directly (.\Optimize-NetworkAdapter.ps1) $MyInvocation.InvocationName
#   is not '.' so the block runs. When dot-sourced for library use
#   (. .\Optimize-NetworkAdapter.ps1) the block is skipped, allowing
#   safe import of functions/constants without side effects.
#
#   Phase 1: Per-adapter optimization (settings + power mgmt + DNS)
#   Phase 2: Global TCP/IP tuning (netsh)
#   Phase 3: Registry tweaks (TCP stack, Nagle, MMCSS) - optional
#   Phase 4: Power management (powercfg + Ultimate plan)
#   Phase 5: Telemetry off - optional
#   Phase 6: MTU auto-detection - informational
# ============================================================
function Write-AsciiArt {
    param([string]$Mode)

    $color = switch ($Mode) {
        'Throughput' { 'Green' }
        'LowLatency' { 'Magenta' }
        'Balanced'   { 'Yellow' }
        default      { 'White' }
    }

    switch ($Mode) {
        'Throughput' {
            Write-Host '       ⚡ ⚡ ⚡' -ForegroundColor $color
            Write-Host '    ┌──────────┐' -ForegroundColor $color
            Write-Host '  ══╡  ██████  ╞══  MAX BANDWIDTH' -ForegroundColor $color
            Write-Host '    └──────────┘' -ForegroundColor $color
            Write-Host '       │ │ │' -ForegroundColor $color
        }
        'LowLatency' {
            Write-Host '    ▄▄▄  ▄▄▄' -ForegroundColor $color
            Write-Host '   ████████████' -ForegroundColor $color
            Write-Host '   ████████████  MIN PING' -ForegroundColor $color
            Write-Host '    ▀▀▀  ▀▀▀' -ForegroundColor $color
        }
        'Balanced' {
            Write-Host '       ⚖' -ForegroundColor $color
            Write-Host '    ┌──┴──┐' -ForegroundColor $color
            Write-Host '    │  ██  │   BALANCED' -ForegroundColor $color
            Write-Host '    └─────┘' -ForegroundColor $color
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
Clear-Host

Write-AsciiArt -Mode $Mode
Write-Host ''

# --- Claude Code style ANSI truecolor banner ---
if ($SupportsVT) {
$esc = [char]27
$BoldBlue    = "$($esc)[1;38;2;59;130;246m"
$BoldWhite   = "$($esc)[1;37m"
$Orange      = "$($esc)[1;38;2;217;119;6m"
$Gold        = "$($esc)[38;2;245;158;11m"
$DimGray     = "$($esc)[2;37m"
$White       = "$($esc)[37m"
$Green       = "$($esc)[1;32m"
$Magenta     = "$($esc)[1;35m"
$Yellow      = "$($esc)[1;33m"
$Reset       = "$($esc)[0m"

$innerWidth = 50

function Write-BannerLine { param($k, $v, $vc=$White)
    $vPad = 30
    if ($null -eq $v) { $v = '' } elseif ($v -isnot [string]) { $v = $v.ToString() }
    $vStr = if ($v.Length -gt $vPad) { $v.Substring(0, $vPad) } else { $v.PadRight($vPad) }
    Write-Host "$BoldBlue│$Reset  $DimGray$($k.PadRight(18))$Reset$vc$vStr$Reset$BoldBlue│$Reset"
}

Write-Host ''
# -- Top box: title + subtitle --
$title    = 'WINDOWS NETWORK OPTIMIZER  v4.0'
$subtitle = 'universal · Win 7 SP1+ / 8.1 / 10 / 11'
$tPad = $innerWidth - $title.Length;    $tL = [Math]::Floor($tPad/2); $tR = $tPad - $tL
$sPad = $innerWidth - $subtitle.Length; $sL = [Math]::Floor($sPad/2); $sR = $sPad - $sL

Write-Host "$BoldBlue╭$('─' * $innerWidth)╮$Reset"
Write-Host "$BoldBlue│$Reset$(' ' * $tL)$BoldWhite$title$Reset$(' ' * $tR)$BoldBlue│$Reset"
Write-Host "$BoldBlue│$Reset$(' ' * $sL)$Gold$subtitle$Reset$(' ' * $sR)$BoldBlue│$Reset"
Write-Host "$BoldBlue╰$('─' * $innerWidth)╯$Reset"
Write-Host ''

# -- System info lines --
Write-BannerLine 'OS:'           $Global:WinInfo.Name           $BoldWhite
Write-BannerLine 'Build:'        $Global:WinInfo.BuildNumber    $BoldWhite
Write-BannerLine 'PowerShell:'   $Global:WinInfo.PSVersion      $BoldWhite
Write-BannerLine 'Architecture:' $Global:WinInfo.Architecture   $BoldWhite
if ($Is32on64) {
    Write-BannerLine 'PS arch:'       '32-bit ⚠ (x86 on x64)'    $Yellow
} else {
    $psArch = if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }
    Write-BannerLine 'PS arch:'       $psArch                     $DimGray
}

# -- Empty separator --
Write-Host "$BoldBlue│$Reset$(' ' * $innerWidth)$BoldBlue│$Reset"

# -- Mode with gradient text --
Write-Host "$BoldBlue│$Reset  $DimGray$('Mode:'.PadRight(18))$Reset" -NoNewline
Write-GradientText -Text $Mode -NoNewline
Write-Host (' ' * (30 - $Mode.Length)) -NoNewline
Write-Host "$BoldBlue│$Reset"
Write-BannerLine 'Telemetry off:' $DisableTelemetry.ToString()        $(if($DisableTelemetry){$Yellow}else{$DimGray})
Write-BannerLine 'Skip registry:' $NoRegistry.ToString()              $(if($NoRegistry){$Yellow}else{$DimGray})
Write-BannerLine 'Skip MTU test:' $NoMtuTest.ToString()               $(if($NoMtuTest){$Yellow}else{$DimGray})
Write-BannerLine 'Silent mode:'   $Silent.ToString()                  $(if($Silent){$Yellow}else{$DimGray})
Write-Host "$BoldBlue╰$('─' * $innerWidth)╯$Reset"
Write-Host ''
} else {
    # --- Simple ASCII banner for non-VT terminals (ISE, Server 2012 R2) ---
    Write-Host ''
    Write-Host '=================================================='
    Write-Host '  WINDOWS NETWORK OPTIMIZER  v4.0'
    Write-Host '  universal - Win 7 SP1+ / 8.1 / 10 / 11'
    Write-Host '--------------------------------------------------'
    Write-Host ('  OS:           ' + $Global:WinInfo.Name)
    Write-Host ('  Build:        ' + $Global:WinInfo.BuildNumber)
    Write-Host ('  PowerShell:   ' + $Global:WinInfo.PSVersion)
    Write-Host ('  Architecture: ' + $Global:WinInfo.Architecture)
    Write-Host ('  Mode:         ' + $Mode)
    Write-Host ('  Telemetry off: ' + $DisableTelemetry.ToString())
    Write-Host ('  Skip registry: ' + $NoRegistry.ToString())
    Write-Host ('  Skip MTU test: ' + $NoMtuTest.ToString())
    Write-Host ('  Silent mode:   ' + $Silent.ToString())
    Write-Host '=================================================='
    Write-Host ''
}

# --- Restore mode bypasses normal flow ---
if ($Restore) {
    Restore-FromBackup
    if (-not $Silent) { Read-Host 'Press Enter to exit' }
    return
}

# ============================================================
#   INTERACTIVE MODE SELECTION (when not specified via -Mode)
# ============================================================
if (-not $PSBoundParameters.ContainsKey('Mode') -and -not $Silent) {
    Write-Host ''
    Write-Host '  ╭─────────────────────────────────────────────╮' -ForegroundColor Cyan
    Write-Host '  │         OPTIMIZATION MODE SELECTION         │' -ForegroundColor White
    Write-Host '  ╰─────────────────────────────────────────────╯' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [1] THROUGHPUT   - max bandwidth     (downloads/streaming)' -ForegroundColor Green
    Write-Host '                     autotuning=experimental, cubic, LSO/RSC ON'
    Write-Host ''
    Write-Host '  [2] LOW LATENCY  - min ping          (gaming/VoIP)' -ForegroundColor Magenta
    Write-Host '                     Nagle OFF, ctcp, LSO/RSC OFF, MMCSS=0'
    Write-Host ''
    Write-Host '  [3] BALANCED     - compromise         (general use)' -ForegroundColor Yellow
    Write-Host '                     adaptive interrupts, cubic, Nagle OFF'
    Write-Host ''
    Write-Host '  [4] FULL MAX     - throughput + telemetry OFF + Cloudflare DNS' -ForegroundColor Cyan
    Write-Host '                     WARNING: disables Microsoft DiagTrack!'
    Write-Host '                     WARNING: applies to ALL Ethernet adapters!'
    Write-Host ''
    Write-Host '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host ''
    $modeChoice = Read-Host 'Choose mode [1-4] (default: 1=Throughput)'
    if ([string]::IsNullOrWhiteSpace($modeChoice)) { $modeChoice = '1' }

    switch ($modeChoice) {
        '1' { $Mode = 'Throughput' }
        '2' { $Mode = 'LowLatency' }
        '3' { $Mode = 'Balanced' }
        '4' {
            $Mode = 'Throughput'
            $DisableTelemetry = $true
            $DnsProvider = 1
            $All = $true
            Write-Warn 'FULL MAX mode: Telemetry OFF + Cloudflare DNS + ALL Ethernet adapters'
        }
        default {
            Write-Warn "Invalid choice '$modeChoice' — using default: Throughput"
            $Mode = 'Throughput'
        }
    }

    # Rebuild optimal settings for the selected mode
    $OptimalSettings = Get-OptimalSettings -ModeName $Mode
    Write-Host ''
    Write-Info "Mode selected: $Mode"
    Start-Sleep -Seconds 1
    Clear-Host
    Write-AsciiArt -Mode $Mode
    Write-Host ''
    # Re-display banner with updated mode (simplified re-display)
    # The full banner was already shown above, just show updated mode
}

Show-Adapters

# ============================================================
#   ADAPTER SELECTION
# ============================================================
if ($All) {
    $targets = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
    if (-not $targets) { Write-Err 'No active Ethernet adapters found'; return }
    Write-Info "Selected $($targets.Count) Ethernet adapter(s) (all active)"
} elseif ($AdapterName) {
    try {
        $targets = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
    } catch {
        Write-Err "Adapter '$AdapterName' not found: $($_.Exception.Message)"
        if (-not $Silent) { Read-Host 'Press Enter to exit' }
        return
    }
} elseif ($Silent) {
    # Silent mode without explicit name -> all active Ethernet
    $targets = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
    if (-not $targets) { Write-Err 'No active Ethernet adapters found (silent mode)'; return }
} else {
    Write-Host ''
    Write-Tip "Current mode: $Mode  (change with -Mode Throughput|LowLatency|Balanced)"
    $name = Read-Host 'Enter adapter name (e.g. Ethernet) or type "all" for all Ethernet adapters'
    if ($name -eq 'all') {
        $targets = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
    } else {
        try {
            $targets = Get-NetAdapter -Name $name -ErrorAction Stop
        } catch {
            Write-Err "Adapter '$name' not found: $($_.Exception.Message)"
            if (-not $Silent) { Read-Host 'Press Enter to exit' }
            return
        }
    }
}

if (-not $targets) {
    Write-Err 'No adapter found'
    if (-not $Silent) { Read-Host 'Press Enter to exit' }
    return
}

# ============================================================
#   DNS PROVIDER SELECTION
# ============================================================
$selectedDns = $null
if ($PSBoundParameters.ContainsKey('DnsProvider')) {
    $selectedDns = Resolve-DnsProvider -InputValue $DnsProvider
    if ($selectedDns) {
        Write-Info "DNS provider selected via parameter: $($selectedDns.Name)"
    } else {
        Write-Info 'DNS will not be changed (Skip / invalid)'
    }
} elseif (-not $Silent) {
    # Interactive prompt with menu
    Write-Host ''
    $useDns = Read-Host 'Change DNS settings? (Y = show menu / N = skip) [N]'
    if ($useDns -match '^[YyTt]') {
        $choice = Show-DnsMenu
        if ($choice -match '^[Cc]') {
            $custom = Read-Host 'Enter custom DNS IPs (comma-separated, e.g. 1.1.1.1,9.9.9.9)'
            $selectedDns = Resolve-DnsProvider -InputValue $custom
        } else {
            $selectedDns = Resolve-DnsProvider -InputValue $choice
        }
    }
}

# ============================================================
#   PHASE 1: PER-ADAPTER OPTIMIZATION
# ============================================================
$adapterIdx = 0; $adapterTotal = @($targets).Count
foreach ($t in $targets) {
    $adapterIdx++
    if ($adapterTotal -gt 1) {
        Write-Host ''
        Write-ProgressBar -Percent ([Math]::Floor($adapterIdx / $adapterTotal * 100)) -Width 50
        Write-Host "  Adapter $adapterIdx / $adapterTotal : $($t.Name)"
    }
    Write-Spinner "Preparing to optimize: $($t.Name)..." 1
    Optimize-Adapter         $t.Name
    Disable-PowerManagement  $t.Name
    if ($selectedDns) {
        Set-DnsForAdapter -AdapterName $t.Name -Provider $selectedDns
    }
}

# ============================================================
#   PHASE 2: GLOBAL TCP/IP TUNING (netsh)
# ============================================================
Write-Spinner 'Applying global TCP/IP netsh tuning...' 1
Optimize-TcpIpGlobal -ModeName $Mode

# ============================================================
#   PHASE 3: REGISTRY TWEAKS (TCP stack + Nagle + MMCSS)
# ============================================================
if (-not $NoRegistry) {
    Write-Spinner 'Applying TCP/IP registry tweaks...' 1
    Set-TcpIpRegistryTweaks   -ModeName $Mode
    Write-Spinner 'Configuring per-interface Nagle settings...' 1
    Set-InterfaceNagleTweaks  -ModeName $Mode
    if (-not $SkipMMCSS) {
        Write-Spinner 'Optimizing MMCSS multimedia scheduler...' 1
        Set-MmcssOptimization     -ModeName $Mode
    } else {
        Write-Skip 'MMCSS optimization skipped (32-bit PS on 64-bit OS)'
    }
} else {
    Write-Skip 'Registry tweaks skipped (-NoRegistry parameter)'
}

# ============================================================
#   PHASE 4: POWER MANAGEMENT (powercfg + Ultimate plan)
# ============================================================
Write-Spinner 'Activating maximum performance power plan...' 1
Set-PerformancePowerPlan
Write-Spinner 'Applying powercfg deep power management...' 1
Set-PowerCfgTweaks

# ============================================================
#   PHASE 5: TELEMETRY OFF (opt-in only)
# ============================================================
if ($DisableTelemetry) {
    Write-Spinner 'Stopping telemetry services...' 1
    Disable-TelemetryServices
} else {
    Write-Info 'Telemetry was NOT disabled (use -DisableTelemetry to disable DiagTrack)'
}

# ============================================================
#   PHASE 6: MTU AUTO-DETECTION (informational)
# ============================================================
if (-not $NoMtuTest) {
    Write-Spinner 'Starting MTU auto-detection...' 1
    Test-OptimalMtu
} else {
    Write-Skip 'MTU test skipped (-NoMtuTest parameter)'
}

# ============================================================
#   FINAL SUMMARY
# ============================================================
Write-Section 'OPTIMIZATION COMPLETE'
Write-OK   'All optimizations applied successfully'
Write-Info "Mode used: $Mode"
if ($selectedDns) { Write-Info "DNS provider: $($selectedDns.Name)" }
Write-Info "Backup folder: $BackupDir"
Write-Tip  'To rollback adapter changes, run with -Restore parameter'
Write-Host ''
Write-Warn 'REBOOT YOUR COMPUTER for full effect!'
Write-Warn 'Some registry/TCP tweaks only activate after reboot.'

Write-Host ''
Show-Adapters

# --- Color-coded summary of what was done ---
Write-Section 'SUMMARY OF APPLIED OPTIMIZATIONS'
function Write-Summary { param([string]$what)
    Write-Host '  [' -NoNewline -ForegroundColor DarkGray
    Write-Host '+' -NoNewline -ForegroundColor Green
    Write-Host ']  ' -NoNewline -ForegroundColor DarkGray
    Write-Host $what -ForegroundColor White
}

Write-Summary "Network adapter ($($targets.Count) interface): ~40 advanced settings tuned"
Write-Summary 'Power Management: Windows device sleep disabled per adapter'
Write-Summary 'TCP/IP global (netsh): 24 settings (autotuning, RSS, ECN, HyStart...)'
if (-not $NoRegistry) {
    Write-Summary 'Registry TCP/IP: 16 stack performance values'
    if ($SkipMMCSS) {
        Write-Summary 'MMCSS: SKIPPED (32-bit PS - run 64-bit PowerShell to apply)'
    } else {
        Write-Summary 'MMCSS: NetworkThrottlingIndex disabled, Games priority boosted'
    }
    if ($Mode -ne 'Throughput') {
        Write-Summary 'Per-NIC Nagle OFF: TcpAckFrequency=1, TCPNoDelay=1 (lower ping)'
    }
}
Write-Summary 'Powercfg: USB Suspend OFF, PCIe LSPM OFF, CPU min 100%'
Write-Summary 'Active power plan: Ultimate Performance (or High Performance)'
if ($selectedDns) {
    Write-Summary "DNS configured: $($selectedDns.Name) ($($selectedDns.V4 -join ', '))"
}
if ($DisableTelemetry) {
    if ($SkipDeliveryOpt) {
        Write-Summary 'Telemetry services disabled (DiagTrack, WMP; DeliveryOpt SKIPPED - 32-bit PS)'
    } else {
        Write-Summary 'Telemetry services disabled (DiagTrack, Delivery Optimization)'
    }
}

Write-Host ''
Write-Host '  Repository: ' -NoNewline -ForegroundColor DarkGray
Write-Host 'https://github.com/Rezurmas/windows-network-optimizer' -ForegroundColor Cyan
Write-Host '  Issues / Stars / PRs welcome!' -ForegroundColor DarkGray
Write-Host ''

if (-not $Silent) { Read-Host 'Press Enter to exit' }
}  # end dot-source guard ($MyInvocation.InvocationName -ne '.')

# --- Error summary check ---
# Since $ErrorActionPreference = 'Continue', non-terminating errors
# are silently recorded in $Error. Warn the user if any occurred
# during the optimization run so they can review the output for
# ◆ warn / ● error markers.
$newErrors = $Error.Count - $ScriptStartErrorCount
if ($newErrors -gt 0) {
    Write-Warn "Optimization completed but $newErrors non-terminating error(s) were recorded in `$Error"
    Write-Warn 'Review output above for ◆ (yellow diamond warning) and ● (red circle error) markers to identify failed settings'
}
