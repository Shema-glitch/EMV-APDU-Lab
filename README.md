# EMV APDU Lab (V15)

**EMV APDU Lab** is a zero-dependency, standalone Windows desktop diagnostic utility built in PowerShell and C#. It provides low-level hardware communication with PC/SC smart card readers via native `winscard.dll` P/Invoke calls, featuring automated EMV application probing, recursive BER-TLV parsing, automated data field interpretation, and step-by-step diagnostic logging.

---

## What's New in V15

* **Automated Card Data Inspector:** Integrated post-sequence data interpretation that automatically walks the collected TLV tree and displays human-readable card attributes immediately upon execution completion.
* **Interactive Field View Filtering:** Dropdown UI filtering supporting specialized inspector views:
  * *All Card Details* (Full summary report)
  * *Expiry Date Only* (Standard `YYYY-MM-DD` formatting)
  * *Cardholder & PAN* (Identifiable data isolation)
  * *Security Capabilities (AIP)* (Bitmask flag decomposition for SDA, DDA, CVM, CDA, etc.)
  * *Application Info* (AID & Application Label)
  * *Full TLV Tag Breakdown* (Complete nested tree visualization)
* **Built-in Sanitization & Masking:** Automated Primary Account Number (PAN) masking (`4111 11** **** 1111`) and Track 2 sanitization across the GUI inspector and exported reports.
* **Unified Diagnostic Console:** Auto-sequence execution piped directly into the interactive APDU Console log for unified tracing.
* **Non-Blocking Pacing Engine:** `Invoke-LazyDelay` routines (`250ms–500ms`) prevent GUI thread locking while preserving diagnostic execution flow visibility.

---

## Key Features

* **Zero External Dependencies:** Native Windows compilation using `Add-Type` with standard `.NET Framework` assemblies (`System.Windows.Forms`, `System.Drawing`).
* **Paced Hardware Engine:** Simulated visual latency during card polling for clear diagnostic visibility.
* **Automated EMV Pipeline:** One-click sequence: `SELECT` -> `GPO` -> `Multi-SFI Record Sweep` -> `Data Extraction`.
* **Recursive BER-TLV Parser:** Full decoding of nested Type-Length-Value structures with side-by-side Hex and ASCII visualization.
* **4-Layer Diagnostic Engine:**
  * **Layer 1:** Hardware & PC/SC Context Interface
  * **Layer 2:** Transport Protocol & ATR Structure Breakdown
  * **Layer 3:** Multi-AID Probing (Visa, Mastercard, Amex, UnionPay, Discover, JCB, PSE/PPSE)
  * **Layer 4:** FCI, BER-TLV Record & Interpreted Field Inspection
* **Transparent Status Handling:** Automatic handling for `61 XX` (Get Response) and `6C XX` (Re-issue Le) return codes.
* **Export Engine:** Timestamped diagnostic report export (`.txt`) with sanitized card data.

---

## ⚠️ Security & Legal Disclaimer

1. **Educational & Research Purpose Only:** This utility is designed strictly for hardware diagnostics, low-level ISO 7816 inspection, security research, and analyzing smart cards that you legally own or have explicit permission to test.
2. **Read-Only Operations:** This software performs standard read/discovery commands (`SELECT`, `GPO`, `READ RECORD`). It does **not** perform financial transactions, alter chip contents, bypass PIN locks, or clone smart card chips.
3. **PCI-DSS & Sensitive Data Handling:** While the script automatically masks Primary Account Numbers (PAN) and Track 2 data in the UI and exported files, users are responsible for handling smart card data in compliance with local privacy laws and PCI-DSS standards.
4. **Card Lock Risk:** Attempting unsupported APDU sequences or incorrect PIN operations on live payment cards can cause the Card Operating System (Card OS) to permanently block application access or lock the card. Proceed at your own risk.

---

## System Requirements

* **OS:** Windows 10 / Windows 11 / Windows Server 2016+
* **Environment:** Windows PowerShell 5.1 (or PowerShell Core with Windows Desktop SDK)
* **Hardware:** Any PC/SC-compliant Smart Card Reader (e.g., OmniKey, ACS, SCR3310, Integrated Laptop Readers)

---

## Quick Start

1. **Clone the repository:**
   ```powershell
   git clone [https://github.com/Shema-glitch/EMV-APDU-Lab.git](https://github.com/Shema-glitch/EMV-APDU-Lab.git)
   cd EMV-APDU-Lab