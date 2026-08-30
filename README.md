# EMV APDU Lab (V14)

**EMV APDU Lab** is a zero-dependency, standalone Windows desktop diagnostic utility built in PowerShell and C#. It provides low-level hardware communication with PC/SC smart card readers via native `winscard.dll` P/Invoke calls, featuring automated EMV application scanning, recursive BER-TLV parsing, and step-by-step diagnostic logging.

---

## What's New in V14

* **Unified Diagnostic Console:** Auto-sequence execution is now piped directly into the interactive APDU Console log for unified tracing.
* **Non-Blocking Lazy Loading:** Integrated `Invoke-LazyDelay` pacing routines (`250ms–500ms` steps) to prevent GUI freezes while delivering a terminal-style diagnostic execution flow.
* **3D Matrix Block Banner:** Added native PowerShell grid rendering function (`Write-3DBlockBanner`) using character layer offsets (`█`, `░`) for terminal header art.

---

## Key Features

* **Zero External Dependencies:** Native Windows compilation using `Add-Type` with standard `.NET Framework` assemblies (`System.Windows.Forms`, `System.Drawing`).
* **Paced Execution Engine:** Simulated visual latency during card polling for enhanced diagnostic visibility.
* **Automated EMV Pipeline:** One-click execution flow executing `SELECT` -> `GPO` -> `Multi-SFI Record Sweep` -> `Data Extraction`.
* **Recursive BER-TLV Parser:** Full decoding of nested Type-Length-Value structures with side-by-side Hex and ASCII visualization.
* **4-Layer Diagnostic Engine:**
  * **Layer 1:** Hardware & PC/SC Context Interface
  * **Layer 2:** Transport Protocol & ATR Structure Breakdown
  * **Layer 3:** Multi-AID Probing (Visa, Mastercard, Amex, UnionPay, Discover, JCB, PSE/PPSE)
  * **Layer 4:** FCI & BER-TLV Record Inspection
* **Automatic Status Handling:** Transparent resolution for `61 XX` (Get Response) and `6C XX` (Re-issue Le) return codes.
* **Export Engine:** One-click timestamped diagnostic report export (`.txt`).

---

## System Requirements

* **OS:** Windows 10 / Windows 11 / Windows Server 2016+
* **Environment:** Windows PowerShell 5.1 (or PowerShell Core with Windows Desktop SDK)
* **Hardware:** Any PC/SC-compliant Smart Card Reader (e.g., OmniKey, ACS, SCR3310, Integrated Laptop Smart Card Readers)

---

## Installation & Quick Start

1. **Clone the repository:**
   ```powershell
   git clone [https://github.com/Shema-glitch/EMV-APDU-Lab.git](https://github.com/Shema-glitch/EMV-APDU-Lab.git)
   cd EMV-APDU-Lab