# 102 — Maßstab und Ausfallsicherheit: was heute trägt und was nicht

Status: Entwurf.  Anlass: „hochgradig skalierende Systeme".  Dieses Kapitel sagt **ehrlich**, wo
cosmos heute steht, welche Größe zuerst weh tut, und welche Entscheidungen man **jetzt** treffen
muss, weil sie später teuer werden.

## 102.1 Der heutige Stand, in einem Satz

**Ein** Controller-Prozess hält den Zustand im Speicher und schreibt ihn in lokale KV-Dateien;
Agenten hängen über Mirror-WebSockets daran.  Das ist eine saubere Grundlage und eine klare
Grenze: der Controller ist **ein** Fehlerpunkt und **eine** Maschine.

- **F102-1** Dieser Entwurf baut **keine** Hochverfügbarkeit ein, bevor sie gebraucht wird.  Eine
  verteilte Zustandshaltung, die niemand benutzt, kostet trotzdem jeden Tag Fehlersuche.  Was er
  tut: er verbaut sie nicht — jede Entscheidung unten ist daraufhin geprüft.

## 102.2 Welche Größe zuerst weh tut

| # | Größe | Erste Grenze | Warum genau dort |
|---|---|---|---|
| 1 | **Lanes je Lauf** | Ausfaltung und Anzeige | Das Kreuzprodukt wächst multiplikativ: 4 Achsen à 4 Werte sind 256 Lanes, 5 à 4 sind 1024 |
| 2 | **Gleichzeitige Schritte** | Zuteilung, ein Lehen je Schritt | Zuteilung ist eine Schleife über offene Schritte; bei 10 000 offenen ist sie heiß |
| 3 | **Agenten** | Takt-Verkehr, Schnappschuss | Jeder Agent meldet sich; der Schnappschuss wird mit jedem größer |
| 4 | **Cache-Einträge** | KV-Größe, WAL | Schlüsselsuche bleibt O(1); die **Datei** wächst, und niemand räumt auf |
| 5 | **Läufe über Zeit** | Anzeige, Speicherplatz | Historie wächst monoton, Ausgabebäume auch |

- **F102-2** Die Reihenfolge ist **gemessen zu prüfen**, nicht zu glauben.  Jede Zeile oben ist
  eine Behauptung über das erste Umfallen; die erste Last-Messung ersetzt sie durch Zahlen.

## 102.3 Entscheidungen, die man jetzt treffen muss

- **F102-3** **Der Lauf-Datensatz ist die Einheit der Verteilung.**  Ein Lauf hängt an einem
  Controller; Lanes dürfen auf viele Knoten.  Damit ist später ein zweiter Controller möglich,
  ohne den Zustand eines Laufs zu teilen — und das ist der Unterschied zwischen „noch einen
  Prozess starten" und „verteilte Zustandshaltung bauen".
- **F102-4** **Inhaltsadressierung ist die Währung** (`92`).  Ein Ausgabebaum gehört keinem
  Knoten; er hat eine Adresse.  Deshalb darf eine Lane auf einem anderen Knoten weiterlaufen
  (`96` F96-14) und deshalb kann ein zweiter Controller denselben Cache lesen, ohne ihn zu
  besitzen.
- **F102-5** **Kein gemeinsamer veränderlicher Zustand zwischen Controllern.**  Wenn es je zwei
  gibt, teilen sie den **CAS** (unveränderlich) und sonst nichts.  Zwei Controller, die dieselbe
  KV schreiben, brauchen ein Konsensverfahren — und das ist ein eigenes Produkt, kein Zusatz.
- **F102-6** **Historie ist Abfall mit Aufbewahrungsfrist.**  Läufe, Ausgabebäume und
  Cache-Einträge brauchen eine Regel, wann sie verschwinden — sonst ist die erste echte Grenze
  die Plattengröße, und sie kommt ohne Vorwarnung.  Die Regel fehlt heute (Frage an den Autor).

## 102.4 Was explizit NICHT skaliert (und das ist in Ordnung)

- **Die Oberfläche** zeigt Fenster, keine Gesamtlisten (`99`, `100` F100-16).  Eine Sicht, deren
  Antwort mit dem System wächst, macht ein großes System unbedienbar.
