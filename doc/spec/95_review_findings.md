# Kapitel 95 — Arbeitsplan aus der Prüfung vom 2026-10-11

Externe Durchsicht von cosmos. Einordnung der Prüfung: brauchbares Fundament, aber
**Entwicklungsprototyp, keine sichere Build-Plattform für fremden Code**. Das deckt sich mit
§AP1.6 (MVP ohne Sandbox → nur eigene, vertrauenswürdige Agenten).

Fünf Befunde, alle als **hoch** eingestuft. Spalte „geprüft" = von mir am Quelltext
nachvollzogen (nicht nur übernommen).

| # | Befund | Ort | geprüft |
|---|---|---|---|
| 1 | ✅ **BEHOBEN 2026-10-11.** **CAS-Objekte sind nachträglich veränderbar.** `put_file` verlinkt die Quelle hart; wird die Quelle überschrieben, ändert sich der Inhalt **unter dem bereits vergebenen Hash**. Damit sind Snapshots und Cache-Treffer nicht verlässlich. | `sources/server/cas_store.aiml:114` | ja (strukturell) |
| 2 | ✅ **BEHOBEN 2026-10-11.** **Pfadausbruch beim Lesen von Lauf-Ausgabe.** `run_ref` wird ungeprüft in den Dateipfad interpoliert; `../` führt aus dem Log-Verzeichnis heraus. Der RPC prüft die Anmeldung, aber weder die Form des Bezeichners noch die Zugehörigkeit des Laufs. | `sources/server/run_store.aiml:35`, `run_read_handlers.aiml:33` | ja |
| 3 | ✅ **BEHOBEN 2026-10-11.** **Agenten können fremde Laufergebnisse melden.** `command_output`/`command_result` prüfen nur, dass der Absender *irgendein* registrierter Agent ist. Die Bindung Agent → zugewiesener Lauf fehlt, obwohl `RunRouter` sie kennt. | `sources/server/run_exec_handlers.aiml:78` | ja (Handler prüfen den Router nicht) |
| 4 | ✅ **BEHOBEN 2026-10-11.** **Verschiedene Umgebungen ergeben denselben Cache-Schlüssel.** `env` wird mit `\n` verkettet, also sind eine Variable `A="x\nB=y"` und zwei Variablen `A=x`, `B=y` dasselbe Material. | `sources/server/action_cache.aiml:54` | ja |
| 5 | ✅ **BEHOBEN 2026-10-11.** **Einrichtung ist nicht vollständig fail closed.** (a) `service_start` liegt **vor** `verify_isolation`; scheitert der Nachweis, kehrt `run` zurück, **ohne den Dienst zu stoppen**. (b) Ein leerer erwarteter Fingerprint wird ohne Bestätigung angenommen — §94.3 S4 verlangt die Bestätigung beim ersten Kontakt. | `sources/server/agent_provisioner.aiml:159`, `:204` | ja |

## 95.1 Was daran meine eigenen Lücken sind

Befund 4 und 5 betreffen Code von heute, und beide zeigen Prüflücken, nicht nur Codefehler:

- **Zu 4:** `test_cas_actions` prüft eine Verkettungs-Kollision zwischen den *Feldern*
  (`("ab","c")` gegen `("a","bc")`), aber nicht *innerhalb* von `env`. Genau dort liegt sie.
  Richtung: längencodierte Felder statt Trennzeichen (`<len>:<wert>`), dann ist jede
  Zerlegung eindeutig.
- **Zu 5a:** Auch §94.2 hat den Fehler, nicht nur der Code — die Schrittfolge setzt den
  Dienststart vor den Nachweis. Entweder der Dienst startet erst nach dem Nachweis, oder ein
  fehlgeschlagener Nachweis stoppt ihn wieder. Die Spec muss mit.
- **Zu 5b:** `run()` bietet überhaupt keinen Weg, einen Fingerprint zu bestätigen; es reicht
  `expected_fp` durch. Die aiml-Ebene ist in Ordnung (`accept_host("")` ist dort die
  *ausgeschriebene* TOFU-Entscheidung) — cosmos nutzt sie ohne Rückfrage.

## 95.1b Stand der Behebung

**Schritt 1 „Integrität" ist erledigt** (Befund 1 und 4), jeweils Spec → Test → Code:

