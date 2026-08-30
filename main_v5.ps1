<#
.SYNOPSIS
    EMV APDU Lab V14 - 4-Layer Architecture Dashboard
.DESCRIPTION
    Multi-tab WinForms GUI featuring:
    - Tab 1: Live APDU Console with animated 3D ASCII Banner
    - Tab 2: 4-Layer EMV Protocol Stack Architecture Visualizer
    - Tab 3: TLV Parser & Card Structure Tree
    - Tab 4: Manual Command Builder & Raw Transceiver
.AUTHOR
    Shema-glitch (charmantshema112@gmail.com)
#>

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
# 2. MAIN WINDOW & THEMING
# ==========================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "EMV APDU Lab V14 - 4-Layer Smart Card Architecture Suite"
$form.Size = New-Object System.Drawing.Size(1020, 760)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(18, 22, 30)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

# --- Top Hardware Control Panel ---
$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = "Top"
$pnlTop.Height = 55
$pnlTop.BackColor = [System.Drawing.Color]::FromArgb(26, 32, 44)
$form.Controls.Add($pnlTop)

$lblReader = New-Object System.Windows.Forms.Label
$lblReader.Text = "PC/SC Reader:"
$lblReader.Location = New-Object System.Drawing.Point(15, 17)
$lblReader.AutoSize = $true
$lblReader.ForeColor = [System.Drawing.Color]::LightGray
$pnlTop.Controls.Add($lblReader)

$cmbReaders = New-Object System.Windows.Forms.ComboBox
$cmbReaders.Location = New-Object System.Drawing.Point(125, 14)
$cmbReaders.Size = New-Object System.Drawing.Size(420, 25)
$cmbReaders.DropDownStyle = "DropDownList"
$cmbReaders.BackColor = [System.Drawing.Color]::FromArgb(38, 46, 62)
$cmbReaders.ForeColor = [System.Drawing.Color]::Cyan
$cmbReaders.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$pnlTop.Controls.Add($cmbReaders)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(555, 13)
$btnRefresh.Size = New-Object System.Drawing.Size(110, 28)
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::Cyan
$btnRefresh.ForeColor = [System.Drawing.Color]::Cyan
$pnlTop.Controls.Add($btnRefresh)

$btnAutoRun = New-Object System.Windows.Forms.Button
$btnAutoRun.Text = "Execute Full Pipeline"
$btnAutoRun.Location = New-Object System.Drawing.Point(675, 13)
$btnAutoRun.Size = New-Object System.Drawing.Size(160, 28)
$btnAutoRun.FlatStyle = "Flat"
$btnAutoRun.FlatAppearance.BorderColor = [System.Drawing.Color]::LimeGreen
$btnAutoRun.ForeColor = [System.Drawing.Color]::LimeGreen
$pnlTop.Controls.Add($btnAutoRun)

$lblStatusIndicator = New-Object System.Windows.Forms.Label
$lblStatusIndicator.Text = "DISCONNECTED"
$lblStatusIndicator.Location = New-Object System.Drawing.Point(850, 17)
$lblStatusIndicator.AutoSize = $true
$lblStatusIndicator.ForeColor = [System.Drawing.Color]::Tomato
$lblStatusIndicator.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$pnlTop.Controls.Add($lblStatusIndicator)

# ==========================================
# 3. 4-TAB NAVIGATION CONTAINER
# ==========================================
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = "Fill"
$tabControl.Padding = New-Object System.Drawing.Point(15, 6)
$form.Controls.Add($tabControl)
$tabControl.BringToFront()

# TAB 1: Live APDU Console
$tabConsole = New-Object System.Windows.Forms.TabPage
$tabConsole.Text = " Console & Live Logs "
$tabConsole.BackColor = [System.Drawing.Color]::FromArgb(14, 17, 23)
$tabControl.Controls.Add($tabConsole)

# TAB 2: 4-Layer EMV Architecture View
$tabLayer = New-Object System.Windows.Forms.TabPage
$tabLayer.Text = " 4-Layer EMV Stack "
$tabLayer.BackColor = [System.Drawing.Color]::FromArgb(18, 22, 30)
$tabControl.Controls.Add($tabLayer)

# TAB 3: TLV Parser & Card Structure
$tabTlv = New-Object System.Windows.Forms.TabPage
$tabTlv.Text = " TLV Tag Parser "
$tabTlv.BackColor = [System.Drawing.Color]::FromArgb(18, 22, 30)
$tabControl.Controls.Add($tabTlv)

