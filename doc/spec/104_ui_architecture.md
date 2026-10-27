# 104 — Aufbau der Oberfläche: eine Quelle, überall dieselbe Aussage

Diese Spec ist die Antwort auf einen berechtigten Vorwurf (User, 2026-10-13): *„dass der
Agent online ist, sieht man nicht überall, wo von Agents die Rede ist."*  Das war kein
Schönheitsfehler an einem Bildschirm, sondern die Folge eines Modellbruchs.

## 104.0 Der Befund

| Stelle | Modell | Kanal |
|---|---|---|
| `ClusterView.nodes` | `Node` — `node_id, name, role, status, labels, agent_tags, cpu/mem, endpoint` | `subscribe_cluster` |
| Agenten-Bildschirm | `AgentInfo` — `agent_id, status, host, os_name, labels, last_seen_ms, current_run` | `subscribe_agents` |

**Zwei Modelle für dieselbe Sache, über zwei getrennte Kanäle.**  Ein Bildschirm, der
Knoten zeigt, *kann* die Anwesenheit nicht zeigen — sie steht im anderen Datensatz, der
über die andere Verbindung kommt.  Gemessen: von elf Client-Dateien kennt genau **eine**
(`agents_screen.aiml`) den Agenten-Zustand.

Das erklärt auch, warum es nicht durch Nachbessern zu heilen war: man hätte in jedem
Bildschirm ein zweites Abonnement geöffnet und zwei Schnappschüsse aus zwei Augenblicken
nebeneinandergelegt — genau das, was F99-9 verbietet.

## 104.1 Eine Quelle

**F104-1: Es gibt EINEN Schnappschuss.**  `ClusterView` trägt Knoten, Arbeitslasten,
Läufe, Jobs **und die Agenten**.  `subscribe_agents` entfällt als eigener Kanal; der
Agenten-Bildschirm rendert aus demselben `g_live_cluster` wie alle anderen.

**F104-2: Ein Agent ist ein Knoten mit Anwesenheit.**  `Node` bekommt die Felder, die
heute nur `AgentInfo` hat (`agent_id`, `last_seen_ms`, `current_run`, `exec_busy`), statt
dass zwei Datensätze nebeneinander gepflegt werden.  Ein Knoten ohne Agent hat
`agent_id = ""` — das ist eine Aussage, kein Fehlen.

**F104-3: Anwesenheit ist abgeleitet, nicht gespeichert.**  `online` ist
`taken_ms - last_seen_ms < presence_timeout_ms` (Vorgabe 15000), gerechnet gegen die
**Server-Uhr** aus dem Schnappschuss (F99-10).  Niemand schreibt „online" in ein Feld,
das dann stehen bleibt, wenn der Agent still verschwindet.

## 104.2 Der Anwesenheits-Vertrag

**F104-4: Wo ein Agent genannt wird, steht seine Anwesenheit.**  Ohne Ausnahme — Liste,
Lauf-Gitter, Schritt-Detail, Shell-Ziel, Pipeline-Ansicht.  Ein Agentenname ohne Zustand
ist eine Behauptung über die Gegenwart, die der Bildschirm nicht belegen kann.

**F104-5: Die Anwesenheit trägt Zeichen UND Farbe.**  `●` anwesend, `○` abwesend, dazu
das Wort (`verbunden` / `weg seit 3 min`).  Farbe allein scheidet aus — dieselbe Regel wie
für Status im Gitter (F97-17), aus demselben Grund.

**F104-6: Jede Ansicht nennt das Alter ihres Schnappschusses.**  „Stand: vor 2 s" ist eine
Aussage; eine Liste ohne Zeitangabe behauptet Gegenwart.  Ist der Schnappschuss älter als
`stale_after_ms` (Vorgabe 10000), wird die **ganze** Ansicht als veraltet gekennzeichnet,
nicht nur der Zeitstempel: ein veralteter Wert sieht sonst aus wie ein aktueller.

**F104-7: Keine Ansicht blendet einen Agenten aus, weil er weg ist.**  Ein verschwundener
Agent mit laufendem Schritt ist genau der Fall, den man sehen muss.  Verbergen ist
Bequemlichkeit, nicht Übersicht.

## 104.3 Ein Ort für die Darstellung

`sources/shared/presence.aiml` — eine Klasse `Presence` mit zwei Methoden:

| Methode | liefert |
|---|---|
| `mark(node, now_ms)` | `"● "` / `"○ "` |
| `phrase(node, now_ms)` | `"verbunden"` / `"weg seit 3 min"` / `"nie gesehen"` |

Sie liegt in `sources/shared/`, weil **Server und Client dieselbe Aussage treffen müssen**:
Steht im Lauf „Agent weg", muss der Server denselben Schluss ziehen, sonst teilt er einem
Toten Schritte zu.  Zwei Implementierungen derselben Regel laufen auseinander — diese
nicht, weil es nur eine gibt.

**F104-8: Die Regel ist geteilter Code, keine Konvention.**

## 104.4 Die Bildschirme und ihre Zuständigkeit

| Bildschirm | Beantwortet | Zeigt Anwesenheit |
|---|---|---|
| **Cluster** | Was gibt es, und lebt es? | je Knoten (F104-4) |
| **Agenten** | Einrichten, Token, Rückbau | je Agent, plus Alter |
| **Läufe** | Was läuft gerade, und wo? | je Gitter-Zelle: der Agent des Schritts |
| **Pipeline** | Was wurde erklärt | am Ziel-Etikett: gibt es dafür einen Agenten? |
| **Shell** | Ein Kommando auf einem Knoten | am Ziel, VOR dem Absenden |

**F104-9: Die Läufe-Ansicht nennt zu jedem laufenden Schritt den Agenten.**  Ohne das ist
eine Störung keinem Knoten zuzuordnen (F101-13) — und genau das ist die Frage, die man vor
einem Gitter stellt.

**F104-10: Die Pipeline-Ansicht sagt vor dem Start, ob ein Schritt überhaupt laufen kann.**
Verlangt eine Stufe `required_label: arm64` und trägt kein anwesender Agent dieses
Etikett, steht das **an der Stufe**, nicht in einem Fehler nach dem Start.  Das ist die
Oberflächen-Seite von F103-1.

## 104.5 Was das Startsignal zeigt

Ein Lauf durchläuft `pending → running → done|failed|skipped`.  Die Oberfläche zeigt je
Schritt **vier** Dinge, und keines ist entbehrlich: den Status, den **Agenten**, die
**Dauer** (laufend: seit wann) und ob er **aus dem Cache** kam (F103-9).

**F104-11: „Aus dem Cache" ist ein sichtbarer Zustand, kein stilles `done`.**  Sonst
erklärt sich eine Pipeline, die in zwei Sekunden durchläuft, nicht — und niemand merkt,
wenn der Cache fälschlich trifft.

## 104.6 Reihenfolge der Umsetzung

1. **Roster zusammenlegen** (F104-1/2): `Node` um die Agenten-Felder erweitern, Server
   füllt sie, `subscribe_agents` entfällt.
2. **`Presence`** anlegen (F104-8) und im Agenten-Bildschirm benutzen — gleicher Anblick
   wie heute, aber aus der neuen Quelle.
3. **Ausbreiten** (F104-4) auf Cluster, Läufe, Pipeline, Shell.
4. **Alter und Veraltung** (F104-6) in die gemeinsame Kopfzeile.
5. **Schritt-Agent und Cache-Zustand** (F104-9/11), sobald doc/spec/103 Schritte zuteilt.