- **Befund 1:** `put_file` und `materialize` verlinken nicht mehr hart, sondern kopieren
  blockweise (`doc/spec/92` §92.5 umgeschrieben, Abnahme **C8** ergänzt).
  `test/test_cas_immutable.aiml` prüft **beide** Richtungen und hat den Fehler zuerst
  reproduziert (5 Fehlschläge), danach 8/8 grün.
  Dabei kam mehr heraus als im Befund stand: weil Quelle → Objekt → Materialisierung **eine**
  Inode teilten, änderte das Beschreiben der materialisierten Datei sogar die **Quelldatei**.
  Nebeneffekt des Fixes: die Sonderbehandlung des `exec`-Bits entfällt, weil eine Kopie ihre
  eigene Inode hat.
  Gegenmessung: **C5 erneut gefahren** — beide Phasen weiter flach (−40 kB / +16 kB bei
  200 MB Differenz). Die Grundlast stieg von ~61,7 auf ~64,8 MB: der jetzt immer benutzte
  1-MiB-Kopierpuffer, also der Beleg, dass die Umstellung greift.
- **Befund 4:** `ActionCache.key` codiert jedes Feld längenpräfixiert (`<byte-laenge>:<wert>`)
  statt es mit `\n` zu verketten; die Anzahl der Env-Variablen geht mit ein
  (`doc/spec/92` §92.2, Abnahme **C6** erweitert).
  Der Test hat zusätzlich einen Fall gefunden, der nicht im Befund stand: ein `\n` in einem
  der **skalaren** Felder (`kind`, `body_hash`, …) verschmolz genauso. Jetzt 20/20.

**Schritt 2 „Zugriff" ist erledigt** (Befund 2 und 3), Spec → Test → Code:

- **Befund 2:** `RunStore.valid_ref` erzwingt die Form; `stream_path`, `append` und `window`
  weisen einen ungültigen Bezeichner ab. Die Prüfung sitzt dort, **wo der Pfad entsteht** —
  im Handler allein hätte sie nur den einen Aufrufer geschützt (§AP1.6a-1).
  `test/test_run_authz.aiml`: 16 Prüfungen, darunter `../geheim`, `run-1-2/../../etc/passwd`,
  leerer ref, falsches Präfix, Buchstaben, und dass `window` für einen Ausbruch **nichts**
  liefert.
  **Dabei habe ich meine eigene Regel korrigiert:** zuerst verlangte sie
  `run-<ziffern>-<ziffern>` — die Form, die `run_on_agent` heute erzeugt. Das liess `run-1`
  durchfallen, das `test_agent_exec` seit je verwendet. Der Konflikt betraf die **Regel**,
  nicht den Test: sicherheitsrelevant ist der **Zeichensatz** (damit sind `/`, `.`, `..`
  ausgeschlossen), und die engere Regel koppelte den Store ans heutige Format, hätte also
  gebrochen, sobald dort ein Feld hinzukommt. Jetzt: `run-` + nur Ziffern und `-`, mindestens
  eine Ziffer. Nicht gelockert, um einen Test grün zu bekommen, sondern weil die engere Regel
  nichts zur Sicherheit beitrug.
- **Befund 3:** `command_output` und `command_result` prüfen, dass der gemeldete `run_ref`
  der dem Agenten **zugewiesene** ist (`current_run_of`), in `command_result` **vor** dem
  Löschen der Bindung. Die Angaben lagen schon vor, sie wurden nur nicht geprüft.
  Gegenprobe im E2E: der echte Agentenlauf bleibt grün, und im Serverlog taucht **keine**
  Verwerfung auf — die Prüfung trifft also nicht den legitimen Verkehr.

**Schritt 3 „Einrichtung" ist erledigt** (Befund 5a und 5b), Spec → Test → Code:

