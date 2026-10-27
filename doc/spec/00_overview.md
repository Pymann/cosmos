# Cosmos — Spezifikation (Überblick & Index)

**Status:** maßgeblich (authoritative).  Diese Spec ist die Wahrheit; die Implementierung richtet
sich nach ihr.  Wo der aktuelle Code abweicht, steht das im jeweiligen Kapitel unter
**„Implementierungsstand"** und gilt als offener Punkt (Reihenfolge: Spec → Tests → Code).

**Was Cosmos ist.**  Cosmos ist eine **Integrations-Control-Plane**: ein Steuerungssystem für
Build-, Deploy- und Integrationsabläufe, das Ideen aus Kubernetes (deklarativer Soll-Zustand,
Platzierung auf Knoten nach Labels und Kapazität) und Jenkins (dauerhafte Build-/Deploy-Jobs auf
Agenten, überlebt Verbindungsabbrüche) zusammenführt.  Kein Spiel, keine DOM-UI — Backend/
Control-Plane plus ein schlanker Browser-Client zur Beobachtung und Steuerung.

**Domäne (Software-Integration).**  Die Begriffe sind bewusst die der Integration:

| Cosmos-Entität | Integrations-Bedeutung |
|---|---|
| `Node` | Ausführungsknoten / Runner-Host (Build-Agent, Worker, Control-Plane) mit Kapazität + Labels |
| `Workload` | deploybares Ziel (Service/Deployment/Job) mit Soll-Replikaten + Ressourcenbedarf |
| `PipelineRun` | ein CI/CD-Lauf über Stages (checkout → build → deploy …) |
| `PipelineStage` | eine Stufe eines Laufs mit Art (`stage_kind`) und Label-Anforderung |
| `Job` (durable) | eine dauerhafte Build-/Deploy-Ausführung auf einem Agenten (Jenkins-artig) |
| `Agent` / `Controller` | Runner-Prozess bzw. dessen Koordinator; live beobachtbar (verbunden/last-seen), durable-task-Protokoll (Kapitel 05) |

**Leitprinzipien.**

1. **Deklarativ + reconciled.**  Nutzer beschreiben den Soll-Zustand (Workloads, Pipelines);
   der Reconciler bringt den Ist-Zustand dorthin (Platzierung, Promotion).
2. **Label-basierte Zuordnung.**  Platzierung und Stage-Ausführung wählen Knoten/Agenten über
   Labels + freie Kapazität — nie über feste Hostnamen.
3. **Dauerhafte Jobs.**  Ein laufender Build/Deploy überlebt den Absturz seines Agenten und des
   Controllers; der Zustand ist persistent und wird nach Reconnect fortgesetzt (Kapitel 05).
4. **Identität ist opak und stabil.**  IDs (`node_id`, `workload_id`, `run_id`, `job_id`) sind
   stabile Schlüssel; Anzeige-/Image-Namen sind davon getrennt.
5. **Server-autoritativ + authentifiziert.**  Lese-/Steueroperationen über das Netz sind
   token-gesichert (Kapitel 06 / Infra); der Client vertraut nie seiner eigenen Identität.
6. **Live-Observability (kein Poll).**  Zustandsänderungen — ein Agent verbindet sich, ein Job
   wechselt den Zustand, ein Workload wird platziert — erscheinen **live** beim Betrachter, ohne
   manuelles Aktualisieren.  Der Server pusht Änderungen ereignisgetrieben an authentifizierte
   Abonnenten (Kapitel 02 + architecture §7.4); ein Aktualisieren-Knopf ist nur Fallback.
7. **Least-Privilege-Ausführung (kein root).**  Fremder/mandanten-fremder Build-Code läuft **nie**
   als root und nie mit Host-Privilegien.  Zwei getrennte Identitäts-Ebenen: **Plattform-Identität**
   (Account/Tenant/RBAC) und **Ausführungs-Identität** (der OS-User im Container).  Letztere ist
   immer **rootless** (User-Namespaces mit Host-UID-Remapping, pro Tenant eigener UID-Bereich),
   mit gedroppten Capabilities, seccomp/MAC, `no-new-privileges`; für nicht vertrauenswürdigen Code
   stärkere Isolation (gVisor/Kata).  Die **isolierende Sandbox ist zugleich die Trace-Sandbox**
   des Versionierungssystems (Kapitel 16) — ein Mechanismus, zwei Zwecke.  Details: Kapitel 06/13/20.

**Nicht-Ziele (vorerst).**  Echte Container-Laufzeit/Image-Pull, verteiltes Multi-Node-Clustering
über Netz, RBAC/Mandantenfähigkeit, Secrets-Management, Autoscaling, Rollout-Strategien
(Canary/Blue-Green).  Diese sind mögliche spätere Kapitel, aber nicht Teil dieser Fassung.

## Zielbild (Vision)

**Nordstern:** Cosmos soll langfristig ein **vollwertiger Cloud-Service** werden (in der Art von
Azure) — Selbstbedienung für Compute, Build und Deploy, mandantenfähig über Accounts.  Die bereits
vorhandene Account-/Login-Schicht (architecture §7) ist der **Mandanten-Keim**: jeder Account ist
ein Tenant, dessen Ressourcen (Workloads, Pipelines, Jobs, Caches) voneinander isoliert sind.

