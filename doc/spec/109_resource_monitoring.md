# 109 — Last-Überwachung für Server und Agenten

**Status:** GEBAUT, 2026-10-17.  Auftrag (User): *„auch speicher cpu last überwachung für
server und agenten"*.

## 109.0 Ist-Stand, am Code geprüft

| Baustein | Vorhanden? |
|---|---|
| `Node.total_cpu/used_cpu/total_memory/used_memory` | **ja, aber Demo-Daten** — `cluster_bootstrap` setzt feste Werte und rechnet damit nur die Platzierung aus; nichts davon ist gemessen |
| `Workload.cpu_request/memory_request` | **ja** — Anforderung, nicht Verbrauch |
| `AgentInfo` | **keine** Last-Felder |
| Messung der eigenen Last (Server oder Agent) | **nein** |

Also: die Oberfläche zeigte Zahlen, die niemand gemessen hat.  Das ist schlimmer als
keine Zahlen — ein Betreiber glaubt sie.

## 109.1 Was gemessen wird, und was nicht

**F109-1: Gemessen wird die Last des EIGENEN Prozesses, nicht die der Maschine.**
`/proc/self/stat` und `/proc/self/status` sagen, was *dieser* Dienst verbraucht.  Die
Maschine als Ganzes (`/proc/stat`, `/proc/meminfo`) ist eine andere Frage mit einer
anderen Antwort — und für die Frage „ist mein Agent überlastet?" die falsche: auf einem
geteilten Knoten sagt die Maschinenlast nichts über den Agenten.

**F109-2: CPU ist eine ABLEITUNG und braucht zwei Messpunkte.**  `utime+stime` ist ein
Zähler seit Prozessstart; die Auslastung ist sein Zuwachs geteilt durch die vergangene
Zeit.  Der **erste** Aufruf liefert darum `0` und nicht den Durchschnitt seit dem Start —
der wäre eine andere Größe und sähe nur aus wie Auslastung.

**F109-3: Promille, nicht Prozent.**  Die Werte sind `i32`; bei Prozent steht ein Dienst
mit 0,4 % Last als `0` da, und vier solche Dienste summieren sich zu `0`.  `1000` ist ein
voll ausgelasteter Kern — mehr ist möglich, wenn der Prozess mehrere Fäden rechnen lässt.

**F109-4: Ein Zeitstempel gehört dazu.**  Ein Messwert ohne Zeitpunkt ist nicht
interpretierbar: der Leser weiß nicht, ob er zehn Sekunden oder zehn Minuten alt ist.
Das ist dieselbe Regel wie bei `AgentList.taken_ms` (doc/spec/104).

## 109.2 Woher die Zahlen kommen

```
/proc/self/stat    Feld 14/15 = utime/stime in Uhr-Ticks (100/s)
/proc/self/status  VmRSS      = belegter Arbeitsspeicher in kB
```

**F109-5: Beim Zerlegen von `/proc/self/stat` ab der SCHLIESSENDEN Klammer zählen.**
Feld 2 ist der Programmname in Klammern und darf Leerzeichen enthalten (`(my prog)`).
Wer stumpf an Leerzeichen trennt, zählt falsch, sobald jemand das Binary umbenennt — ein
Fehler, der erst im Betrieb auftritt und dann nach einem Messfehler aussieht.

**F109-6 (aiml-Befund, behoben): `io.read_file` konnte `/proc` nicht lesen.**  Die
Funktion dimensionierte ihren Puffer über `ftell`; virtuelle Dateien melden Größe `0` und
liefern trotzdem Inhalt, also kam **immer** eine leere Zeichenkette zurück — ohne Fehler.
Gemessen und behoben am 17.10.2026 (aiml `src/core/path_runtime.cpp`: liest bis EOF, die
Größe ist nur noch ein Hinweis für die erste Allokation); aiml spec/42 trägt den Befund.
Ohne diesen Fix wäre dieses Kapitel nicht baubar gewesen, und die Ursache hätte wie ein
Fehler in der Messung ausgesehen.

## 109.3 Wer misst wen

| | misst | meldet an | sichtbar in |
|---|---|---|---|
| Agent | sich selbst | Heartbeat → `AgentInfo` | Agenten-Liste |
| Server | sich selbst | Cluster-Schnappschuss | Fußzeile der Hülle |

**F109-7: Der Agent meldet seine Last im HEARTBEAT, nicht in einem eigenen RPC.**  Der
Heartbeat läuft ohnehin und trägt schon „ich lebe"; „und so geht es mir" gehört in
dieselbe Nachricht.  Ein zweiter Takt wäre ein zweiter Weg, auf dem Daten veralten
können.

**F109-8: Die Last gehört NICHT ins KV.**  `AgentInfo` lebt im Speicher der
`AgentRegistry` (`list<AgentInfo>`), und das ist hier richtig: ein Messwert von vor einem
Neustart ist wertlos, und ein neues Feld an einem persistierten Modell kostet einen
Schema-Fingerprint (doc/spec/108 F108-2).

## 109.4 Abnahme — Stand 17.10.2026

| | | Stand |
|---|---|---|
| **R1** | erster Messpunkt CPU `0`, zweiter nach echter Arbeit `> 0` | ✅ `test_res_usage` |
| **R2** | `rss_kb` plausibel (`> 0`, `< 16 GB`) | ✅ gemessen: 49 MB |
| **R3** | ein Faden erzeugt nie mehr als ~1000 Promille | ✅ gemessen: 1000/1000 |
| **R4** | Agent meldet, Liste zeigt | ✅ **am laufenden Agenten gemessen**: `run_e2e.sh` fragt nach dem Agentenstart `subscribe_agents` und findet `res_seen=1`, RSS 48376 kB |
| **R5** | Server misst sich, Fußzeile zeigt es | ✅ `ClusterView.srv_*` → `set_server_load` |
| **R6** | ohne Meldung „k. A.", nicht `0` | ✅ `res_seen` trennt beides |

**Zur Genauigkeit, gemessen und nicht geschätzt:** ein Uhr-Tick ist 10 ms.  Über ein
Fenster von 20 ms ergibt ein einziger Tick Unterschied schon 500 Promille — die erste
Fassung der Probe maß deshalb 2000 Promille für einen einzelnen Faden und sah aus wie ein
Rechenfehler.  Im Betrieb wird alle 3 s (Agent) bzw. 5 s (Server) gemessen, da fällt die
Quantisierung nicht ins Gewicht.  Wer das Fenster verkürzt, muss das wissen.

**Warum die Prüfung WARTET statt einmal zu schauen:** ein eben verbundener Agent hat noch
keinen Heartbeat geschickt, und `res_seen=0` heißt dann „noch nichts gemeldet", nicht
„null Last".  Die Probe fragt deshalb bis zu zwölfmal im Sekundentakt — eine Prüfung, die
zu früh schaut, misst nur die eigene Ungeduld.

**Und die Beschriftung „—" war unsichtbar:** der Geviertstrich fehlt im Font-Atlas, die
Zelle blieb leer — also genau die Verwechslung, die R6 verhindern soll, nur andersherum.
Jetzt steht dort „k. A.".  Gefunden im Rendering, nicht im Code (siehe
`doc/spec/ui/shots/AgentsScene.png`).