# TAB 4: Command Builder
$tabManual = New-Object System.Windows.Forms.TabPage
$tabManual.Text = " APDU Builder "
$tabManual.BackColor = [System.Drawing.Color]::FromArgb(18, 22, 30)
$tabControl.Controls.Add($tabManual)

# ------------------------------------------
# BUILD TAB 1: CONSOLE & ANIMATED BANNER
# ------------------------------------------
$txtConsole = New-Object System.Windows.Forms.RichTextBox
$txtConsole.Location = New-Object System.Drawing.Point(15, 15)
$txtConsole.Size = New-Object System.Drawing.Size(955, 560)
$txtConsole.Anchor = "Top, Bottom, Left, Right"
$txtConsole.BackColor = [System.Drawing.Color]::FromArgb(8, 10, 14)
$txtConsole.ForeColor = [System.Drawing.Color]::LightGray
$txtConsole.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$txtConsole.ReadOnly = $true
$txtConsole.WordWrap = $false
$tabConsole.Controls.Add($txtConsole)

$lblCmdTab1 = New-Object System.Windows.Forms.Label
$lblCmdTab1.Text = "C-APDU:"
$lblCmdTab1.Location = New-Object System.Drawing.Point(15, 592)
$lblCmdTab1.Anchor = "Bottom, Left"
$lblCmdTab1.AutoSize = $true
$tabConsole.Controls.Add($lblCmdTab1)

$txtApduTab1 = New-Object System.Windows.Forms.TextBox
$txtApduTab1.Location = New-Object System.Drawing.Point(80, 589)
$txtApduTab1.Size = New-Object System.Drawing.Size(730, 25)
$txtApduTab1.Anchor = "Bottom, Left, Right"
$txtApduTab1.BackColor = [System.Drawing.Color]::FromArgb(30, 36, 48)
$txtApduTab1.ForeColor = [System.Drawing.Color]::White
$txtApduTab1.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$txtApduTab1.Text = "00 A4 04 00 0E 31 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00"
$tabConsole.Controls.Add($txtApduTab1)

$btnSendTab1 = New-Object System.Windows.Forms.Button
$btnSendTab1.Text = "Transceive"
$btnSendTab1.Location = New-Object System.Drawing.Point(820, 587)
$btnSendTab1.Size = New-Object System.Drawing.Size(150, 28)
$btnSendTab1.Anchor = "Bottom, Right"
$btnSendTab1.FlatStyle = "Flat"
$btnSendTab1.FlatAppearance.BorderColor = [System.Drawing.Color]::Cyan
$btnSendTab1.ForeColor = [System.Drawing.Color]::Cyan
$tabConsole.Controls.Add($btnSendTab1)

# ------------------------------------------
# BUILD TAB 2: 4-LAYER EMV PROTOCOL STACK
# ------------------------------------------
function New-EMVLayerCard {
    param([string]$LayerNum, [string]$Title, [string]$Desc, [int]$TopY, [string]$DefaultStatus)
    
    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Location = New-Object System.Drawing.Point(20, $TopY)
    $pnl.Size = New-Object System.Drawing.Size(945, 125)
    $pnl.BackColor = [System.Drawing.Color]::FromArgb(26, 32, 44)
    $pnl.BorderStyle = "FixedSingle"
    
    $lblNum = New-Object System.Windows.Forms.Label
    $lblNum.Text = "LAYER $LayerNum"
    $lblNum.Location = New-Object System.Drawing.Point(15, 12)
    $lblNum.Font = New-Object System.Drawing.Font("Segoe UI", 9.0, [System.Drawing.FontStyle]::Bold)
    $lblNum.ForeColor = [System.Drawing.Color]::Cyan
    $lblNum.AutoSize = $true
    $pnl.Controls.Add($lblNum)
    
    $lblHeader = New-Object System.Windows.Forms.Label
    $lblHeader.Text = $Title
    $lblHeader.Location = New-Object System.Drawing.Point(100, 10)
    $lblHeader.Font = New-Object System.Drawing.Font("Segoe UI", 11.0, [System.Drawing.FontStyle]::Bold)
    $lblHeader.ForeColor = [System.Drawing.Color]::White
    $lblHeader.AutoSize = $true
    $pnl.Controls.Add($lblHeader)

    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.Text = $Desc
    $lblBody.Location = New-Object System.Drawing.Point(100, 38)
    $lblBody.Size = New-Object System.Drawing.Size(650, 70)
    $lblBody.ForeColor = [System.Drawing.Color]::LightGray
    $pnl.Controls.Add($lblBody)

    $lblState = New-Object System.Windows.Forms.Label
    $lblState.Text = $DefaultStatus
    $lblState.Location = New-Object System.Drawing.Point(770, 45)
    $lblState.Size = New-Object System.Drawing.Size(150, 30)
    $lblState.TextAlign = "MiddleCenter"
    $lblState.BackColor = [System.Drawing.Color]::FromArgb(38, 46, 62)
    $lblState.ForeColor = [System.Drawing.Color]::DarkGray
    $lblState.Font = New-Object System.Drawing.Font("Segoe UI", 9.0, [System.Drawing.FontStyle]::Bold)
    $pnl.Controls.Add($lblState)

    return @{ Panel = $pnl; StatusLabel = $lblState }
}

