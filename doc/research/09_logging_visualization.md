# 09 — Logging (Builds + DB/Services) mit Visualisierung

**Ziel (spec 11):** vollständiges Build- **und** DB-/Service-Logging, direkt visualisiert — Live-Tail,
Zeitreihen, Suche/Filter — aus einem Modell, einer Ansicht.  Keimzelle: der durable Job hält schon
das **vollständige Build-Log** (spec 05).

## Landschaft
- **Log-Pipelines:** Loki (Label-indexiert, günstig), Elastic/OpenSearch (Volltext, teuer), Vector/
  Fluent Bit (Shipping/Transform), journald.
- **Modell:** Loki trennt **Labels** (indexiert) von **Linien** (komprimiert gespeichert) — gutes,
  schlankes Vorbild.
- **DB-Observability:** Query-Logs, Slow-Logs, WAL-/Checkpoint-Events, Row/Size-Metriken — bei cosmos
  **AionDB** selbst (Mirror/KV/TimeSeries) als Quelle.

## cosmos-Modell
- **Log-Stream-Entität:** Besitzer (Job/Node/Service/DB) + Labels + append-only Linien; Speicherung
  über **AionDB** (KV-Blob je Stream + optional TimeSeries für Raten).  CAS-Verknüpfung: das Log
  eines StepSnapshots gehört zum Snapshot (reproduzierbar auffindbar).
- **Live-Tail:** über den vorhandenen **authentifizierten Server-Push** (architecture §7.4) — neue
  Linien werden an Abonnenten gepusht (kein Poll, Leitprinzip 6).
- **Suche/Filter:** Label-Filter + Substring/Regex über den Stream.
- **Visualisierung:** fällt mit 08/10 zusammen — Log-Panel + Zeitreihen in der nativen OpenGL-Szene.

## Reuse vs. Build
- **Reuse:** Loki-**Labelmodell** als Blaupause; Vector/Fluent-Bit als optionale externe Shipper (via
  http-Ingest).
- **Neu in cosmos:** Log-Stream-Entität + Ingest + **Live-Tail-Push** + Such-Index (einfacher
  invertierter Index oder linearer Scan über AionDB); DB-Event-Tap aus AionDB.

## aiml-Eignung
- **Gut:** `log`-Namespace, ws/mirror-Push, KV/TimeSeries, `ui`-Charts/`textbox` — alles vorhanden.
  Der durable Job streamt sein Log bereits (Kapitel 05).
- **Lücke:** Such-Index; strukturierte (JSON-)Log-Felder; Retention/Rotation; DB-Event-Hooks.

## Empfehlung
Log-Streams als AionDB-gestützte, labelbehaftete append-only Entitäten; **Live-Tail über den
vorhandenen Push**; einfache Suche zuerst (Scan/Substring), invertierter Index später; visualisiert
nativ (10).  Externe Shipper (Vector) nur als optionalen Ingest akzeptieren.
