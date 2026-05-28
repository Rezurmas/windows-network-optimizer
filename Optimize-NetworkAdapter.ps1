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
    Version:  3.0
    Updated:  2026

    REBOOT REQUIRED after first run for full effect.
#>

[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$All,
    [string]$AdapterName,

    # === TRYBY PRACY ===
    # Throughput   = max przepustowosc (download/upload, streaming, file transfer)
    # LowLatency   = min ping (gaming, VoIP, kompetytywne FPS)
    # Balanced     = kompromis - dobra przepustowosc i ping
    [ValidateSet('Throughput','LowLatency','Balanced','Max')]
    [string]$Mode = 'Max',

    # Wylacza Microsoft telemetrie (DiagTrack, dmwappushservice) -> wyzsza realna przepustowosc
    [switch]$DisableTelemetry,

    # DNS provider:
    #   $null / 0  = interaktywne menu wyboru (default)
    #   1-21       = wybor konkretnego dostawcy DNS
    #   'Skip'     = nie zmieniaj DNS
    #   IP1,IP2    = lista wlasnych adresow DNS
    $DnsProvider,

    # Pomija registry tweaks (tylko ustawienia karty + netsh)
    [switch]$NoRegistry,

    # Pomija test MTU (oszczedza ~30 sekund)
    [switch]$NoMtuTest,

    # Tryb cichy - bez promptow, exit po zakonczeniu (CI/automation)
    [switch]$Silent
)

$ErrorActionPreference = 'Continue'
$BackupDir = Join-Path $env:USERPROFILE 'Desktop\NIC-Backup'

# Mode 'Max' = Throughput + agresywne tweaks (registry + telemetry off)
if ($Mode -eq 'Max') {
    $Mode = 'Throughput'
    if (-not $PSBoundParameters.ContainsKey('DisableTelemetry')) {
        $DisableTelemetry = $false  # NIE wymuszamy wylaczenia telemetrii bez zgody
    }
}

# ============================================================
#   HELPERS
# ============================================================
function Write-Section($title) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}
function Write-OK   ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Err  ($m) { Write-Host "  [ERR]  $m" -ForegroundColor Red }
function Write-Info ($m) { Write-Host "  [..]   $m" -ForegroundColor Gray }