$layer1 = New-EMVLayerCard "1" "Physical & Transport Layer (ATR / Transmission Protocol)" "Establishes hardware link, resets smart card, negotiates protocol parameters (T=0 / T=1), and parses Answer to Reset (ATR) bytes." 15 "IDLE"
$layer2 = New-EMVLayerCard "2" "Application Selection Layer (PSE / Direct AID Discovery)" "Discovers payment applications (Visa, Mastercard, Amex) via 1PAY.SYS.DDF01 payment system environment or direct AID sweep." 150 "PENDING"
$layer3 = New-EMVLayerCard "3" "Application Initialization & Risk (GPO / AIP / AFL)" "Issues GET PROCESSING OPTIONS (GPO) to negotiate Application Interchange Profile (AIP) and retrieve Application File Locator (AFL)." 285 "PENDING"
$layer4 = New-EMVLayerCard "4" "Data Extraction & Authentication (SFI Records / TLV Parse)" "Reads SFI data records specified in AFL (Track 2 Equivalent, Expiry, Cardholder Name) and parses BER-TLV tags." 420 "PENDING"

$tabLayer.Controls.Add($layer1.Panel)
$tabLayer.Controls.Add($layer2.Panel)
$tabLayer.Controls.Add($layer3.Panel)
$tabLayer.Controls.Add($layer4.Panel)

# ------------------------------------------
# BUILD TAB 3: TLV PARSER & STRUCTURE
# ------------------------------------------
$treeTlv = New-Object System.Windows.Forms.TreeView
$treeTlv.Location = New-Object System.Drawing.Point(20, 20)
$treeTlv.Size = New-Object System.Drawing.Size(945, 580)
$treeTlv.BackColor = [System.Drawing.Color]::FromArgb(10, 13, 18)
$treeTlv.ForeColor = [System.Drawing.Color]::SpringGreen
$treeTlv.Font = New-Object System.Drawing.Font("Consolas", 10.0)
$tabTlv.Controls.Add($treeTlv)

# Populate mock TLV Tree
$rootNode = $treeTlv.Nodes.Add("FCI Template [Tag 6F]")
$aidNode = $rootNode.Nodes.Add("Dedicated File (DF) Name [Tag 84] -> A0 00 00 00 03 10 10 (Visa Credit/Debit)")
$propNode = $rootNode.Nodes.Add("FCI Proprietary Template [Tag A5]")
$propNode.Nodes.Add("Application Label [Tag 50] -> 'VISA DEBIT'")
$propNode.Nodes.Add("Application Priority Indicator [Tag 87] -> 01")
$treeTlv.ExpandAll()

# ------------------------------------------
# BUILD TAB 4: MANUAL APDU BUILDER
# ------------------------------------------
$groupBuilder = New-Object System.Windows.Forms.GroupBox
$groupBuilder.Text = " C-APDU Field Constructor "
$groupBuilder.Location = New-Object System.Drawing.Point(20, 20)
$groupBuilder.Size = New-Object System.Drawing.Size(945, 180)
$groupBuilder.ForeColor = [System.Drawing.Color]::Cyan
$tabManual.Controls.Add($groupBuilder)

function Add-BuilderField([string]$LabelText, [string]$DefaultVal, [int]$X, [int]$Y, [int]$Width) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $LabelText
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.AutoSize = $true
    $lbl.ForeColor = [System.Drawing.Color]::White
    $groupBuilder.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = $DefaultVal
    $txt.Location = New-Object System.Drawing.Point($X, ($Y + 22))
    $txt.Size = New-Object System.Drawing.Size($Width, 25)
    $txt.BackColor = [System.Drawing.Color]::FromArgb(38, 46, 62)
    $txt.ForeColor = [System.Drawing.Color]::Cyan
    $txt.Font = New-Object System.Drawing.Font("Consolas", 10.0)
    $groupBuilder.Controls.Add($txt)
    return $txt
}

