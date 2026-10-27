# 08 — Observability: Metriken, Dashboards ohne Grafana-JSON

**Ziel (spec 10, Leitprinzip 6):** eingebaute Überwachung + **automatische** Default-Dashboards aus
dem Domänenmodell — kein jahrelanges Grafana-JSON; live, ereignisgetrieben.

## Landschaft

| Baustein | Vertreter | Rolle | für cosmos |
|---|---|---|---|
| **Metrik-Datenmodell** | **Prometheus** (Pull, Exposition-Format), **OpenTelemetry** (Metrics/Traces/Logs, OTLP) | standardisierte Erfassung | **Semantik übernehmen** (Counter/Gauge/Histogram; OTLP als Ingest) |
| **TSDB** | Prometheus TSDB, VictoriaMetrics, Mimir | Zeitreihen speichern | aiml **AionDB TimeSeries** prüfen (01) als eingebaute TSDB |
| **Dashboards** | **Grafana** (JSON-Hölle), **Perses** (CNCF-Sandbox, dashboards-as-code: Go/CUE-SDK, `percli`, GitOps) | Visualisierung | **Perses als Referenz/Export-Ziel**; aber: auch Perses ist *as-code*, nicht *auto* |
| **Traces/Logs** | Tempo, Loki, Pyroscope (Profiling) | Korrelation | später (09) |

**Belegt:** Perses ist die moderne, GitOps-orientierte Grafana-Alternative (Prometheus/Tempo/Loki/
Pyroscope; v0.52, Sep 2025).  **Aber** auch Perses ist *dashboards-as-code* — es nimmt dir das
**Schreiben** nicht ganz ab.  Keine der gefundenen Quellen liefert „Dashboards **automatisch** aus
Metriken/Modell".  **Genau da liegt cosmos' Differenzierer.**

## Der cosmos-Differenzierer: Auto-Dashboards aus dem Domänenmodell
Weil cosmos ein **getyptes Domänenmodell** hat (Node/Workload/PipelineRun/Job/Agent + StepSnapshot-
DAG), kann es **Default-Visualisierungen ableiten**, ohne dass jemand Dashboards schreibt:
- Jede Entität hat bekannte Felder (Zustände, Zähler, Zeitstempel, Kapazität) → pro Entitätstyp ein
  **generiertes Default-Dashboard** (Status-Verteilung, Zeitreihe von `used_cpu`/Job-Dauer/Erfolgsrate,
  Live-Liste).  Overrides optional, nie Pflicht (spec 10).
- Das ist dieselbe Idee wie „dataviz aus Schema", nur fürs Control-Plane-Modell — und sie fällt mit
  der **OpenGL-Visualisierung** (10) zusammen: die Live-Szene **ist** das Default-Dashboard.

## Reuse vs. Build
- **Reuse (Modelle/Formate):** Prometheus-Exposition + **OTLP** als **Ingest-Formate** (damit externe
  Exporter/Agenten Metriken liefern können); Perses-Dashboard-JSON als **optionales Export-Ziel**
  (Interop mit vorhandenen Grafana/Perses-Setups).
- **Neu in cosmos bauen:**
  1. **Metrik-Entitäten** (Counter/Gauge/Histogram) + Erfassung aus dem Domänenmodell (Job-Dauer,
     Queue-Länge, Node-Last, Cache-Hit-Rate …).
  2. **Eingebaute TSDB** auf **AionDB TimeSeries** (01 prüfen) — kein externes Prometheus nötig.
  3. **Auto-Dashboard-Generator**: Modell/Schema → Default-Panels (Regelwerk: enum→Verteilung,
     i64-Zeitstempel→Zeitreihe, Liste→Live-Tabelle).  **Das ist der Kern-Neubau und der USP.**
  4. **Live-Push** der Metriken an Abonnenten (vorhandener auth. Server-Push, architecture §7.4).

## aiml-Eignung
- **Sehr gut:** aiml hat KV/**TimeSeries** (AionDB), `log`, ws/mirror-Push und **engine/gl/ui/prefabs**
  zum Rendern — also Erfassung **und** Visualisierung eingebaut.  Das ist ungewöhnlich günstig: die
  „Dashboards" sind native OpenGL-Szenen (10), nicht ein separates Grafana.
- **Lücke:** kein Prometheus/OTLP-Ingest (müsste als http/Decoder gebaut werden); kein Histogramm-/
  Quantil-Primitiv; Auto-Dashboard-Logik ist komplett neu.

## Empfehlung
**OTLP/Prometheus als Ingest akzeptieren** (Interop), **AionDB-TimeSeries als eingebaute TSDB**,
und den **Auto-Dashboard-Generator aus dem Domänenmodell** als Alleinstellungsmerkmal selbst bauen —
gerendert über die vorhandene Engine (10).  **Perses-Export** optional für Nutzer mit Bestands-Setup.
Kein Grafana-JSON als Pflichtweg.

## Quellen
- Perses: prometheus.io/docs/visualization/perses, dash0 „what is Perses", pkg.go.dev/perses v0.52 (Sep 2025), DevConf.US 2025 (GitOps-Alternative zu Grafana).
- Prometheus/OpenTelemetry/OTLP, VictoriaMetrics/Mimir/Tempo/Loki/Pyroscope (Allgemeinwissen, Cutoff 2026).
