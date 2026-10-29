# 101 — Wie ein Schritt zum Agenten kommt

Status: Entwurf.  `96` §96.11 legt fest, **wer** steuert (der Server gibt Schritte heraus, der
Agent fragt nach).  Dieses Kapitel sagt, **wie** — und vor allem, was passiert, wenn etwas
schiefgeht, denn daran entscheidet sich, ob ein verteiltes System benutzbar ist.

## 101.1 Ziehen, nicht schieben

- **F101-1** Der Agent **fragt nach Arbeit** (`claim_step`), der Server schiebt nicht.  Drei
  Gründe, und keiner davon ist Geschmack:
  - der Agent kennt seinen eigenen Zustand (Platte voll, Last, gerade neu gestartet), der Server
    nur dessen letzten Takt;
  - Anhalten ist dann **ein Nichts-Tun** (F96-12: das Tor sitzt bei der Zuteilung) statt einer
    Nachricht, die ankommen muss;
  - ein Agent hinter NAT braucht keine eingehende Verbindung.
- **F101-2** Ein `claim_step` nennt die **Fähigkeiten** des Agenten (Labels), nicht einen Wunsch.
  Welcher Schritt passt, entscheidet der Server — sonst suchen sich Agenten die billigen Schritte
  aus, und das Verhalten des Systems hängt davon ab, wer zuerst fragt.

## 101.2 Lehen statt Zuweisung

Ein zugeteilter Schritt ist ein **Lehen auf Zeit** (`lease`), kein Eigentumsübertrag.

- **F101-3** Ein Lehen hat eine **Frist** und wird durch Lebenszeichen verlängert.  Läuft sie ab,
  gibt der Server den Schritt wieder frei.  Ohne Frist bleibt ein Schritt für immer bei einem
  Agenten, der nie wiederkommt — und genau das passiert, wenn ein Knoten neu startet.
- **F101-4** Ein abgelaufenes Lehen heißt **nicht**, dass der Schritt nicht lief.  Der Agent kann
  gearbeitet und nur die Verbindung verloren haben.  Darum:
  - `pure`/`resolved`: ein zweiter Lauf ist harmlos — gleiches Ergebnis, gleicher Schlüssel.
  - `opaque`: ein zweiter Lauf kann etwas zweimal tun.  Das ist der **Preis von `opaque`** und
    steht hier, damit niemand es für einen Fehler hält.
- **F101-6** Ein freigegebener Schritt **nennt weiter seinen letzten Halter**.  `agent` wird beim
  Ablauf der Frist *nicht* geleert, nur `lease_until`.  Damit darf genau dieser Agent **nachmelden**:
  war die Störung kurz und hat ihn niemand neu genommen, ist seine Arbeit gültig und zählt.  Ohne
  diese Regel wurde das fertige Ergebnis verworfen und der Schritt lief ein zweites Mal — bei einem
  `echo` unsichtbar, bei einem Deploy ein zweites Deploy (gemessen 2026-10-15).  Nimmt ein anderer
  Agent den Schritt, überschreibt er `agent`, und der Nachzügler wird abgelehnt (F103-4) — der
  Eintrag ist also auch der Schiedsrichter zwischen beiden.
- **F101-7** Jede Zuteilung ist ein **Versuch mit Nummer** (`attempt`), und jede Rückmeldung
  trägt sie mit.  `claim` erhöht sie — auch wenn derselbe Agent denselben Schritt erneut
  nimmt.  `report`, `renew_lease` und `release_step` werden abgewiesen, wenn die Nummer nicht
  die aktuelle ist.

  F101-6 allein genügt dafür nicht: sie erkennt *wer* meldet, nicht *welchen Durchlauf*.  Hat
  derselbe Agent den Schritt nach einem Fristablauf ein zweites Mal bekommen, war sein
  verspäteter Bericht aus Durchlauf 1 von einem aus Durchlauf 2 nicht zu unterscheiden — und
  schloss die laufende Ausführung ab, während sie noch arbeitete.  Mit der Nummer ist genau
  ein Durchlauf gültig; die Halter-Regel bleibt als zweite Bedingung bestehen.

  **`attempt = 0` heißt „ohne Nummer"** und fällt auf F101-6 zurück.  Ein noch nicht
  erneuerter Agent kann so weiterarbeiten, statt ab dem Server-Update jede Meldung abgewiesen
  zu bekommen.  Das ist eine Übergangsregel, keine Dauerlösung: sie gehört entfernt, sobald
  alle Agenten die Nummer senden.

  Die Nummer ersetzt **keine** Idempotenz der äußeren Wirkung.  Sie entscheidet, welche
  *Meldung* gilt; ob ein zweimal ausgeführtes Deployment zweimal wirkt, entscheidet das
  Deployment (F101-4, F103-11).
