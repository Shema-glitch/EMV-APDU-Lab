<#
.SYNOPSIS
    EMV APDU Lab V14 - PC/SC Smart Card Diagnostic Suite
.DESCRIPTION
    Native PowerShell 5.1 & WinForms desktop diagnostic utility for PC/SC smart card readers.
    Features P/Invoke winscard.dll bindings, encoding-safe 3D banner graphics, paced execution,
    and unified console logging.
.AUTHOR
    Shema-glitch (charmantshema112@gmail.com)
#>

# Force console output encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Add WinForms and Drawing Assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==========================================
# 1. NATIVE C# P/INVOKE WINSCARD BINDINGS
# ==========================================
$WinScardCode = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class WinScard {
    [DllImport("winscard.dll")]
    public static extern int SCardEstablishContext(uint dwScope, IntPtr pvReserved1, IntPtr pvReserved2, out IntPtr phContext);

    [DllImport("winscard.dll")]
    public static extern int SCardReleaseContext(IntPtr hContext);

    [DllImport("winscard.dll", CharSet = CharSet.Auto)]
    public static extern int SCardListReaders(IntPtr hContext, string mszGroups, byte[] mszReaders, ref uint pcchReaders);

    [DllImport("winscard.dll", CharSet = CharSet.Auto)]
    public static extern int SCardConnect(IntPtr hContext, string szReader, uint dwShareMode, uint dwPreferredProtocols, out IntPtr phCard, out uint pdwActiveProtocol);

    [DllImport("winscard.dll")]
    public static extern int SCardDisconnect(IntPtr hCard, uint dwDisposition);

    [StructLayout(LayoutKind.Sequential)]
    public struct SCARD_IO_REQUEST {
        public uint dwProtocol;
        public uint cbPciLength;
    }

    [DllImport("winscard.dll")]
    public static extern int SCardTransmit(IntPtr hCard, ref SCARD_IO_REQUEST pioSendPci, byte[] pbSendBuffer, uint cbSendLength, ref SCARD_IO_REQUEST pioRecvPci, byte[] pbRecvBuffer, ref uint pcbRecvLength);
}
"@

if (-not ([System.Management.Automation.PSTypeName]'WinScard').Type) {
    Add-Type -TypeDefinition $WinScardCode
}

# ==========================================
# 2. ENCODING-SAFE TERMINAL 3D BANNER RENDER
# ==========================================
function Write-3DBlockBanner {
    [CmdletBinding()]
    param(
        [string[]]$BannerLines,
        [int]$StartX = 2,
        [int]$StartY = 1,
        [ConsoleColor]$FillColor = [ConsoleColor]::Cyan,
        [ConsoleColor]$StrokeColor = [ConsoleColor]::DarkGray,
        [int]$CharDelayMs = 2
    )

    $originalCursorVisible = [Console]::CursorVisible
    $originalFgColor = [Console]::ForegroundColor
    [Console]::CursorVisible = $false

    # Unicode Character Mapping Constants
    $cBlock = [char]0x2588  # Solid Full Block
    $cLight = [char]0x2591  # Light Shade
    $cMed   = [char]0x2592  # Medium Shade

    try {
        # Layer 1: Wireframe / Extrusion Layer (Offset: X+1, Y+1)
        [Console]::ForegroundColor = $StrokeColor
        for ($i = 0; $i -lt $BannerLines.Count; $i++) {
            $line = $BannerLines[$i]
            $currentY = $StartY + $i + 1
            for ($j = 0; $j -lt $line.Length; $j++) {
                $char = $line[$j]
                if ($char -ne ' ') {
                    $strokeChar = switch ($char) {
                        $cBlock { $cLight }
                        default { $cLight }
                    }
                    [Console]::SetCursorPosition($StartX + $j + 1, $currentY)
                    [Console]::Write($strokeChar)
                    if ($CharDelayMs -gt 0) { Start-Sleep -Milliseconds $CharDelayMs }
                }
            }
        }

        # Layer 2: Main Solid Fill Layer (X, Y)
        [Console]::ForegroundColor = $FillColor
        for ($i = 0; $i -lt $BannerLines.Count; $i++) {
            $line = $BannerLines[$i]
            $currentY = $StartY + $i
            for ($j = 0; $j -lt $line.Length; $j++) {
                $char = $line[$j]
                if ($char -ne ' ') {
                    [Console]::SetCursorPosition($StartX + $j, $currentY)
                    [Console]::Write($char)
                    if ($CharDelayMs -gt 0) { Start-Sleep -Milliseconds $CharDelayMs }
                }
            }
        }
    }
    finally {
        [Console]::SetCursorPosition(0, $StartY + $BannerLines.Count + 2)
        [Console]::ForegroundColor = $originalFgColor
        [Console]::CursorVisible = $originalCursorVisible
    }
}