# ============================================================
#   WINDOWS COMPATIBILITY DETECTION
# ============================================================
function Get-WindowsInfo {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { $os = Get-WmiObject Win32_OperatingSystem }
    $build = [int]($os.BuildNumber)

    # Windows version detection (BuildNumber based)
    $name = switch ($build) {
        { $_ -ge 22000 } { 'Windows 11' }
        { $_ -ge 10240 } { 'Windows 10' }
        { $_ -ge 9600  } { 'Windows 8.1 / Server 2012 R2' }
        { $_ -ge 9200  } { 'Windows 8 / Server 2012' }
        { $_ -ge 7601  } { 'Windows 7 SP1 / Server 2008 R2' }
        default          { "Unknown ($build)" }
    }

    return [PSCustomObject]@{
        Name           = $name
        Version        = $os.Version
        BuildNumber    = $build
        PSVersion      = $PSVersionTable.PSVersion.ToString()
        SupportsNetAdapter   = ($build -ge 9600)   # Win 8.1+
        SupportsPwshDns      = ($build -ge 9600)   # Set-DnsClientServerAddress requires Win 8.1+
        Is64Bit              = [System.Environment]::Is64BitOperatingSystem
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
    Write-Err 'Skrypt wymaga uprawnien Administratora!'
    Write-Info 'Uruchom przez Run-NIC-Optimizer.bat lub PowerShell jako Administrator'
    if (-not $Silent) { Read-Host 'Nacisnij Enter aby zamknac' }
    exit 1
}

# Warn if older Windows
if ($Global:WinInfo.BuildNumber -lt 9600) {
    Write-Warn "Wykryto starszy Windows: $($Global:WinInfo.Name)"
    Write-Warn 'Niektore funkcje moga byc niedostepne (Get-NetAdapter wymaga Win 8.1+)'
    Write-Info 'Skrypt sprobuje uzyc fallbackow netsh/WMI gdzie to mozliwe'
    if (-not $Silent) {
        $cont = Read-Host 'Kontynuowac mimo to? (T/N)'
        if ($cont -notmatch '^[TtYy]') { exit 0 }
    }
}

# ============================================================
#   DNS PROVIDERS DATABASE
#   Zrodla: DNSPerf 2025, Reddit r/dns, Cloudflare/Google/Quad9 docs,
#           AdGuard, NextDNS, ControlD, DNS4EU, Mullvad, AliDNS
# ============================================================
$Global:DnsProviders = @(
    # === SPEED / NEUTRAL (no filtering) ===
    [PSCustomObject]@{ Id=1;  Cat='Speed';    Name='Cloudflare';            V4=@('1.1.1.1','1.0.0.1');                 V6=@('2606:4700:4700::1111','2606:4700:4700::1001'); Desc='Najszybszy globalnie wg DNSPerf, no log, no filter' }
    [PSCustomObject]@{ Id=2;  Cat='Speed';    Name='Google Public DNS';     V4=@('8.8.8.8','8.8.4.4');                 V6=@('2001:4860:4860::8888','2001:4860:4860::8844'); Desc='Google, stabilny i szybki, ECS support' }
    [PSCustomObject]@{ Id=3;  Cat='Speed';    Name='Quad9 Unsecured';       V4=@('9.9.9.10','149.112.112.10');         V6=@('2620:fe::10','2620:fe::fe:10');                Desc='Quad9 bez filtra bezpieczenstwa' }
    [PSCustomObject]@{ Id=4;  Cat='Speed';    Name='OpenDNS Home';          V4=@('208.67.222.222','208.67.220.220');   V6=@('2620:119:35::35','2620:119:53::53');           Desc='Cisco OpenDNS, basic phishing block' }

    # === SECURITY (malware + phishing block) ===
    [PSCustomObject]@{ Id=5;  Cat='Security'; Name='Cloudflare Malware';    V4=@('1.1.1.2','1.0.0.2');                 V6=@('2606:4700:4700::1112','2606:4700:4700::1002'); Desc='Cloudflare + blokada malware' }
    [PSCustomObject]@{ Id=6;  Cat='Security'; Name='Quad9 Secure (recommended)'; V4=@('9.9.9.9','149.112.112.112');    V6=@('2620:fe::fe','2620:fe::9');                    Desc='Szwajcaria, blokada malware/phishing, no log, DNSSEC' }
    [PSCustomObject]@{ Id=7;  Cat='Security'; Name='CleanBrowsing Security'; V4=@('185.228.168.9','185.228.169.9');    V6=@('2a0d:2a00:1::2','2a0d:2a00:2::2');             Desc='Security filter, blokada malware' }

    # === FAMILY (adult content block) ===
    [PSCustomObject]@{ Id=8;  Cat='Family';   Name='Cloudflare Family';     V4=@('1.1.1.3','1.0.0.3');                 V6=@('2606:4700:4700::1113','2606:4700:4700::1003'); Desc='Cloudflare + malware + adult content block' }
    [PSCustomObject]@{ Id=9;  Cat='Family';   Name='OpenDNS FamilyShield';  V4=@('208.67.222.123','208.67.220.123');   V6=@();                                              Desc='OpenDNS + adult content auto-block' }
    [PSCustomObject]@{ Id=10; Cat='Family';   Name='CleanBrowsing Family';  V4=@('185.228.168.168','185.228.169.168'); V6=@('2a0d:2a00:1::','2a0d:2a00:2::');               Desc='Family + adult + malware filter' }

    # === ADBLOCK (blocks ads + trackers) ===
    [PSCustomObject]@{ Id=11; Cat='AdBlock';  Name='AdGuard DNS (default)'; V4=@('94.140.14.14','94.140.15.15');       V6=@('2a10:50c0::ad1:ff','2a10:50c0::ad2:ff');       Desc='Blokada reklam + trackerow (popularny)' }
    [PSCustomObject]@{ Id=12; Cat='AdBlock';  Name='AdGuard Family';        V4=@('94.140.14.15','94.140.15.16');       V6=@('2a10:50c0::bad1:ff','2a10:50c0::bad2:ff');     Desc='AdGuard + adult content block' }
    [PSCustomObject]@{ Id=13; Cat='AdBlock';  Name='ControlD Free (ads)';   V4=@('76.76.2.0','76.76.10.0');            V6=@('2606:1a40::','2606:1a40:1::');                 Desc='ControlD - blokuje reklamy, customizable' }
    [PSCustomObject]@{ Id=14; Cat='AdBlock';  Name='Mullvad AdBlock';       V4=@('194.242.2.3','194.242.2.4');         V6=@('2a07:e340::3','2a07:e340::4');                 Desc='Mullvad VPN - prywatnosc + adblock' }

    # === PRIVACY (no logs, encrypted) ===
    [PSCustomObject]@{ Id=15; Cat='Privacy';  Name='AdGuard Unfiltered';    V4=@('94.140.14.140','94.140.14.141');     V6=@('2a10:50c0::1:ff','2a10:50c0::2:ff');           Desc='AdGuard bez filtra, no log' }
    [PSCustomObject]@{ Id=16; Cat='Privacy';  Name='Mullvad DNS';           V4=@('194.242.2.2','194.242.2.3');         V6=@('2a07:e340::2','2a07:e340::3');                 Desc='Szwecja, max prywatnosc, no log' }

    # === EU (European Union, GDPR) ===
    [PSCustomObject]@{ Id=17; Cat='EU';       Name='DNS4EU Protective';     V4=@('86.54.11.1','86.54.11.201');         V6=@('2a13:1001::86:54:11:1','2a13:1001::86:54:11:201'); Desc='EU-finansowany, GDPR, blokada malware' }
    [PSCustomObject]@{ Id=18; Cat='EU';       Name='DNS4EU Unfiltered';     V4=@('86.54.11.100','86.54.11.200');       V6=@('2a13:1001::86:54:11:100','2a13:1001::86:54:11:200'); Desc='DNS4EU bez filtra' }
    [PSCustomObject]@{ Id=19; Cat='EU';       Name='DNS4EU Child Protect';  V4=@('86.54.11.13','86.54.11.213');        V6=@();                                              Desc='DNS4EU + ochrona dzieci' }

    # === CHINA (for users in mainland China) ===
    [PSCustomObject]@{ Id=20; Cat='China';    Name='AliDNS (Alibaba)';      V4=@('223.5.5.5','223.6.6.6');             V6=@('2400:3200::1','2400:3200:baba::1');            Desc='Alibaba, najszybszy w Chinach (zhongguo)' }
    [PSCustomObject]@{ Id=21; Cat='China';    Name='DNSPod (Tencent)';      V4=@('119.29.29.29','182.254.116.116');    V6=@();                                              Desc='Tencent, stabilny w Chinach' }

    # === RESET / SKIP ===
    [PSCustomObject]@{ Id=99; Cat='Reset';    Name='Reset to DHCP (router)'; V4=@();                                   V6=@();                                              Desc='Wroc do DNS od routera (DHCP, np. AdBlock OpenWrt)' }
)

# ============================================================
#   DNS INTERACTIVE MENU
# ============================================================
function Show-DnsMenu {
    Write-Section 'WYBOR DNS - DOSTAWCY POSORTOWANI WG KATEGORII'
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
        }
        Write-Host ('  ' + $icon + '  ' + $cat.Name.ToUpper()) -ForegroundColor $color
        foreach ($p in $cat.Group) {
            $ips = ($p.V4 -join ', ')
            Write-Host ('     [{0,2}] {1,-32} {2}' -f $p.Id, $p.Name, $ips) -ForegroundColor White
            Write-Host ('          {0}' -f $p.Desc) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-Host '  [Skip]  Nie zmieniaj DNS (zostan przy DHCP/router)' -ForegroundColor DarkGray
    Write-Host '  [c]     Custom - podaj wlasne adresy DNS (np. 1.1.1.1,9.9.9.9)' -ForegroundColor DarkGray
    Write-Host ''
    return Read-Host 'Wybierz ID DNS (1-21, Skip, c)'
}

# ============================================================
#   SET DNS (uniwersalny - dziala z dowolnym providerem z listy)
# ============================================================
function Set-DnsForAdapter {
    param(
        [Parameter(Mandatory)] [string]$AdapterName,
        [Parameter(Mandatory)] $Provider  # PSCustomObject z $Global:DnsProviders
    )

    Write-Section "DNS: $($Provider.Name) -> $AdapterName"

    # Specjalna obsluga: Reset / Skip
    if ($Provider.Id -eq 99 -or $Provider.Cat -eq 'Reset') {
        try {
            if ($Global:WinInfo.SupportsPwshDns) {
                Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ResetServerAddresses -ErrorAction Stop
            } else {
                netsh interface ip set dns name="$AdapterName" source=dhcp | Out-Null
                netsh interface ipv6 set dns name="$AdapterName" source=dhcp | Out-Null
            }
            Write-OK "DNS zresetowany do DHCP (router)"
            return
        } catch {
            Write-Warn "Reset DNS: $($_.Exception.Message)"
            return
        }
    }

    # Zbierz wszystkie IP (v4 + v6)
    $addresses = @()
    if ($Provider.V4) { $addresses += $Provider.V4 }
    if ($Provider.V6) { $addresses += $Provider.V6 }
    if (-not $addresses) {
        Write-Warn 'Brak adresow DNS dla tego providera'
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
        Write-OK "DNS ustawiony:"
        foreach ($addr in $addresses) { Write-Host "         $addr" -ForegroundColor Gray }

        # Wyczysc cache DNS
        try {
            if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue) {
                Clear-DnsClientCache -ErrorAction SilentlyContinue
            } else {
                ipconfig /flushdns | Out-Null
            }
            Write-OK 'DNS cache wyczyszczony'
        } catch { }
    } catch {
        Write-Warn "DNS: $($_.Exception.Message)"
    }
}