- **F101-5** Die Zustellung ist **mindestens einmal**, nicht genau einmal.  „Genau einmal" über
  ein Netz zu behaupten, ist in jedem System eine Lüge; was man bauen kann, ist „mindestens
  einmal plus Idempotenz", und die Idempotenz liefert hier der Schlüssel (`92`).

## 101.3 Was über die Leitung geht

- **F101-6** Zum Agenten wandert ein **Bundle** (`sys.bundle`, aiml F62-50/F62-51), das er mit
  `sys.exec` ausführt — kein Quelltext für einen Kommandozeilen-Compiler, kein übersetztes Objekt.
  Nachgewiesen über eine echte Verbindung in `aiml tests/bundle_socket`.
- **F101-7** Mit dem Bundle wandern: die **Lane-Bindungen**, die **Wirtswerte** (`host:`), der
  **Arbeitsbereichs-Pfad** und die Ergebnisse der `needs` (aiml §13.5h).  Alles davon steht schon
  im Lauf-Datensatz (`96` F96-31/F96-34) — der Server schickt also nur weiter, was er ohnehin hat.
- **F101-8** **Keine Geheimnisse im Bundle.**  Wirtswerte, die Geheimnisse sind, kommen über einen
  eigenen, kurzlebigen Kanal (dieselbe Regel wie beim Enrollment-Token, `90` §AP1.9) — ein Bundle
  ist Quelltext, und Quelltext landet in Protokollen.

## 101.4 Reihenfolge und Riegel

- **F101-9** Ein Schritt wird erst zugeteilt, wenn **alle seine `needs` fertig** sind (aiml F62-9
  macht den Graphen azyklisch, F62-114 hängt die Schlüssel zusammen).  Der Server braucht dafür
  keine Sortierung: er teilt nur zu, was bereit ist.
- **F101-10** Ein `per: once`-Schritt ist ein **Riegel** (aiml F62-116): er wird genau einmal
  zugeteilt, und was ihn braucht, wartet.  Scheitert er mit `on_fail: lane`, werden seine
  Abhängigen **übersprungen** (F62-117) — übersprungen heißt: nie zugeteilt, kein Ausgang, keine
  Aufzeichnung.
- **F101-11** Zwei Agenten dürfen denselben Schritt **nicht gleichzeitig** haben.  Das Lehen ist
  exklusiv; die Freigabe nach Ablauf ist der einzige Weg, wie ein zweiter ihn bekommt.

## 101.5 Was der Server aufschreibt

- **F101-12** Ein fertiger Schritt wird über `StepRunner.record` aufgezeichnet (`92`): Schlüssel,
  Ausgabebaum, Exit-Code — und **nur bei Erfolg** (aiml F62-92).
- **F101-13** Der Lauf-Datensatz führt je Eintrag `status` **und** `agent` **und** `lease_until`.
  Ohne den Agenten kann niemand eine Störung einem Knoten zuordnen; ohne die Frist sieht ein
  hängender Schritt aus wie ein laufender.

## 101.5a Stand: die Logik steht, die Leitung fehlt

`sources/shared/step_scheduler.aiml` setzt §101.1–§101.4 um, nimmt den Lauf als `ref<PipelineRun>`
entgegen (er **ändert** ihn — ein Wert-Argument änderte eine Kopie) und ist **ohne Netz und ohne
Agenten** geprüft (`test/test_step_scheduler.aiml`, 18 Prüfungen): Lane-Reihenfolge, Lehen mit Frist,
Freigabe nach Ablauf, Verwerfen eines verspäteten Berichts, Zurückhalten der Nachfolger eines
gescheiterten Schritts.

