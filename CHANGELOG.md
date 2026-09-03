# Changelog

All notable changes to the **EMV APDU Lab** project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-09-03

### Added
* **Automated Card Data Inspector:** Automatic post-sequence TLV tree walking to extract and display human-readable card properties.
* **Interactive Field View Filter:** Added dropdown inspector filtering (`All Card Details`, `Expiry Date Only`, `Cardholder & PAN`, `Security Capabilities (AIP)`, `Application Info`, `Full TLV Tag Breakdown`).
* **Data Masking & Sanitization:** Automated masking for Primary Account Numbers (PAN) (`4111 11** **** 1111`) and Track 2 equivalent data across UI views and log exports.
* **Security & Legal Disclaimers:** Explicit guardrails regarding read-only operations, card lock risks, and PCI-DSS compliance in `README.md`.

### Changed
* **Repository Architecture:** Consolidated standalone script execution into `EMV_APDU_Lab_V15.ps1` and cleaned legacy test files (`main_v5*.ps1`).
* **Pacing Engine:** Enhanced non-blocking UI delay routines (`250ms–500ms`) using `Invoke-LazyDelay` to ensure responsive terminal-style execution.

---

## [0.14.0] - Legacy (V14)

### Added
* **Unified Diagnostic Console:** Direct piping of auto-sequence execution into the interactive APDU console log.
* **3D Matrix Block Banner:** Native PowerShell grid rendering function (`Write-3DBlockBanner`) using character layer offsets (`█`, `░`).

---

## [0.5.0] - Legacy (V5)

### Added
* Initial multi-tab desktop GUI layout using `.NET System.Windows.Forms`.
* Low-level `winscard.dll` P/Invoke bindings for Windows PC/SC smart card readers.
* Basic ISO 7816-4 APDU command transmission (`SELECT`, `GPO`, `READ RECORD`).
* Recursive BER-TLV binary parser with side-by-side Hex and ASCII inspector.