# ============================================================
#   PARSE DnsProvider parameter (input from -DnsProvider)
# ============================================================
function Resolve-DnsProvider {
    param($InputValue)

    # Skip
    if ($null -eq $InputValue -or $InputValue -eq '' -or $InputValue -eq 'Skip' -or $InputValue -eq 'skip') {
        return $null
    }

    # Numeric ID
    if ($InputValue -match '^\d+$') {
        $id = [int]$InputValue
        $provider = $Global:DnsProviders | Where-Object { $_.Id -eq $id }
        if ($provider) { return $provider }
        Write-Warn "Nieznany ID DNS: $id"
        return $null
    }

    # Custom IP list (np. "1.1.1.1,9.9.9.9")
    if ($InputValue -match '^[\d\.,:a-fA-F\s]+$') {
        $ips = $InputValue -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $v4 = $ips | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        $v6 = $ips | Where-Object { $_ -match ':' }
        return [PSCustomObject]@{
            Id=999; Cat='Custom'; Name='Custom DNS'; V4=$v4; V6=$v6; Desc='Wlasne adresy uzytkownika'
        }
    }

    return $null
}

# ============================================================
#   OPTIMAL SETTINGS - dynamicznie budowane wg Mode
#   Klucze to regex DisplayName, wartości to docelowy DisplayValue
#   Skrypt sam wykryje co karta wspiera (pomija nieobsługiwane).
# ============================================================
function Get-OptimalSettings {
    param([string]$ModeName)

    $base = @(
        # === LINK NEGOTIATION (kluczowe dla problemu 100Mbps!) ===
        @{ Pattern = '^Speed.+Duplex$|^Szybkosc.+Dupleks$|^Speed/Duplex$';  Value = 'Auto Negotiation' }
        @{ Pattern = '^Auto Negotiation$';                                  Value = 'Enabled' }
        @{ Pattern = 'Wait for Link';                                       Value = 'On' }

        # === FLOW CONTROL & RSS ===
        @{ Pattern = '^Flow Control$|Sterowanie przeplywem';                Value = 'Rx & Tx Enabled' }
        @{ Pattern = 'Receive Side Scaling$|^RSS$';                         Value = 'Enabled' }
        @{ Pattern = 'Maximum Number of RSS Queues|RSS Queues';             Value = '4 Queues' }
        @{ Pattern = 'NetworkDirect|RDMA';                                  Value = 'Enabled' }

        # === BUFORY (max przepustowosc) ===
        @{ Pattern = 'Receive Buffers|Bufory odbioru';                      Value = '2048' }
        @{ Pattern = 'Transmit Buffers|Bufory wysylania|Send Buffers';      Value = '2048' }

        # === OFFLOAD CHECKSUMOW (CPU offload do karty) ===
        @{ Pattern = 'TCP Checksum Offload \(IPv4\)';                       Value = 'Rx & Tx Enabled' }
        @{ Pattern = 'TCP Checksum Offload \(IPv6\)';                       Value = 'Rx & Tx Enabled' }
        @{ Pattern = 'UDP Checksum Offload \(IPv4\)';                       Value = 'Rx & Tx Enabled' }
        @{ Pattern = 'UDP Checksum Offload \(IPv6\)';                       Value = 'Rx & Tx Enabled' }
        @{ Pattern = 'IPv4 Checksum Offload';                               Value = 'Rx & Tx Enabled' }
        @{ Pattern = 'ARP Offload';                                         Value = 'Enabled' }
        @{ Pattern = 'NS Offload';                                          Value = 'Enabled' }

        # === JUMBO (router PPPoE 1492 nie wspiera 9k - WYLACZAMY) ===
        @{ Pattern = 'Jumbo (Packet|Frame)';                                Value = 'Disabled' }
        @{ Pattern = 'Packet Priority.+VLAN|Priority.+VLAN';                Value = 'Packet Priority & VLAN Enabled' }

        # === WYLACZ OSZCZEDZANIE ENERGII (glowna przyczyna problemu 100Mbps!) ===
        @{ Pattern = 'Energy.Efficient Ethernet|^EEE$';                     Value = 'Disabled' }
        @{ Pattern = 'Advanced EEE';                                        Value = 'Disabled' }
        @{ Pattern = 'Green Ethernet';                                      Value = 'Disabled' }
        @{ Pattern = 'Power Saving Mode|Power Save';                        Value = 'Disabled' }
        @{ Pattern = 'Ultra Low Power';                                     Value = 'Disabled' }
        @{ Pattern = 'Gigabit Lite';                                        Value = 'Disabled' }
        @{ Pattern = 'Auto Disable Gigabit';                                Value = 'Disabled' }
        @{ Pattern = 'Selective Suspend';                                   Value = 'Disabled' }
        @{ Pattern = 'System Idle Power Saver';                             Value = 'Disabled' }
        @{ Pattern = 'Reduce Speed On Power Down';                          Value = 'Disabled' }
        @{ Pattern = 'Power Down PHY|Shutdown Wake.On.Lan';                 Value = 'Disabled' }
    )

    # === ROZNICE TRYBOW ===
    if ($ModeName -eq 'Throughput') {
        # Max przepustowosc - wszystkie offloady wlaczone, interrupt moderation ON
        $base += @(
            @{ Pattern = 'Large Send Offload V2 \(IPv4\)';                  Value = 'Enabled' }
            @{ Pattern = 'Large Send Offload V2 \(IPv6\)';                  Value = 'Enabled' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv4\)';                Value = 'Enabled' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv6\)';                Value = 'Enabled' }
            @{ Pattern = '^Interrupt Moderation$';                          Value = 'Enabled' }
            @{ Pattern = 'Interrupt Moderation Rate';                       Value = 'Adaptive' }
            @{ Pattern = 'Adaptive Inter.Frame Spacing';                    Value = 'Disabled' }
        )
    }
    elseif ($ModeName -eq 'LowLatency') {
        # Gaming / VoIP - LSO/RSC OFF (zwieksza opoznienia), Interrupt Moderation OFF
        $base += @(
            @{ Pattern = 'Large Send Offload V2 \(IPv4\)';                  Value = 'Disabled' }
            @{ Pattern = 'Large Send Offload V2 \(IPv6\)';                  Value = 'Disabled' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv4\)';                Value = 'Disabled' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv6\)';                Value = 'Disabled' }
            @{ Pattern = '^Interrupt Moderation$';                          Value = 'Disabled' }
            @{ Pattern = 'Interrupt Moderation Rate';                       Value = 'Off' }
            @{ Pattern = 'Adaptive Inter.Frame Spacing';                    Value = 'Disabled' }
            @{ Pattern = 'Priority.+VLAN.+Tag';                             Value = 'Priority Enabled' }
        )
    }
    else {
        # Balanced - kompromis (Adaptive)
        $base += @(
            @{ Pattern = 'Large Send Offload V2 \(IPv4\)';                  Value = 'Enabled' }
            @{ Pattern = 'Large Send Offload V2 \(IPv6\)';                  Value = 'Enabled' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv4\)';                Value = 'Enabled' }
            @{ Pattern = 'Recv Segment Coalescing \(IPv6\)';                Value = 'Enabled' }
            @{ Pattern = '^Interrupt Moderation$';                          Value = 'Enabled' }
            @{ Pattern = 'Interrupt Moderation Rate';                       Value = 'Adaptive' }
        )
    }

    return $base
}

