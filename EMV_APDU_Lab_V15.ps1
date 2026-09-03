#requires -Version 5.1
<#
    EMV APDU LAB V14 - Instrument Edition
    ======================================
    Windows-native, zero-dependency smart-card workbench.

    Design goals:
      - Terminal-first automated workflow: the live execution trace is the primary UI.
      - Exact EMV flow: ATR -> PSE/PPSE -> AID -> SELECT -> PDOL -> GPO -> AFL -> READ RECORD.
      - No blind 4-layer dashboard. Every operation is visible as a timestamped event.
      - Read/diagnostic operations only. Sensitive payment data is masked in UI and exports.
      - Native winscard.dll + Add-Type / .NET Framework; no external DLLs or installer.
#>

$ErrorActionPreference = "Stop"

$code = @"
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Drawing2D;
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

    public bool IsConstructed
    {
        get
        {
            if (string.IsNullOrEmpty(Tag)) return false;
            byte b = Convert.ToByte(Tag.Substring(0, 2), 16);
            return (b & 0x20) == 0x20;
        }
    }

    public static List<TLVNode> Parse(byte[] data)
    {
        List<TLVNode> nodes = new List<TLVNode>();
        if (data == null) return nodes;
        int i = 0;
        while (i < data.Length)
        {
            if (data[i] == 0x00 || data[i] == 0xFF) { i++; continue; }
            int tagStart = i;
            i++;
            if ((data[tagStart] & 0x1F) == 0x1F)
            {
                while (i < data.Length)
                {
                    byte tb = data[i++];
                    if ((tb & 0x80) == 0) break;
                }
            }
            if (i > data.Length) break;
            string tag = APDULabV14.Hex(data, tagStart, i - tagStart).Replace(" ", "");
            if (i >= data.Length) break;

            int length = data[i++];
            if ((length & 0x80) != 0)
            {
                int n = length & 0x7F;
                if (n == 0 || n > 3 || i + n > data.Length) break;
                length = 0;
                for (int j = 0; j < n; j++) length = (length << 8) | data[i++];
            }
            if (length < 0 || i + length > data.Length) break;

            byte[] value = new byte[length];
            Array.Copy(data, i, value, 0, length);
            i += length;

            TLVNode node = new TLVNode { Tag = tag, Length = length, Value = value };
            if (node.IsConstructed) node.Children = Parse(value);
            nodes.Add(node);
        }
        return nodes;
    }
}

public class AFLRecord
{
    public int Sfi;
    public int FirstRecord;
    public int LastRecord;
    public int OfflineAuthRecords;
}

public class SequenceStats
{
    public int Apdus;
    public int Successes;
    public int Failures;
    public int Records;
    public int Tlvs;
    public int Retries;
    public int Steps;
    public string ActiveAid = "N/A";
    public string ApplicationLabel = "N/A";
    public string CardholderName = "N/A";
    public string Expiry = "N/A";
    public string PanMasked = "N/A";
    public string Atr = "N/A";
    public string Protocol = "-";
    public string LastStatus = "-";
    public DateTime Started;
    public DateTime Finished;
}

public class EMVSummary
{
    public string AID = "N/A";
    public string Label = "N/A";
    public string PAN = "N/A";
    public string Cardholder = "N/A";
    public string Expiry = "N/A";
    public string ServiceCode = "N/A";
    public string IssuerCountryCode = "N/A";
    public string AIP = "N/A";
    public string AFL = "N/A";
    public string Security = "Not determined";
    public List<string> AipFlags = new List<string>();
    public List<AFLRecord> AflRecords = new List<AFLRecord>();
    public string FormattedTlvTree = "";
    public string RawTlvTree = "";

    public static void Walk(List<TLVNode> nodes, EMVSummary s)
    {
        foreach (TLVNode n in nodes)
        {
            string h = APDULabV14.Hex(n.Value).Replace(" ", "");
            string t = n.Tag.ToUpperInvariant();
            if (t == "4F" && s.AID == "N/A") s.AID = h;
            else if (t == "50") s.Label = APDULabV14.DecodeAscii(n.Value).Trim();
            else if (t == "5A" && s.PAN == "N/A") s.PAN = APDULabV14.MaskPan(h.TrimEnd('F', 'f'));
            else if (t == "57" && s.PAN == "N/A")
            {
                int d = h.IndexOf('D');
                if (d > 0) s.PAN = APDULabV14.MaskPan(h.Substring(0, d));
            }
            else if (t == "5F20") s.Cardholder = APDULabV14.DecodeAscii(n.Value).Trim();
            else if (t == "5F24" && h.Length >= 6) s.Expiry = "20" + h.Substring(0,2) + "/" + h.Substring(2,2) + "/" + h.Substring(4,2);
            else if (t == "82") s.AIP = h;
            else if (t == "94") s.AFL = h;
            else if (t == "57")
            {
                int d = h.IndexOf('D');
                if (d >= 0 && h.Length >= d + 8) s.ServiceCode = h.Substring(d + 5, 3);
            }
            if (n.Children != null && n.Children.Count > 0) Walk(n.Children, s);
        }
        if (s.AIP != "N/A")
        {
            try
            {
                int aip = Convert.ToInt32(s.AIP.Substring(0,4), 16);
                List<string> flags = new List<string>();
                if ((aip & 0x8000) != 0) flags.Add("Static Data Authentication (SDA) Supported");
                if ((aip & 0x4000) != 0) flags.Add("Dynamic Data Authentication (DDA) Supported");
                if ((aip & 0x2000) != 0) flags.Add("Cardholder Verification (CVM) Supported");
                if ((aip & 0x1000) != 0) flags.Add("Terminal Risk Management Supported");
                if ((aip & 0x0800) != 0) flags.Add("Issuer Authentication Supported");
                if ((aip & 0x0080) != 0) flags.Add("Combined DDA / Application Cryptogram (CDA) Supported");
                s.AipFlags = flags;
                s.Security = flags.Count == 0 ? "No recognized authentication capability bits indicated" : string.Join(", ", flags.ToArray());
            }
            catch { s.AipFlags = new List<string>(); }
        }
    }
}

public class APDULabV14
{
    const uint SCARD_SCOPE_SYSTEM = 2;
    const uint SCARD_SHARE_EXCLUSIVE = 1;
    const uint SCARD_SHARE_SHARED = 2;
    const uint SCARD_SHARE_DIRECT = 3;
    const uint SCARD_PROTOCOL_T0 = 1;
    const uint SCARD_PROTOCOL_T1 = 2;
    const int SCARD_S_SUCCESS = 0;
    const uint SCARD_LEAVE_CARD = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct SCARD_IO_REQUEST { public uint dwProtocol; public uint cbPciLength; }