Das ist dieselbe Trennung wie bei `StepRunner`: **entscheiden und festhalten** sind prüfbar, ohne
dass etwas läuft.  Was fehlt, ist die Leitung — `claim_step`/`report_step` als RPC und die
Ausführung des Bundles auf dem Agenten.

## 101.7 Anhalten, Weiterlaufen, Einzelschritt (22.10.2026)

Vorgabe des Nutzers: *„und ich könnte nach jeder Kugel anhalten?!"*  Die Sprache hat das längst
entschieden (aiml `spec/62` §5.9); hier steht, wie der Controller es tut.

- **F101-20: Das Tor steht bei der ZUTEILUNG, nicht beim Agenten.**  Ein Lauf hält nur am
  Stufen-Rand (aiml F62-53), und der einzige Ort, an dem der Rand existiert, ist die Zuteilung:
  was noch nicht zugeteilt ist, wird es nicht.  Eine laufende Stufe läuft zu Ende (F62-55) — sie
  anzuhalten hieße, ihren halb geschriebenen Arbeitsbereich zu hashen und später als Treffer
  auszugeben.  Wer etwas Laufendes stoppen will, **bricht ab**; das ist ein anderer Akt mit einer
  anderen Aufzeichnung.
- **F101-21: Drei Worte, ein Zustand.**  `pause_run` (halten), `resume_run` (frei laufen),
  `step_run` (genau *n* Stufen freigeben, danach wieder halten).  Der Zustand liegt in
  `RunControl` — einem **eigenen** KV, nicht am Lauf: es ist die Absicht eines Menschen und kein
  Teil der Aufzeichnung, und ein neues Feld an `PipelineRun` hätte jeden gespeicherten Lauf
  unlesbar gemacht (doc/spec/108 F108-2).
- **F101-22: Eine Frage, drei Frager — auch hier.**  `claim_for`, `pending_for` und
  `first_pending_want` prüfen `run_halted` **vor** den Stufen (F110-84).  Täten sie es nicht,
  stünde der Lauf still, während der Controller im Minutentakt Container für ihn startete.
- **F101-23: „Einen Schritt" heißt nicht „keinen".**  `steps: 0` wird als 1 gelesen.  Jede
  Zuteilung verbraucht eine Freigabe; fällt sie auf 0, steht der nächste wieder.
- **F101-24: `paused` ist ein Lebenszustand, nie ein Ausgang** (aiml F62-44).  Ein angehaltener
  Lauf hat noch kein Ergebnis — genau darum kann er weitergehen.  `PipeStatus` kennt das Wort
  jetzt; gesetzt wird es nur, solange nichts läuft.

Geprüft in `test/test_step_dispatch.aiml`: angehalten wird nichts zugeteilt **und** es wartet auch
nichts (sonst spawnte der Controller dafür); im Einzelschritt kommt genau eine Stufe durch, bei
zwei Freigaben genau zwei; freigegeben läuft er wieder von selbst.

**Und „ab dieser Kugel neu starten"?**  Das braucht kein eigenes Kommando (aiml F62-56): ein
zweiter Lauf, der die erledigten Stufen aus dem Cache trifft, **ist** der Wiedereinstieg.  Dafür
fehlen zwei Dinge, beide benannt: der ActionCache hängt noch nicht an der Zuteilung
(doc/spec/92), und der Zustand, auf den eine Stufe aufsetzt, ist bei einer Bau-Pipeline das
Dateisystem der Vorgängerstufe — also die Schicht je Stufe aus doc/spec/107 §107.1c.  Die Platten
im Bild sind damit nicht Schmuck, sondern der Wiedereinstiegspunkt.

## 101.8 „Ab hier nochmal" — und was es NICHT ist