Richtungsweisende Bausteine (noch nicht alle spezifiziert/umgesetzt; sie prägen die Modellierung
schon jetzt, damit nichts den späteren Ausbau verbaut):

- **Mandantenfähigkeit.**  Account = Tenant; jede Entität trägt (künftig) eine Eigentümer-Identität
  (`owner`/`tenant` = `player_id` aus der Auth-Schicht).  Isolation + Quotas pro Tenant.
- **Erstklassiges Caching.**  Build-/Artefakt-/Layer-Caches als bewusste, inspizierbare Entitäten
  (Cache-Keys, Hits/Misses, Wiederverwendung über Läufe und Agenten) — nicht als Nebeneffekt.
- **Container-Anbindung.**  Workloads/Jobs laufen gegen eine Container-Laufzeit (Image-Pull,
  Start/Stop, Limits); `image_ref` + `stage_kind` sind die Anknüpfungspunkte.
- **Git-Anbindung.**  Repositories/Branches als eingebundene Quelle (checkout-Stage, `repo_url`/
  `branch`), inkl. späterer Git-Library-Integration für Historie/Trigger.
- **Live-Monitoring.**  Agenten/Runner, Jobs und Pipelines werden live überwacht; Verbinden/
  Trennen eines Agenten und jeder Zustandswechsel sind sofort sichtbar (Leitprinzip 6).
- **Observability ohne Ballast.**  Überwachung und Dashboards sind **eingebaut** — kein
  jahrelanges Grafana-JSON-Schreiben.  Metriken, Status und Logs sind erstklassige Entitäten, die
  Cosmos aus dem Domänenmodell heraus **automatisch** visualisiert (Default-Dashboards pro Node/
  Workload/Pipeline/Job/Datenbank; Overrides optional, nie Pflicht).
- **Durchgängiges Logging + Visualisierung.**  Build-Logs **und** Datenbank-/Service-Zustände
  werden vollständig erfasst und direkt visualisiert — Live-Tail, Zeitreihen, Suche/Filter — aus
  einem Modell, in einer Ansicht.  Der durable Job hält bereits das vollständige Build-Log
  (Kapitel 05); das ist die Keimzelle dieses Pfeilers.
- **Build-Verfolgung wie Blue Ocean.**  Ein Lauf wird als **Pipeline-Stage-Graph** dargestellt
  (Stufen als Knoten, parallele Zweige, je Stufe Live-Status und Fortschritt, Drill-down ins
  Stage-Log) — die visuelle Verlaufsansicht, die Jenkins Blue Ocean bietet.
- **OpenGL-Fortschritt im Infrastruktur-Kontext.**  Der Lauf/Job wird **live als OpenGL/WebGL-Szene**
  gerendert, eingebettet in die Infrastruktur: welcher Node/Agent führt gerade welche Stage aus,
  wie wandert der Fortschritt durch den Cluster.  Die Cluster-Ansicht ist damit keine Textliste,
  sondern eine lebende Szene (knüpft an `doc/spec/2026-05-29_rendering_and_sync_direction.md` und
  den vorhandenen Engine-/GL-Client an).
