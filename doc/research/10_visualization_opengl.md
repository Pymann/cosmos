# 10 — Visualisierung: Blue-Ocean-DAG + OpenGL im Infra-Kontext

**Ziel (spec 15):** Build-Verfolgung wie Jenkins **Blue Ocean** (Pipeline-Stage-Graph, Live-Status/
Fortschritt, Drill-down) **und** Lauf/Job live als **OpenGL/WebGL-Szene** im Infrastruktur-Kontext
(welcher Node/Agent fährt welche Stage; Fortschritt wandert durch den Cluster).  Cluster-Ansicht =
lebende Szene statt Textliste.

## Hier ist aiml ungewöhnlich stark
Die Inventur (01) bestätigt: `gl` (Shader/Texturen/FBOs/instanced draw/Timer-Queries), `ui`
(Widgets/Charts), `engine` (GLFW-Fenster, Frame-Loop, Layout, Hit-Test), `prefabs`, `gltf`,
**nativ + wasm32**, plus `mirror`-Push für Live-Zustand.  Das heißt: **die „Dashboards" sind native
OpenGL-Szenen** (bzw. im Browser via wasm), kein separates Grafana/Three.js-Stack nötig.  Der
cosmos-Client macht das bereits im Kleinen (Login→Menu→Cluster, Live-Push §7.4).

## Was zu bauen ist
1. **Graph-Layout.**  Blue-Ocean = **Sugiyama/Layered-Layout** (Ebenen nach topologischer Ordnung,
   Kreuzungsminimierung) für den **StepSnapshot-DAG** (02).  Für den Infra-Kontext ein **Force-/
   Hierarchie-Layout** (Nodes/Agents als Cluster, Jobs als wandernde Marker).  Layout-Algorithmen
   (dagre/ELK/Sugiyama) als **Konzept** übernehmen, in aiml implementieren.
2. **Mapping Modell→Szene.**  Entitäten (01) → Prefabs: Node=Knoten mit Kapazitätsring, Agent=
   Marker (verbunden/last-seen), Stage/Step=DAG-Knoten mit Status-Farbe + Fortschritt, Kante=
   Abhängigkeit; Cache-Treffer visuell markiert (02).
3. **Live.**  Zustands-/Fortschritts-Updates über den vorhandenen **auth. Server-Push** → Szene
   re-rendert bei Sequenzwechsel (wie die heutige Cluster-Ansicht, nur grafisch).
4. **Drill-down.**  Hit-Test (vorhanden) → Stage-Log/Metriken-Panel (08/09).

## Reuse vs. Build
- **Reuse (Konzepte):** Sugiyama-Layered-Layout, Blue-Ocean-UX (Stage-Spalten, parallele Zweige),
  dagre/ELK-Ideen.  Keine externe Rendering-Lib nötig — `gl/engine` ersetzt sie.
- **Neu in cosmos:** Layout-Code (aiml), Modell→Prefab-Mapping, Live-Anbindung, Interaktion.

## aiml-Lücken
- Kein fertiger Graph-Layout-Algorithmus (muss in aiml geschrieben werden — reine Rechenlogik,
  gut machbar).  Textbox/Charts vorhanden; für große DAGs ggf. instanced draw (vorhanden) nutzen.
- Browser: wasm-Host-Import-Fläche begrenzt — aber die Cluster-Ansicht läuft bereits via wasm, also
  tragfähig.

## Empfehlung
Das ist cosmos' **sichtbarster Alleinstellungspunkt bei geringstem Fremd-Risiko** (Engine ist da).
Reihenfolge: (1) Stage-DAG-Layout + Live-Status als erste Ausbaustufe der heutigen Cluster-Ansicht,
(2) Infra-Szene (Nodes/Agents + wandernde Jobs), (3) Drill-down in Logs/Metriken (08/09).  Nichts
Fremdes einbinden; nur Layout + Mapping bauen.

## Quellen
- Sugiyama/Layered graph drawing, dagre/ELK (Allgemeinwissen).  aiml `gl/ui/engine/prefabs` (Inventur 01).  Jenkins Blue Ocean (UX-Vorbild).