- **F101-25: `rewind_run` setzt zurück, es rollt nicht zurück.**  Die genannte Stufe und alles
  danach in derselben Lane werden wieder `pending`; das **Dateisystem bleibt, wie der Lauf es
  hinterlassen hat**.  Die Stufe läuft also auf dem *jetzigen* Stand erneut, nicht auf dem von
  damals.  Für eine Bau-Pipeline ist das oft genau richtig (nochmal übersetzen) und manchmal
  falsch (wenn die spätere Stufe etwas kaputtgemacht hat) — deshalb heißt es im Werkzeug „wieder
  wartend", nicht „zurückgesetzt".
- **F101-26: Ein echtes Zurück braucht die Schichten je Stufe** (doc/spec/107 §107.1c): erst wenn
  jede Stufe ihren eigenen overlayfs-`upper` hat, ist der Stand von vorher ein `lower`, den man
  wieder auflegen kann.  Dann — und erst dann — ist „ab dieser Kugel" dasselbe wie ein zweiter
  Lauf, der bis dorthin aus dem Cache trifft (aiml F62-56).
  **Seit 22.10.2026 gibt es sie** (doc/spec/110 F110-93 ff.): jede Stufe schreibt in ihren
  eigenen `upper` unter `<work>/<lauf>/layers/<nr>`, und wer eine Stufe erneut laufen lässt,
  wirft ihre Schicht und **alle späteren** weg (F110-97).  `rewind_run` selbst bleibt damit, was
  F101-25 sagt — es setzt den Zustand zurück, nicht das Dateisystem; das Zurücklegen geschieht
  beim nächsten Start der Stufe, auf dem Wirt, der die Schichten hat.  Der Controller tut es
  nicht: er kennt den Arbeitsbereich des Wirts nicht, und eine laufende Stufe ist der einzige
  Zeitpunkt, an dem „alles ab hier ist ungültig" mit Sicherheit stimmt.
- **F101-27: Eine laufende Stufe wird nicht zurückgesetzt.**  Sie läuft zu Ende (F62-55); sonst
  hätte man einen Agenten, der an einem Schritt arbeitet, den der Server für wartend hält.

## 101.9 Vorrang und Warteschlange (25.10.2026)

**Vorgabe des Nutzers:** *„wir bauen in die Job-Config eine Priorisierungsmöglichkeit und ein
Queuing seitens des Servers, wenn Agenten belegt sind."*

### Was vorher geschah

Eine Warteschlange gab es längst — nur ohne Ordnung.  `claim_for` lief über das Lauf-KV und nahm
den **ersten** Schritt, den dieser Agent nehmen durfte; die Reihenfolge war die des Speichers,
also die der Einfügung.  Bei drei Jobs sieht das aus wie FIFO.  Bei dreihundert ist es das nicht:
ein Lauf mit 1024 Lanes, der früh im KV steht, hält jeden freien Agenten, bis er fertig ist, und
der Zwei-Minuten-Job dahinter wartet eine Stunde.

- **F101-28: Ziehen bleibt; geordnet wird die ANGEBOTS-Seite.**  Der Agent zieht weiterhin
  (F101-1) — nur ist jetzt festgelegt, welchen Schritt er zuerst angeboten bekommt.  Das ist der
  Unterschied zwischen Lastausgleich und Warteschlangen-Disziplin: wer die Arbeit *macht*, sagt
  der Agent; **welche** Arbeit als nächste dran ist, sagt der Server.  Ein Verteiler, der schiebt,
  müsste raten, wie viel Luft ein Agent hat; der Agent weiß es.
- **F101-29: Die Ordnung ist (Vorrang, dann Alter).**  Höherer Vorrang zuerst; bei gleichem
  Vorrang der **ältere Lauf** zuerst.  Zwei Regeln, beide in einem Satz erklärbar — und die
  zweite ist die, die Verhungern verhindert: innerhalb eines Vorrangs kann kein Lauf einen
  anderen überholen, egal wie breit er ist.