- **Skalierung + Load-Balancing (Abgrenzung zu Jenkins).**  Horizontal skalierbar über viele
  Agenten/Nodes; Jobs und Stages werden **lastverteilt** auf freie, geeignete Runner platziert
  (nicht „erster passender", sondern am wenigsten ausgelasteter — §03).  Jenkins hat genau das
  **nicht** (ein Master, Agenten ohne echtes Scheduling/Balancing); Cosmos macht Scheduling +
  Lastverteilung zum Kern.  Die Control-Plane selbst soll mehrfach instanziierbar sein
  (zustandslos über geteiltem Store), damit kein Single Point of Contention entsteht.
- **… und mehr** als spätere Kapitel: Regionen/Verfügbarkeitszonen, Quotas/Billing, Policies,
  Rollout-Strategien, Secrets, Autoscaling, Service-Katalog.

Diese Fassung spezifiziert zuerst das **Domänenmodell + die Lebenszyklen** (Kapitel 01–05), weil
alles Weitere darauf aufbaut.  Die Cloud-/Mandanten-Themen sind als eigene Kapitel vorgesehen, hier
aber nur als Rahmen genannt — damit die Entitäten von Anfang an einen Eigentümer tragen können.

## Kapitel

| Kapitel | Inhalt |
|---|---|
| [01_domain_model.md](01_domain_model.md) | Entitäten, Felder, Identität, Beziehungen |
| [02_lifecycles.md](02_lifecycles.md) | Zustandsautomaten: Workload, PipelineRun/Stage, Job |
| [03_scheduling_and_reconcile.md](03_scheduling_and_reconcile.md) | Platzierung (Label + Kapazität), Reconcile-Semantik |
| [04_pipelines_and_jobs.md](04_pipelines_and_jobs.md) | Pipeline→Job-Orchestrierung, Promotion |
| [05_runner_protocol.md](05_runner_protocol.md) | Controller/Agent-Protokoll für durable Jobs |

**Arbeitspakete** — Kapitel, die am laufenden Bau mitgeschrieben werden (90er-Block):

| Kapitel | Inhalt |
|---|---|
| [90_ap1_agent_exec.md](90_ap1_agent_exec.md) | AP1: Kommando auf einem Agenten, Ausgabe-Ströme, Enrollment-Tokens |
| [91_ap2_users_exec_aiml.md](91_ap2_users_exec_aiml.md) | AP2: Ausführungs-Identität (rootless/userns), Threads, UI-Sichtbarkeit, Schritt-Modell |
| [92_cas.md](92_cas.md) | Inhaltsadressierter Speicher: Blobs, Trees, Materialisierung |
| [93_runtime_group.md](93_runtime_group.md) | Aufbau des Controllers: Dienste und Handler als Classgroup-Instanzen |
| [94_agent_provisioning.md](94_agent_provisioning.md) | Agenten-Einrichtung über SSH: einmal `sudo` im Server, Knoten richtet sich selbst ein |
| [95_review_findings.md](95_review_findings.md) | Arbeitsplan aus der Prüfung 2026-10-11: fünf Befunde (Integrität, Zugriff, Einrichtung) mit Reihenfolge |
| [96_layer_cache.md](96_layer_cache.md) | Layer-Cache: Pipelines wiederholbar machen — Lanes, Status, anhalten/fortsetzen, Knotenwahl; **deckt das geplante 12_caching.md ab** |
| [97_pipeline_scene.md](97_pipeline_scene.md) | Zielbild: die Matrix als 3D-Szene (Parameterraum = Szenenraum); **deckt das geplante 15_visualization.md ab** |
| [98_webapp_ui.md](98_webapp_ui.md) | UI der Webapp: Pipeline-Editor (Gutter, Hervorhebung), Befundliste, Prüfung über RPC |

**Geplante Kapitel (Zielbild, noch nicht geschrieben):**

| Kapitel | Inhalt |
|---|---|
| 06_security.md | Normative Auth-/Security-Vorgaben (architecture §7.1) **+ Krypto-Agilität & Post-Quanten**: hybrider ML-KEM-Transport (FIPS 203, sobald OpenSSL 3.5+/oqs), ML-DSA/SLH-DSA-Signaturen (FIPS 204/205) für Provenienz; symmetrische Teile (PBKDF2/HMAC/CSPRNG-Tokens/CAS-Hash) bereits PQ-sicher |
| 10_observability.md | Metriken/Status/Logs als Entitäten; **automatische** Default-Dashboards (kein Grafana-JSON) |
| 11_logging.md | Durchgängiges Build- **und** DB-/Service-Logging mit Visualisierung (Live-Tail, Zeitreihen, Suche) |
| ~~12_caching.md~~ | **geschrieben als [96_layer_cache.md](96_layer_cache.md)** (mit aiml `spec/62` als Sprachseite) |
| 13_container.md | Container-Laufzeit-Anbindung (Image-Pull, Start/Stop, Limits) — Vorklärung liegt in [96_layer_cache.md](96_layer_cache.md) §96.12, Zielbild `image:`/`push:` in aiml `spec/62` §16 |
| 14_git.md | Git-/Repo-Anbindung (checkout, Historie, Trigger) |
| ~~15_visualization.md~~ | **geschrieben als [97_pipeline_scene.md](97_pipeline_scene.md)** — und über Blue Ocean hinaus: ein Stage-Graph ist zweidimensional, eine Matrix nicht |
| 20_tenancy.md | Mandantenfähigkeit: Account=Tenant, Isolation, Quotas/Billing, Regionen |
| 21_scaling.md | Skalierung + Load-Balancing: least-loaded-Scheduling, mehrfache Control-Plane, Verfügbarkeit (Jenkins-Abgrenzung) |

**Infrastruktur** (Transport, Auth/Security, Browser-Tier, Deployment) ist in
[../architecture.md](../architecture.md) §7 beschrieben und aus 9rooms übernommen; ihre
normativen Sicherheitsvorgaben fasst Kapitel 06 (folgt) zusammen.

**Forschungs-Dossier.**  Die Machbarkeit des Zielbilds (aiml-Ist-Stand, Library-Vergleiche,
Reuse-vs-Build, was neu zu bauen ist) ist in [../research/](../research/) analysiert — Einstieg
[research/99_synthesis_roadmap.md](../research/99_synthesis_roadmap.md), Fundament
[research/01_aiml_capability_inventory.md](../research/01_aiml_capability_inventory.md).

## Konventionen

- **MUSS / SOLL / KANN** im Sinne von RFC 2119.
- Zustände sind in dieser Spec als **Enums** definiert; wo die Implementierung heute Strings
  nutzt, ist das eine zu behebende Abweichung (Kapitel 02 „Implementierungsstand").
- Zeiten sind `time.now`-Millisekunden (i64), UTC-basiert.
- Persistenz über AionDB-KV (spec/31 der aiml-Spec); Schlüssel = die jeweilige Entitäts-ID.