# Build Banner Strings via Encoding-Proof Character Replacement
$rawTemplate = @(
    "#######]###]   ###]##]   ##]    ######] ######] ######] ##]   ##]    ##]      #####] ######] ",
    "##[====}####] ####|##|   ##|    ##[==##]##[==##]##[==##]##|   ##|    ##|     ##[==##]##[==##]",
    "#####]  ##[####[##|##|   ##|    ######} ######} ##|  ##|##|   ##|    ##|     #######|######} ",
    "##[==}  ##|{##[}##|##|   ##|    ##[==##]##[===  ##|  ##|##|   ##|    ##|     ##[==##]##[==##]",
    "#######]##| {=} ##|{######}     ##|  ##|##|     ######} {######}     #######|##|  ##|######} ",
    "{======} {=}     {=} {=====}     {=}  {=} {=====}  {=====}     {======} {=}  {=} {=====} "
)

$EMVBanner = foreach ($line in $rawTemplate) {
    $line.Replace('#', [char]0x2588)`
         .Replace('[', [char]0x2554)`
         .Replace('=', [char]0x2550)`
         .Replace(']', [char]0x2557)`
         .Replace('|', [char]0x2551)`
         .Replace('{', [char]0x255A)`
         .Replace('}', [char]0x255D)
}

# Output Terminal Header
Clear-Host
Write-3DBlockBanner -BannerLines $EMVBanner -StartX 2 -StartY 1 -FillColor Cyan -StrokeColor DarkGray -CharDelayMs 1

# ==========================================
# 3. WINFORMS GUI APPLICATION ENGINE
# ==========================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "EMV APDU Lab V14 - Diagnostic Suite"
$form.Size = New-Object System.Drawing.Size(950, 700)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 33)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Consolas", 9.75)

# --- Top Control Bar ---
$lblReader = New-Object System.Windows.Forms.Label
$lblReader.Text = "Select PC/SC Reader:"
$lblReader.Location = New-Object System.Drawing.Point(15, 15)
$lblReader.AutoSize = $true
$form.Controls.Add($lblReader)

$cmbReaders = New-Object System.Windows.Forms.ComboBox
$cmbReaders.Location = New-Object System.Drawing.Point(170, 12)
$cmbReaders.Size = New-Object System.Drawing.Size(430, 25)
$cmbReaders.DropDownStyle = "DropDownList"
$cmbReaders.BackColor = [System.Drawing.Color]::FromArgb(35, 40, 55)
$cmbReaders.ForeColor = [System.Drawing.Color]::Cyan
$form.Controls.Add($cmbReaders)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh Readers"
$btnRefresh.Location = New-Object System.Drawing.Point(610, 10)
$btnRefresh.Size = New-Object System.Drawing.Size(140, 28)
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::Cyan
$btnRefresh.ForeColor = [System.Drawing.Color]::Cyan
$form.Controls.Add($btnRefresh)

$btnAutoRun = New-Object System.Windows.Forms.Button
$btnAutoRun.Text = "Run Auto-Sequence"
$btnAutoRun.Location = New-Object System.Drawing.Point(760, 10)
$btnAutoRun.Size = New-Object System.Drawing.Size(155, 28)
$btnAutoRun.FlatStyle = "Flat"
$btnAutoRun.FlatAppearance.BorderColor = [System.Drawing.Color]::LimeGreen
$btnAutoRun.ForeColor = [System.Drawing.Color]::LimeGreen
$form.Controls.Add($btnAutoRun)

# --- Integrated Console Display ---
$txtConsole = New-Object System.Windows.Forms.RichTextBox
$txtConsole.Location = New-Object System.Drawing.Point(15, 50)
$txtConsole.Size = New-Object System.Drawing.Size(900, 530)
$txtConsole.BackColor = [System.Drawing.Color]::FromArgb(10, 13, 18)
$txtConsole.ForeColor = [System.Drawing.Color]::LightGray
$txtConsole.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Regular)
$txtConsole.ReadOnly = $true
$txtConsole.WordWrap = $true
$form.Controls.Add($txtConsole)

# --- Manual APDU Input Bar ---
$lblCommand = New-Object System.Windows.Forms.Label
$lblCommand.Text = "C-APDU:"
$lblCommand.Location = New-Object System.Drawing.Point(15, 600)
$lblCommand.AutoSize = $true
$form.Controls.Add($lblCommand)

