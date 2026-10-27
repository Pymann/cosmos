# 99 — Die lebende Sicht: Agenten, Läufe, Speicher, Verbindungen

Status: Entwurf.  `97` sagt, wie eine **Pipeline** aussieht; dieses Kapitel sagt, wie der
**laufende Betrieb** aussieht — Agenten, geöffnete KV-Speicher, Verbindungen, Läufe.  Es ist
bewusst ein eigenes Kapitel, weil die Pipeline eine *Struktur* ist und der Betrieb ein *Zustand*:
das eine ändert sich beim Schreiben, das andere jede Sekunde.

## 99.1 Ein Mechanismus, nicht sechs Widgets

- **F99-1** Jede lebende Sicht ist eine **Tabelle mit Farb-Läufen** in einer Textbox mit
  Festbreitenschrift — derselbe Mechanismus wie das Lane-Gitter (`97` §97.7) und die
  Syntax-Hervorhebung.  Begründung: cosmos hat **keine** Prefab-Container (gemessen: Listen werden
  überall als Text gezeichnet, `agents_box`), und eine Tabelle wächst mit der Zeilenzahl, während
  eine feste Zahl vorgezeichneter Kästchen eine Obergrenze einbaut, die niemand sieht, bis sie
  erreicht ist.
- **F99-2** Die **Farbe trägt den Zustand, der Text nennt ihn** (wie `97` F97-17).  Eine Sicht,
  die nur über Farbe spricht, ist für ein Protokoll, eine Suche und für Farbenblinde wertlos.
- **F99-3** Jede Sicht zeigt ihr **Alter**: „Stand vor 3 s".  Ohne diese Angabe sieht eine
  eingefrorene Sicht aus wie eine gesunde — und genau das ist der Fehler, der im Betrieb am
  teuersten ist.  Ein Zähler ohne Alter ist eine Behauptung ohne Datum.

## 99.2 Was gezeigt wird

### Agenten
| Spalte | Inhalt | Warum |
|---|---|---|
| `agent` | Kennung/Label | das, was man in `runs_on` schreibt |
| `zustand` | `verbunden` / `still` / `weg` | Farbe: grün / gelb / rot |
| `letzter Takt` | Sekunden seit Heartbeat | ein Agent „weg" ohne Zeitangabe ist nicht nachvollziehbar |
| `Schritt` | was er gerade tut, sonst `—` | verbindet Agent und Lauf |

- **F99-4** Ein Agent ohne Takt ist **nicht** sofort „weg": er ist **still**, bis die Frist
  abläuft.  Zwei Zustände statt einem, weil ein Netz-Schluckauf und ein abgestürzter Knoten
  verschieden behandelt werden müssen — und weil „weg" eine Entscheidung ist, die Schritte
  umverteilt.

### Geöffnete Speicher (KV / CAS)
| Spalte | Inhalt |
|---|---|
| `speicher` | Name (`cas_actions`, `auth_users`, …) |
| `pfad` | Verzeichnis |
| `wal` | Größe der WAL in MB |
| `letzter Schreibvorgang` | Sekunden her |

- **F99-5** Die **WAL-Größe gehört in die Sicht**.  Gemessen in 9rooms: eine WAL, die fest bei
  16 MB steht, sieht gesund aus und ist es nicht, wenn nie ein Checkpoint läuft — das war dort die
  Ursache einer Fehlsuche über Tage.  Eine Zahl, deren Normalwert man nicht kennt, kostet mehr
  Zeit als sie spart; darum steht neben der Größe, wann zuletzt geschrieben wurde.
- **F99-6** Die Sicht zeigt **geöffnete** Speicher, nicht alle vorhandenen.  Ein Speicher, den
  niemand geöffnet hat, ist kein Betriebszustand, sondern eine Datei.
- **F99-7** Kein Inhalt, nur Kennzahlen.  Eine Oberfläche, die KV-Werte zeigt, zeigt früher oder
  später ein Geheimnis — und die Begründung „nur für Diagnose" hält genau bis zum ersten
  Bildschirmfoto in einem Ticket.

### Verbindungen
`peer_id`, Benutzer (oder `—` bei unauthentifiziert), seit wann, letzte Nachricht.
- **F99-8** Unauthentifizierte Verbindungen werden **gezählt, nicht einzeln aufgeführt**: sie sind
  die Angriffsfläche, nicht der Betrieb.  Eine Liste davon lädt dazu ein, sie einzeln zu
  beurteilen, statt die Zahl zu beobachten.

## 99.3 Woher die Daten kommen

- **F99-9** Alles aus **einem** Schnappschuss je Takt (`get_cluster` / `subscribe_cluster`), nicht
  aus je einem RPC pro Sicht.  Sonst zeigt die Oberfläche vier Stände aus vier Augenblicken und
  niemand kann sagen, welcher gilt.
- **F99-10** Der Schnappschuss trägt **seinen Zeitpunkt** (Server-Uhr).  Das Alter aus F99-3
  rechnet die Oberfläche daraus — nicht aus der eigenen Uhr, weil die Uhren auseinanderlaufen.
- **F99-11** Die Sicht ist **lesend**.  Eingriffe (Agent trennen, Lauf abbrechen) sind eigene,
  authentifizierte RPCs mit eigener Bestätigung (`96` F96-11) — ein Doppelklick in einer Tabelle
  darf nie etwas abschalten.

## 99.4 Was nicht gezeigt wird

- **F99-12** Keine Fortschrittsbalken ohne Grundlage.  Ein Schritt weiß nicht, wie weit er ist;
  ein Balken, der aus der Laufzeit geraten wird, ist eine Lüge mit Oberfläche.  Gezeigt wird die
  **Dauer** und, wo vorhanden, die Dauer des letzten erfolgreichen Laufs desselben Schlüssels.
- **F99-13** Keine Durchschnitte über ungleiche Dinge (z.B. „mittlere Schrittdauer" über alle
  Lanes).  Eine Matrix hat absichtlich verschiedene Lanes; ein Mittelwert darüber verwischt genau
  das Muster, wegen dem man die Matrix gebaut hat.
