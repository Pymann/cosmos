# sys.exec remote agent execution gaps

## Problem

`Cosmos` braucht mittelfristig so etwas wie verteilte Build- und
Steuerungsagenten. Dafuer reicht es nicht, `Code` nur zu speichern; wir muessen
Bundles auch verlässlich ausfuehren koennen.

`sys.exec` ist dafuer die naheliegende AIML-Funktion, aber der aktuelle Stand
hat noch funktionale Luecken.

## Aktueller Stand

Positiv:

- isolierte Ausfuehrung ueber `new_context` ist angelegt
- shared-context Hot-Reload-Richtung ist angelegt
- `start_call` wird bereits ausgewertet

Fehlend oder eingeschraenkt:

- `data_chunks` werden aktuell noch nicht wirklich ausgefuehrt
- `start_call` ist praktisch noch auf 0-Argument-Funktionen begrenzt
- neue Symbole zur Laufzeit sind nur teilweise unterstuetzt
- AOT-/shared-context Verhalten ist noch nicht vollstaendig
- echtes Remote-Agent-Szenario ist noch nicht als End-to-End-Test abgedeckt

## Risiko fuer Cosmos

Ohne diese Punkte koennen wir zwar Bundles definieren, aber nicht robust:

- Agent-Aufgaben mit Payload uebergeben
- Worker-Kontext rekonstruieren
- parameterisierte Einstiegspunkte starten
- Build-/Deploy-Jobs ueber Netzwerk streamen

## Zielbild

Ein `Cosmos`-Agent kann:

1. ein `Code`-Objekt empfangen
2. Typen und Funktionen daraus laden
3. Datenobjekte aus `data_chunks` rekonstruieren
4. `start_call` mit den benoetigten Daten ausfuehren
5. einen Exit-Code und spaeter Logs/Artefakte zurueckliefern

## Vorschlag

1. `sys.exec` fuer `data_chunks` vervollstaendigen.
2. Parameterisierte `start_call`-Ausfuehrung ermoeglichen.
3. Einen minimalen `CosmosAgentTask`-Roundtrip als Test entwerfen.
4. JIT- und AOT-Verhalten getrennt dokumentieren.

## Akzeptanzkriterien

- Ein Bundle mit Daten und Einstiegspunkt laeuft reproduzierbar.
- `data_chunks` initialisieren echte Laufzeitobjekte.
- Ein Agenten-Task mit Parametern ist ausfuehrbar.
- Die Unterschiede zwischen JIT, shared context und isolated context sind fuer `Cosmos` dokumentiert.