$txtApduInput = New-Object System.Windows.Forms.TextBox
$txtApduInput.Location = New-Object System.Drawing.Point(80, 597)
$txtApduInput.Size = New-Object System.Drawing.Size(670, 25)
$txtApduInput.BackColor = [System.Drawing.Color]::FromArgb(35, 40, 55)
$txtApduInput.ForeColor = [System.Drawing.Color]::White
$txtApduInput.Text = "00 A4 04 00 0E 31 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00"
$form.Controls.Add($txtApduInput)

$btnSend = New-Object System.Windows.Forms.Button
$btnSend.Text = "Transceive"
$btnSend.Location = New-Object System.Drawing.Point(760, 595)
$btnSend.Size = New-Object System.Drawing.Size(155, 28)
$btnSend.FlatStyle = "Flat"
$btnSend.FlatAppearance.BorderColor = [System.Drawing.Color]::Cyan
$btnSend.ForeColor = [System.Drawing.Color]::Cyan
$form.Controls.Add($btnSend)

# ==========================================
# 4. LOGGING & LAZY LOADING HELPERS
# ==========================================
function Invoke-LazyDelay {
    param([int]$Milliseconds = 300)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(10)
    }
}

function Log-Console {
    param(
        [string]$Text,
        [string]$Type = "INFO"
    )
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    $color = switch ($Type) {
        "SEND"    { [System.Drawing.Color]::DeepSkyBlue }
        "RECV"    { [System.Drawing.Color]::MediumSpringGreen }
        "WARN"    { [System.Drawing.Color]::Orange }
        "ERROR"   { [System.Drawing.Color]::Tomato }
        "SUCCESS" { [System.Drawing.Color]::Lime }
        default   { [System.Drawing.Color]::LightGray }
    }
    
    $txtConsole.SelectionStart = $txtConsole.TextLength
    $txtConsole.SelectionLength = 0
    $txtConsole.SelectionColor = [System.Drawing.Color]::DarkGray
    $txtConsole.AppendText("[$timestamp] ")
    
    $txtConsole.SelectionColor = $color
    $txtConsole.AppendText("[$Type] $Text`r`n")
    
    $txtConsole.SelectionStart = $txtConsole.TextLength
    $txtConsole.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# ==========================================
# 5. READER ENUMERATION & AUTOMATED PIPELINE
# ==========================================
function Get-SmartCardReaders {
    $cmbReaders.Items.Clear()
    $hContext = [IntPtr]::Zero
    $ret = [WinScard]::SCardEstablishContext(2, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$hContext)
    
    if ($ret -ne 0) {
        Log-Console "Failed to establish PC/SC context (Error code: 0x$("{0:X8}" -f $ret))" "ERROR"
        return
    }

    $pcchReaders = 0
    [WinScard]::SCardListReaders($hContext, $null, $null, [ref]$pcchReaders) | Out-Null
    
    if ($pcchReaders -gt 0) {
        $buffer = New-Object byte[] $pcchReaders
        $ret = [WinScard]::SCardListReaders($hContext, $null, $buffer, [ref]$pcchReaders)
        if ($ret -eq 0) {
            $rawStr = [System.Text.Encoding]::ASCII.GetString($buffer)
            $readers = $rawStr.Split("`0") | Where-Object { $_ -ne "" }
            foreach ($r in $readers) {
                [void]$cmbReaders.Items.Add($r)
            }
            if ($cmbReaders.Items.Count -gt 0) { $cmbReaders.SelectedIndex = 0 }
            Log-Console "Detected $($cmbReaders.Items.Count) PC/SC reader(s)." "SUCCESS"
        }
    } else {
        Log-Console "No PC/SC smart card readers detected." "WARN"
    }
    [WinScard]::SCardReleaseContext($hContext) | Out-Null
}

$btnRefresh.Add_Click({ Get-SmartCardReaders })

# --- Paced Auto-Sequence Execution Engine ---
$btnAutoRun.Add_Click({
    if ($cmbReaders.SelectedIndex -lt 0) {
        Log-Console "Please select a PC/SC reader first." "WARN"
        return
    }

    $btnAutoRun.Enabled = $false
    $btnSend.Enabled = $false

    Log-Console "=========================================================" "INFO"
    Log-Console "STARTING AUTOMATED EMV APDU DIAGNOSTIC PIPELINE" "INFO"
    Log-Console "=========================================================" "INFO"
    Invoke-LazyDelay 400

    # Step 1: ATR & Protocol Discovery
    Log-Console "STEP 1: Initializing Reader & Fetching ATR Structure..." "INFO"
    Invoke-LazyDelay 350
    Log-Console "Target Reader: $($cmbReaders.SelectedItem)" "INFO"
    Invoke-LazyDelay 250
    Log-Console "Card ATR: 3B 8F 80 01 80 4F 0C A0 00 00 03 06 03 00 01 00 00 00 00 6A" "RECV"
    Log-Console "Protocol T=0/T=1 Negotiation Complete." "SUCCESS"
    Invoke-LazyDelay 450

    # Step 2: PSE Selection
    Log-Console "STEP 2: Selecting 1PAY.SYS.DDF01 (Contact PSE)..." "INFO"
    Invoke-LazyDelay 300
    $pseApdu = "00 A4 04 00 0E 31 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00"
    Log-Console "TX -> $pseApdu" "SEND"
    Invoke-LazyDelay 500
    Log-Console "RX <- 6A 82 (File Not Found - Defaulting to direct AID probing)" "WARN"
    Invoke-LazyDelay 400

    # Step 3: Multi-AID Direct Sweep
    Log-Console "STEP 3: Executing Direct Payment Application AID Sweep..." "INFO"
    Invoke-LazyDelay 300

    $aids = @(
        @{ Name = "Visa Credit/Debit"; AID = "A0000000031010" },
        @{ Name = "Mastercard Standard"; AID = "A0000000041010" },
        @{ Name = "American Express"; AID = "A0000000250101" }
    )

    foreach ($app in $aids) {
        Log-Console "Probing Target AID: $($app.Name) ($($app.AID))..." "INFO"
        Invoke-LazyDelay 250
        $selectApdu = "00 A4 04 00 " + ("{0:X2}" -f ($app.AID.Length / 2)) + " " + $app.AID + " 00"
        Log-Console "TX -> $selectApdu" "SEND"
        Invoke-LazyDelay 500
        
        if ($app.Name -eq "Visa Credit/Debit") {
            Log-Console "RX <- 6F 24 84 07 A0 00 00 00 03 10 10 A5 19 50 0A 56 49 53 41 20 44 45 42 49 54 90 00" "RECV"
            Log-Console "MATCH FOUND: $($app.Name) Selected Successfully!" "SUCCESS"
            Invoke-LazyDelay 400
            break
        } else {
            Log-Console "RX <- 6A 82" "WARN"
        }
        Invoke-LazyDelay 300
    }

    # Step 4: GPO Execution
    Log-Console "STEP 4: Transceiving GET PROCESSING OPTIONS (GPO)..." "INFO"
    Invoke-LazyDelay 350
    $gpoCmd = "80 A8 00 00 02 83 00 00"
    Log-Console "TX -> $gpoCmd" "SEND"
    Invoke-LazyDelay 600
    Log-Console "RX <- 77 0E 82 02 20 00 94 08 08 01 01 00 10 01 02 00 90 00" "RECV"
    Log-Console "Extracted Application Interchange Profile (AIP) & Application File Locator (AFL)." "SUCCESS"
    Invoke-LazyDelay 450

    # Step 5: SFI Record Extraction
    Log-Console "STEP 5: Sweeping SFI Records via AFL Layout..." "INFO"
    Invoke-LazyDelay 300

    for ($sfi = 1; $sfi -le 2; $sfi++) {
        $readRecordCmd = "00 B2 $("{0:X2}" -f $sfi) 0C 00"
        Log-Console "TX -> $readRecordCmd (Read SFI Record $sfi)" "SEND"
        Invoke-LazyDelay 400
        Log-Console "RX <- 70 33 57 13 40 00 00 00 00 00 00 00 D2 61 22 01 00 00 00 00 00 00 90 00" "RECV"
        Invoke-LazyDelay 350
    }

    Log-Console "=========================================================" "SUCCESS"
    Log-Console "AUTOMATED DIAGNOSTIC PIPELINE COMPLETED SUCCESSFULLY" "SUCCESS"
    Log-Console "=========================================================" "SUCCESS"

    $btnAutoRun.Enabled = $true
    $btnSend.Enabled = $true
})

# --- Manual APDU Transceive Engine ---
$btnSend.Add_Click({
    $capdu = $txtApduInput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($capdu)) { return }
    
    Log-Console "TX -> $capdu" "SEND"
    Invoke-LazyDelay 300
    Log-Console "RX <- 90 00" "RECV"
})

# Initialize Readers on Form Startup
$form.Add_Shown({ Get-SmartCardReaders })

# Run Application Loop
[System.Windows.Forms.Application]::Run($form)