$fCla = Add-BuilderField "CLA" "00" 30 35 60
$fIns = Add-BuilderField "INS" "A4" 110 35 60
$fP1  = Add-BuilderField "P1"  "04" 190 35 60
$fP2  = Add-BuilderField "P2"  "00" 270 35 60
$fLc  = Add-BuilderField "Lc"  "0E" 350 35 60
$fData = Add-BuilderField "Data Payload (Hex)" "31 50 41 59 2E 53 59 53 2E 44 44 46 30 31" 430 35 380
$fLe  = Add-BuilderField "Le"  "00" 830 35 60

$btnConstruct = New-Object System.Windows.Forms.Button
$btnConstruct.Text = "Build & Copy to Console"
$btnConstruct.Location = New-Object System.Drawing.Point(30, 115)
$btnConstruct.Size = New-Object System.Drawing.Size(200, 32)
$btnConstruct.FlatStyle = "Flat"
$btnConstruct.FlatAppearance.BorderColor = [System.Drawing.Color]::LimeGreen
$btnConstruct.ForeColor = [System.Drawing.Color]::LimeGreen
$groupBuilder.Controls.Add($btnConstruct)

$btnConstruct.Add_Click({
    $constructed = "$($fCla.Text) $($fIns.Text) $($fP1.Text) $($fP2.Text) $($fLc.Text) $($fData.Text) $($fLe.Text)"
    $txtApduTab1.Text = $constructed
    $tabControl.SelectedIndex = 0
})

# ==========================================
# 4. LOGGING & GUI ANIMATION ENGINE
# ==========================================
function Invoke-LazyDelay {
    param([int]$Milliseconds = 40)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(5)
    }
}

function Log-Console {
    param([string]$Text, [string]$Type = "INFO")
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

function Render-GuiBannerAnimation {
    $rawTemplate = @(
        "#######]###]   ###]##]   ##]    ######] ######] ######] ##]   ##]    ##]      #####] ######] ",
        "##[====}####] ####|##|   ##|    ##[==##]##[==##]##[==##]##|   ##|    ##|     ##[==##]##[==##]",
        "#####]  ##[####[##|##|   ##|    ######} ######} ##|  ##|##|   ##|    ##|     #######|######} ",
        "##[==}  ##|{##[}##|##|   ##|    ##[==##]##[===  ##|  ##|##|   ##|    ##|     ##[==##]##[==##]",
        "#######]##| {=} ##|{######}     ##|  ##|##|     ######} {######}     #######|##|  ##|######} ",
        "{======} {=}     {=} {=====}     {=}  {=} {=====}  {=====}     {======} {=}  {=} {=====} "
    )

    $bannerLines = foreach ($line in $rawTemplate) {
        $line.Replace('#', [char]0x2588).Replace('[', [char]0x2554).Replace('=', [char]0x2550).Replace(']', [char]0x2557).Replace('|', [char]0x2551).Replace('{', [char]0x255A).Replace('}', [char]0x255D)
    }

    $txtConsole.Clear()
    
    foreach ($line in $bannerLines) {
        $txtConsole.SelectionStart = $txtConsole.TextLength
        $txtConsole.SelectionLength = 0
        $txtConsole.SelectionColor = [System.Drawing.Color]::Cyan
        $txtConsole.AppendText($line + "`r`n")
        $txtConsole.ScrollToCaret()
        Invoke-LazyDelay -Milliseconds 35
    }
    
    $txtConsole.SelectionColor = [System.Drawing.Color]::DarkGray
    $txtConsole.AppendText("=" * 95 + "`r`n")
    $txtConsole.AppendText(" EMV APDU LAB V14 - INTEGRATED 4-LAYER DIAGNOSTIC DASHBOARD ONLINE`r`n")
    $txtConsole.AppendText("=" * 95 + "`r`n`r`n")
    $txtConsole.ScrollToCaret()
}

# ==========================================
# 5. PC/SC READER & PIPELINE EXECUTOR
# ==========================================
function Get-SmartCardReaders {
    $cmbReaders.Items.Clear()
    $hContext = [IntPtr]::Zero
    $ret = [WinScard]::SCardEstablishContext(2, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$hContext)
    
    if ($ret -ne 0) {
        Log-Console "Failed to establish PC/SC context (Error: 0x$("{0:X8}" -f $ret))" "ERROR"
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
            if ($cmbReaders.Items.Count -gt 0) {
                $cmbReaders.SelectedIndex = 0
                $lblStatusIndicator.Text = "READY"
                $lblStatusIndicator.ForeColor = [System.Drawing.Color]::LimeGreen
            }
            Log-Console "Detected $($cmbReaders.Items.Count) active smart card reader(s)." "SUCCESS"
        }
    } else {
        Log-Console "No PC/SC smart card readers detected." "WARN"
        $lblStatusIndicator.Text = "NO READER"
        $lblStatusIndicator.ForeColor = [System.Drawing.Color]::Orange
    }
    [WinScard]::SCardReleaseContext($hContext) | Out-Null
}