- **F101-30: Der Vorrang gehört zum JOB und wird beim Start FESTGESCHRIEBEN.**  Dieselbe Regel
  wie bei den Parametern (doc/spec/106 F106-14): ein Lauf trägt den Vorrang, den er beim Start
  hatte.  Sonst änderte das Verstellen eines Reglers die Reihenfolge laufender Läufe rückwirkend,
  und niemand könnte mehr erklären, warum etwas wann lief.  Eine Eingabe von Hand („diesen Lauf
  vorziehen") ist dadurch nicht verbaut: sie schreibt den Vorrang **dieses Laufs** um, nicht den
  des Jobs.
- **F101-31: 0 ist normal, grösser ist früher, kleiner ist später.**  Eine Zahl und kein
  Namensschema (`hoch`/`normal`/`niedrig`): Namen brauchen eine Tabelle, die irgendwann drei
  Einträge zu wenig hat.  Der Bereich ist bewusst offen; die Oberfläche bietet −5…+5 an, der
  Datensatz kann mehr.
- **F101-32: Ein leerer Eintrag ist kein Sonderfall.**  Ein Job ohne Vorrang-Datensatz hat 0.
  Damit braucht kein bestehender Job eine Wanderung, und der Beiwagen bleibt klein: gespeichert
  wird nur, was von 0 abweicht.
- **F101-33: Die Kosten stehen im Protokoll, nicht in der Hoffnung.**  Die Ordnung wird je
  Anfrage neu gebildet (O(n²) über die Läufe mit offenen Schritten).  Bei den heutigen Größen ist
  das nichts; es ist dieselbe Stelle, die doc/spec/102 §102.2 Zeile 2 als erste heiße nennt, und
  sie wird mit demselben Index behoben — nicht mit einer zweiten Ordnung daneben.

### Stand (25.10.2026)

Umgesetzt und gemessen in `test/test_queue_order.aiml` (12 Prüfungen, ohne Netz und ohne
Agenten): Ordnung nach Alter, Überholen durch Vorrang, negativer Vorrang nach hinten, die
Zuteilung folgt der Ordnung, und ein Job ohne Eintrag hat 0 ohne Datensatz.  Der Vorrang steht
in der Oberfläche auf dem Reiter „Parameter" (doc/spec/106 §106.6a), weil er zur Konfiguration
**dieses Jobs** gehört und dort die Seite ist, die ihn zeigt — zwei Knöpfe für eine Einstellung
hätten einander überschrieben.

Nicht umgesetzt: die **Warteposition** ist nicht sichtbar.  Ein Lauf, der wartet, steht auf
„queued"; dass er Dritter in der Schlange ist, sieht man nicht.  Das ist die nächste kleine
Scheibe und braucht nur die Ordnung, die es jetzt gibt.

### Was das NICHT ist

- **Kein Lastausgleich.**  Es wird nichts auf Agenten verteilt; es wird nur die Reihenfolge der
  Angebote festgelegt.  Welcher Agent zieht, entscheidet weiterhin der Agent.
- **Keine Verdrängung.**  Ein laufender Schritt wird nicht abgebrochen, weil etwas Wichtigeres
  kommt.  Vorrang wirkt an der **Zuteilung**, nicht im Lauf — ein abgebrochener Schritt kostet
  seine ganze Zeit noch einmal, und die Schicht ist dann halb geschrieben.
- **Keine Reservierung.**  Ein Lauf mit hohem Vorrang bekommt keine Agenten *freigehalten*; er
  bekommt den nächsten, der fragt.  Alles andere hiesse, Agenten leer stehen zu lassen, und das
  ist teurer als jede Wartezeit.

## 101.6 Was dieses Kapitel NICHT löst

- **Faire Verteilung.**  Wer zuerst fragt, bekommt zuerst.  Das genügt, solange Agenten gleich
  sind; sobald sie es nicht sind (schnelle und langsame Knoten), braucht es eine Regel, und die
  ist hier bewusst offen (Frage an den Autor).
- **Wiederholung bei Knotenausfall mitten im Schritt.**  Geregelt ist, dass das Lehen abläuft und
  der Schritt neu zugeteilt wird; **nicht** geregelt ist, wie ein halb geschriebener
  Arbeitsbereich auf dem gestorbenen Knoten aufgeräumt wird.
