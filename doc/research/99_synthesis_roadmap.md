# 99 — Synthese & Roadmap

Gesamtbild aus 01–12.  **Kernbefund:** cosmos steht auf einem **ungewöhnlich breiten aiml-Fundament**
(Prozesse, Netz/TLS/WS/HTTP/mirror+auth-Push, eingebettete WAL-DB **mit TimeSeries**, Digests/HMAC/
PBKDF2, FFI zu C-Libs, native OpenGL-Engine, JIT/AOT/wasm).  Fast jede Lücke ist **„reife C-Lib
anbinden" oder „kleine aiml-Logik"**, nicht „from scratch" — bis auf vier echte Großbaustellen.

## Reuse vs. Build (Überblick)

| Thema | Reuse (nicht nachbauen) | Neu bauen | Klasse |
|---|---|---|---|
| CAS/Versionierung (02) | REAPI-Modell, OCI/ORAS, casync-Chunking | Blob/Tree/ActionCache auf AionDB, Tree-Hashing, StepSnapshot-DAG, GC | **GROSS** |
| Sandbox/Tracing (03) | overlayfs, Landlock, seccomp, fanotify, idmapped mounts | Launcher-Adapter, readset/writeset-Erfassung, Bernstein-Logik | **GROSS** |
| Container/Isolation (04) | crun/youki, gVisor/Kata, buildkit/kaniko | OCI-Spec-Adapter (`sys.exe`), Tree-Materialisierung, Isolations-Policy, per-Tenant-UID | mittel |
| Git (05) | git-CLI / libgit2 / gitoxide | Ingestion-Dienst `repo@ref→CAS-Tree`, Credential-Grenze | klein→mittel |
| Deps/Packaging (06) | Conan/npm/… im Container, OCI/ORAS | Artefakt-Entität im CAS, dünne Resolver-Adapter, OCI-Client | klein→mittel |
| Scheduling (07) | k8s/Nomad-Konzepte (filter→score) | nativer least-loaded + cache-affiner Scheduler, Job-Leases | klein |
| Observability (08) | Prometheus/OTLP-Ingest, Perses-Export | **Auto-Dashboards aus Domänenmodell** (USP), Metrik-Entitäten auf TimeSeries | mittel |
| Logging (09) | Loki-Labelmodell, Vector-Ingest | Log-Stream-Entität, Live-Tail-Push, Suche | klein→mittel |
| OpenGL-Viz (10) | Sugiyama-Layout, Blue-Ocean-UX | DAG-Layout + Modell→Prefab-Mapping (Engine ist da!) | mittel, **geringes Risiko** |
| PQC/Crypto (11) | OpenSSL 3.5+ / liboqs, FIPS 203/204/205 | OpenSSL-3.5-Relink, ML-DSA/SLH-DSA-Signatur-Builtins, Krypto-Agilität | mittel |
| Transport/Scaling (12) | mirror/ws (da), nginx/envoy, S3/OCI, Raft | zustandsloser Daemon (Leases/Subscriber im Store), Store-Replikation | klein→**GROSS** |

## Neu zu implementieren — nach Aufwandsklasse

**A. Kleine aiml-Logik (Tage, reine Sprache):**
- Scheduler filter→score (least-loaded, cache-affin) [07]
- Bernstein-Vertauschbarkeit (Mengen-Schnitte) [03]
- Agent als eigene Entität + `ClusterView.agents`; Agent-Ereignisse in die Push-Signatur [01-Abw. 4/5]
- Enum-Umstellung der Zustände; `owner`/Tenant-Feld [spec 01 Abw. 1–3]
- rekursiver FS-Walk/Copy + Globber (fehlt, aber trivial über `list_dir`+`is_dir`) [01]

**B. C-Lib anbinden via FFI/exodus.json (bekannter Pfad, Beispiele vorhanden):**
- **OpenSSL 3.5+ relinken** → Hybrid-PQC-Transport „gratis"; ML-DSA/SLH-DSA-Signaturen [11]
- **BLAKE3** fürs CAS-Hashing (schneller als sha256; sonst sha256 nativ) [02]
- **crun/youki** als Runtime (meist via `sys.exe`, kaum FFI) [04]
- **libgit2/gitoxide** später am Git-Adapter (CLI reicht zuerst) [05]
- optional **liboqs** falls OpenSSL-Relink nicht geht [11]

