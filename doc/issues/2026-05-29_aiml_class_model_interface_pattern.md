# AIML class-model-interface pattern for Cosmos

## Problem

`Cosmos` soll spaeter deutlich mehr Verhalten bekommen als heute:

- Scheduler-Verhalten
- Build-Agent-Verhalten
- Queue-/Pipeline-Logik
- Deploy-/Rollout-Strategien

Aktuell benutzen wir fast nur `model`. Das ist fuer persistente Daten gut, aber
noch nicht als bewusstes Architekturpattern fuer Verhalten dokumentiert.

## Beobachtung

Die AIML-Spec ist hier inzwischen ziemlich stark:

- `model` ist fuer strukturierte Daten, Validierung und Serialisierung gedacht.
- `class` ist fuer Verhalten, Methoden, Kapselung und Heap-/Stack-Objekte gedacht.
- `interface` liefert Polymorphie ueber Methodenvertraege.
- `models:` in einer `class` erlaubt strukturelle Komposition:
  Model-Felder werden in die Klasse injiziert, ohne dass Verhalten gemischt wird.

Damit ergibt sich fuer `Cosmos` ein natuerliches Muster:

- `Node`, `Workload`, `PipelineRun` bleiben `model`
- `NodeBehavior`, `SchedulerBehavior`, `BuildAgentBehavior` werden `class`
- `Schedulable`, `Runnable`, `Deployable` werden `interface`

## Risiko

Ohne dieses Pattern droht:

- Logik landet ungeordnet in top-level `def`s
- Daten- und Verhaltensverantwortung vermischen sich
- Polymorphie fuer verschiedene Agent- oder Workload-Typen wird spaeter haerter
- Bundle-/Exec-basierte Fernsteuerung bekommt keine klaren Behaviour-Traeger

## Ziel

Eine feste Regel fuer `Cosmos` dokumentieren:

- persistenter Zustand = `model`
- Verhalten = `class`
- austauschbare Faehigkeiten = `interface`
- Datenuebernahme in Verhaltenstraeger = `models:`

## Vorschlag

1. Unter `sources/shared/models` die reinen Datentraeger sammeln.
2. Unter `sources/shared/classes` Behaviour-Klassen einfuehren.
3. Unter `sources/shared/interfaces` die Faehigkeitsvertraege ablegen.
4. Ein kleines vertikales Beispiel bauen:
   `Node` + `NodeBehavior` + `RunnableAgent`.

## Akzeptanzkriterien

- Es gibt mindestens ein dokumentiertes Beispiel fuer `model + class + interface`.
- `Cosmos` nutzt `models:` bewusst fuer Verhalten ueber persistenten Daten.
- Neue Verhaltenslogik wird nicht mehr primaer als lose globale Funktion modelliert.
