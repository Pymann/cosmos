# Cosmos Rendering and Sync Direction

## Entscheidung

`Cosmos` verfolgt ab jetzt eine klare Produkt- und Technikrichtung:

- reine AIML-Anwendung
- grafische Hauptoberflaeche ueber OpenGL ES / WebGL
- kein HTML-/CSS-/Formular-Stack als primaere UI
- Live-Synchronisation ueber Mirror

## Motivation

Der entscheidende Treiber ist die dynamische Visualisierung:

- Pipeline-Laeufe
- Stage-Uebergaenge
- Build-Agent-Fluesse
- Queue-Bewegungen
- Node-/Cluster-Topologien
- Scheduler-Entscheidungen in Echtzeit

Diese Probleme sind eher Szenen- und Renderprobleme als DOM- oder
Formularprobleme.

## Konsequenzen

### 1. UI-Modell

Die Hauptoberflaeche von `Cosmos` wird als Render-Szene gedacht:

- Kamera / Zoom / Pan
- Render-Layer
- Pipeline-Knoten und Kanten
- Node-/Agent-Visualisierung
- Farb- und Zustandsanimation
- Selektion, Fokus, Hover, Overlay

### 2. Browser-Rolle

Der Browser bleibt nur:

- Host fuer Canvas/WebGL
- Loader fuer WASM-/Asset-Artefakte
- Transport-Endpunkt fuer WebSocket / Mirror

Nicht Zielbild:

- komplexe HTML-Form-Generierung
- CSS-getriebene Primar-UI
- AJAX-zentrierte Oberflaechenlogik

### 3. Networking

Der Live-Zustand soll ueber Mirror laufen:

- PipelineRun-Zustand
- Node-Zustand
- Queue-Zustand
- Agent-Lifecycle
- spaeter moeglicherweise verteilte Code-/Task-Bundles

### 4. Architekturfolge fuer Cosmos

Sinnvolle Schichten:

- `shared/models` fuer synchronisierte Daten
- `shared/classes` fuer Verhalten
- `shared/interfaces` fuer polymorphe Rollen
- `client` fuer Render- und Interaktionslogik
- `server` fuer Scheduling, Queueing, Agent-Koordination

## Kurzregel

Wenn eine neue Anforderung auftaucht, gilt:

- ist es primaer visuell, dynamisch oder topologisch -> GL-Szene
- ist es primaer synchronisierter Systemzustand -> Mirror + AIML-Modelle
- HTML nur als minimale Huelle, nicht als Produktkern

## Naechste technische Schritte

1. `Cosmos`-Client als AIML-/WASM-/GL-Frontend anlegen.
2. Pipeline-Graph als erste Scene-Struktur modellieren.
3. Mirror-View fuer PipelineRun/Node/Workload definieren.
4. Erste animierte Laufvisualisierung fuer einen Demo-Pipeline-Run bauen.
