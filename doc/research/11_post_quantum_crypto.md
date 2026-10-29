# 11 — Quantensichere Krypto (Post-Quantum)

**Ziel (spec 06):** Krypto-Agilität; hybrider PQC-Transport; PQ-Signaturen für Provenienz; feststellen,
was schon PQ-sicher ist.

## Stand der Standards (belegt)
- **NIST, Aug 2024:** **FIPS 203 ML-KEM** (Kyber, Key-Encapsulation), **FIPS 204 ML-DSA** (Dilithium,
  Signatur), **FIPS 205 SLH-DSA** (SPHINCS+, hash-basierte Signatur).  Falcon/FN-DSA (FIPS 206) folgt.
- **OpenSSL 3.5.0 (8. Apr 2025, LTS bis 8. Apr 2030):** ML-KEM, ML-DSA, SLH-DSA **eingebaut**;
  Default-TLS-Gruppen bevorzugen **Hybrid `X25519MLKEM768`**; Server-QUIC.  → Mit OpenSSL 3.5+ gibt
  es **hybriden PQC-Schlüsselaustausch praktisch „kostenlos"** über die TLS-Schicht.
- **liboqs / oqs-provider**: Alternative/Ergänzung, falls das verlinkte OpenSSL < 3.5 ist.

## Schon PQ-sicher bei cosmos (symmetrisch/Hash; Grover nur √-Speedup → ≥256 Bit)
- Passwörter: **PBKDF2-HMAC-SHA256** (spec/… aiml `hash.pbkdf2`).
- Tokens: **`math.random_hex(32)`** = 256-bit CSPRNG, symmetrisches Geheimnis.
- **HMAC/SHA-256**; **CAS-Inhaltshashing** (256-bit ≈ 128-bit PQ; SHA-512/SHA3/BLAKE3-256 wenn
  paranoid).  → **Die Auth-Schicht ist im Kern bereits quantenresistent.**

## Muss migrieren (asymmetrisch; Shor)
- **TLS-Schlüsselaustausch** (heute ECDHE/X25519) → **hybrid X25519+ML-KEM768**.  **Dringlich** wegen
  **harvest-now-decrypt-later**: heutiger Mitschnitt wird später entschlüsselt → Vertraulichkeit
  **jetzt** hybrid absichern.
- **Public-Key-Signaturen**, sobald cosmos sie einführt (Artefakt-/StepSnapshot-Provenienz, Code-
  Signing, Cert-Ketten) → **ML-DSA** oder **SLH-DSA**.  **SLH-DSA ist hash-basiert** → passt
  konzeptionell perfekt in die CAS/Hash-Welt (02); sehr konservativ, nur größere/langsamere Signaturen.

## aiml-Ist / Lücke
- aiml linkt **System-OpenSSL 3.0.13** (geprüft) → **kein ML-KEM** (kam mit 3.5).  Transport heute
  klassisch ECDHE.  `hash.*`/`math.random_hex` (symmetrisch) vorhanden; **asymmetrische Primitive/
  Signaturen fehlen** (01 bestätigt voraussichtlich „keine asym. Krypto").
- **Weg:** aiml gegen **OpenSSL 3.5+** bauen/linken (exodus-Linker-Pfad) → Mirror/ws/tls bekommen
  Hybrid automatisch, **sofern** die aiml-TLS-Schicht die Gruppen durchreicht (prüfen).  Für
  Signaturen: ML-DSA/SLH-DSA via OpenSSL-3.5-API **oder** liboqs, angebunden per aiml-FFI (spec 35)
  oder als neue `crypto.*`-Builtins.

## Reuse vs. Build
- **Reuse:** OpenSSL 3.5+ (bzw. liboqs/oqs-provider) — **nicht** selbst PQC implementieren
  (gefährlich/sinnlos).  FIPS 203/204/205 als Vorgabe.
- **Neu in cosmos/aiml:**
  1. OpenSSL-3.5-Link + Durchreichen der Hybrid-Gruppen in der TLS/ws/mirror-Schicht.
  2. `crypto.*`-Builtins oder FFI für **ML-DSA/SLH-DSA-Signaturen** (Sign/Verify) — für Provenienz.
  3. **Krypto-Agilität**: Algorithmus-ID + Version in Tokens/Signaturen/Handshake; Rotation.

## Empfehlung
Kurzfristig: symmetrische Teile sind schon gut; **OpenSSL 3.5+ verlinken** für hybriden Transport
(größter Sicherheitsgewinn, HNDL).  Mittelfristig: **SLH-DSA** für StepSnapshot-/Artefakt-Signaturen
(hash-basiert, CAS-nah).  Grundsatz **Krypto-Agilität** von Anfang an in die Formate schreiben.

## Quellen
- OpenSSL 3.5.0 PQC + LTS: heise 10345305, admin-magazine „OpenSSL 3.5 Released", OpenSSL-Release-Notes (maßgeblich).
- NIST FIPS 203/204/205 (Aug 2024).  liboqs/oqs-provider (Allgemeinwissen).
- Geprüft lokal: `openssl version` = 3.0.13 (kein ML-KEM).