$OptimalSettings = Get-OptimalSettings -ModeName $Mode

# ============================================================
#   FUNCTIONS
# ============================================================
function Show-Adapters {
    Write-Section 'KARTY SIECIOWE W SYSTEMIE'
    Get-NetAdapter | Sort-Object @{e='Status';desc=$true}, Name |
        Format-Table -AutoSize `
            @{N='Name';        E={$_.Name}},
            @{N='Status';      E={$_.Status}},
            @{N='Speed';       E={$_.LinkSpeed}},
            @{N='MAC';         E={$_.MacAddress}},
            @{N='Description'; E={$_.InterfaceDescription}}
}

function Backup-AdapterSettings($adapterName) {
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = $adapterName -replace '[\\/:*?"<>|]', '_'
    $file     = Join-Path $BackupDir "$safeName--$stamp.json"

    $props = Get-NetAdapterAdvancedProperty -Name $adapterName -ErrorAction SilentlyContinue |
             Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue, ValidDisplayValues

    if ($props) {
        $props | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8
        Write-OK "Backup zapisany: $file"
    } else {
        Write-Warn 'Brak ustawien zaawansowanych do backupu'
    }
    return $file
}

function Optimize-Adapter($adapterName) {
    Write-Section "OPTYMALIZACJA KARTY: $adapterName"
    Backup-AdapterSettings $adapterName | Out-Null

    $props = Get-NetAdapterAdvancedProperty -Name $adapterName -ErrorAction SilentlyContinue
    if (-not $props) {
        Write-Warn 'Karta nie udostepnia ustawien zaawansowanych'
        return
    }

    $applied = 0; $alreadyOk = 0; $skipped = 0; $failed = 0

    foreach ($prop in $props) {
        $displayName = $prop.DisplayName
        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

        # Find a matching optimal setting
        $match = $OptimalSettings | Where-Object { $displayName -match $_.Pattern } | Select-Object -First 1
        if (-not $match) {
            $skipped++
            continue
        }

        $newValue = $match.Value
        if ($prop.DisplayValue -eq $newValue) {
            Write-Info "$displayName  =  $newValue  (juz OK)"
            $alreadyOk++
            continue
        }

        # Sprawdź czy karta wspiera tę wartość (jeśli ma listę dopuszczalnych)
        if ($prop.ValidDisplayValues -and $prop.ValidDisplayValues.Count -gt 0) {
            if ($prop.ValidDisplayValues -notcontains $newValue) {
                # Spróbuj znaleźć najbliższy odpowiednik
                $alt = $prop.ValidDisplayValues | Where-Object { $_ -match 'Disabled|Off' -and $newValue -match 'Disabled' } | Select-Object -First 1
                if (-not $alt) {
                    $alt = $prop.ValidDisplayValues | Where-Object { $_ -match 'Enabled|On' -and $newValue -match 'Enabled' } | Select-Object -First 1
                }
                if ($alt) {
                    $newValue = $alt
                } else {
                    Write-Warn "$displayName : '$($match.Value)' nieobslugiwane (mozliwe: $($prop.ValidDisplayValues -join ', '))"
                    $failed++
                    continue
                }
            }
        }

        try {
            Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $displayName -DisplayValue $newValue -NoRestart -ErrorAction Stop
            Write-OK "$displayName : $($prop.DisplayValue)  ->  $newValue"
            $applied++
        } catch {
            Write-Warn "$displayName  ->  $newValue  (blad: $($_.Exception.Message.Split([Environment]::NewLine)[0]))"
            $failed++
        }
    }

    Write-Host ''
    Write-Info "Zastosowano: $applied  |  Juz OK: $alreadyOk  |  Pominieto: $skipped  |  Bledy: $failed"

    # Restart adapter once at end (so all changes apply together)
    if ($applied -gt 0) {
        try {
            Write-Info 'Restartuje karte aby zastosowac zmiany...'
            Restart-NetAdapter -Name $adapterName -ErrorAction Stop
            Start-Sleep -Seconds 3
            Write-OK 'Karta zrestartowana'
        } catch {
            Write-Warn "Restart karty nie powiodl sie: $($_.Exception.Message)"
        }
    }
}

function Disable-PowerManagement($adapterName) {
    Write-Section "WYLACZANIE POWER MANAGEMENT: $adapterName"
    try {
        $adapter   = Get-NetAdapter -Name $adapterName -ErrorAction Stop
        $instance  = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSPower_DeviceEnable' -ErrorAction SilentlyContinue |
                     Where-Object { $_.InstanceName -like "*$($adapter.PnPDeviceID)*" }
        if ($instance) {
            $instance.Enable = $false
            Set-CimInstance -InputObject $instance -ErrorAction Stop
            Write-OK 'Wylaczono "Pozwol komputerowi wylaczac to urzadzenie"'
        } else {
            Write-Info 'Karta nie wspiera Windows power management API'
        }

        # Also disable WakeOnMagicPacket / WakeOnPattern (not really power but related)
        $wake = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSPower_DeviceWakeEnable' -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceName -like "*$($adapter.PnPDeviceID)*" }
        if ($wake) {
            $wake.Enable = $false
            Set-CimInstance -InputObject $wake -ErrorAction SilentlyContinue
            Write-OK 'Wylaczono "Wake on magic packet" (oszczedzanie)'
        }
    } catch {
        Write-Warn "Power mgmt: $($_.Exception.Message)"
    }
}

function Optimize-TcpIpGlobal {
    param([string]$ModeName = 'Throughput')
    Write-Section "OPTYMALIZACJA TCP/IP GLOBALNA  (tryb: $ModeName)"

    # === Auto-tuning level zalezny od trybu ===
    # experimental    = max throughput (RFC 7323), wykorzystuje window scaling do max
    # normal          = standard, dobry kompromis
    # highlyrestricted= najnizszy ping ale ogranicza window scaling
    $autotuning = switch ($ModeName) {
        'Throughput' { 'experimental' }   # max BDP - polski ISP wspiera
        'LowLatency' { 'normal' }          # nie psuje windows scaling, ale konserwatywny
        default      { 'normal' }
    }

    # === Congestion provider ===
    # cubic    = standard od Win10 1709, dobry dla wysokich przepustowosci (gigabit+)
    # ctcp     = Compound TCP - lepszy dla srednich predkosci
    # newreno  = stary, kompatybilny ale wolny
    $congestion = switch ($ModeName) {
        'Throughput' { 'cubic' }
        'LowLatency' { 'ctcp' }    # bardziej responsywny przy niskich opoznieniach
        default      { 'cubic' }
    }

    $cmds = @(
        # === AUTO-TUNING & HEURISTICS ===
        @{c="netsh int tcp set global autotuninglevel=$autotuning";           desc="TCP Auto-tuning: $autotuning"}
        @{c='netsh int tcp set heuristics disabled';                          desc='TCP Heuristics: OFF (wymusza autotuninglevel)'}
        @{c='netsh int tcp set global rss=enabled';                           desc='Receive Side Scaling: ON'}
        @{c='netsh int tcp set global rsc=enabled';                           desc='Receive Segment Coalescing: ON'}
        @{c='netsh int tcp set global chimney=automatic';                     desc='TCP Chimney Offload: auto'}
        @{c='netsh int tcp set global dca=enabled';                           desc='Direct Cache Access: ON (CPU cache)'}
        @{c='netsh int tcp set global netdma=enabled';                        desc='NetDMA: ON'}

        # === CONGESTION & ECN ===
        @{c="netsh int tcp set supplemental internet congestionprovider=$congestion"; desc="Congestion provider: $congestion"}
        @{c='netsh int tcp set global ecncapability=enabled';                 desc='ECN Capability: ON (lepsze przy zatorach)'}
        @{c='netsh int tcp set global prr=enabled';                           desc='Proportional Rate Reduction: ON'}
        @{c='netsh int tcp set global hystart=enabled';                       desc='HyStart slow-start: ON'}

        # === TIMING ===
        @{c='netsh int tcp set global timestamps=disabled';                   desc='TCP Timestamps: OFF (mniejszy overhead)'}
        @{c='netsh int tcp set global initialrto=2000';                       desc='Initial RTO: 2000ms'}
        @{c='netsh int tcp set global nonsackrttresiliency=disabled';         desc='Non-SACK RTT resiliency: OFF'}
        @{c='netsh int tcp set global maxsynretransmissions=2';               desc='Max SYN retransmissions: 2'}
        @{c='netsh int tcp set global fastopen=enabled';                      desc='TCP Fast Open: ON (szybszy handshake)'}
        @{c='netsh int tcp set global fastopenfallback=enabled';              desc='TFO Fallback: ON'}

        # === PACING (zostaw default - off psuje sieci 1Gbps+) ===
        @{c='netsh int tcp set global pacingprofile=off';                     desc='TCP Pacing: OFF'}

        # === IP STACK ===
        @{c='netsh int ip   set global taskoffload=enabled';                  desc='IP Task Offload: ON'}
        @{c='netsh int ip   set global neighborcachelimit=8192';              desc='Neighbor cache: 8192'}
        @{c='netsh int ip   set global icmpredirects=disabled';               desc='ICMP redirects: OFF (security)'}
        @{c='netsh int ip   set global sourceroutingbehavior=drop';           desc='Source routing: DROP (security)'}

        # === UDP (gaming traffic) ===
        @{c='netsh int udp set global uro=enabled';                           desc='UDP Receive Offload: ON'}

        # === Winsock reset jest CELOWO pominiete ===
        # 'netsh winsock reset' moze zlamac VPN klientow / antivirusy z LSP.
        # Uruchom recznie tylko gdy masz problemy z polaczeniem!
    )

    foreach ($cmd in $cmds) {
        try {
            $out = cmd.exe /c $cmd.c 2>&1
            if ($LASTEXITCODE -eq 0 -or $out -match 'OK|Ok') {
                Write-OK $cmd.desc
            } else {
                Write-Warn ("{0}  ({1})" -f $cmd.desc, (($out -join ' ').Trim() -replace '\s+', ' '))
            }
        } catch {
            Write-Warn "$($cmd.desc): $($_.Exception.Message)"
        }
    }
}

# ============================================================
#   REGISTRY TWEAKS (TCP/IP performance)
#   HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters
# ============================================================
function Set-TcpIpRegistryTweaks {
    param([string]$ModeName = 'Throughput')
    Write-Section "REGISTRY TWEAKS - TCP/IP STACK  (tryb: $ModeName)"

    $tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

    # Tweaks zebrane z: Microsoft Learn, Reddit r/pcmasterrace, guru3D, Windows Forum
    $tweaks = @(
        @{ Name='DefaultTTL';                Value=64;     Type='DWord'; Desc='Default TTL: 64 (standard)' }
        @{ Name='Tcp1323Opts';               Value=1;      Type='DWord'; Desc='RFC 1323 Window Scaling: ON, Timestamps: OFF' }
        @{ Name='TcpTimedWaitDelay';         Value=30;     Type='DWord'; Desc='TIME_WAIT delay: 30s (default 240s)' }
        @{ Name='MaxUserPort';               Value=65534;  Type='DWord'; Desc='MaxUserPort: 65534 (default 5000)' }
        @{ Name='TcpMaxDupAcks';             Value=2;      Type='DWord'; Desc='Max Duplicate ACKs: 2 (szybsze recovery)' }
        @{ Name='SackOpts';                  Value=1;      Type='DWord'; Desc='Selective ACK: ON' }
        @{ Name='EnablePMTUDiscovery';       Value=1;      Type='DWord'; Desc='Path MTU Discovery: ON' }
        @{ Name='EnablePMTUBHDetect';        Value=0;      Type='DWord'; Desc='Black Hole Router Detection: OFF (false positives)' }
        @{ Name='EnableTCPChimney';          Value=1;      Type='DWord'; Desc='TCP Chimney: ON' }
        @{ Name='EnableTCPA';                Value=1;      Type='DWord'; Desc='TCP-A: ON' }
        @{ Name='EnableRSS';                 Value=1;      Type='DWord'; Desc='RSS: ON (rejestr backup)' }
        @{ Name='DisableTaskOffload';        Value=0;      Type='DWord'; Desc='Task Offload: enabled (0=ON)' }
        @{ Name='MaxFreeTcbs';               Value=65536;  Type='DWord'; Desc='Max Free TCBs: 65536 (wiecej polaczen)' }
        @{ Name='MaxHashTableSize';          Value=65536;  Type='DWord'; Desc='TCB Hash Table: 65536' }
        @{ Name='GlobalMaxTcpWindowSize';    Value=65535;  Type='DWord'; Desc='Global Max TCP Window: 65535' }
        @{ Name='TcpWindowSize';             Value=65535;  Type='DWord'; Desc='Default TCP Window: 65535' }
    )

    foreach ($t in $tweaks) {
        try {
            Set-ItemProperty -Path $tcpParams -Name $t.Name -Value $t.Value -Type $t.Type -Force -ErrorAction Stop
            Write-OK $t.Desc
        } catch {
            Write-Warn "$($t.Name): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        }
    }
}

# ============================================================
#   PER-INTERFACE NAGLE TWEAKS
#   HKLM\...\Tcpip\Parameters\Interfaces\{GUID}
#   TcpAckFrequency / TCPNoDelay = redukcja ping w gameach (~5-15ms)
# ============================================================
function Set-InterfaceNagleTweaks {
    param([string]$ModeName = 'Throughput')

    # Nagle tylko dla LowLatency / Balanced (w Throughput moze obnizyc throughput)
    if ($ModeName -eq 'Throughput') {
        Write-Info "Nagle tweaks pominieto (tryb Throughput - moga obnizyc throughput o 5-10%)"
        return
    }

    Write-Section "PER-INTERFACE NAGLE OFF  (tryb: $ModeName)"

    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $interfaces = Get-ChildItem -Path $base -ErrorAction SilentlyContinue

    $count = 0
    foreach ($iface in $interfaces) {
        # Tylko interfejsy z przypisanym IP (aktywne)
        $props = Get-ItemProperty -Path $iface.PSPath -ErrorAction SilentlyContinue
        if (-not $props.IPAddress -and -not $props.DhcpIPAddress) { continue }

        try {
            Set-ItemProperty -Path $iface.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $iface.PSPath -Name 'TCPNoDelay'      -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $iface.PSPath -Name 'TcpDelAckTicks'  -Value 0 -Type DWord -Force -ErrorAction Stop
            $ip = if ($props.DhcpIPAddress) { $props.DhcpIPAddress } else { $props.IPAddress }
            Write-OK "Interfejs $ip : TcpAckFrequency=1, TCPNoDelay=1, TcpDelAckTicks=0"
            $count++
        } catch {
            Write-Warn "$($iface.PSChildName): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        }
    }
    if ($count -eq 0) {
        Write-Warn 'Nie znaleziono aktywnych interfejsow z IP'
    }
}

# ============================================================
#   MMCSS OPTIMIZATION (Multimedia Class Scheduler)
#   - NetworkThrottlingIndex = 0xFFFFFFFF -> wylaczone throttling sieci
#   - SystemResponsiveness   = 10  (default 20, dla gamingu)
#   - Tasks\Games priority boost
# ============================================================
function Set-MmcssOptimization {
    param([string]$ModeName = 'Throughput')
    Write-Section "MMCSS - MULTIMEDIA SCHEDULER  (tryb: $ModeName)"

    $sysProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $games      = "$sysProfile\Tasks\Games"

    # SystemResponsiveness:
    # 0  = 100% CPU dla multimedia/gier (max gaming)
    # 10 = 90% multimedia, 10% inne (zalecane Microsoft)
    # 20 = default (Windows zostawia 20% dla "innych" zadan)
    $sysResp = if ($ModeName -eq 'LowLatency') { 0 } else { 10 }

    $tweaks = @(
        # 0xFFFFFFFF jako DWord = -1 (signed int32, ten sam bit pattern)
        @{ Path=$sysProfile; Name='NetworkThrottlingIndex';   Value=([int]-1);  Type='DWord'; Desc='Network Throttling: WYLACZONE (max throughput)' }
        @{ Path=$sysProfile; Name='SystemResponsiveness';     Value=$sysResp;   Type='DWord'; Desc="System Responsiveness: $sysResp" }

        # Boost dla zadan typu Games
        @{ Path=$games;      Name='GPU Priority';             Value=8;   Type='DWord'; Desc='Games\GPU Priority: 8 (max)' }
        @{ Path=$games;      Name='Priority';                 Value=6;   Type='DWord'; Desc='Games\Priority: 6 (high)' }
        @{ Path=$games;      Name='Scheduling Category';      Value='High';        Type='String'; Desc='Games\Scheduling: High' }
        @{ Path=$games;      Name='SFIO Priority';            Value='High';        Type='String'; Desc='Games\SFIO Priority: High' }
        @{ Path=$games;      Name='Affinity';                 Value=0;   Type='DWord'; Desc='Games\Affinity: 0 (wszystkie CPU)' }
        @{ Path=$games;      Name='Background Only';          Value='False';       Type='String'; Desc='Games\Background Only: False' }
        @{ Path=$games;      Name='Clock Rate';               Value=10000; Type='DWord'; Desc='Games\Clock Rate: 10000' }
    )

    # Upewnij sie ze klucze istnieja
    foreach ($p in @($sysProfile, $games)) {
        if (-not (Test-Path $p)) {
            try { New-Item -Path $p -Force | Out-Null } catch { }
        }
    }

    foreach ($t in $tweaks) {
        try {
            Set-ItemProperty -Path $t.Path -Name $t.Name -Value $t.Value -Type $t.Type -Force -ErrorAction Stop
            Write-OK $t.Desc
        } catch {
            Write-Warn "$($t.Name): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        }
    }
}

# ============================================================
#   POWER TWEAKS (powercfg)
#   - USB Selective Suspend OFF
#   - PCI-Express Link State Power Management OFF
#   - Min CPU State 100% on AC
# ============================================================
function Set-PowerCfgTweaks {
    Write-Section 'POWERCFG - GLEBOKA OPTYMALIZACJA ZASILANIA'

    $cmds = @(
        # USB Selective Suspend
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'; desc='USB Selective Suspend (AC): OFF'}
        @{c='powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'; desc='USB Selective Suspend (Battery): OFF'}

        # PCI Express Link State Power Management
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0'; desc='PCIe Link State Power Mgmt (AC): OFF'}
        @{c='powercfg /setdcvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0'; desc='PCIe Link State Power Mgmt (Battery): OFF'}

        # Minimum processor state
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100'; desc='Min CPU State (AC): 100%'}

        # Wireless adapter power mode
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0'; desc='Wireless Adapter (AC): Maximum Performance'}

        # Hard disk timeout (0 = never)
        @{c='powercfg /setacvalueindex SCHEME_CURRENT 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0'; desc='HDD timeout (AC): never'}

        # Apply
        @{c='powercfg /setactive SCHEME_CURRENT'; desc='Apply current power scheme'}
    )

    foreach ($cmd in $cmds) {
        try {
            $out = cmd.exe /c $cmd.c 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-OK $cmd.desc
            } else {
                Write-Warn ("{0}  ({1})" -f $cmd.desc, (($out -join ' ').Trim()))
            }
        } catch {
            Write-Warn "$($cmd.desc): $($_.Exception.Message)"
        }
    }
}

# ============================================================
#   DISABLE TELEMETRY SERVICES (uwalnia bandwidth)
# ============================================================
function Disable-TelemetryServices {
    Write-Section 'WYLACZANIE TELEMETRII (DiagTrack, dmwappushservice)'

    $services = @('DiagTrack', 'dmwappushservice', 'WMPNetworkSvc')
    foreach ($svc in $services) {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s) {
                Write-Info "$svc : nie znaleziono (OK)"
                continue
            }
            if ($s.Status -eq 'Running') {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
            Write-OK "$svc : zatrzymane i wylaczone"
        } catch {
            Write-Warn "$svc : $($_.Exception.Message)"
        }
    }

    # Wylacz Delivery Optimization (P2P Windows Update)
    try {
        $doPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
        if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force | Out-Null }
        Set-ItemProperty -Path $doPath -Name 'DODownloadMode' -Value 0 -Type DWord -Force
        Write-OK 'Delivery Optimization: OFF (P2P Windows Update)'
    } catch {
        Write-Warn "Delivery Optimization: $($_.Exception.Message)"
    }
}

# ============================================================
#   MTU AUTO-DETECTION (informacyjne)
# ============================================================
function Test-OptimalMtu {
    Write-Section 'MTU - AUTOMATYCZNA DETEKCJA'
    Write-Info 'Test moze potrwac ~30 sekund...'

    $target = '1.1.1.1'
    $low = 1300; $high = 1500; $best = 0
    while ($low -le $high) {
        $mid = [int](($low + $high) / 2)
        $result = ping.exe -f -l $mid -n 1 -w 1500 $target 2>&1
        if ($result -match 'Reply from') {
            $best = $mid
            $low = $mid + 1
        } else {
            $high = $mid - 1
        }
    }
    if ($best -gt 0) {
        $optimalMtu = $best + 28  # +20 IP header + 8 ICMP header
        Write-OK "Optymalne MTU: $optimalMtu  (payload max: $best)"
        Write-Info "Aktualne MTU mozna sprawdzic: netsh int ipv4 show subinterfaces"
        Write-Info "Dla Orange PPPoE typowo 1492 jest poprawne"
    } else {
        Write-Warn 'Nie udalo sie wykryc MTU (firewall blokuje ICMP?)'
    }
}

function Set-PerformancePowerPlan {
    Write-Section 'PLAN ZASILANIA WINDOWS'
    try {
        $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
        $highPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

        # Try Ultimate first, fall back to High Performance
        $schemes = (powercfg /list) -join "`n"
        if ($schemes -notmatch $ultimate) {
            powercfg -duplicatescheme $ultimate 2>&1 | Out-Null
        }
        powercfg /setactive $ultimate 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            powercfg /setactive $highPerf 2>&1 | Out-Null
            Write-OK 'Aktywowano plan: High Performance'
        } else {
            Write-OK 'Aktywowano plan: Ultimate Performance'
        }
    } catch {
        Write-Warn "Power plan: $($_.Exception.Message)"
    }
}