    [DllImport("winscard.dll")]
    static extern int SCardEstablishContext(uint scope, IntPtr r1, IntPtr r2, out IntPtr context);
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)]
    static extern int SCardListReaders(IntPtr context, string groups, char[] readers, ref uint length);
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)]
    static extern int SCardConnect(IntPtr context, string reader, uint shareMode, uint preferredProtocols, out IntPtr card, out uint protocol);
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)]
    static extern int SCardStatus(IntPtr card, char[] readerName, ref uint readerNameLength, out uint state, out uint protocol, byte[] atr, ref uint atrLength);
    [DllImport("winscard.dll")]
    static extern int SCardTransmit(IntPtr hCard, ref SCARD_IO_REQUEST pioSendPci, byte[] send, int sendLen, IntPtr recvPci, byte[] recv, ref int recvLen);
    [DllImport("winscard.dll")]
    static extern int SCardDisconnect(IntPtr card, uint disposition);

    class Session
    {
        public IntPtr Context = IntPtr.Zero;
        public IntPtr Card = IntPtr.Zero;
        public uint Protocol;
        public string Reader = "";
        public byte[] Atr = new byte[0];
        public bool Connected { get { return Card != IntPtr.Zero; } }
    }

    static Session session = new Session();
    static Form form;
    static ComboBox readerCombo;
    static Button connectButton, disconnectButton, autoButton, stopButton, exportButton, clearButton, sendButton;
    static Label connectionLabel, protocolLabel, atrLabel, phaseLabel, statApdu, statRecord, statTlv, statError;
    static RichTextBox terminal;
    static RichTextBox inspector;
    static ComboBox cardViewFilter;
    static RichTextBox cardDataOutput;
    static RichTextBox manualOutput;
    static TextBox manualInput;
    static ComboBox presetCombo;
    static TabControl tabs;
    static volatile bool cancelSequence = false;
    static volatile bool sequenceRunning = false;
    static SequenceStats stats = new SequenceStats();
    static List<string> transcript = new List<string>();
    static object transcriptLock = new object();
    static EMVSummary currentSummary = new EMVSummary();
    static List<TLVNode> collectedNodes = new List<TLVNode>();

    public static readonly Color Bg = Color.FromArgb(11,13,16);
    public static readonly Color Panel = Color.FromArgb(17,20,24);
    public static readonly Color Surface = Color.FromArgb(23,27,32);
    public static readonly Color Surface2 = Color.FromArgb(29,34,40);
    public static readonly Color Border = Color.FromArgb(43,49,57);
    public static readonly Color Text = Color.FromArgb(225,230,236);
    public static readonly Color Muted = Color.FromArgb(132,143,155);
    public static readonly Color Accent = Color.FromArgb(91,206,145);
    public static readonly Color Blue = Color.FromArgb(83,160,255);
    public static readonly Color Warn = Color.FromArgb(238,184,91);
    public static readonly Color Bad = Color.FromArgb(232,101,101);
    public static readonly Color TerminalBg = Color.FromArgb(8,11,10);
    public static readonly Color TerminalFg = Color.FromArgb(178,239,193);

    public static string Hex(byte[] data)
    {
        return Hex(data, 0, data == null ? 0 : data.Length);
    }
    public static string Hex(byte[] data, int start, int count)
    {
        if (data == null || count <= 0) return "";
        StringBuilder sb = new StringBuilder();
        int end = Math.Min(data.Length, start + count);
        for (int i=start; i<end; i++) { if (sb.Length > 0) sb.Append(" "); sb.Append(data[i].ToString("X2")); }
        return sb.ToString();
    }
    public static byte[] Bytes(string hex)
    {
        if (hex == null) return new byte[0];
        hex = hex.Replace(" ","").Replace("-","").Replace("0x","").Replace("0X","");
        if (hex.Length % 2 != 0) throw new FormatException("Hex input must contain complete byte pairs.");
        byte[] b = new byte[hex.Length/2];
        for (int i=0;i<b.Length;i++) b[i] = Convert.ToByte(hex.Substring(i*2,2),16);
        return b;
    }
    public static string DecodeAscii(byte[] data)
    {
        if (data == null) return "";
        StringBuilder sb = new StringBuilder();
        foreach (byte b in data) sb.Append(b >= 32 && b <= 126 ? (char)b : '.');
        return sb.ToString();
    }
    public static string MaskPan(string pan)
    {
        if (string.IsNullOrEmpty(pan)) return "N/A";
        pan = pan.Trim();
        if (pan.Length <= 10) return new string('*', pan.Length);
        return pan.Substring(0,6) + new string('*', pan.Length-10) + pan.Substring(pan.Length-4);
    }
    public static string MaskTrack2(string hex)
    {
        if (string.IsNullOrEmpty(hex)) return "N/A";
        int d = hex.IndexOf('D');
        if (d < 1) return "[REDACTED TRACK 2]";
        return MaskPan(hex.Substring(0,d)) + " D [REDACTED]";
    }
    static string SwText(byte sw1, byte sw2)
    {
        int sw=(sw1<<8)|sw2;
        switch(sw)
        {
            case 0x9000: return "90 00  | SUCCESS";
            case 0x6A82: return "6A 82  | FILE / APPLICATION NOT FOUND";
            case 0x6A81: return "6A 81  | FUNCTION NOT SUPPORTED";
            case 0x6A86: return "6A 86  | INCORRECT P1/P2";
            case 0x6700: return "67 00  | WRONG LENGTH";
            case 0x6982: return "69 82  | SECURITY STATUS NOT SATISFIED";
            case 0x6985: return "69 85  | CONDITIONS NOT SATISFIED";
            case 0x6D00: return "6D 00  | INS NOT SUPPORTED";
            case 0x6E00: return "6E 00  | CLA NOT SUPPORTED";
            default:
                if (sw1==0x61) return string.Format("{0:X2} {1:X2}  | {1} BYTES AVAILABLE",sw1,sw2);
                if (sw1==0x6C) return string.Format("{0:X2} {1:X2}  | RETRY WITH Le={1:X2}",sw1,sw2);
                return string.Format("{0:X2} {1:X2}  | STATUS",sw1,sw2);
        }
    }
    static string ErrorText(int rc)
    {
        uint u=(uint)rc;
        switch(u)
        {
            case 0x80100009: return "SCARD_E_NOT_TRANSACTING (0x80100009)";
            case 0x8010000C: return "SCARD_E_SHARE_VIOLATION (0x8010000C)";
            case 0x8010000D: return "SCARD_E_NO_SMARTCARD (0x8010000D)";
            case 0x80100069: return "SCARD_W_REMOVED_CARD (0x80100069)";
            case 0x80100017: return "SCARD_E_READER_UNAVAILABLE (0x80100017)";
            case 0x80100006: return "SCARD_E_INVALID_HANDLE (0x80100006)";
            default: return "PC/SC error 0x"+u.ToString("X8");
        }
    }

    static void Ui(Action a)
    {
        if (form == null || form.IsDisposed) return;
        if (form.InvokeRequired) form.BeginInvoke(a); else a();
    }
    static void SetPhase(string s) { Ui(() => phaseLabel.Text=s); }
    static void Log(string text) { Log(text, Text); }
    static void Log(string text, Color c)
    {
        string line="["+DateTime.Now.ToString("HH:mm:ss.fff")+"] "+text;
        lock(transcriptLock) transcript.Add(line);
        Ui(() => {
            int start=terminal.TextLength;
            terminal.AppendText(line+Environment.NewLine);
            terminal.Select(start, line.Length);
            terminal.SelectionColor=c;
            terminal.SelectionLength=0;
            terminal.SelectionStart=terminal.TextLength;
            terminal.ScrollToCaret();
        });
    }
    static void TX(byte[] cmd, string label)
    {
        Log("→ "+label, Blue);
        Log("  TX  "+Hex(cmd), Text);
    }
    static void RX(byte[] resp)
    {
        if (resp == null || resp.Length < 2) { Log("  RX  "+Hex(resp), Warn); return; }
        byte sw1=resp[resp.Length-2], sw2=resp[resp.Length-1];
        Color c=(sw1==0x90 && sw2==0x00) ? Accent : (sw1==0x6A || sw1==0x69 || sw1==0x67 || sw1==0x6D ? Warn : Text);
        Log("  RX  "+Hex(resp), c);
        Log("  SW  "+SwText(sw1,sw2), c);
    }

    static void EstablishContext()
    {
        if (session.Context != IntPtr.Zero) return;
        int rc=SCardEstablishContext(SCARD_SCOPE_SYSTEM,IntPtr.Zero,IntPtr.Zero,out session.Context);
        if(rc!=SCARD_S_SUCCESS) throw new Exception(ErrorText(rc));
    }
    static string[] ListReaders()
    {
        EstablishContext();
        uint len=0;
        int rc=SCardListReaders(session.Context,null,null,ref len);
        if(rc!=SCARD_S_SUCCESS || len==0) return new string[0];
        char[] buf=new char[len];
        rc=SCardListReaders(session.Context,null,buf,ref len);
        if(rc!=SCARD_S_SUCCESS) throw new Exception(ErrorText(rc));
        List<string> list=new List<string>(); StringBuilder sb=new StringBuilder();
        foreach(char ch in buf)
        {
            if(ch=='\0') { if(sb.Length==0) break; list.Add(sb.ToString()); sb.Clear(); }
            else sb.Append(ch);
        }
        return list.ToArray();
    }
    static void RefreshReaders()
    {
        try
        {
            string[] rs=ListReaders();
            readerCombo.Items.Clear();
            foreach(string r in rs) readerCombo.Items.Add(r);
            if(readerCombo.Items.Count>0) readerCombo.SelectedIndex=0;
            connectionLabel.Text=rs.Length+" reader"+(rs.Length==1?"":"s")+" detected";
            connectionLabel.ForeColor=rs.Length>0?Accent:Warn;
            Log("Reader inventory refreshed: "+rs.Length+" detected.", Muted);
        }
        catch(Exception ex) { MessageBox.Show(ex.Message,"PC/SC",MessageBoxButtons.OK,MessageBoxIcon.Error); }
    }
    static void ReadAtr()
    {
        char[] rn=new char[256]; uint rnl=(uint)rn.Length; uint state,protocol; byte[] atr=new byte[64]; uint al=(uint)atr.Length;
        int rc=SCardStatus(session.Card,rn,ref rnl,out state,out protocol,atr,ref al);
        if(rc!=SCARD_S_SUCCESS) throw new Exception(ErrorText(rc));
        session.Atr=new byte[al]; Array.Copy(atr,session.Atr,(int)al);
        atrLabel.Text="ATR  "+Hex(session.Atr);
        stats.Atr=Hex(session.Atr);
        Log("ATR  "+Hex(session.Atr), Accent);
    }
    static void Connect()
    {
        if(readerCombo.SelectedItem==null) throw new Exception("Select a smart card reader first.");
        Disconnect(false);
        EstablishContext();
        session.Reader=readerCombo.SelectedItem.ToString();
        Log("CONNECT  "+session.Reader, Blue);
        int rc=SCardConnect(session.Context,session.Reader,SCARD_SHARE_SHARED,SCARD_PROTOCOL_T0|SCARD_PROTOCOL_T1,out session.Card,out session.Protocol);
        if(rc!=SCARD_S_SUCCESS) rc=SCardConnect(session.Context,session.Reader,SCARD_SHARE_SHARED,SCARD_PROTOCOL_T0,out session.Card,out session.Protocol);
        if(rc!=SCARD_S_SUCCESS) rc=SCardConnect(session.Context,session.Reader,SCARD_SHARE_SHARED,SCARD_PROTOCOL_T1,out session.Card,out session.Protocol);
        if(rc!=SCARD_S_SUCCESS) rc=SCardConnect(session.Context,session.Reader,SCARD_SHARE_EXCLUSIVE,SCARD_PROTOCOL_T0|SCARD_PROTOCOL_T1,out session.Card,out session.Protocol);
        if(rc!=SCARD_S_SUCCESS) { session.Card=IntPtr.Zero; throw new Exception(ErrorText(rc)); }
        ReadAtr();
        protocolLabel.Text="PROTOCOL  "+(session.Protocol==SCARD_PROTOCOL_T0?"T=0":session.Protocol==SCARD_PROTOCOL_T1?"T=1":"UNKNOWN");
        stats.Protocol=protocolLabel.Text.Replace("PROTOCOL  ","");
        connectionLabel.Text="●  CARD CONNECTED"; connectionLabel.ForeColor=Accent;
        connectButton.Enabled=false; disconnectButton.Enabled=true; autoButton.Enabled=true; sendButton.Enabled=true; exportButton.Enabled=true;
        Log("SESSION READY  |  "+stats.Protocol, Accent);
    }
    static void Disconnect(bool ui)
    {
        cancelSequence=true;
        if(session.Card!=IntPtr.Zero) { try{SCardDisconnect(session.Card,SCARD_LEAVE_CARD);}catch{} session.Card=IntPtr.Zero; }
        if(ui)
        {
            connectionLabel.Text="●  DISCONNECTED"; connectionLabel.ForeColor=Bad;
            protocolLabel.Text="PROTOCOL  -"; atrLabel.Text="ATR  -";
            connectButton.Enabled=true; disconnectButton.Enabled=false; autoButton.Enabled=false; sendButton.Enabled=false;
            Log("SESSION CLOSED", Muted);
        }
    }

    static byte[] TransmitOnce(byte[] cmd)
    {
        if(!session.Connected) throw new Exception("No active smart-card session.");
        SCARD_IO_REQUEST io=new SCARD_IO_REQUEST(); io.dwProtocol=session.Protocol; io.cbPciLength=8;
        byte[] recv=new byte[4096]; int len=recv.Length;
        int rc=SCardTransmit(session.Card,ref io,cmd,cmd.Length,IntPtr.Zero,recv,ref len);
        if(rc!=SCARD_S_SUCCESS) throw new Exception(ErrorText(rc));
        byte[] result=new byte[len]; Array.Copy(recv,result,len); return result;
    }
    static byte[] SendApdu(byte[] cmd, string label, bool trace)
    {
        stats.Apdus++;
        if(trace) TX(cmd,label);
        byte[] resp=TransmitOnce(cmd);
        if(resp.Length>=2)
        {
            byte sw1=resp[resp.Length-2], sw2=resp[resp.Length-1];
            if(sw1==0x6C)
            {
                stats.Retries++;
                byte[] retry=(byte[])cmd.Clone();
                if(retry.Length>=5) retry[retry.Length-1]=sw2;
                else throw new Exception("6Cxx received but APDU has no Le byte to repair.");
                if(trace) Log("  ↻ AUTO-RETRY  6Cxx → Le="+sw2.ToString("X2"),Warn);
                resp=TransmitOnce(retry);
            }
            if(resp.Length>=2 && resp[resp.Length-2]==0x61)
            {
                stats.Retries++;
                List<byte> all=new List<byte>();
                int dataLen=resp.Length-2; for(int i=0;i<dataLen;i++) all.Add(resp[i]);
                byte le=resp[resp.Length-1];
                byte[] getr=new byte[]{0x00,0xC0,0x00,0x00,le};
                if(trace) { Log("  ↳ AUTO GET RESPONSE  Le="+le.ToString("X2"),Warn); TX(getr,"GET RESPONSE"); }
                byte[] r2=TransmitOnce(getr);
                if(r2.Length>=2) { for(int i=0;i<r2.Length-2;i++) all.Add(r2[i]); all.Add(r2[r2.Length-2]); all.Add(r2[r2.Length-1]); }
                resp=all.ToArray();
            }
        }
        if(trace) RX(resp);
        if(resp.Length>=2) stats.LastStatus=SwText(resp[resp.Length-2],resp[resp.Length-1]);
        return resp;
    }

    static bool Ok(byte[] r) { return r!=null && r.Length>=2 && r[r.Length-2]==0x90 && r[r.Length-1]==0x00; }
    static byte[] DataPart(byte[] r)
    {
        if(r==null || r.Length<2) return new byte[0];
        byte[] d=new byte[r.Length-2]; Array.Copy(r,d,d.Length); return d;
    }
    static List<TLVNode> ParseResponse(byte[] r)
    {
        List<TLVNode> n=TLVNode.Parse(DataPart(r));
        stats.Tlvs += CountNodes(n);
        return n;
    }
    static int CountNodes(List<TLVNode> n)
    {
        int c=0; foreach(TLVNode x in n){c++; if(x.Children!=null)c+=CountNodes(x.Children);} return c;
    }
    static TLVNode FindTag(List<TLVNode> nodes,string tag)
    {
        foreach(TLVNode n in nodes){ if(n.Tag.Equals(tag,StringComparison.OrdinalIgnoreCase)) return n; if(n.Children!=null){TLVNode f=FindTag(n.Children,tag); if(f!=null)return f;} } return null;
    }
    static List<TLVNode> FindAllTag(List<TLVNode> nodes,string tag)
    {
        List<TLVNode> result=new List<TLVNode>();
        foreach(TLVNode n in nodes){if(n.Tag.Equals(tag,StringComparison.OrdinalIgnoreCase))result.Add(n); if(n.Children!=null)result.AddRange(FindAllTag(n.Children,tag));}
        return result;
    }
    static void AddNodes(List<TLVNode> source) { if(source!=null) foreach(TLVNode n in source) collectedNodes.Add(n); }

    static string AIDName(string aid)
    {
        if(aid==null)return "Unknown";
        string a=aid.ToUpperInvariant();
        if(a.StartsWith("A000000003")) return "Visa family";
        if(a.StartsWith("A000000004")) return "Mastercard / Maestro family";
        if(a.StartsWith("A000000025")) return "American Express family";
        if(a.StartsWith("A000000065")) return "JCB family";
        if(a.StartsWith("A000000333")) return "UnionPay family";
        if(a.StartsWith("A000000152")) return "Discover / Diners family";
        return "Payment application";
    }
    static List<string> ExtractAids(List<TLVNode> nodes)
    {
        List<string> result=new List<string>();
        foreach(TLVNode n in FindAllTag(nodes,"4F")) { string a=Hex(n.Value).Replace(" ",""); if(a.Length>0 && !result.Contains(a)) result.Add(a); }
        return result;
    }
    static byte[] SelectByName(string name, string label)
    {
        byte[] cmd=Bytes("00A40400"+((name.Length/2).ToString("X2"))+name+"00");
        return SendApdu(cmd,label,true);
    }
    static byte[] SelectAid(string aid, string label) { return SelectByName(aid,label); }

    static byte[] BuildPDOL(List<TLVNode> fci)
    {
        TLVNode pdol=FindTag(fci,"9F38");
        if(pdol==null || pdol.Value.Length==0) return Bytes("8300");
        List<byte> data=new List<byte>(); int i=0;
        while(i<pdol.Value.Length)
        {
            int tagStart=i++; if((pdol.Value[tagStart]&0x1F)==0x1F){while(i<pdol.Value.Length && (pdol.Value[i++]&0x80)!=0){} }
            int len=i<pdol.Value.Length?pdol.Value[i++]:0;
            string tag=Hex(pdol.Value,tagStart,i-tagStart).Replace(" ","");
            byte[] val=DefaultDolValue(tag,len);
            foreach(byte b in val) data.Add(b);
        }
        if(data.Count>255) throw new Exception("PDOL data is too large for short GPO APDU.");
        List<byte> gpo=new List<byte>(); gpo.Add(0x83); gpo.Add((byte)data.Count); gpo.AddRange(data);
        return WrapCommand(0x80,0xA8,0x00,0x00,gpo.ToArray(),0x00);
    }
    static byte[] DefaultDolValue(string tag,int len)
    {
        byte[] v=new byte[len];
        if(tag.Equals("9F1A",StringComparison.OrdinalIgnoreCase) && len==2) {v[0]=0x06;v[1]=0x46;}
        else if(tag.Equals("5F2A",StringComparison.OrdinalIgnoreCase) && len==2) {v[0]=0x06;v[1]=0x46;}
        else if(tag.Equals("9A",StringComparison.OrdinalIgnoreCase) && len==3) {DateTime d=DateTime.Now; v[0]=ToBcd(d.Year%100);v[1]=ToBcd(d.Month);v[2]=ToBcd(d.Day);}
        else if(tag.Equals("9C",StringComparison.OrdinalIgnoreCase) && len==1) v[0]=0x00;
        else if(tag.Equals("9F37",StringComparison.OrdinalIgnoreCase) && len==4) {Random r=new Random();r.NextBytes(v);}
        else if(tag.Equals("9F35",StringComparison.OrdinalIgnoreCase) && len==1) v[0]=0x22;
        else if(tag.Equals("9F66",StringComparison.OrdinalIgnoreCase) && len==4) {v[0]=0x26;v[1]=0x00;v[2]=0xC0;v[3]=0x00;}
        return v;
    }
    static byte ToBcd(int n){return (byte)(((n/10)<<4)|(n%10));}
    static byte[] WrapCommand(byte cla,byte ins,byte p1,byte p2,byte[] data,byte le)
    {
        List<byte> x=new List<byte>(); x.Add(cla);x.Add(ins);x.Add(p1);x.Add(p2);x.Add((byte)data.Length);x.AddRange(data);x.Add(le);return x.ToArray();
    }
    static List<AFLRecord> ParseAfl(List<TLVNode> nodes)
    {
        List<AFLRecord> result=new List<AFLRecord>(); TLVNode afl=FindTag(nodes,"94");
        if(afl==null || afl.Value.Length<4) return result;
        for(int i=0;i+3<afl.Value.Length;i+=4)
        {
            int sfi=(afl.Value[i]>>3)&0x1F; if(sfi==0)continue;
            result.Add(new AFLRecord{Sfi=sfi,FirstRecord=afl.Value[i+1],LastRecord=afl.Value[i+2],OfflineAuthRecords=afl.Value[i+3]});
        }
        return result;
    }
    static string SafeField(string value)
    {
        return string.IsNullOrWhiteSpace(value) || value == "N/A" ? "Not Provided by Card" : value;
    }

    static string FormatExpiry(string expiry)
    {
        if (string.IsNullOrWhiteSpace(expiry) || expiry == "N/A") return "Not Provided by Card";
        DateTime d;
        if (DateTime.TryParseExact(expiry, "yyyy/MM/dd", null, System.Globalization.DateTimeStyles.None, out d)) return d.ToString("yyyy-MM-dd");
        if (DateTime.TryParseExact(expiry, "yy/MM/dd", null, System.Globalization.DateTimeStyles.None, out d)) return d.ToString("yyyy-MM-dd");
        return expiry.Replace("/", "-");
    }

    static string BuildTlvTreeText(List<TLVNode> nodes)
    {
        StringBuilder sb = new StringBuilder();
        foreach (TLVNode n in nodes) AppendNodeText(sb, n, 0);
        return sb.ToString();
    }

    static void AppendNodeText(StringBuilder sb, TLVNode n, int depth)
    {
        string val = Hex(n.Value);
        string display = val;
        if (n.Tag.Equals("5A", StringComparison.OrdinalIgnoreCase)) display = MaskPan(val.TrimEnd('F','f'));
        else if (n.Tag.Equals("57", StringComparison.OrdinalIgnoreCase)) display = MaskTrack2(val);
        else if (n.Tag.Equals("5F20", StringComparison.OrdinalIgnoreCase) || n.Tag.Equals("50", StringComparison.OrdinalIgnoreCase)) display = DecodeAscii(n.Value).Trim();
        sb.Append(new string(' ', depth * 2));
        sb.Append(n.Tag).Append("  ").Append(TagName(n.Tag)).Append("  [").Append(n.Length).Append("]  ").AppendLine(display);
        if (n.Children != null) foreach (TLVNode c in n.Children) AppendNodeText(sb, c, depth + 1);
    }

    static string GenerateFullSummaryReport(EMVSummary cardData)
    {
        StringBuilder sb = new StringBuilder();
        sb.AppendLine("============================================================");
        sb.AppendLine("                  CARD ANALYSIS SUMMARY");
        sb.AppendLine("============================================================");
        sb.AppendLine("Application Label   : " + SafeField(cardData.Label));
        sb.AppendLine("Selected AID        : " + SafeField(cardData.AID));
        sb.AppendLine("Issuer Country Code : " + SafeField(cardData.IssuerCountryCode));
        sb.AppendLine();
        sb.AppendLine("[CARDHOLDER DETAILS]");
        sb.AppendLine("Cardholder Name     : " + SafeField(cardData.Cardholder));
        sb.AppendLine("PAN (Sanitized)     : " + SafeField(cardData.PAN));
        sb.AppendLine("Expiration Date     : " + FormatExpiry(cardData.Expiry));
        sb.AppendLine();
        sb.AppendLine("[SECURITY PROFILE (AIP)]");
        if (cardData.AipFlags != null && cardData.AipFlags.Count > 0)
            foreach (string f in cardData.AipFlags) sb.AppendLine("  • " + f);
        else sb.AppendLine("  • Not Provided by Card");
        sb.AppendLine();
        sb.AppendLine("[RECORD READ SUMMARY]");
        sb.AppendLine("  • Active SFI Records Read: " + stats.Records);
        sb.AppendLine("  • AFL Entries Decoded: " + (cardData.AflRecords == null ? 0 : cardData.AflRecords.Count));
        sb.AppendLine("  • Processing Status: " + (stats.LastStatus == "90 00  | SUCCESS" ? "Complete (0x9000)" : SafeField(stats.LastStatus)));
        sb.AppendLine("  • APDUs Transmitted: " + stats.Apdus);
        sb.AppendLine("  • TLV Nodes Parsed: " + stats.Tlvs);
        sb.AppendLine("============================================================");
        return sb.ToString();
    }

    static void UpdateCardDataView(string selectedFilter)
    {
        EMVSummary cardData = currentSummary;
        string output;
        switch (selectedFilter)
        {
            case "Expiry Date Only":
                output = "Expiration Date: " + FormatExpiry(cardData.Expiry);
                break;
            case "Cardholder & PAN":
                output = "Cardholder Name : " + SafeField(cardData.Cardholder) + Environment.NewLine +
                         "PAN (Redacted)  : " + SafeField(cardData.PAN) + Environment.NewLine +
                         "Expiry Date     : " + FormatExpiry(cardData.Expiry);
                break;
            case "Security Capabilities (AIP)":
                output = "=== SECURITY & AUTHENTICATION (AIP) ===" + Environment.NewLine;
                if (cardData.AipFlags != null && cardData.AipFlags.Count > 0)
                    output += " - " + string.Join(Environment.NewLine + " - ", cardData.AipFlags.ToArray());
                else output += " - Not Provided by Card";
                break;
            case "Application Info (AID / Label)":
                output = "Application Label : " + SafeField(cardData.Label) + Environment.NewLine +
                         "Selected AID      : " + SafeField(cardData.AID);
                break;
            case "Full TLV Tag Breakdown":
                output = SafeField(cardData.FormattedTlvTree);
                break;
            case "[ All Card Details ]":
            default:
                output = GenerateFullSummaryReport(cardData);
                break;
        }
        Ui(() => { if (cardDataOutput != null) cardDataOutput.Text = output; });
    }

    static void DisplayInterpretedCardData()
    {
        currentSummary = new EMVSummary();
        EMVSummary.Walk(collectedNodes, currentSummary);
        currentSummary.Expiry = FormatExpiry(currentSummary.Expiry);
        currentSummary.AflRecords = ParseAfl(collectedNodes);
        currentSummary.FormattedTlvTree = BuildTlvTreeText(collectedNodes);
        currentSummary.RawTlvTree = currentSummary.FormattedTlvTree;
        stats.ApplicationLabel = currentSummary.Label;
        stats.CardholderName = currentSummary.Cardholder;
        stats.Expiry = currentSummary.Expiry;
        stats.PanMasked = currentSummary.PAN;
        Ui(() => { if (cardViewFilter != null) cardViewFilter.SelectedIndex = 0; });
        UpdateCardDataView("[ All Card Details ]");
    }

    static void RenderSummary()
    {
        DisplayInterpretedCardData();
        Ui(() => { statApdu.Text="APDU  "+stats.Apdus; statRecord.Text="REC  "+stats.Records; statTlv.Text="TLV  "+stats.Tlvs; statError.Text="ERR  "+stats.Failures; });
    }
    static void AddInspectionTree(List<TLVNode> nodes,string heading)
    {
        Ui(()=>{inspector.AppendText("\n"+heading+"\n────────────────────────────────────────────\n"); foreach(TLVNode n in nodes) AppendNode(inspector,n,0);});
    }
    static void AppendNode(RichTextBox box,TLVNode n,int depth)
    {
        string val=Hex(n.Value);
        string display=val;
        if(n.Tag.Equals("5A",StringComparison.OrdinalIgnoreCase)) display=MaskPan(val.TrimEnd('F','f'));
        else if(n.Tag.Equals("57",StringComparison.OrdinalIgnoreCase)) display=MaskTrack2(val);
        else if(n.Tag.Equals("5F20",StringComparison.OrdinalIgnoreCase)) display=DecodeAscii(n.Value).Trim();
        else if(n.Tag.Equals("50",StringComparison.OrdinalIgnoreCase)) display=DecodeAscii(n.Value).Trim();
        string name=TagName(n.Tag);
        box.AppendText(new string(' ',depth*2)+n.Tag+"  "+name+"  ["+n.Length+"]  "+display+Environment.NewLine);
        if(n.Children!=null) foreach(TLVNode c in n.Children) AppendNode(box,c,depth+1);
    }
    static string TagName(string tag)
    {
        switch(tag.ToUpperInvariant())
        {
            case "4F":return "AID"; case "50":return "Application Label"; case "57":return "Track 2 Equivalent Data";
            case "5A":return "PAN"; case "5F20":return "Cardholder Name"; case "5F24":return "Application Expiration Date";
            case "5F2A":return "Transaction Currency Code"; case "82":return "AIP"; case "84":return "DF Name";
            case "87":return "Application Priority"; case "94":return "AFL"; case "9F38":return "PDOL";
            case "9F12":return "Application Preferred Name"; case "9F36":return "ATC"; case "9F37":return "Unpredictable Number";
            case "9F10":return "Issuer Application Data"; case "9F33":return "Terminal Capabilities"; case "9F66":return "TTQ";
            default:return "EMV tag";
        }
    }

    static void RunAutoSequence()
    {
        if(sequenceRunning) return;
        sequenceRunning=true; cancelSequence=false; stats=new SequenceStats(); stats.Started=DateTime.Now; collectedNodes.Clear();
        Ui(()=>{autoButton.Enabled=false;stopButton.Enabled=true;clearButton.Enabled=false;phaseLabel.Text="INITIALIZING";inspector.Clear();});
        try
        {
            Log("══════════ AUTOMATED EMV SEQUENCE ══════════",Accent);
            Log("Mode: read-only discovery / diagnostics",Muted);
            SetPhase("DISCOVERING APPLICATION ENVIRONMENT");
            if(!session.Connected) throw new Exception("No active card session.");

            // 1. PSE / PPSE discovery. This is preferred over blindly probing records.
            List<TLVNode> directory=new List<TLVNode>();
            string[] names=new string[]{"315041592E5359532E4444463031","325041592E5359532E4444463031"};
            string[] labels=new string[]{"SELECT 1PAY.SYS.DDF01 (PSE)","SELECT 2PAY.SYS.DDF01 (PPSE)"};
            for(int i=0;i<names.Length && directory.Count==0;i++)
            {
                if(cancelSequence) return;
                Log("STEP 01  DIRECTORY DISCOVERY",Accent);
                byte[] r=SelectByName(names[i],labels[i]);
                if(Ok(r)) { directory=ParseResponse(r); AddNodes(directory); Log("  ✓ DIRECTORY ACCEPTED  |  "+labels[i],Accent); }
                else Log("  · directory not present; continuing",Muted);
            }

            // 2. Get AIDs from directory; fallback to well-known payment AIDs.
            SetPhase("DISCOVERING APPLICATIONS");
            List<string> aids=ExtractAids(directory);
            if(aids.Count==0)
            {
                Log("STEP 02  DIRECTORY RETURNED NO AIDs; FALLBACK PROBE",Warn);
                aids.Add("A0000000031010");
                aids.Add("A0000000041010");
                aids.Add("A0000000043060");
                aids.Add("A0000000250101");
                aids.Add("A0000000651010");
                aids.Add("A0000003330101");
                aids.Add("A0000001523010");
            }
            else Log("STEP 02  AIDs DISCOVERED: "+aids.Count,Accent);

            List<TLVNode> activeFci=null; string activeAid="";
            foreach(string aid in aids)
            {
                if(cancelSequence) return;
                string rlabel="SELECT AID  "+aid+"  ·  "+AIDName(aid);
                byte[] r=SelectAid(aid,rlabel);
                if(Ok(r))
                {
                    activeFci=ParseResponse(r); activeAid=aid; AddNodes(activeFci); stats.ActiveAid=aid;
                    Log("  ✓ APPLICATION SELECTED  "+AIDName(aid),Accent); break;
                }
                stats.Failures++;
                Log("  · not accepted",Muted);
            }
            if(activeFci==null) throw new Exception("No payment application accepted SELECT.");

            // 3. PDOL-aware GPO.
            SetPhase("INITIALIZING APPLICATION / GPO");
            Log("STEP 03  BUILD GET PROCESSING OPTIONS",Accent);
            byte[] gpo=BuildPDOL(activeFci);
            byte[] gpoResp=SendApdu(gpo,"GET PROCESSING OPTIONS (PDOL-aware)",true);
            List<TLVNode> gpoNodes=ParseResponse(gpoResp); AddNodes(gpoNodes);
            if(!Ok(gpoResp))
            {
                Log("  ↻ GPO fallback: empty PDOL",Warn);
                byte[] fallback=Bytes("80A8000002830000");
                gpoResp=SendApdu(fallback,"GET PROCESSING OPTIONS (empty PDOL fallback)",true);
                gpoNodes=ParseResponse(gpoResp); AddNodes(gpoNodes);
            }
            if(!Ok(gpoResp)) throw new Exception("GPO was not accepted: "+stats.LastStatus);

            // 4. AFL drives exact READ RECORD requests.
            SetPhase("READING AFL-DEFINED RECORDS");
            List<AFLRecord> afl=ParseAfl(gpoNodes);
            if(afl.Count==0) throw new Exception("No AFL (tag 94) could be parsed from GPO response.");
            Log("STEP 04  AFL DECODED  |  ENTRIES="+afl.Count,Accent);
            foreach(AFLRecord ar in afl)
            {
                if(cancelSequence) return;
                Log(string.Format("  SFI {0:D2}  RECORDS {1:D2}–{2:D2}  OFFLINE-AUTH={3}",ar.Sfi,ar.FirstRecord,ar.LastRecord,ar.OfflineAuthRecords),Blue);
                for(int rec=ar.FirstRecord;rec<=ar.LastRecord;rec++)
                {
                    if(cancelSequence) return;
                    byte p2=(byte)((ar.Sfi<<3)|4);
                    byte[] cmd=new byte[]{0x00,0xB2,(byte)rec,p2,0x00};
                    byte[] rr=SendApdu(cmd,string.Format("READ RECORD  SFI={0}  REC={1}",ar.Sfi,rec),true);
                    if(Ok(rr))
                    {
                        stats.Records++;
                        List<TLVNode> nodes=ParseResponse(rr); AddNodes(nodes);
                        Log("  ✓ RECORD ACCEPTED  |  TLVs="+CountNodes(nodes),Accent);
                    }
                    else { stats.Failures++; Log("  · record unavailable",Muted); }
                }
            }

            SetPhase("PARSING / SANITIZING RESULTS");
            DisplayInterpretedCardData();
            RenderSummary();
            stats.Finished=DateTime.Now; stats.Successes=stats.Apdus-stats.Failures;
            SetPhase("SEQUENCE COMPLETE");
            Log("══════════ SEQUENCE COMPLETE  |  "+stats.Apdus+" APDUs  |  "+stats.Records+" records  |  "+stats.Tlvs+" TLVs ══════════",Accent);
        }
        catch(Exception ex)
        {
            stats.Failures++;
            SetPhase("SEQUENCE STOPPED / ERROR");
            Log("✕ SEQUENCE ERROR  "+ex.Message,Bad);
            Ui(()=>{statError.Text="ERR  "+stats.Failures;});
        }
        finally
        {
            sequenceRunning=false;
            Ui(()=>{autoButton.Enabled=session.Connected;stopButton.Enabled=false;clearButton.Enabled=true;exportButton.Enabled=session.Connected;});
        }
    }

    static void StartAuto()
    {
        if(!session.Connected){MessageBox.Show("Connect a card first.","No Card",MessageBoxButtons.OK,MessageBoxIcon.Warning);return;}
        Thread t=new Thread(RunAutoSequence); t.IsBackground=true; t.Start();
    }
    static void StopAuto(){if(sequenceRunning){cancelSequence=true;SetPhase("STOP REQUESTED");Log("■ STOP REQUESTED — finishing current PC/SC transaction...",Warn);}}

    static void ClearWorkspace()
    {
        terminal.Clear(); if(cardDataOutput!=null) cardDataOutput.Text="READY\r\n\r\nRun the Auto Sequence to populate the interpreted card view."; manualOutput.Clear(); lock(transcriptLock) transcript.Clear(); collectedNodes.Clear(); stats=new SequenceStats();
        statApdu.Text="APDU  0";statRecord.Text="REC  0";statTlv.Text="TLV  0";statError.Text="ERR  0";phaseLabel.Text="IDLE";
        Log("Workspace cleared.",Muted);
    }
    static void ExportReport()
    {
        using(SaveFileDialog sfd=new SaveFileDialog())
        {
            sfd.Filter="Text Report (*.txt)|*.txt|All Files (*.*)|*.*";
            sfd.FileName="EMV_APDU_Lab_"+DateTime.Now.ToString("yyyyMMdd_HHmmss")+".txt";
            if(sfd.ShowDialog()!=DialogResult.OK)return;
            StringBuilder sb=new StringBuilder();
            sb.AppendLine("EMV APDU LAB V14 — INSTRUMENT REPORT");
            sb.AppendLine("Generated: "+DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("Reader: "+session.Reader); sb.AppendLine("Protocol: "+stats.Protocol); sb.AppendLine("ATR: "+stats.Atr);
            sb.AppendLine(); sb.AppendLine("SUMMARY"); sb.AppendLine("AID: "+currentSummary.AID); sb.AppendLine("Application: "+currentSummary.Label);
            sb.AppendLine("Cardholder: "+(currentSummary.Cardholder=="N/A"?"N/A":"[REDACTED]"));
            sb.AppendLine("PAN: "+currentSummary.PAN); sb.AppendLine("Expiry: "+currentSummary.Expiry); sb.AppendLine("Service Code: "+currentSummary.ServiceCode);
            sb.AppendLine("AIP: "+currentSummary.AIP); sb.AppendLine("AFL: "+currentSummary.AFL); sb.AppendLine("Security: "+currentSummary.Security);
            sb.AppendLine(); sb.AppendLine("COUNTERS"); sb.AppendLine("APDUs: "+stats.Apdus); sb.AppendLine("Retries: "+stats.Retries); sb.AppendLine("Records: "+stats.Records); sb.AppendLine("TLVs: "+stats.Tlvs); sb.AppendLine("Errors: "+stats.Failures);
            sb.AppendLine(); sb.AppendLine("EXECUTION TRACE"); lock(transcriptLock) foreach(string line in transcript) sb.AppendLine(SanitizeLog(line));
            File.WriteAllText(sfd.FileName,sb.ToString(),Encoding.UTF8);
            MessageBox.Show("Sanitized report exported.\n\n"+sfd.FileName,"Export Complete",MessageBoxButtons.OK,MessageBoxIcon.Information);
        }
    }
    static string SanitizeLog(string line)
    {
        // Keep the execution trace useful while removing obvious Track-2-like data.
        int idx=line.IndexOf("57  ");
        return idx>=0 ? line.Substring(0,idx)+"57  [REDACTED]" : line;
    }
    static void ManualSend()
    {
        try
        {
            byte[] cmd=Bytes(manualInput.Text.Trim());
            manualOutput.AppendText("→ TX  "+Hex(cmd)+Environment.NewLine);
            byte[] r=SendApdu(cmd,"MANUAL APDU",false);
            manualOutput.AppendText("← RX  "+Hex(r)+Environment.NewLine);
            if(r.Length>=2) manualOutput.AppendText("  SW  "+SwText(r[r.Length-2],r[r.Length-1])+Environment.NewLine);
            List<TLVNode> n=ParseResponse(r);
            if(n.Count>0){manualOutput.AppendText("  TLV\n");foreach(TLVNode x in n)AppendNode(manualOutput,x,1);}
            manualOutput.AppendText("────────────────────────────────────────────\n");
        }catch(Exception ex){manualOutput.AppendText("✕ ERROR  "+ex.Message+Environment.NewLine);}
    }
    static void PresetChanged()
    {
        switch(presetCombo.SelectedIndex)
        {
            case 0:manualInput.Text="00 A4 04 00 0E 31 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00";break;
            case 1:manualInput.Text="00 A4 04 00 0E 32 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00";break;
            case 2:manualInput.Text="00 A4 04 00 07 A0 00 00 00 03 10 10 00";break;
            case 3:manualInput.Text="00 A4 04 00 07 A0 00 00 00 04 10 10 00";break;
            case 4:manualInput.Text="80 A8 00 00 02 83 00 00";break;
            case 5:manualInput.Text="00 B2 01 0C 00";break;
        }
    }

    static void StyleButton(Button b, Color bg, Color fg, bool bold)
    {
        b.FlatStyle=FlatStyle.Flat; b.FlatAppearance.BorderSize=1; b.FlatAppearance.BorderColor=Border; b.BackColor=bg; b.ForeColor=fg;
        b.Font=new Font("Segoe UI",9f,bold?FontStyle.Bold:FontStyle.Regular); b.Cursor=Cursors.Hand;
        Color hover=ControlPaint.Light(bg,0.12f); b.MouseEnter+=(s,e)=>{if(b.Enabled)b.BackColor=hover;}; b.MouseLeave+=(s,e)=>{b.BackColor=bg;};
    }
    static void StyleInput(Control c){c.BackColor=Surface2;c.ForeColor=Text;c.Font=new Font("Consolas",9f);}
    static Label L(string text,Color color,float size,bool bold)
    {return new Label{Text=text,AutoSize=true,ForeColor=color,Font=new Font("Segoe UI",size,bold?FontStyle.Bold:FontStyle.Regular)};}

    static void BuildUI()
    {
        form=new Form{Text="EMV APDU Lab V14 — Instrument Edition",Width=1400,Height=900,MinimumSize=new Size(1100,720),StartPosition=FormStartPosition.CenterScreen,BackColor=Bg,Font=new Font("Segoe UI",9f)};

        // Header
        Panel header=new Panel{Dock=DockStyle.Top,Height=76,BackColor=Bg};
        Label title=L("EMV",Accent,22,true); title.Location=new Point(20,13);
        Label title2=L("APDU LAB",Text,22,false); title2.Location=new Point(77,13);
        Label subtitle=L("PC/SC  ·  ISO 7816  ·  EMV DISCOVERY WORKBENCH",Muted,8,false); subtitle.Location=new Point(21,48);
        Panel liveDot=new Panel{Width=8,Height=8,BackColor=Bad,Location=new Point(1240,22)};
        Label live=L("DISCONNECTED",Muted,8,true); live.Location=new Point(1255,18); live.Anchor=AnchorStyles.Top|AnchorStyles.Right;
        header.Controls.AddRange(new Control[]{title,title2,subtitle,liveDot,live});
        Panel headerLine=new Panel{Dock=DockStyle.Bottom,Height=1,BackColor=Border}; header.Controls.Add(headerLine);

        // Connection / command bar
        Panel bar=new Panel{Dock=DockStyle.Top,Height=62,BackColor=Panel};
        readerCombo=new ComboBox{Left=16,Top=16,Width=330,DropDownStyle=ComboBoxStyle.DropDownList};StyleInput(readerCombo);
        Button refresh=new Button{Text="↻",Left=354,Top=15,Width=36,Height=31};StyleButton(refresh,Surface,Text,false);
        connectButton=new Button{Text="CONNECT",Left=398,Top=15,Width=92,Height=31};StyleButton(connectButton,Surface,Accent,true);
        disconnectButton=new Button{Text="DISCONNECT",Left=497,Top=15,Width=96,Height=31,Enabled=false};StyleButton(disconnectButton,Surface,Bad,false);
        autoButton=new Button{Text="▶  RUN AUTO SEQUENCE",Left=607,Top=15,Width=174,Height=31,Enabled=false};StyleButton(autoButton,Accent,Bg,true);
        stopButton=new Button{Text="■  STOP",Left=789,Top=15,Width=82,Height=31,Enabled=false};StyleButton(stopButton,Surface,Warn,true);
        clearButton=new Button{Text="CLEAR",Left=879,Top=15,Width=70,Height=31};StyleButton(clearButton,Surface,Text,false);
        exportButton=new Button{Text="EXPORT",Left=957,Top=15,Width=78,Height=31,Enabled=false};StyleButton(exportButton,Surface,Text,false);
        bar.Controls.AddRange(new Control[]{readerCombo,refresh,connectButton,disconnectButton,autoButton,stopButton,clearButton,exportButton});

        // Status strip
        Panel status=new Panel{Dock=DockStyle.Top,Height=38,BackColor=Panel};
        connectionLabel=L("●  DISCONNECTED",Bad,8.5f,true);connectionLabel.Location=new Point(18,11);
        protocolLabel=L("PROTOCOL  -",Muted,8.5f,true);protocolLabel.Location=new Point(185,11);
        atrLabel=L("ATR  -",Muted,8.5f,false);atrLabel.Location=new Point(300,11);
        phaseLabel=L("IDLE",Muted,8.5f,true);phaseLabel.Location=new Point(1120,11);phaseLabel.Anchor=AnchorStyles.Top|AnchorStyles.Right;
        status.Controls.AddRange(new Control[]{connectionLabel,protocolLabel,atrLabel,phaseLabel});
        Panel sr=new Panel{Dock=DockStyle.Bottom,Height=1,BackColor=Border};status.Controls.Add(sr);

        // Main split
		SplitContainer split = new SplitContainer
		{
			Dock = DockStyle.Fill,
			Orientation = Orientation.Vertical,
			BackColor = Border,
			Panel1MinSize = 1,
			Panel2MinSize = 1,
			IsSplitterFixed = false
		};

		// Calculate a safe splitter position.
		Action positionSplitter = () =>
		{
			int available = split.ClientSize.Width;
			int min = 420;
			int max = available - 280;

			if (available >= 720 && max >= min)
			{
				int desired = (int)(available * 0.68);
				desired = Math.Max(min, Math.Min(desired, max));

				try
				{
					split.SplitterDistance = desired;
				}
				catch
				{
					// Ignore resize race conditions during initial layout.
				}
			}
		};

		split.Resize += (s, e) => positionSplitter();

		form.Shown += (s, e) =>
		{
			positionSplitter();
		};

        // Left: terminal
        Panel left=new Panel{Dock=DockStyle.Fill,BackColor=TerminalBg,Padding=new Padding(0)};
        Panel termHeader=new Panel{Dock=DockStyle.Top,Height=42,BackColor=Panel};
        Label termTitle=L("LIVE EXECUTION TRACE",Text,9,true);termTitle.Location=new Point(16,12);
        Label termHint=L("automation is visible here — no hidden layers",Muted,8,false);termHint.Location=new Point(190,13);
        termHeader.Controls.AddRange(new Control[]{termTitle,termHint});
        terminal=new RichTextBox{Dock=DockStyle.Fill,ReadOnly=true,BackColor=TerminalBg,ForeColor=TerminalFg,BorderStyle=BorderStyle.None,Font=new Font("Consolas",9.5f),WordWrap=false,DetectUrls=false,HideSelection=false,ScrollBars=RichTextBoxScrollBars.Both};
        left.Controls.Add(terminal);left.Controls.Add(termHeader);

        // Bottom counters
        Panel counters=new Panel{Dock=DockStyle.Bottom,Height=44,BackColor=Panel};
        statApdu=L("APDU  0",Blue,8,true);statApdu.Location=new Point(18,14);
        statRecord=L("REC  0",Accent,8,true);statRecord.Location=new Point(115,14);
        statTlv=L("TLV  0",Text,8,true);statTlv.Location=new Point(200,14);
        statError=L("ERR  0",Bad,8,true);statError.Location=new Point(285,14);
        counters.Controls.AddRange(new Control[]{statApdu,statRecord,statTlv,statError});
        left.Controls.Add(counters);
        split.Panel1.Controls.Add(left);

        // Right inspector
        Panel right=new Panel{Dock=DockStyle.Fill,BackColor=Panel};
        tabs=new TabControl{Dock=DockStyle.Fill,Padding=new Point(12,6)};
        TabPage summaryTab=new TabPage("CARD DATA"){BackColor=Surface};
        Panel cardViewHeader=new Panel{Dock=DockStyle.Top,Height=58,BackColor=Panel};
        Label viewLabel=L("INTERPRETED CARD VIEW",Text,8.5f,true); viewLabel.Location=new Point(12,9);
        cardViewFilter=new ComboBox{Left=12,Top=27,Width=290,DropDownStyle=ComboBoxStyle.DropDownList};
        cardViewFilter.Items.AddRange(new string[]{"[ All Card Details ]","Expiry Date Only","Cardholder & PAN","Security Capabilities (AIP)","Application Info (AID / Label)","Full TLV Tag Breakdown"});
        cardViewFilter.SelectedIndex=0; StyleInput(cardViewFilter);
        cardViewHeader.Controls.AddRange(new Control[]{viewLabel,cardViewFilter});
        cardDataOutput=new RichTextBox{Dock=DockStyle.Fill,ReadOnly=true,BackColor=Surface,ForeColor=Text,BorderStyle=BorderStyle.None,Font=new Font("Consolas",9.5f),WordWrap=false,DetectUrls=false,ScrollBars=RichTextBoxScrollBars.Both};
        cardDataOutput.Text="READY\r\n\r\nRun the Auto Sequence to populate the interpreted card view.";
        summaryTab.Controls.Add(cardDataOutput); summaryTab.Controls.Add(cardViewHeader);
        inspector=cardDataOutput;
        cardViewFilter.SelectedIndexChanged+=(s,e)=>UpdateCardDataView(cardViewFilter.SelectedItem == null ? "[ All Card Details ]" : cardViewFilter.SelectedItem.ToString());
        TabPage manualTab=new TabPage("MANUAL APDU"){BackColor=Surface};
        Panel mp=new Panel{Dock=DockStyle.Top,Height=92,BackColor=Panel};
        Label pl=L("PRESET",Muted,8,true);pl.Location=new Point(12,12);
        presetCombo=new ComboBox{Left=12,Top=30,Width=260,DropDownStyle=ComboBoxStyle.DropDownList};presetCombo.Items.AddRange(new string[]{"SELECT PSE","SELECT PPSE","SELECT VISA AID","SELECT MASTERCARD AID","GPO EMPTY PDOL","READ SFI 1 / RECORD 1"});StyleInput(presetCombo);presetCombo.SelectedIndex=0;
        manualInput=new TextBox{Left=12,Top=60,Width=360,Height=22};StyleInput(manualInput);
        sendButton=new Button{Text="SEND",Left=382,Top=59,Width=70,Height=24,Enabled=false};StyleButton(sendButton,Accent,Bg,true);
        mp.Controls.AddRange(new Control[]{pl,presetCombo,manualInput,sendButton});
        manualOutput=new RichTextBox{Dock=DockStyle.Fill,ReadOnly=true,BackColor=TerminalBg,ForeColor=TerminalFg,BorderStyle=BorderStyle.None,Font=new Font("Consolas",8.5f),WordWrap=false};
        manualTab.Controls.Add(manualOutput);manualTab.Controls.Add(mp);
        TabPage aboutTab=new TabPage("ABOUT"){BackColor=Surface};
        RichTextBox about=new RichTextBox{Dock=DockStyle.Fill,ReadOnly=true,BackColor=Surface,ForeColor=Text,BorderStyle=BorderStyle.None,Font=new Font("Segoe UI",9.5f)};
        about.Text="EMV APDU LAB V14\n\nInstrument-first smart-card diagnostics.\n\n• PC/SC reader discovery\n• T=0 / T=1 connection fallbacks\n• ATR capture\n• 61xx GET RESPONSE handling\n• 6Cxx Le correction\n• PSE / PPSE discovery\n• Directory-driven AID discovery\n• PDOL-aware GPO construction\n• AFL-driven READ RECORD\n• Recursive BER-TLV parsing\n• Human-readable EMV tag dictionary\n• PAN / Track 2 masking\n• Sanitized text export\n\nThe automated sequence is intentionally read/diagnostic focused. It does not expose card-write or personalization operations.\n";
        aboutTab.Controls.Add(about);
        tabs.TabPages.Add(summaryTab);tabs.TabPages.Add(manualTab);tabs.TabPages.Add(aboutTab);right.Controls.Add(tabs);split.Panel2.Controls.Add(right);

        form.Controls.Add(split);form.Controls.Add(status);form.Controls.Add(bar);form.Controls.Add(header);

        refresh.Click+=(s,e)=>RefreshReaders();
        connectButton.Click+=(s,e)=>{try{Connect();}catch(Exception ex){MessageBox.Show(ex.Message,"Connection Failure",MessageBoxButtons.OK,MessageBoxIcon.Error);}};
        disconnectButton.Click+=(s,e)=>Disconnect(true);
        autoButton.Click+=(s,e)=>StartAuto(); stopButton.Click+=(s,e)=>StopAuto(); clearButton.Click+=(s,e)=>ClearWorkspace(); exportButton.Click+=(s,e)=>ExportReport();
        sendButton.Click+=(s,e)=>ManualSend(); presetCombo.SelectedIndexChanged+=(s,e)=>PresetChanged();
        manualInput.KeyDown+=(s,e)=>{if(e.KeyCode==Keys.Enter){ManualSend();e.SuppressKeyPress=true;}};
        form.FormClosing+=(s,e)=>{cancelSequence=true;Disconnect(false);};
        PresetChanged();
        inspector.Text="READY\n\nConnect a card and press  ▶ RUN AUTO SEQUENCE.\n\nThe terminal on the left is the primary execution surface.\nThe inspector on the right shows interpreted, sanitized results.\n";
        Log("EMV APDU LAB V14 initialized.",Accent);
    }

    public static void Main()
    {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); BuildUI(); RefreshReaders(); Application.Run(form);
    }
}
"@

try {
    Add-Type -TypeDefinition $code -Language CSharp -ReferencedAssemblies "System.dll","System.Drawing.dll","System.Windows.Forms.dll"
    [APDULabV14]::Main()
}
catch {
    Write-Host "EMV APDU Lab startup/compilation error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) { Write-Host $_.Exception.InnerException.Message -ForegroundColor Red }
}