- **5a:** Die Schrittfolge in §94.2 war selbst falsch, nicht nur der Code. Der Nachweis braucht
  den Dienst nicht (er prüft Profil, `uidmap`, ID-Bereich), also steht er jetzt **vor** dem
  Start; danach folgt eine neue Prüfung `service_active` („kein Fehler beim Starten" ist nicht
  dasselbe wie „läuft"). Zusätzlich stoppt ein **beliebiger** Fehlschlag den Dienst vorsorglich
  (`service_stop_cmd`) — bei einem Wiederholungslauf könnte er aus einem früheren, damals
  erfolgreichen Lauf noch laufen.
  Geprüft: der Plan-Test stellt sicher, dass `verify_isolation` **vor** `service_start` liegt
  und `service_active` der letzte Schritt ist; der Lauf-Test, dass bei scheiterndem Nachweis
  der Dienst **nie** gestartet wurde.
- **5b:** `run()` ohne erwarteten Fingerprint ist jetzt zweiphasig: es verbindet, liest den
  Fingerprint, **authentifiziert nicht** und meldet `host_key_unconfirmed` samt Fingerprint
  zum Anzeigen. Damit gibt es keinen Weg, blind zu vertrauen; vorher wurde ein leerer Wert
  stillschweigend angenommen, was §94.3 S4 direkt widersprach. Neue Abnahme **P8**.

**Alle fünf Befunde behoben.** Stand: `exodus build --all` grün, Suite 9/9, E2E grün, C5 grün.

**Weiter nach §95.2 Punkt 4:** ein durchgängiger Ablauf
(Auftrag → isolierte Ausführung → quittierte Logs → Artefakt-Snapshot → Wiederanlauf).
Dazu ist der `ActionCache` zwar korrekt, aber **noch von niemandem benutzt** — die Verdrahtung
ist der nächste Schritt. Die *isolierte* Ausführung bleibt bis dahin blockiert (AppArmor-Profil
auf dem Knoten, braucht `sudo`); Auftrag, Logs, Snapshot und Wiederanlauf lassen sich ohne sie
bauen und messen.

## 95.2 Reihenfolge

Die Prüfung empfiehlt: zuerst CAS-Integrität und Zugriffskontrollen, dann **einen**
durchgängigen Ablauf (Auftrag → isolierte Ausführung → quittierte Logs → Artefakt-Snapshot →
Wiederanlauf), erst danach Scheduler, Visualisierung, Skalierung. Das übernehme ich, mit einer
Ergänzung: Befund 4 gehört zu „CAS-Integrität", weil ein falscher Cache-Treffer dieselbe
Wirkung hat wie ein veränderliches Objekt.

1. **Integrität** — Befund 1 (unabhängige Kopie oder Reflink; Hash über den *gespeicherten*
   Inhalt) und Befund 4 (längencodierte Schlüsselfelder, Test erweitern).
2. **Zugriff** — Befund 2 (Bezeichnerform erzwingen: 64 Hex bzw. das `run_ref`-Format, kein
   Pfadanteil) und Befund 3 (Agent → Lauf über `RunRouter` binden).
3. **Einrichtung** — Befund 5a/5b samt Spec-Korrektur in §94.2/§94.3.
4. Erst danach der durchgängige Ablauf und alles Weitere.

## 95.3 Was die Prüfung ausdrücklich nicht abgedeckt hat

Kein vollständiger Neubau, kein Browser-Abnahmetest, kein echter Einrichtungslauf gegen einen
fremden Knoten; Produktivcode wurde nicht geändert. Zwei weitere Feststellungen ohne eigene
Nummer, die ich hier festhalte, damit sie nicht verlorengehen:

- Der aktive Remote-Runner startet weiter `sh -c` **ohne Job-Sandbox** — bekannt und in
  §AP1.6 so festgehalten, aber es bleibt die größte Lücke zwischen den Bausteinen.
- README und Architekturtext vermischen mehrere Entwicklungsstände.

## 95.4 Nebenbefund in aiml (2026-10-11)

Beim Verdrahten der Einrichtung in die App aufgefallen und in aiml vermerkt
(aiml-spec/61 Container-Lesezugriff, aiml-spec/23 `sys.env`):

**`map<string:string>.get` increft nicht.** spec/61 sagt für einen `string`-Wert „shared
handle, incref"; tatsächlich kommt ein roher Zeiger in die Map zurück. Stirbt die Map,
dangelt der Wert. In `defaults_from_env` stand dadurch der **Name einer anderen
Umgebungsvariablen** (`QT_IM_MODULE`) im Befehl statt des Dienstnutzers — und zwar nur bei
manchen Schlüsseln, weil die übrigen Slots noch nicht überschrieben waren. Das Symptom sah
wie ein Konfigurationsfehler aus (`useradd: Permission denied`) und war keiner.

Cosmos-seitig umgangen durch `AgentProvisioner.env_or`, das den Wert über Interpolation in
eine frische Zeichenkette kopiert und als `producer` übergibt. Nebeneffekt: 14 fast
identische `if`-Blöcke sind dadurch zu 14 Einzeilern geworden.

## 95.5 Nebenbefund in aiml (2026-10-11, zweiter)

Beim Bauen des Einrichtungs-Bildschirms aufgefallen, vermerkt in aiml-spec/44_8:
**der Kindnamen-Check deckt `child_clicked` und `text_value` nicht ab** — nur die
schreibenden Methoden (`set_text` & Co.). Ein Tippfehler dort ergibt einen stummen toten
Knopf bzw. ein stumm leeres Feld, also genau die Fehlklasse, für die der Check existiert.
Zudem verfolgt er nur Instanzen aus einer direkten `decl`-Bindung, nicht in Klassen-Membern
gehaltene Szenen — und so sind alle cosmos-Bildschirme gebaut.

Für `ProvisionOverlay` habe ich den Abgleich daher von Hand gemacht: alle 12 benutzten
Kindnamen stehen in der `children:`-Liste (Differenzmenge leer).

