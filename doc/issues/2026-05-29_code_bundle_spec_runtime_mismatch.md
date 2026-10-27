# Code bundle spec/runtime mismatch

## Problem

Die AIML-Idee fuer transportierbare Codeobjekte ist fuer `Cosmos` zentral:
Agenten sollen AIML-Code empfangen, laden und ausfuehren koennen.

Zwischen Spec und aktuellem Runtime-Stand gibt es aber noch Unsauberkeiten.

## Beobachtung

Die aeltere Serialisierungs-Spec beschreibt `Code` noch vereinfacht als:

- `id`
- `start_call`
- `chunks`

Die aktuelle Runtime ist bereits weiter und nutzt effektiv:

- `id`
- `start_call`
- `code_chunks`
- `data_chunks`
- `new_context`

Das ist fuer `Cosmos` sogar die richtigere Richtung, weil wir statische
Definitionen und konkreten Laufzeit-Zustand trennen muessen.

## Warum das fuer Cosmos wichtig ist

Ein Agent-Task braucht typischerweise:

- Typdefinitionen und Funktionen
- konkrete Instanzdaten
- einen definierten Einstiegspunkt

Beispiel:

- `code_chunks`: `model`, `class`, `def`, `enum`
- `data_chunks`: rekonstruiert `NodeTask`, `PipelinePayload`, `ArtifactRef`
- `start_call`: ruft den passenden Einstieg mit vorbereiteten Daten auf

## Offene Punkte

- Welche `Code`-Definition ist fuer `Cosmos` verbindlich?
- Soll `start_call` String/YAML bleiben oder spaeter wieder strukturierter werden?
- Wie genau wird Instanzzustand in `data_chunks` abgelegt?
- Wie werden `enum`-Definitionen sicher mitgebuendelt?
- Welche Teile der Bundle-Struktur gelten schon als stabil?

## Vorschlag

1. Fuer `Cosmos` nur noch das neue 5-Feld-Modell annehmen:
   `id`, `start_call`, `code_chunks`, `data_chunks`, `new_context`.
2. Eine kleine `Cosmos`-interne Bundle-Spec unter `doc/spec` festschreiben.
3. Ein minimales Bundle-Beispiel dokumentieren:
   Worker-Def + Payload-Model + Payload-Daten + Start-Call.

## Akzeptanzkriterien

- Es gibt genau eine dokumentierte `Code`-Struktur fuer `Cosmos`.
- `code_chunks` und `data_chunks` sind semantisch getrennt beschrieben.
- Die Bundle-Form ist so dokumentiert, dass ein spaeterer Agent sie konsumieren kann.