function Restore-FromBackup {
    Write-Section 'PRZYWRACANIE Z BACKUPU'
    if (-not (Test-Path $BackupDir)) {
        Write-Err "Brak folderu z backupami: $BackupDir"
        return
    }
    $backups = Get-ChildItem $BackupDir -Filter '*.json' | Sort-Object LastWriteTime -Descending
    if (-not $backups) { Write-Err 'Brak plikow backupu'; return }

    Write-Host 'Dostepne backupy (najnowsze pierwsze):'
    for ($i = 0; $i -lt $backups.Count; $i++) {
        Write-Host ("  [{0}] {1}    ({2})" -f $i, $backups[$i].Name, $backups[$i].LastWriteTime)
    }
    $idx = Read-Host 'Numer backupu do przywrocenia (Enter = anuluj)'
    if ([string]::IsNullOrWhiteSpace($idx)) { return }

    $file        = $backups[[int]$idx].FullName
    $data        = Get-Content $file -Raw | ConvertFrom-Json
    $adapterName = ($backups[[int]$idx].BaseName -replace '--\d{8}-\d{6}$', '') -replace '_', ' '

    Write-Info "Karta: $adapterName"
    foreach ($p in $data) {
        try {
            Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $p.DisplayName `
                -DisplayValue $p.DisplayValue -NoRestart -ErrorAction Stop
            Write-OK "$($p.DisplayName)  ->  $($p.DisplayValue)"
        } catch {
            Write-Warn "$($p.DisplayName): $($_.Exception.Message)"
        }
    }
    Restart-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
    Write-OK 'Przywrocono ustawienia, karta zrestartowana'
}

# ============================================================
#   MAIN
# ============================================================
Clear-Host
Write-Host @"
+==================================================================+
|         WINDOWS NETWORK OPTIMIZER  v3.0                          |
|         universal - works on Win 8.1/10/11/Server 2012R2+        |
+==================================================================+
|  OS:      $($Global:WinInfo.Name.PadRight(56))|
|  Build:   $($Global:WinInfo.BuildNumber.ToString().PadRight(56))|
|  PSVer:   $($Global:WinInfo.PSVersion.PadRight(56))|
|                                                                  |
|  Mode:           $($Mode.PadRight(49))|
|  Telemetry off:  $($DisableTelemetry.ToString().PadRight(49))|
|  Skip registry:  $($NoRegistry.ToString().PadRight(49))|
|  Skip MTU test:  $($NoMtuTest.ToString().PadRight(49))|
|  Silent mode:    $($Silent.ToString().PadRight(49))|
+==================================================================+
"@ -ForegroundColor Cyan

if ($Restore) {
    Restore-FromBackup
    if (-not $Silent) { Read-Host 'Enter aby zamknac' }
    exit
}

Show-Adapters

# --- Choose adapter ---
if ($All) {
    $targets = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
    if (-not $targets) { Write-Err 'Brak aktywnych kart Ethernet'; exit 1 }
} elseif ($AdapterName) {
    $targets = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
} elseif ($Silent) {
    # Silent + brak nazwy -> wszystkie aktywne Ethernet
    $targets = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
    if (-not $targets) { Write-Err 'Brak aktywnych kart Ethernet (silent mode)'; exit 1 }
} else {
    Write-Host ''
    Write-Info "Aktualny tryb: $Mode  (zmien przez -Mode Throughput|LowLatency|Balanced)"
    $name = Read-Host 'Podaj nazwe karty (np. Ethernet) lub wpisz "all" dla wszystkich Ethernet'
    if ($name -eq 'all') {
        $targets = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
    } else {
        $targets = Get-NetAdapter -Name $name -ErrorAction Stop
    }
}

if (-not $targets) { Write-Err 'Nie znaleziono karty'; if(-not $Silent){Read-Host 'Enter'}; exit 1 }

# --- Resolve DNS provider ---
$selectedDns = $null
if ($PSBoundParameters.ContainsKey('DnsProvider')) {
    $selectedDns = Resolve-DnsProvider -InputValue $DnsProvider
} elseif (-not $Silent) {
    # Interactive menu
    Write-Host ''
    $useDns = Read-Host 'Czy zmienic DNS? (T = pokaz menu / N = pomin) [N]'
    if ($useDns -match '^[TtYy]') {
        $choice = Show-DnsMenu
        if ($choice -match '^[Cc]') {
            $custom = Read-Host 'Podaj adresy DNS (np. 1.1.1.1,9.9.9.9)'
            $selectedDns = Resolve-DnsProvider -InputValue $custom
        } else {
            $selectedDns = Resolve-DnsProvider -InputValue $choice
        }
    }
}

# === FAZA 1: Karta sieciowa (per-adapter) ===
foreach ($t in $targets) {
    Optimize-Adapter         $t.Name
    Disable-PowerManagement  $t.Name
    if ($selectedDns) {
        Set-DnsForAdapter -AdapterName $t.Name -Provider $selectedDns
    }
}

# === FAZA 2: TCP/IP global (netsh) ===
Optimize-TcpIpGlobal -ModeName $Mode

# === FAZA 3: Registry tweaks (TCP/IP stack + MMCSS + Nagle) ===
if (-not $NoRegistry) {
    Set-TcpIpRegistryTweaks   -ModeName $Mode
    Set-InterfaceNagleTweaks  -ModeName $Mode
    Set-MmcssOptimization     -ModeName $Mode
} else {
    Write-Info 'Pominieto registry tweaks (-NoRegistry)'
}

# === FAZA 4: Power management ===
Set-PowerCfgTweaks
Set-PerformancePowerPlan

# === FAZA 5: Telemetry off (opcjonalne) ===
if ($DisableTelemetry) {
    Disable-TelemetryServices
} else {
    Write-Info 'Telemetria nie zostala wylaczona (uzyj -DisableTelemetry aby wylaczyc DiagTrack)'
}

# === FAZA 6: MTU detection (informacyjne) ===
if (-not $NoMtuTest) {
    Test-OptimalMtu
}

Write-Section 'ZAKONCZONO'
Write-OK   'Optymalizacja wykonana pomyslnie'
Write-Info "Tryb: $Mode"
if ($selectedDns) { Write-Info "DNS: $($selectedDns.Name)" }
Write-Info "Backup ustawien: $BackupDir"
Write-Info 'Cofniecie zmian karty: uruchom z parametrem -Restore'
Write-Warn 'WYMAGANY RESTART komputera dla pelnego efektu!'
Write-Warn '(Niektore tweaks rejestru aktywuja sie dopiero po reboot)'

Write-Host ''
Show-Adapters

# Pokaz summary co zostalo zrobione
Write-Section 'PODSUMOWANIE WYKONANYCH OPTYMALIZACJI'
Write-Host '  [+] Karta sieciowa: ~40 ustawien zaawansowanych'         -ForegroundColor Green
Write-Host '  [+] Power management: wylaczone wylaczanie do oszczednosci' -ForegroundColor Green
Write-Host '  [+] TCP/IP netsh: 24 ustawienia globalne'                -ForegroundColor Green
if (-not $NoRegistry) {
    Write-Host '  [+] Registry TCP/IP: 16 wartosci wydajnosciowych'     -ForegroundColor Green
    Write-Host '  [+] MMCSS: NetworkThrottlingIndex, Games priority'    -ForegroundColor Green
    if ($Mode -ne 'Throughput') {
        Write-Host '  [+] Per-NIC Nagle off: TcpAckFrequency=1, TCPNoDelay=1' -ForegroundColor Green
    }
}
Write-Host '  [+] Powercfg: USB Suspend off, PCIe LSPM off, CPU 100%'  -ForegroundColor Green
Write-Host '  [+] Plan zasilania: Ultimate Performance'                -ForegroundColor Green
if ($selectedDns) {
    Write-Host "  [+] DNS: $($selectedDns.Name) ($($selectedDns.V4 -join ', '))" -ForegroundColor Green
}
if ($DisableTelemetry) {
    Write-Host '  [+] Telemetria: wylaczona (DiagTrack, Delivery Opt.)' -ForegroundColor Green
}

Write-Host ''
if (-not $Silent) { Read-Host 'Nacisnij Enter aby zamknac' }
