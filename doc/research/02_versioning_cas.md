# 02 — Inhaltsadressierter Store / Versionierungssystem (CAS)

**Ziel (spec 16):** inputgeschlüsselter DAG von Build-Zuständen; Snapshot pro Schritt, Cache/Resume/
Branch als Grundoperationen; Build ≠ Packaging; Bernstein-Vertauschbarkeit aus read/writeset.

## Landschaft & Vergleich

| System | Modell | Stärke | für cosmos |
|---|---|---|---|
| **git odb** | Merkle-DAG aus blobs/trees/commits, SHA-1→SHA-256 | universell, robust, Diff/Pack | **Vorbild** fürs Tree-Format; Quelle via Ingestion (05) |
| **Bazel Remote APIs (REAPI)** | CAS + ActionCache + Execution, gRPC/protobuf, blobs per `{hash}/{size}` | **produktionsreif**, verteiltes Caching + Remote-Execution, genau „inputgeschlüsselt" | **stärkste Referenz**; Protokoll ggf. direkt adaptieren |
| **Nix / ca-derivations** | hermetische Derivations, Store-Pfade | Reproduzierbarkeit, „early cutoff" | Konzept-Vorbild; **ca-derivations noch experimentell (~71%)**, Cache-Poisoning offen → nicht 1:1 übernehmen |
| **OSTree / casync** | inhaltsadressierte Dateibäume, Chunking/Dedup | effiziente große/binäre Bäume, Deltas | **Chunking-Technik** für Snapshot-Speicherung |
| **OCI / ORAS** | inhaltsadressierte Layer/Artefakte, Registry | Transport-/Verteilungsstandard | **Transport-/Packaging-Senke** (13) |
| **IPFS** | CID/Merkle-DAG, P2P | globale Adressierung | eher Inspiration, nicht Kern |
| **restic/borg** | dedup, Chunking (content-defined) | Backup-Dedup | Technik für GC/Store-Layout |

**Hash:** BLAKE3 (schnell, parallel, verifizierbares Streaming) oder SHA-256. 256-bit Hash ≈
128-bit PQ-Sicherheit (ausreichend; SHA-512/SHA3 wenn paranoid, siehe 11).

**Kernbefund:** Die **REAPI** (Bazel) ist das einzige **produktionsreif** erprobte Modell, das genau
cosmos' „CAS + ActionCache (Input-Hash→Output) + Remote-Execution" abbildet.  Nix zeigt, dass
„alles content-addressed" selbst nach Jahren noch experimentell ist — also **REAPI-Semantik als
Referenz**, nicht Nix nachbauen.

## Reuse vs. Build

- **Reuse (als Referenz/Protokoll, ggf. später Interop):** REAPI-Datenmodell (CAS-Blob, Directory-
  Merkle-Tree, Action/Command, ActionResult).  OCI/ORAS für Artefakt-Transport.  casync/BLAKE3-
  Chunking-Ideen.
- **Neu in cosmos/aiml bauen (nötig, weil es das so nicht gibt):**
  1. **CAS-Store über AionDB**: Blob-Put/Get per Hash, Directory-Trees (Name→Hash), Dedup.  aiml
     hat KV + heap-serialization (prüfe 01) → ein CAS ist „KV mit Hash-Schlüssel + Tree-Objekten".
  2. **Hashing von Dateibäumen** (Merkle über Verzeichnis) — fehlt in aiml, muss nativ oder per
     BLAKE3-FFI (07/11-Muster).
  3. **ActionCache**: `input_hash → output_tree_hash` (ein typisiertes KV).  Trivial auf AionDB.
  4. **StepSnapshot-Entität** + DAG-Kanten (spec 16); Resume = Tree materialisieren; Branch = neuer
     Elternknoten.
  5. **GC / Retention** (Mark-and-Sweep über erreichbare Hashes) — neu.
  6. **Materialisierung** eines Trees ins Dateisystem/Container (Hardlink/overlay/idmapped) — neu,
     hängt an 03/04.

## aiml-Lücken (vorläufig, 01 bestätigt)

- Kein Datei-Baum-Hashing/Merkle; kein Chunking.  BLAKE3/SHA über `buffer` + `io.read_bytes`
  grundsätzlich baubar; FFI zu BLAKE3 wäre schneller.
- KV ist da (AionDB, persist, indexed, heap-ser) → gutes **Fundament** für Blob-/Tree-/ActionCache-
  Stores.  Großblob-Handling (mmap 16 MB Reserve, spec/31) für große Artefakte prüfen.
- Keine Dedup-/GC-Primitive.

## Empfehlung

CAS **nativ auf AionDB** bauen (Blob/Tree/ActionCache als typisierte KVs), **REAPI-Datenmodell als
Blaupause**, **BLAKE3 via FFI** fürs Hashing, **casync-Chunking** für große Bäume später.  Nicht
Nix/Bazel als Ganzes einbinden — nur deren Modelle übernehmen.  Das ist substanzieller Neubau,
aber auf vorhandenem KV-Fundament; der Kern (Blob/Tree/ActionCache) ist in Wochen machbar, GC/
Chunking/Remote-Execution sind spätere Ausbaustufen.

## Quellen
- Bazel REAPI: bazelbuild/remote-apis, `remote_execution.proto` (CAS + ActionCache + Execution).
- Nix ca-derivations: NixOS/nix Meilenstein (experimentell, ~71%), tweag.io CAS-Serie, nixos.wiki/Ca-derivations.
- OSTree/casync, OCI/ORAS, BLAKE3 (Allgemeinwissen, Cutoff 2026).
