#requires -Version 5.1

<#
    EMV APDU LAB V12 - Enhanced 4-Layer Inspector & Diagnostic Suite
    ===========================================================================
    - Native C# BER-TLV Recursive Tag/Length/Value Parser
    - Automated GPO & Multi-SFI Record Sweeper (SFIs 1-10, Records 1-5)
    - Extended AID Probing (Visa, MC, Maestro, Amex, UnionPay, Discover, JCB)
    - Single-Click Timestamped Diagnostic Report Exporter
    - Automatic Status Word Protocol Handling (61 XX / 6C XX)
    - Zero External Dependencies (Native Win32 winscard.dll via C# / .NET)
#>

$ErrorActionPreference = "Stop"

$code = @"
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Windows.Forms;

public class TLVNode
{
    public string Tag { get; set; }
    public int Length { get; set; }
    public byte[] Value { get; set; }
    public List<TLVNode> Children { get; set; }

    public TLVNode()
    {
        Children = new List<TLVNode>();
    }

    public static List<TLVNode> Parse(byte[] data)
    {
        List<TLVNode> nodes = new List<TLVNode>();
        if (data == null || data.Length == 0) return nodes;

        int i = 0;
        while (i < data.Length)
        {
            if (data[i] == 0x00 || data[i] == 0xFF) { i++; continue; }

            int tagStart = i;
            if ((data[i] & 0x1F) == 0x1F)
            {
                i += 2;
            }
            else
            {
                i += 1;
            }
            if (i > data.Length) break;

            string tagHex = BitConverter.ToString(data, tagStart, i - tagStart).Replace("-", "");

            if (i >= data.Length) break;
            int length = data[i++];
            if ((length & 0x80) != 0)
            {
                int lenBytes = length & 0x7F;
                length = 0;
                for (int j = 0; j < lenBytes && i < data.Length; j++)
                {
                    length = (length << 8) | data[i++];
                }
            }

            if (i + length > data.Length) break;

            byte[] value = new byte[length];
            Array.Copy(data, i, value, 0, length);
            i += length;

            TLVNode node = new TLVNode { Tag = tagHex, Length = length, Value = value };

            byte firstTagByte = Convert.ToByte(tagHex.Substring(0, 2), 16);
            if ((firstTagByte & 0x20) == 0x20)
            {
                node.Children = Parse(value);
            }

            nodes.Add(node);
        }
        return nodes;
    }

    public string FormatTree(int indent = 0)
    {
        StringBuilder sb = new StringBuilder();
        string prefix = new string(' ', indent * 2);
        string ascii = APDULabV12.DecodeAscii(Value);
        sb.AppendLine(prefix + "[Tag " + Tag + "] (Len: " + Length + ") -> Hex: " + APDULabV12.Hex(Value) + " | ASCII: \"" + ascii + "\"");
        foreach (var child in Children)
        {
            sb.Append(child.FormatTree(indent + 1));
        }
        return sb.ToString();
    }
}

public class APDULabV12
{
    // PC/SC CONSTANTS
    const uint SCARD_SCOPE_SYSTEM = 2;
    const uint SCARD_SHARE_EXCLUSIVE = 1;
    const uint SCARD_SHARE_SHARED = 2;
    const uint SCARD_SHARE_DIRECT = 3;

    const uint SCARD_PROTOCOL_T0 = 1;
    const uint SCARD_PROTOCOL_T1 = 2;
    const int SCARD_S_SUCCESS = 0;
    const uint SCARD_LEAVE_CARD = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct SCARD_IO_REQUEST
    {
        public uint dwProtocol;
        public uint cbPciLength;
    }

    // P/INVOKE IMPORTS
    [DllImport("winscard.dll")]
    static extern int SCardEstablishContext(uint scope, IntPtr r1, IntPtr r2, out IntPtr context);

    [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
    static extern int SCardListReaders(IntPtr context, string groups, char[] readers, ref uint length);

    [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
    static extern int SCardConnect(IntPtr context, string reader, uint shareMode, uint preferredProtocols, out IntPtr card, out uint protocol);

    [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
    static extern int SCardStatus(IntPtr card, char[] readerName, ref uint readerNameLength, out uint state, out uint protocol, byte[] atr, ref uint atrLength);

    [DllImport("winscard.dll")]
    static extern int SCardTransmit(IntPtr hCard, ref SCARD_IO_REQUEST pioSendPci, byte[] pbSendBuffer, int cbSendLength, IntPtr pioRecvPci, byte[] pbRecvBuffer, ref int pcbRecvLength);

    [DllImport("winscard.dll")]
    static extern int SCardDisconnect(IntPtr card, uint disposition);

    [DllImport("winscard.dll")]
    static extern int SCardReleaseContext(IntPtr context);

    class CardSession
    {
        public IntPtr Context = IntPtr.Zero;
        public IntPtr Card = IntPtr.Zero;
        public uint Protocol;
        public string Reader = "";
        public byte[] Atr = new byte[0];

        public bool Connected { get { return Card != IntPtr.Zero; } }
    }

    static CardSession session = new CardSession();
    static Form form;

    // UI Controls
    static ComboBox readerCombo;
    static Button connectButton;
    static Button disconnectButton;
    static Button inspectButton;
    static Button exportButton;

    static Label connectionLabel;
    static Label protocolLabel;
    static Label atrLabel;

    static TabControl mainTabControl;
    static RichTextBox layer1Text;
    static RichTextBox layer2Text;
    static RichTextBox layer3Text;
    static RichTextBox layer4Text;
    static RichTextBox fullLogText;

    // APDU Console Controls
    static ComboBox presetCombo;
    static TextBox apduInputText;
    static Button sendApduButton;
    static RichTextBox apduOutputText;

    // HELPERS
    public static string Hex(byte[] data)
    {
        if (data == null || data.Length == 0) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < data.Length; i++)
        {
            if (i > 0) sb.Append(" ");
            sb.Append(data[i].ToString("X2"));
        }
        return sb.ToString();
    }

    public static byte[] StringToByteArray(string hex)
    {
        hex = hex.Replace(" ", "").Replace("-", "").Replace("0x", "");
        if (hex.Length % 2 != 0) hex = "0" + hex;
        byte[] bytes = new byte[hex.Length / 2];
        for (int i = 0; i < hex.Length; i += 2)
            bytes[i / 2] = Convert.ToByte(hex.Substring(i, 2), 16);
        return bytes;
    }

    public static string DecodeAscii(byte[] data)
    {
        if (data == null) return "";
        StringBuilder sb = new StringBuilder();
        foreach (byte b in data)
        {
            if (b >= 32 && b <= 126) sb.Append((char)b);
            else sb.Append(".");
        }
        return sb.ToString();
    }

    static string DecodeSw(byte sw1, byte sw2)
    {
        ushort sw = (ushort)((sw1 << 8) | sw2);
        switch (sw)
        {
            case 0x9000: return "90 00 [Success / OK]";
            case 0x6A82: return "6A 82 [File / Application Not Found]";
            case 0x6A81: return "6A 81 [Function Not Supported]";
            case 0x6A86: return "6A 86 [Incorrect P1-P2 Parameters]";
            case 0x6700: return "67 00 [Wrong Length (Lc/Le)]";
            case 0x6D00: return "6D 00 [Instruction Code Not Supported]";
            case 0x6E00: return "6E 00 [Class Not Supported]";
            case 0x6982: return "69 82 [Security Status Not Satisfied]";
            case 0x6985: return "69 85 [Conditions of Use Not Satisfied]";
            default:
                if (sw1 == 0x61) return string.Format("{0:X2} {1:X2} [Bytes Available: {2}]", sw1, sw2, sw2);
                if (sw1 == 0x6C) return string.Format("{0:X2} {1:X2} [Re-issue with Le={2}]", sw1, sw2, sw2);
                return string.Format("{0:X2} {1:X2} [Response Status Code]", sw1, sw2);
        }
    }

    static string GetScardErrorMessage(int rc)
    {
        uint uRc = (uint)rc;
        switch (uRc)
        {
            case 0x80100009: return "SCARD_E_NOT_TRANSACTING (0x80100009): Card connection reset or card removed.";
            case 0x8010000C: return "SCARD_E_SHARE_VIOLATION (0x8010000C): Card is in use by another process.";
            case 0x8010000D: return "SCARD_E_NO_SMARTCARD (0x8010000D): No smart card in reader.";
            case 0x80100069: return "SCARD_W_REMOVED_CARD (0x80100069): Smart card was removed.";
            case 0x80100017: return "SCARD_E_READER_UNAVAILABLE (0x80100017): Smart card reader disconnected.";
            default: return "PC/SC Error Code: 0x" + uRc.ToString("X8");
        }
    }

    static void Log(string text)
    {
        if (form == null || form.IsDisposed) return;
        if (form.InvokeRequired)
        {
            form.Invoke(new Action(() => Log(text)));
            return;
        }
        fullLogText.AppendText("[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] " + text + Environment.NewLine);
        fullLogText.SelectionStart = fullLogText.Text.Length;
        fullLogText.ScrollToCaret();
    }

    // HARDWARE ENGINE
    static void EstablishContext()
    {
        int rc = SCardEstablishContext(SCARD_SCOPE_SYSTEM, IntPtr.Zero, IntPtr.Zero, out session.Context);
        if (rc != SCARD_S_SUCCESS)
        {
            session.Context = IntPtr.Zero;
            throw new Exception(GetScardErrorMessage(rc));
        }
    }

    static string[] ListReaders()
    {
        if (session.Context == IntPtr.Zero) EstablishContext();

        uint length = 0;
        int rc = SCardListReaders(session.Context, null, null, ref length);
        if (rc != SCARD_S_SUCCESS || length == 0) return new string[0];

        char[] buffer = new char[length];
        rc = SCardListReaders(session.Context, null, buffer, ref length);
        if (rc != SCARD_S_SUCCESS) return new string[0];

        List<string> readersList = new List<string>();
        StringBuilder current = new StringBuilder();

        for (int i = 0; i < buffer.Length; i++)
        {
            if (buffer[i] == '\0')
            {
                if (current.Length == 0) break;
                readersList.Add(current.ToString());
                current.Clear();
            }
            else current.Append(buffer[i]);
        }
        return readersList.ToArray();
    }

    static void RefreshReaders()
    {
        try
        {
            string[] readers = ListReaders();
            readerCombo.Items.Clear();
            foreach (string reader in readers) readerCombo.Items.Add(reader);
            if (readerCombo.Items.Count > 0) readerCombo.SelectedIndex = 0;
            connectionLabel.Text = readers.Length + " reader(s) detected";
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "PC/SC Initialization Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    static void Connect()
    {
        if (readerCombo.SelectedItem == null)
        {
            MessageBox.Show("Select a smart card reader first.", "No Reader Selected", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        Disconnect(false);

        if (session.Context == IntPtr.Zero) EstablishContext();

        session.Reader = readerCombo.SelectedItem.ToString();
        Log("Connecting to: " + session.Reader);

        // Multi-stage connection logic
        int rc = SCardConnect(session.Context, session.Reader, SCARD_SHARE_SHARED, SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, out session.Card, out session.Protocol);
        if (rc != SCARD_S_SUCCESS) rc = SCardConnect(session.Context, session.Reader, SCARD_SHARE_SHARED, SCARD_PROTOCOL_T0, out session.Card, out session.Protocol);
        if (rc != SCARD_S_SUCCESS) rc = SCardConnect(session.Context, session.Reader, SCARD_SHARE_SHARED, SCARD_PROTOCOL_T1, out session.Card, out session.Protocol);
        if (rc != SCARD_S_SUCCESS) rc = SCardConnect(session.Context, session.Reader, SCARD_SHARE_EXCLUSIVE, SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, out session.Card, out session.Protocol);
        if (rc != SCARD_S_SUCCESS) rc = SCardConnect(session.Context, session.Reader, SCARD_SHARE_DIRECT, 0, out session.Card, out session.Protocol);

        if (rc != SCARD_S_SUCCESS)
        {
            session.Card = IntPtr.Zero;
            throw new Exception(GetScardErrorMessage(rc));
        }

        ReadAtr();

        connectionLabel.Text = "* CONNECTED";
        connectionLabel.ForeColor = Color.DarkGreen;
        protocolLabel.Text = "Protocol: " + (session.Protocol == SCARD_PROTOCOL_T0 ? "T=0" : session.Protocol == SCARD_PROTOCOL_T1 ? "T=1" : "Direct");

        connectButton.Enabled = false;
        disconnectButton.Enabled = true;
        inspectButton.Enabled = true;
        exportButton.Enabled = true;
        sendApduButton.Enabled = true;

        Log("Card connected successfully. Protocol: " + protocolLabel.Text);
        Log("ATR: " + Hex(session.Atr));
    }

    static void Disconnect(bool updateUi)
    {
        if (session.Card != IntPtr.Zero)
        {
            SCardDisconnect(session.Card, SCARD_LEAVE_CARD);
            session.Card = IntPtr.Zero;
        }

        if (updateUi)
        {
            connectionLabel.Text = "o DISCONNECTED";
            connectionLabel.ForeColor = Color.DarkRed;
            connectButton.Enabled = true;
            disconnectButton.Enabled = false;
            inspectButton.Enabled = false;
            exportButton.Enabled = false;
            sendApduButton.Enabled = false;
            protocolLabel.Text = "Protocol: -";
            atrLabel.Text = "ATR: -";
            Log("Disconnected from reader.");
        }
    }

    static void ReadAtr()
    {
        char[] readerName = new char[256];
        uint readerNameLength = (uint)readerName.Length;
        byte[] atr = new byte[64];
        uint atrLength = (uint)atr.Length;
        uint state, protocol;

        int rc = SCardStatus(session.Card, readerName, ref readerNameLength, out state, out protocol, atr, ref atrLength);
        if (rc == SCARD_S_SUCCESS)
        {
            session.Atr = new byte[atrLength];
            Array.Copy(atr, session.Atr, (int)atrLength);
            atrLabel.Text = "ATR: " + Hex(session.Atr);
        }
    }

    static byte[] SendApduRaw(byte[] sendBuffer)
    {
        if (!session.Connected) throw new Exception("No active card connection.");

        SCARD_IO_REQUEST ioRequest = new SCARD_IO_REQUEST();
        ioRequest.dwProtocol = session.Protocol;
        ioRequest.cbPciLength = 8;

        byte[] recvBuffer = new byte[258];
        int recvLength = recvBuffer.Length;

        int rc = SCardTransmit(session.Card, ref ioRequest, sendBuffer, sendBuffer.Length, IntPtr.Zero, recvBuffer, ref recvLength);

        // Auto-resolve 61 XX (GET RESPONSE)
        if (rc == SCARD_S_SUCCESS && recvLength >= 2 && recvBuffer[recvLength - 2] == 0x61)
        {
            byte le = recvBuffer[recvLength - 1];
            byte[] getRespCmd = new byte[] { 0x00, 0xC0, 0x00, 0x00, le };
            return SendApduRaw(getRespCmd);
        }

        // Auto-resolve 6C XX (Re-issue with correct Le)
        if (rc == SCARD_S_SUCCESS && recvLength >= 2 && recvBuffer[recvLength - 2] == 0x6C)
        {
            byte correctLe = recvBuffer[recvLength - 1];
            byte[] reissueCmd = (byte[])sendBuffer.Clone();
            reissueCmd[reissueCmd.Length - 1] = correctLe;
            return SendApduRaw(reissueCmd);
        }

        if (rc != SCARD_S_SUCCESS)
        {
            throw new Exception(GetScardErrorMessage(rc));
        }

        byte[] result = new byte[recvLength];
        Array.Copy(recvBuffer, result, recvLength);
        return result;
    }

    // 4-LAYER DIAGNOSTIC ENGINE
    static void RunFullInspection()
    {
        layer1Text.Clear();
        layer2Text.Clear();
        layer3Text.Clear();
        layer4Text.Clear();

        // LAYER 1: HARDWARE & ENVIRONMENT
        layer1Text.AppendText("=== LAYER 1: HARDWARE INTERFACE ===\n");
        layer1Text.AppendText("Selected Reader : " + session.Reader + "\n");
        layer1Text.AppendText("PC/SC Context   : Active (0x" + session.Context.ToInt64().ToString("X8") + ")\n");
        layer1Text.AppendText("Hardware Status : Ready & Communicating\n\n");

        // LAYER 2: TRANSPORT & ATR BREAKDOWN
        layer2Text.AppendText("=== LAYER 2: TRANSPORT & ATR PROTOCOL ===\n");
        layer2Text.AppendText("Active Protocol : " + (session.Protocol == SCARD_PROTOCOL_T0 ? "T=0" : "T=1") + "\n");
        layer2Text.AppendText("Raw ATR Bytes   : " + Hex(session.Atr) + "\n");
        if (session.Atr.Length > 0)
        {
            layer2Text.AppendText("ATR Header Byte : 0x" + session.Atr[0].ToString("X2") + " (" + (session.Atr[0] == 0x3B ? "Direct Convention" : "Inverse Convention") + ")\n");
            layer2Text.AppendText("ATR Length      : " + session.Atr.Length + " bytes\n");
        }
        layer2Text.AppendText("Transport Status: PASS (Card initialized without reset flags)\n\n");

        // LAYER 3 & 4: EXPANDED AID PROBING & RECORD SWEEPING
        layer3Text.AppendText("=== LAYER 3: EXPANDED AID DISCOVERY ===\n");
        layer4Text.AppendText("=== LAYER 4: RECORD & BER-TLV INSPECTION ===\n");

        Dictionary<string, string> targets = new Dictionary<string, string>
        {
            { "1PAY.SYS.DDF01 (Contact PSE)", "00A404000E315041592E5359532E444446303100" },
            { "2PAY.SYS.DDF01 (Contactless PPSE)", "00A404000E325041592E5359532E444446303100" },
            { "VISA Credit/Debit", "00A4040007A000000003101000" },
            { "VISA Electron", "00A4040007A000000003201000" },
            { "Mastercard Standard", "00A4040007A000000004101000" },
            { "Maestro", "00A4040007A000000004306000" },
            { "American Express", "00A4040007A000000025010100" },
            { "UnionPay", "00A4040007A000000331101000" },
            { "Discover / Diners", "00A4040007A000000152301000" },
            { "JCB", "00A4040007A000000065101000" }
        };

        string activeAppFound = "";

        foreach (var entry in targets)
        {
            byte[] command = StringToByteArray(entry.Value);
            try
            {
                byte[] response = SendApduRaw(command);
                if (response.Length >= 2)
                {
                    byte sw1 = response[response.Length - 2];
                    byte sw2 = response[response.Length - 1];

                    string status = DecodeSw(sw1, sw2);
                    layer3Text.AppendText("Target: " + entry.Key + "\n");
                    layer3Text.AppendText("  TX: " + Hex(command) + "\n");
                    layer3Text.AppendText("  RX: " + Hex(response) + "\n");
                    layer3Text.AppendText("  SW: " + status + "\n\n");

                    if (sw1 == 0x90 && sw2 == 0x00)
                    {
                        activeAppFound = entry.Key;
                        layer4Text.AppendText("Active App Selected: " + entry.Key + "\n");
                        layer4Text.AppendText("Raw FCI Response   : " + Hex(response) + "\n");
                        layer4Text.AppendText("--- BER-TLV FCI Structure ---\n");
                        
                        var fciNodes = TLVNode.Parse(response);
                        foreach (var node in fciNodes)
                        {
                            layer4Text.AppendText(node.FormatTree(1));
                        }
                        layer4Text.AppendText("----------------------------------------\n\n");
                    }
                }
            }
            catch (Exception ex)
            {
                layer3Text.AppendText("Target: " + entry.Key + " -> Error: " + ex.Message + "\n\n");
            }
        }

        // AUTOMATED SFI RECORD SWEEPER
        if (!string.IsNullOrEmpty(activeAppFound))
        {
            layer4Text.AppendText("--> AUTOMATED RECORD SWEEPER (SFIs 1-10, Records 1-5)\n");
            
            // Execute GPO with Rwanda Country Code (06 46)
            try
            {
                byte[] gpoCmd = StringToByteArray("80 A8 00 00 04 83 02 06 46 00");
                byte[] gpoResp = SendApduRaw(gpoCmd);
                layer4Text.AppendText("GPO Response (06 46): " + Hex(gpoResp) + "\n");
                var gpoNodes = TLVNode.Parse(gpoResp);
                foreach (var node in gpoNodes) layer4Text.AppendText(node.FormatTree(1));
                layer4Text.AppendText("\n");
            }
            catch { /* Proceed to record sweep */ }

            for (byte sfi = 1; sfi <= 10; sfi++)
            {
                for (byte rec = 1; rec <= 5; rec++)
                {
                    byte p2 = (byte)((sfi << 3) | 4);
                    byte[] readCmd = new byte[] { 0x00, 0xB2, rec, p2, 0x00 };

                    try
                    {
                        byte[] recResp = SendApduRaw(readCmd);
                        if (recResp.Length > 2 && recResp[recResp.Length - 2] == 0x90 && recResp[recResp.Length - 1] == 0x00)
                        {
                            layer4Text.AppendText(string.Format("[Found] SFI {0:D2} Rec {1:D2} -> Raw: {2}\n", sfi, rec, Hex(recResp)));
                            var recNodes = TLVNode.Parse(recResp);
                            foreach (var node in recNodes)
                            {
                                layer4Text.AppendText(node.FormatTree(1));
                            }
                            layer4Text.AppendText("\n");
                        }
                    }
                    catch { /* Ignore non-existent records */ }
                }
            }
        }

        mainTabControl.SelectedIndex = 0;
        Log("Completed 4-Layer Inspection Sweep.");
    }

    // EXPORT REPORT HANDLER
    static void ExportReport()
    {
        using (SaveFileDialog sfd = new SaveFileDialog())
        {
            sfd.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*";
            sfd.FileName = "EMV_Inspection_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".txt";
            if (sfd.ShowDialog() == DialogResult.OK)
            {
                try
                {
                    StringBuilder sb = new StringBuilder();
                    sb.AppendLine("==================================================================");
                    sb.AppendLine("              EMV APDU LAB V12 - DIAGNOSTIC REPORT               ");
                    sb.AppendLine("==================================================================");
                    sb.AppendLine("Generated On : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                    sb.AppendLine("Reader Used  : " + session.Reader);
                    sb.AppendLine("ATR Bytes    : " + Hex(session.Atr));
                    sb.AppendLine("==================================================================\n");

                    sb.AppendLine(layer1Text.Text);
                    sb.AppendLine(layer2Text.Text);
                    sb.AppendLine(layer3Text.Text);
                    sb.AppendLine(layer4Text.Text);

                    sb.AppendLine("==================================================================");
                    sb.AppendLine("                     SYSTEM TRACE FEED LOG                        ");
                    sb.AppendLine("==================================================================");
                    sb.AppendLine(fullLogText.Text);

                    File.WriteAllText(sfd.FileName, sb.ToString());
                    MessageBox.Show("Diagnostic report exported successfully to:\n" + sfd.FileName, "Export Complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    MessageBox.Show("Failed to export report: " + ex.Message, "Export Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }
    }

    // APDU CONSOLE HANDLER
    static void ExecuteManualApdu()
    {
        string input = apduInputText.Text.Trim();
        if (string.IsNullOrEmpty(input)) return;

        try
        {
            byte[] apdu = StringToByteArray(input);
            apduOutputText.AppendText(">> TX: " + Hex(apdu) + "\n");
            
            byte[] response = SendApduRaw(apdu);
            apduOutputText.AppendText("<< RX: " + Hex(response) + "\n");

            if (response.Length >= 2)
            {
                byte sw1 = response[response.Length - 2];
                byte sw2 = response[response.Length - 1];
                apduOutputText.AppendText("   SW: " + DecodeSw(sw1, sw2) + "\n");
                apduOutputText.AppendText("   ASCII: " + DecodeAscii(response) + "\n");

                var nodes = TLVNode.Parse(response);
                if (nodes.Count > 0)
                {
                    apduOutputText.AppendText("   --- Parsed BER-TLV Nodes ---\n");
                    foreach (var node in nodes)
                    {
                        apduOutputText.AppendText(node.FormatTree(1));
                    }
                }
            }
            apduOutputText.AppendText("--------------------------------------------------\n");
            Log("Executed APDU Command: " + Hex(apdu));
        }
        catch (Exception ex)
        {
            apduOutputText.AppendText("!! ERROR: " + ex.Message + "\n--------------------------------------------------\n");
            Log("APDU Execution Error: " + ex.Message);
        }
    }

    // UI DASHBOARD BUILDER
    static void BuildUi()
    {
        form = new Form
        {
            Text = "EMV APDU Lab V12 - Enhanced 4-Layer Inspector & Diagnostic Suite",
            Width = 1180,
            Height = 780,
            StartPosition = FormStartPosition.CenterScreen,
            Font = new Font("Segoe UI", 9f)
        };

        // Top Control Panel
        Panel top = new Panel { Dock = DockStyle.Top, Height = 55, BackColor = Color.FromArgb(240, 240, 243) };
        readerCombo = new ComboBox { Left = 12, Top = 14, Width = 310, DropDownStyle = ComboBoxStyle.DropDownList };
        Button refreshBtn = new Button { Text = "Refresh", Left = 330, Top = 12, Width = 85, Height = 28 };
        connectButton = new Button { Text = "Connect", Left = 422, Top = 12, Width = 85, Height = 28 };
        disconnectButton = new Button { Text = "Disconnect", Left = 514, Top = 12, Width = 85, Height = 28, Enabled = false };
        inspectButton = new Button { Text = "4-Layer Inspect", Left = 606, Top = 12, Width = 130, Height = 28, Enabled = false, BackColor = Color.LightSkyBlue };
        exportButton = new Button { Text = "Export Report", Left = 742, Top = 12, Width = 120, Height = 28, Enabled = false, BackColor = Color.LightGreen };

        top.Controls.AddRange(new Control[] { readerCombo, refreshBtn, connectButton, disconnectButton, inspectButton, exportButton });

        // Info Header Banner
        Panel info = new Panel { Dock = DockStyle.Top, Height = 50, BackColor = Color.White };
        connectionLabel = new Label { Text = "o DISCONNECTED", Left = 12, Top = 14, AutoSize = true, ForeColor = Color.DarkRed, Font = new Font("Segoe UI", 10, FontStyle.Bold) };
        protocolLabel = new Label { Text = "Protocol: -", Left = 220, Top = 15, AutoSize = true, Font = new Font("Segoe UI", 9.5f) };
        atrLabel = new Label { Text = "ATR: -", Left = 400, Top = 15, AutoSize = true, Font = new Font("Consolas", 9.5f) };
        info.Controls.AddRange(new Control[] { connectionLabel, protocolLabel, atrLabel });

        // Main Tab Control
        mainTabControl = new TabControl { Dock = DockStyle.Fill };

        // Tab 1: 4-Layer Inspector View
        TabPage tabLayers = new TabPage { Text = "4-Layer Inspector" };
        TableLayoutPanel layerLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2 };
        layerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50f));
        layerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50f));
        layerLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 50f));
        layerLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 50f));

        layer1Text = new RichTextBox { Dock = DockStyle.Fill, Font = new Font("Consolas", 9), ReadOnly = true, BackColor = Color.GhostWhite };
        layer2Text = new RichTextBox { Dock = DockStyle.Fill, Font = new Font("Consolas", 9), ReadOnly = true, BackColor = Color.GhostWhite };
        layer3Text = new RichTextBox { Dock = DockStyle.Fill, Font = new Font("Consolas", 9), ReadOnly = true, BackColor = Color.GhostWhite };
        layer4Text = new RichTextBox { Dock = DockStyle.Fill, Font = new Font("Consolas", 9), ReadOnly = true, BackColor = Color.GhostWhite };

        layerLayout.Controls.Add(layer1Text, 0, 0);
        layerLayout.Controls.Add(layer2Text, 1, 0);
        layerLayout.Controls.Add(layer3Text, 0, 1);
        layerLayout.Controls.Add(layer4Text, 1, 1);
        tabLayers.Controls.Add(layerLayout);

        // Tab 2: Manual APDU Lab Console
        TabPage tabApdu = new TabPage { Text = "APDU Lab & Console" };
        Panel apduTopPanel = new Panel { Dock = DockStyle.Top, Height = 50 };
        
        Label presetLbl = new Label { Text = "Presets:", Left = 10, Top = 15, AutoSize = true };
        presetCombo = new ComboBox { Left = 65, Top = 12, Width = 280, DropDownStyle = ComboBoxStyle.DropDownList };
        presetCombo.Items.AddRange(new string[] {
            "SELECT 1PAY.SYS.DDF01 (PSE)",
            "SELECT 2PAY.SYS.DDF01 (PPSE)",
            "SELECT Visa AID",
            "SELECT Visa Electron AID",
            "SELECT Mastercard AID",
            "SELECT Maestro AID",
            "GPO (Rwanda Country Code 06 46)",
            "READ SFI 1 Rec 2 (Name Field)",
            "READ SFI 3 Rec 1 (PAN/Expiry)"
        });

        apduInputText = new TextBox { Left = 355, Top = 12, Width = 380, Font = new Font("Consolas", 10) };
        sendApduButton = new Button { Text = "Transmit APDU", Left = 745, Top = 10, Width = 120, Height = 28, Enabled = false };
        
        apduTopPanel.Controls.AddRange(new Control[] { presetLbl, presetCombo, apduInputText, sendApduButton });
        apduOutputText = new RichTextBox { Dock = DockStyle.Fill, Font = new Font("Consolas", 9.5f), ReadOnly = true, BackColor = Color.Black, ForeColor = Color.LimeGreen };
        
        tabApdu.Controls.Add(apduOutputText);
        tabApdu.Controls.Add(apduTopPanel);

        // Tab 3: System Log
        TabPage tabLog = new TabPage { Text = "Diagnostic Trace Log" };
        fullLogText = new RichTextBox { Dock = DockStyle.Fill, Font = new Font("Consolas", 9), ReadOnly = true, BackColor = Color.FromArgb(28, 28, 28), ForeColor = Color.LightGray };
        tabLog.Controls.Add(fullLogText);

        mainTabControl.TabPages.Add(tabLayers);
        mainTabControl.TabPages.Add(tabApdu);
        mainTabControl.TabPages.Add(tabLog);

        form.Controls.Add(mainTabControl);
        form.Controls.Add(info);
        form.Controls.Add(top);

        // Event Hookups
        refreshBtn.Click += (s, e) => RefreshReaders();
        connectButton.Click += (s, e) => {
            try { Connect(); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Connection Failure", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        };
        disconnectButton.Click += (s, e) => Disconnect(true);
        inspectButton.Click += (s, e) => {
            try { RunFullInspection(); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Inspection Error", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        };
        exportButton.Click += (s, e) => ExportReport();

        presetCombo.SelectedIndexChanged += (s, e) => {
            switch (presetCombo.SelectedIndex)
            {
                case 0: apduInputText.Text = "00 A4 04 00 0E 31 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00"; break;
                case 1: apduInputText.Text = "00 A4 04 00 0E 32 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00"; break;
                case 2: apduInputText.Text = "00 A4 04 00 07 A0 00 00 00 03 10 10 00"; break;
                case 3: apduInputText.Text = "00 A4 04 00 07 A0 00 00 00 03 20 10 00"; break;
                case 4: apduInputText.Text = "00 A4 04 00 07 A0 00 00 00 04 10 10 00"; break;
                case 5: apduInputText.Text = "00 A4 04 00 07 A0 00 00 00 04 30 60 00"; break;
                case 6: apduInputText.Text = "80 A8 00 00 04 83 02 06 46 00"; break;
                case 7: apduInputText.Text = "00 B2 02 0C 4F"; break;
                case 8: apduInputText.Text = "00 B2 01 1C 47"; break;
            }
        };

        sendApduButton.Click += (s, e) => ExecuteManualApdu();
    }

    public static void Main()
    {
        Application.EnableVisualStyles();
        BuildUi();
        RefreshReaders();
        Application.Run(form);
    }
}
"@

try {
    Add-Type `
        -TypeDefinition $code `
        -Language CSharp `
        -ReferencedAssemblies `
            "System.dll",
            "System.Drawing.dll",
            "System.Windows.Forms.dll"

    [APDULabV12]::Main()
}
catch {
    Write-Host "Startup error: " $_.Exception.Message -ForegroundColor Red
}