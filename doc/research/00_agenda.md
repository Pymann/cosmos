# Cosmos — Forschungs-Dossier (Agenda & Methode)

**Auftrag (User, 2026-10-08, autonome Nachtarbeit):** Recherchieren und dokumentieren, wie die
cosmos-Vision („die Träume eines Programmierers wahr werden lassen") real wird.  Für jedes Thema:
aiml-Ist-Stand prüfen, **existierende Libraries/Systeme vergleichen**, und benennen, **was neu
implementiert werden muss**.  Keine Code-Änderungen in dieser Sitzung — nur Analyse + Dokumentation.

**Methode.**
- **aiml-Ist-Stand**: am Repo verifiziert (Spec `test/aiml/spec/*.md` + Quellen `src/…`), nicht aus
  dem Gedächtnis.  Zusammengetragen in [01_aiml_capability_inventory.md](01_aiml_capability_inventory.md).
- **Library-Vergleich**: Stand meines Wissens (Cutoff Jan 2026) + gezielte Websuche zur Auffrischung
  zeitkritischer Fakten (PQC/OpenSSL-Versionen, Reife von gitoxide/youki/crun, REAPI, BLAKE3,
  Landlock, idmapped mounts, OTel).  Websuche ist US-begrenzt und stichprobenartig — Fakten, die ich
  nur per Suche „bestätigt" habe, sind als solche markiert.
- **Reuse vs. Build**: jede Themendatei endet mit einer Einschätzung „einbinden (FFI/Adapter) vs.
  nativ in aiml bauen" + konkreten Lücken.  Gesamtsynthese in [99_synthesis_roadmap.md](99_synthesis_roadmap.md).

**Leitfrage.**  Cosmos soll (Zielbild spec/00): Cloud-Service (mandantenfähig), Live-Observability
ohne Poll, Observability/Dashboards ohne Grafana-JSON, durchgängiges Build-+DB-Logging mit
Visualisierung, Blue-Ocean-Build-Verfolgung + OpenGL-Infra-Rendering, erstklassiges Caching,
Container- und Git-Anbindung, Skalierung + Load-Balancing, inhaltsadressiertes Versionierungssystem
(inputgeschlüsselter CAS-DAG), Least-Privilege/rootless Ausführung, quantensichere Krypto.

## Themendateien

| Datei | Thema | Load-bearing? |
|---|---|---|
| 01_aiml_capability_inventory.md | aiml-Laufzeit: was da ist / fehlt | ⭑ Fundament |
| 02_versioning_cas.md | Inhaltsadressierter Store / Versionierung (Nix, Bazel-CAS, OSTree, git odb, casync, BLAKE3) | ⭑⭑ |
| 03_build_sandbox_tracing.md | read/writeset-Tracing + Sandbox (BuildXL, rattle, Landlock, fuse/overlay, ptrace, seccomp) | ⭑⭑ |
| 04_containers_isolation_rootless.md | runc/crun/youki, rootless/userns, gVisor/Kata/Firecracker, buildkit/kaniko | ⭑⭑ |
| 05_git_ingestion.md | Git-Adapter: CLI vs libgit2 vs gitoxide | ⭑ |
| 06_dependencies_packaging.md | Conan/vcpkg/… + OCI/ORAS als Adapter | |
| 07_scheduling_loadbalancing.md | k8s-Scheduler, Nomad, bin-packing, least-loaded | ⭑ |
| 08_observability_metrics.md | Prometheus/OTel-Modell, TSDB, Auto-Dashboards ohne Grafana-JSON | ⭑⭑ |
| 09_logging_visualization.md | strukturierte Logs, Live-Tail, Suche (Loki/Vector/journald) | |
| 10_visualization_opengl.md | Blue-Ocean-DAG-Layout + OpenGL-Infra-Szene | ⭑ |
| 11_post_quantum_crypto.md | liboqs, OpenSSL 3.5 ML-KEM, PQClean, FIPS 203/204/205 | ⭑ |
| 12_transport_scaling.md | Mirror-Transport, Multi-Instanz-Control-Plane | |
| 13_container_agents_containerd.md | Pod als Agent (containerd vs. nackte OCI-Runtime), Docker-Client nicht nötig | Nachtrag 18.10.2026, auf Frage des Users |
| 99_synthesis_roadmap.md | Reuse-vs-Build-Matrix, Phasen, Risiken, Neu-zu-bauen-Liste | ⭑⭑⭑ |

**Lesereihenfolge für den Morgen:** 99 (Synthese/Roadmap) zuerst für den Überblick, dann 01
(aiml-Fundament), dann die ⭑⭑-Themen.