**C. Neue Subsysteme auf vorhandenem Fundament (Wochen):**
- **CAS** (Blob/Tree/ActionCache auf AionDB + Tree-Hashing + Materialisierung) [02] — der Dreh- und Angelpunkt
- **Sandbox-Launcher + Tracing** (overlayfs + rootless-Runtime + read/writeset) [03/04]
- **Auto-Dashboard-Generator** aus dem Modell (USP) [08] + DAG-Layout/Szene [10]
- **Log-Streams + Live-Tail + Suche** [09]
- **Container-/Runner-Ausbau** des durable Jobs (OCI-Spec, Tree-Materialisierung) [04/05]

**D. Echte Großbaustellen / Forschung (Monate, Risiko):**
- **Store-Replikation/Clustering** (AionDB single-node) für echte HA/Skalierung [12]
- **Feingranulares, hermetisches read-set-Tracing** (fanotify/FUSE) + Reproduzierbarkeit [03]
- **Remote-Execution** (REAPI-artig, Build-Verteilung über Agenten) [02/04]
- **Volle Mandantenfähigkeit** (Quotas/Billing/Isolation/Regionen) [spec 20]

## Empfohlene Reihenfolge (größter Hebel × geringstes Risiko zuerst)

1. **Modell härten** (A): Enums, `owner`/Tenant, Agent-Entität + Live-Push auf Agent-Ereignisse,
   FS-Walk/Globber.  → macht die Spec/Impl konsistent, kleiner Aufwand, sofortiger Live-Nutzen.
2. **CAS-Kern** (C/02): Blob/Tree/ActionCache auf AionDB + sha256/BLAKE3-Tree-Hashing.  → Fundament
   für Caching, Versionierung, Snapshots.
3. **Rootless-Runner + Materialisierung** (04/03): crun via `sys.exe`, overlay lower=CAS-Tree,
   writeset aus upper (readset zunächst konservativ).  → sichere Ausführung + Snapshot pro Schritt.
4. **Git-Ingestion-Adapter** (05, CLI zuerst) + **StepSnapshot-DAG** (02) + **Scheduler** (07).
   → echte, gecachte, lastverteilte Pipelines.
5. **Visualisierung** (10) + **Auto-Dashboards/Logging** (08/09) auf dem Live-Push.  → der sichtbare
   „Programmierer-Traum", geringes Fremd-Risiko (Engine ist da).
6. **PQC-Transport** (11, OpenSSL-3.5-Relink) + Signaturen für Provenienz.
7. **Skalierung** (12): zustandsloser Daemon + Leases; Replikation später.

## Risiken / ehrliche Vorbehalte
- **AionDB single-node** ist die härteste Skalierungsgrenze (12/D).  Entkopplung Rechnen/Speichern
  (CAS in externen Objektspeicher) mildert, löst sie nicht.
- **Hermetisches Tracing** ist fummelig (versteckte Inputs, FUSE/fanotify-Overhead); konservativ
  starten, Präzision später.
- **Reproduzierbarkeit** ist ein Dauerthema (selbst Nix ca-derivations noch experimentell).
- **Untrusted-Code-Isolation** braucht echte Grenzen (Kata/gVisor), nicht nur Container.
- **OpenSSL-Relink** muss die aiml-TLS-Schicht die Hybrid-Gruppen durchreichen lassen (prüfen).

## Offene Verifikationen (nur Wissen, nicht per Suche bestätigt)
- Genaues Feature-Set/Reife von libgit2 heute; idmapped-mounts-Kernelstand; ob aiml-`mirror`/`tls`
  die OpenSSL-3.5-Hybrid-Gruppen ohne Codeänderung durchreicht; AionDB-Großblob-Grenzen fürs CAS.

## Fazit
Der „Traum" ist realistisch, **weil** aiml das seltene Fundament (Prozesse+Netz+DB+TimeSeries+FFI+
OpenGL+wasm) schon mitbringt.  Der kritische Pfad ist **CAS → Sandbox/Runner → Snapshot-DAG**; alles
andere (Scheduling, Observability, Viz, Git, Deps) sind überschaubare Aufsätze.  Die zwei echten
Langfrist-Brocken sind **Store-Skalierung** und **hermetisches Tracing/Remote-Execution**.