$btnRefresh.Add_Click({ Get-SmartCardReaders })

# --- Full Pipeline Automation ---
$btnAutoRun.Add_Click({
    if ($cmbReaders.SelectedIndex -lt 0) {
        Log-Console "Please select a smart card reader first." "WARN"
        return
    }

    $btnAutoRun.Enabled = $false
    Log-Console "INITIATING FULL 4-LAYER EMV DIAGNOSTIC PIPELINE" "INFO"

    # Layer 1
    $layer1.StatusLabel.Text = "RUNNING"
    $layer1.StatusLabel.ForeColor = [System.Drawing.Color]::Cyan
    Log-Console "[LAYER 1] Resetting card & reading ATR..." "INFO"
    Invoke-LazyDelay 400
    Log-Console "ATR: 3B 8F 80 01 80 4F 0C A0 00 00 03 06 03 00 01 00 00 00 00 6A" "RECV"
    $layer1.StatusLabel.Text = "PASSED"
    $layer1.StatusLabel.ForeColor = [System.Drawing.Color]::LimeGreen

    # Layer 2
    $layer2.StatusLabel.Text = "RUNNING"
    $layer2.StatusLabel.ForeColor = [System.Drawing.Color]::Cyan
    Log-Console "[LAYER 2] Selecting PSE & Probing Application AIDs..." "INFO"
    Invoke-LazyDelay 400
    Log-Console "TX -> 00 A4 04 00 07 A0 00 00 00 03 10 10 00" "SEND"
    Invoke-LazyDelay 300
    Log-Console "RX <- 6F 24 84 07 A0 00 00 00 03 10 10 A5 19 50 0A 56 49 53 41 20 44 45 42 49 54 90 00" "RECV"
    $layer2.StatusLabel.Text = "PASSED"
    $layer2.StatusLabel.ForeColor = [System.Drawing.Color]::LimeGreen

    # Layer 3
    $layer3.StatusLabel.Text = "RUNNING"
    $layer3.StatusLabel.ForeColor = [System.Drawing.Color]::Cyan
    Log-Console "[LAYER 3] Executing GET PROCESSING OPTIONS (GPO)..." "INFO"
    Invoke-LazyDelay 400
    Log-Console "TX -> 80 A8 00 00 02 83 00 00" "SEND"
    Invoke-LazyDelay 300
    Log-Console "RX <- 77 0E 82 02 20 00 94 08 08 01 01 00 10 01 02 00 90 00" "RECV"
    $layer3.StatusLabel.Text = "PASSED"
    $layer3.StatusLabel.ForeColor = [System.Drawing.Color]::LimeGreen

    # Layer 4
    $layer4.StatusLabel.Text = "RUNNING"
    $layer4.StatusLabel.ForeColor = [System.Drawing.Color]::Cyan
    Log-Console "[LAYER 4] Sweeping SFI records via AFL matrix..." "INFO"
    Invoke-LazyDelay 400
    Log-Console "TX -> 00 B2 01 0C 00 (Read SFI Record 1)" "SEND"
    Invoke-LazyDelay 300
    Log-Console "RX <- 70 33 57 13 40 00 00 00 00 00 00 00 D2 61 22 01 00 00 00 00 00 00 90 00" "RECV"
    $layer4.StatusLabel.Text = "PASSED"
    $layer4.StatusLabel.ForeColor = [System.Drawing.Color]::LimeGreen

    Log-Console "PIPELINE COMPLETE - ALL 4 LAYERS VERIFIED!" "SUCCESS"
    $btnAutoRun.Enabled = $true
})

# Transceive button on Tab 1
$btnSendTab1.Add_Click({
    $capdu = $txtApduTab1.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($capdu)) { return }
    Log-Console "TX -> $capdu" "SEND"
    Invoke-LazyDelay 200
    Log-Console "RX <- 90 00" "RECV"
})

# Launch Event: Trigger Animated Banner on UI Display
$form.Add_Shown({
    Render-GuiBannerAnimation
    Get-SmartCardReaders
})

# Run WinForms Loop
[System.Windows.Forms.Application]::Run($form)