- **Ein Lauf** ist nicht beliebig breit: ab drei Achsen bildet die Anzeige auf Kacheln ab
  (`97` F97-12), und irgendwann ist eine Matrix mit 4 096 Lanes keine Anzeige mehr, sondern ein
  Bericht.  Das ist eine Eigenschaft der Aufgabe, nicht ein Mangel der Software.
- **Der Controller** macht keine Schwerarbeit: er prüft, faltet aus, teilt zu und zeichnet auf.
  Alles, was rechnet, läuft auf Agenten.  Diese Trennung ist die eigentliche Skalierungsaussage —
  ein Controller, der selbst baut, skaliert nie (und ist zudem die RCE-Fläche, `96` F96-28).

## 102.4a Schemawechsel: erkennen, benennen, bereinigen

Ein persistiertes Modell zu **erweitern** macht alles Gespeicherte unlesbar.  AionDB prüft
einen Schema-Fingerabdruck; passt er nicht, wirft `ser_decode`:

```
[ser-FATAL] SerializationFormatException: incompatible KV blob
  (schema fp stored=0xe311ad48 expected=0x0972868d, n_nodes=35)
```

Gemessen am 15.10.2026: ein neues Feld in `PipelineStage` (`attempt`, F101-7) machte **jeden
gespeicherten Lauf** unlesbar.  Der Server lief weiter und bekam bei jedem Lesen ein leeres
Modell — also einen Lauf ohne Kennung und ohne Stufen, mit einer FATAL-Zeile je Zugriff.

**F102-8: Ein unlesbarer Datensatz ist ein BEFUND, kein Rauschen.**  Der Server zählt sie
**beim Start** und sagt in einer Zeile, wie viele es sind und was zu tun ist.  Er löscht
nichts von sich aus: was nicht gelesen werden kann, kann auch nicht beurteilt werden, und
stilles Löschen beim Start wäre Datenverlust ohne Entscheidung.

Die Bereinigung ist ein **eigener Aufruf** (`purge_demo`, `COSMOS_DROP_UNREADABLE=1`) bei
stehendem Server — ein zweiter Schreiber auf demselben WAL ist keine gute Idee.

**Der Fingerabdruck erkennt keine UMBENENNUNG.**  Er bildet Typen und Reihenfolge ab, nicht
Namen: `timeout_s` → `timeout_ms` (beides `i32`, gleiche Stelle) ging am 15.10.2026 ohne
Befund durch.  Das ist bequem, solange nur der Name wechselt — und eine Falle, wenn mit dem
Namen die **Bedeutung** wechselt, hier Sekunden → Millisekunden.  Gespeicherte Werte werden
dann stillschweigend umgedeutet.  In diesem Fall stand überall `0`, also hat es nichts
gekostet; die Regel daraus: **eine Bedeutungsänderung braucht einen neuen Feldnamen UND
einen Typwechsel oder eine ausdrückliche Migration** — sonst merkt es niemand.

Was hier ausdrücklich **noch nicht** gelöst ist: eine echte Migration.  Ein Schema mit
Version und Aufwärts-Wandlung (altes Feld lesen, neues Feld voreinstellen) wäre die
vollständige Antwort; sie gehört in die Scheibe, die auch Aufbewahrungsregeln bringt.  Bis
dahin gilt: **Laufgeschichte ist entbehrlich, Jobs und Konten sind es nicht.**  Darum trifft
der Fingerabdruck-Bruch bisher nur Läufe — `JobDef`, Konten und Token bleiben unberührt, und
genau deshalb ist „zählen und auf Zuruf wegräumen" vorerst tragbar.

## 102.5 Messpunkte, bevor irgendetwas optimiert wird

- **F102-7** Vor jeder Maßnahme steht eine Messung mit **Zahlen im Protokoll**: Zuteilungsdauer
  je Schritt, Schnappschussgröße, WAL-Wachstum je Stunde, Dauer von `plan` je Domäne.  Ohne diese
  vier Zahlen ist jede Optimierung geraten — und in diesem Projekt hat „gemessen statt vermutet"
  schon mehrfach das Gegenteil der Erwartung ergeben (zuletzt: gleichzeitiges Übersetzen bringt
  **nichts**, aiml F62-99).
