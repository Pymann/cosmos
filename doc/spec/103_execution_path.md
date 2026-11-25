# 103 — Die Ausführungskette: wie ein Schritt auf einen Agenten kommt

Diese Spec schliesst die Lücke zwischen „ein Lauf existiert" (doc/spec/96) und „ein
Kommando lief auf einem Knoten" (doc/spec/90, AP1).  Sie ist entstanden, weil der Weg
dazwischen bis 2026-10-13 **nicht** existierte und das auch niemand sehen konnte.

## 103.0 Der Befund, der diese Spec ausgelöst hat

Gemessen am 2026-10-13 am laufenden System:

| Stelle | Stand |
|---|---|
| Server-RPCs | `run_pipeline` legt einen Lauf mit Stufen an — und hört dort auf |
| Server-RPCs | `run_on_agent` schickt **ein** Kommando an **einen** Agenten (AP1) |
| Agent | nimmt genau **eine** Methode an: `run_command` |
| `StepScheduler` | `claim`/`report`/`expire`/`lane_ready` sind fertig und geprüft — **ohne Aufrufer** |

Ein Lauf entstand also, seine Stufen standen auf `pending`, und niemand holte sie ab.
Die Oberfläche zeigte einen Lauf, der nie laufen konnte, ohne das zu sagen.  **F103-1:
Ein Zustand, der nicht vorankommen kann, muss sich als solcher zeigen** — ein `pending`,
für das es keinen Abholer gibt, ist ein Fehler und kein Warten.

## 103.1 Ziehen, nicht schieben

Der Agent **holt** Arbeit (`claim_step`), der Server schiebt sie nicht.  Drei Gründe, und
der erste allein genügt:

1. **Erreichbarkeit.** Der Agent baut die Verbindung auf (`--exec-url ws://…`, AP1).  Ein
   Knoten hinter NAT oder Firewall ist vom Controller aus nicht erreichbar; umgekehrt
   immer.  Schieben hiesse, jeden Agenten erreichbar zu machen — das ist genau die
   Netz-Topologie, die cosmos vermeiden will.
2. **Rückstau.** Ein ziehender Agent nimmt sich Arbeit, wenn er Platz hat.  Ein
   schiebender Server muss Kapazität **schätzen**; liegt er daneben, entsteht eine
   Warteschlange auf dem Knoten, die niemand sieht.
3. **Ausfall.** Fällt ein ziehender Agent aus, holt er nichts mehr — der Schritt bleibt
   zuteilbar.  Beim Schieben müsste der Server erkennen, dass die Zustellung ins Leere
   ging, und das ist dieselbe Erkennung wie das Lehen, nur zusätzlich.

**F103-2:** Arbeit wird gezogen.  Der Server hält Zustand, er treibt nicht.

## 103.2 Die drei RPCs

Alle drei sind **Agent → Server**, token-gesichert wie `run_command` (AP1 §9).

### `claim_step`

```
Anfrage:  { agent_id, token, labels, capacity }
Antwort:  StepAssignment { found, run_id, stage_id, lease_until, step: StepDef }
```

`found = 0` heisst „nichts für dich" — **kein** Fehler.  Der Agent fragt dann im
Herzschlag-Takt erneut (§103.6).  `labels` entscheidet mit: ein Schritt mit
`required_label: "arm64"` geht nur an einen Agenten, der das Etikett führt (F103-3).

Der Server beantwortet `claim_step` über `StepScheduler.claim` — die Zuteilungslogik ist
schon da und bleibt netzlos prüfbar.

### F103-3a: Wer darf einen Schritt nehmen? — drei Stufen, eine Regel

Im Job-Quelltext (spec/62) steht die Auswahl als `agent:` (F62-146; bis 2026-10-25 `runs_on:`, F62-47):

```yaml
- pipeline:
    name: nightly
    agent: linux              # Vorgabe fuer ALLE Stufen
    steps:
      - stage:
          name: build
          agent: builder-1    # schlaegt die Vorgabe — Etikett ODER Agenten-Kennung
          run: "make"
```

Aufgelöst wird in dieser Reihenfolge: **Stufe → Pipeline → keines**.  Ohne Angabe darf
jeder Agent ran.  Als Etikett zählt auch die **Kennung** des Agenten: ohne das müsste man
einem Rechner erst ein eigenes Etikett verpassen, obwohl er schon einen eindeutigen Namen
trägt — der häufigste Fall („genau diese Maschine") wäre der umständlichste gewesen.

Beides war vor dem 2026-10-15 **nicht erreichbar**: `runs_on:` gab es nur an der Stufe, stand
in keinem Beispiel, und eine Pipeline-Vorgabe fehlte.  Die Abnahme dafür ist
`test/e2e_pipeline_run.aiml` (`run_e2e_pipeline.sh`): drei Stufen — ohne Etikett, mit
Etikett, mit Agenten-Kennung — müssen alle drei auf dem Agenten durchlaufen.

> Diese Abnahme deckte zugleich eine Lücke auf: geprüft war bis dahin nur der **Ad-hoc-Befehl**
> (`run_on_agent`), nie die eigentliche Kette Job → Lauf → Schritt → Meldung.  Genau sie
> brauchte der Nutzer, und genau sie hatte keinen Test.

### `report_step`

```
Anfrage:  { agent_id, token, run_id, stage_id, exit_code, output_ref, duration_ms }
Antwort:  { accepted }
```

`accepted = 0` heisst: das Lehen war abgelaufen und der Schritt ist inzwischen anderweitig
zugeteilt.  **Der Agent verwirft sein Ergebnis dann** (F103-4) — zwei Ergebnisse für
denselben Schritt zu mischen wäre schlimmer als eines zu verlieren.

### `renew_lease`

```
Anfrage:  { agent_id, token, run_id, stage_id }
Antwort:  { lease_until }
```

Ein langer Schritt darf nicht daran scheitern, dass er lange dauert.  Der Agent erneuert
das Lehen, solange der Kindprozess lebt — hört er auf, läuft es ab und der Schritt wird
wieder frei (F101-3).  **F103-5: Das Lehen bestätigt, dass der Agent lebt, nicht dass der
Schritt vorankommt.**  Ein hängendes Kommando hält sein Lehen; dagegen hilft nur ein
Zeitlimit am Schritt selbst (§103.7).

### `release_step`

```
Anfrage:  { agent_id, token, run_id, stage_id, output }   # output = Begründung
Antwort:  { accepted }
```

Der Gegenspieler zu `renew_lease`: der Agent **gibt einen Schritt zurück**, von dem er
weiss, dass er verloren ist.  `output` nennt den Grund im Klartext, damit das Protokoll
des Servers erklärt, warum eine Stufe neu zugeteilt wurde.

**F103-12: Wer es weiss, sagt es — er lässt es nicht ablaufen.**  Nach einem Neustart des
Agenten oder seines Rechners liest der Agent seine Schritt-Ablage (§103.4a) und prüft jeden
Eintrag mit `sys.process_attach`.  Findet er den Prozess weder laufend noch mit Ergebnis,
dann ist die Antwort schon bekannt — auf das 30-s-Lehen zu warten hiesse, eine halbe Minute
zu schweigen und den Lauf künstlich hängen zu lassen.

`accepted = 1` heisst freigegeben (die Stufe ist wieder `pending`), `accepted = 0`:
nicht sein Schritt oder **inzwischen abgeschlossen**.  Der zweite Fall ist der wichtige —
ein Bericht, der vor dem Absturz noch durchkam, darf nicht nachträglich zu einer
Wiederholung werden.  **Nur der eingetragene Halter darf zurückgeben** (wie bei
`renew_lease`), sonst räumte ein längst ersetzter Agent fremde laufende Arbeit ab.

Die Frist bleibt als **Netz** darunter: kommt die Meldung nicht durch (Server gerade weg),
läuft das Lehen ab wie bisher — nur später.  Zwei Wege zum selben Ergebnis, der schnelle
ist nicht der einzige.

## 103.3 Von der Stufe zum ausführbaren Schritt

`PipelineStage` (doc/spec/96) ist der **Platz im Gitter**: `stage_id`, `name`,
`bindings`, `status`, `agent`, `lease_until`, `required_label`, `script_ref`.
`StepDef` (doc/spec/92) ist die **Arbeitsanweisung**: `kind`, `body`, `input_tree`, `cwd`,
`env`, `cache_class`, `resolve`.

Die Stufe trägt die Anweisung **nicht** — sie verweist mit `script_ref` darauf.  Beim
`claim_step` baut der Server den `StepDef`:

1. `script_ref` im CAS auflösen (doc/spec/92), `body` einsetzen.
2. `bindings` der Lane als `env` ergänzen (`arch=x86_64` → `arch=x86_64`), damit der
   Schritt weiss, welche Lane er ist.
3. `cache_class`/`resolve` aus der Deklaration übernehmen.

**F103-6: Der Server stellt den `StepDef` zusammen, nicht der Agent.**  Der Agent kennt
die Pipeline nicht und soll sie nicht kennen — er bekommt genau das, was er ausführen
muss.  Das hält auch den Schlüssel des ActionCache beim Server, der ihn ohnehin bildet.

## 103.4 Ausführung auf dem Agenten

Der Agent führt den `StepDef` **im Sandkasten** aus (doc/spec/91, `bwrap`), nicht mit
blankem `sys.exe`.  Das ist seit 2026-10-13 nachgewiesen möglich: eigene `bwrap`-Kopie,
eigenes AppArmor-Profil, Probe meldet `ISOLATION_OK`.

Je Schritt ein **eigenes Arbeitsverzeichnis** `<run_dir>/<run_id>/<stage_id>/`, und nur
dieses ist im Sandkasten beschreibbar:

```
bwrap --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup
      --die-with-parent --uid 0 --gid 0
      --ro-bind /usr /usr  --ro-bind /etc /etc
      --proc /proc --dev /dev --tmpfs /tmp
      --bind <workdir> <workdir>  --chdir <workdir>
      sh -c '<body>'
```

**F103-7: `/opt/cosmos` wird NICHT in den Sandkasten gebunden.**  Dort liegt
`agent.token`; ein Schritt, der ihn lesen kann, kann sich als der Agent ausgeben.  Ebenso
bleiben `/home`, `/root`, `/var` und `/media` draussen — der Schritt sieht das
Betriebssystem, nicht den Menschen, dem der Rechner gehört (Abnahme A1, doc/spec/91).

**F103-9a: Die Werkzeuge kommen vom KNOTEN, nicht aus einem Abbild.**  Der Sandkasten
blendet `/usr` des Knotens **lesend** ein — gemessen 2026-10-15: `sh`, `bash`, `gcc`, `g++`,
`git`, `python3`, `make`, `curl`, `tar` sind da, 2309 Programme in `/usr/bin`, innen `uid 0`,
`/usr` schreibgeschützt, `/home` und `/opt` **unsichtbar** (F103-7 hält).

Das ist die klassische Jenkins-Semantik („der Agent bringt die Toolchain mit"), **nicht** die
Container-Semantik („jeder Job bringt sein Abbild mit"), und die Folgen gehören ausgeschrieben:

- Ein Job, der `gcc 13` braucht, braucht einen **Knoten** mit `gcc 13`. Es gibt kein `image:`.
- Zwei Knoten mit verschiedenen Paketständen führen denselben Job verschieden aus —
  reproduzierbar ist er nur **innerhalb** eines Knotens. Wer mehr will, braucht Etiketten
  (F103-3) oder später ein Abbild je Job.
- Der Job liest alles, was auf dem Knoten liegt. Gegen Diebstahl von Geheimnissen schützt das
  Ausblenden von `/home` und `/opt`; gegen das Lesen von `/etc/passwd` nicht.

> Messfalle am Rande: `command -v` unter `dash` (das `/usr/bin/sh` auf Ubuntu ist) nimmt nur
> **ein** Argument. Eine Prüfung `command -v gcc git python3` meldet fälschlich, alles ausser
> dem ersten fehle — im `run:` eines Jobs braucht es eine Schleife.

**F103-8: Das Netz bleibt zunächst offen** (kein `--unshare-net`).  Ein Build, der seine
Abhängigkeiten nicht laden kann, ist kein Build.  Das ist eine bewusste Lücke, keine
Nachlässigkeit: sie steht hier, damit sie beim ersten fremden Nutzer wieder aufgemacht
wird, statt vergessen zu werden.


### 103.4b Die Umgebung des Schritts wird GEBAUT, nicht geerbt

**F103-14: Ein Schritt erbt die Umgebung des Agenten nicht.**  Der Agent läuft mit
`COSMOS_AGENT_TOKEN` in seiner Umgebung — das ist sein Ausweis.  `sys.exe` übernimmt ohne
`env:`-Option `environ` (aiml `process_runtime.cpp`: `has_env = mapPtr != nullptr`, sonst
`envp = environ`), und `bwrap` ohne `--clearenv` gibt sie weiter.  Ein Schritt mit
`env | grep COSMOS` hätte sich damit als der Agent ausgeben können — F103-7 (das
Token-*Verzeichnis* bleibt ungebunden) reicht dagegen nicht, denn das Token stand gar nicht
in der Datei, die man nicht sieht, sondern in der Umgebung, die man erbt.

Darum eine **Erlaubnisliste**, keine Verbotsliste: der Agent baut die Umgebung des Schritts
aus dem, was sie braucht.

| Variable | Wert | Warum |
|---|---|---|
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin` | fest; die Pfade des Agenten gehören nicht dazu |
| `HOME` | das Schrittverzeichnis | das Einzige, was beschreibbar ist |
| `TMPDIR` | `/tmp` | im Sandkasten ein `tmpfs` |
| `LANG`, `TZ` | vom Agenten, falls gesetzt | Darstellung, kein Geheimnis |
| `LD_LIBRARY_PATH` | vom Agenten, falls gesetzt | **nur aussen**: `bwrap` selbst braucht seine Bibliotheken |
| die Lane-Bindungen | `arch=x86_64` → `arch=x86_64` | §103.3 Punkt 2 |

Eine Verbotsliste wäre hier falsch: sie müsste jedes künftige Geheimnis kennen.  Die
Erlaubnisliste kennt nur, was der Schritt braucht, und ist beim nächsten neuen Geheimnis
von sich aus richtig.

Zweifach abgesichert: die Umgebung wird `sys.exe` **ausdrücklich** übergeben (ersetzt, nicht
ergänzt), und `bwrap` bekommt zusätzlich `--clearenv` plus `--setenv` je Variable.  Das erste
schützt auch ohne Sandkasten, das zweite auch bei einem Fehler im ersten.

Die Lane-Bindungen gehören in diese Umgebung, weil §103.3 das seit je behauptet hat: ein
`run: "echo $arch"` lief bis 2026-10-15 mit leerem `$arch`, die Zeile im Spec war
unbelegt.  Jetzt setzt sie der Agent — innen wie aussen aus derselben Liste.

### 103.4c Die Ausführungsgrenze

**F103-17: Jeder Schritt hat eine Grenze.**  F103-5 sagt, dass ein Lehen den *Agenten*
bestätigt, nicht den Fortschritt — ein hängender Befehl hielt seinen Schritt darum für
immer: der Agent erneuerte brav alle 10 s, die Stufe blieb `running`, und nichts rührte
sich.  §103.7 hat die Grenze seit je als nötig benannt; es gab sie nur nicht.

```yaml
- pipeline:
    name: nightly
    timeout: 1800000       # ms, Vorgabe für alle Stufen (aiml F62-40)
    steps:
      - stage:
          name: build
          timeout: 300000  # das letzte Wort hat die Stufe
          run: "make"
```

Ohne Angabe gilt die Vorgabe des Agenten: **3600 s**.  Es gibt also keinen Schritt ohne
Grenze — eine fehlende Zeile ist eine Stunde, nicht Unendlichkeit.

Durchgesetzt wird sie **vom abgekoppelten Beobachter** (spec/23 §5.3: `SIGTERM`, nach 2 s
`SIGKILL`, `returncode = 124`), nicht vom Agenten.  Das ist der Punkt: die Grenze gilt auch
dann, wenn der Agent zwischendurch stirbt — ein Agent, der selbst die Zeit nähme, könnte
genau im falschen Moment weg sein.  `124` wird mit Begründung gemeldet, damit ein Abbruch
nicht wie ein beliebiger Fehlschlag aussieht.

### 103.4d Ein veralteter Agent sagt es selbst

**F103-18: „Verbunden" ist keine Zusage, arbeiten zu können.**  Die Nachrichten tragen einen
Schema-Fingerabdruck (wie die KV-Blobs, doc/spec/102 §102.4a).  Bekommt `StepAssignment` ein
neues Feld, kann ein **älterer** Agent die Antwort auf `claim_step` nicht mehr
entschlüsseln.  Er meldet sich an, gilt als online, fragt alle 2 s nach Arbeit — und nimmt
nie etwas an.  Von außen sieht das aus wie „der Agent ist da, es läuft nur nichts", und
genau darüber ist der Nutzer am 15.10.2026 gestolpert.

Der Agent zählt darum erfolglose Anfragen und wird nach der fünften **einmal** deutlich:
*dieser Agent ist vermutlich älter als der Server, bitte „Aktualisieren" drücken*.  Danach
fragt er nur noch alle 30 s, damit ein veralteter Agent das Protokoll nicht zumüllt.

Das ist die Diagnose, nicht die Lösung: ein Agent, dessen Protokoll nicht passt, **muss**
erneuert werden.  Dass das nicht von selbst geht, ist Absicht — die Einrichtung braucht das
sudo-Passwort des Menschen (doc/spec/94), und das wird nirgends gespeichert.

### 103.4a Die Schritt-Ablage des Agenten

Der Agent führt **je laufendem Schritt einen Datensatz** in einem persistenten KV
(`agent_steps`, Schlüssel = `stage_id`): `run_id`, `stage_id`, `step_dir`, `pid`,
`started_ms`.  Das KV liegt unter dem `WorkingDirectory` des Dienstes
(`/var/lib/cosmos-agent/aiondb/`), das dem Dienstbenutzer gehört.

**F103-13: Die Ablage ist eine Datenbank, keine Notiz.**  Bis 2026-10-15 war es eine Datei
`steps/current` mit vier Zeilen.  Zwei Gründe gegen sie:

1. `io.write_file` ist **nicht atomar**.  Stirbt der Agent mitten im Schreiben, liegt eine
   halbe Notiz da.  Sie gilt als unlesbar, der Schritt wird vergessen — und läuft ein
   zweites Mal.  Genau das, was der Merkzettel verhindern sollte.  Das KV schreibt über
   ein WAL; ein Eintrag ist da oder nicht da.
2. Eine Datei namens `current` fasst **einen** Schritt.  Mehrere Schritte je Agent
   (§103.8) wären nicht erweiterbar, sondern ein Umbau.  Der Schlüssel ist darum die
   Stufen-Kennung: die Ablage ist schon mehrzahlfähig, nur die Obergrenze fehlt.

Ein Eintrag hat drei Zustände, und der Agent schreibt ihn **dreimal**:

| Zustand | Felder | Bedeutung |
|---|---|---|
| vorgemerkt | `pid = 0`, `done = 0` | *vor* `sys.exe`: der Schritt ist angenommen, aber noch nicht gestartet |
| laufend | `pid > 0`, `done = 0` | gestartet; `pid` ist der abgekoppelte Beobachter |
| fertig, Meldung offen | `done = 1`, `exit_code` | beendet, aber der Server hat es noch nicht bestätigt |

**F103-15: Vorgemerkt wird VOR dem Start.**  Vorher schrieb der Agent den Eintrag erst
*nach* `sys.exe`.  Stirbt er in diesem Fenster, läuft ein Schritt ohne jede Notiz weiter —
niemand beobachtet ihn, niemand meldet sein Ergebnis, und der Server teilt die Stufe nach
Fristablauf ein zweites Mal zu, während die erste Ausführung noch arbeitet.  Ein `pid = 0`
beim Neustart heißt: *unklar, ob er lief*.  Das wird wie ein Verlust behandelt
(`release_step`) — denn die Zustellung ist ausdrücklich **mindestens einmal** (F101-5), und
„vielleicht gelaufen" muss zu einer Wiederholung führen, nicht zu einem Stillstand.

**F103-16: Ein Ergebnis wird erst nach BESTÄTIGUNG vergessen.**  `report_step` lieferte
seinen Transport-Rückgabewert zurück, und `tick` löschte den Eintrag trotzdem.  Ein
Netzfehler genau in diesem Augenblick warf also ein fertiges Ergebnis weg: der Schritt lief
nach Fristablauf ein zweites Mal — bei einem `echo` unsichtbar, bei einem Deploy ein zweites
Deploy.  Darum:

1. Der Agent schreibt `done = 1` mit dem `exit_code` in die Ablage.
2. Er meldet.
3. Erst eine **Antwort** des Servers (angenommen *oder* abgelehnt — beides ist eine
   Entscheidung) löscht den Eintrag.
4. Bleibt die Antwort aus, bleibt der Eintrag liegen und die Meldung wird wiederholt — beim
   nächsten `tick` und, wenn der Agent dazwischen stirbt, nach dem Neustart.

Eine **Ablehnung** ist dabei ein gültiger Abschluss: sie heißt, dass der Server den Schritt
inzwischen anderweitig zugeteilt hat (F103-4), und ein zweites Melden ändert daran nichts.

Beim Start geht der Agent **alle** Einträge durch (spec/23 §5.4, `sys.process_attach`):

| Befund | Was geschieht |
|---|---|
| `done = 1` | Meldung nachholen (F103-16) — das Ergebnis ist da, nur die Bestätigung fehlt |
| `pid = 0` | `release_step`: unklar, ob er lief (F103-15) |
| `running()` | wieder aufnehmen, weiter beobachten — als wäre nichts gewesen |
| `returncode >= 0` | das Ergebnis steht in der Status-Datei und wird gemeldet |
| weder noch | `release_step` an den Server (F103-12), Eintrag löschen |

Der letzte Fall ist der **Rechner-Neustart**: dann ist jeder dieser Prozesse weg, und der
Agent liest an seiner Ablage genau ab, *welche* — und sagt es, statt es ablaufen zu lassen.

## 103.4e Die Ausgabe des Schritts

Bis 2026-10-15 landete `stdout`/`stderr` eines Schrittes **nur auf dem Agenten**
(`steps/<run>/<stage>/out` und `/err`).  `report_step` trug ein Feld `output`, das
ausschliesslich Begründungen enthielt („kein Befehl am Schritt", „Zeitgrenze
überschritten") — die eigentliche Ausgabe hat der Server nie gesehen.  Ein Fehlschlag war
damit eine Zahl ohne Text: `exit 1`, und wer wissen wollte *warum*, musste sich auf den
Agenten einloggen.

**F103-19: Die Ausgabe gehört dem Lauf, nicht dem Agenten.**  Ein Agent ist austauschbar und
darf verschwinden; das Protokoll eines Laufs muss das überleben.  Darum wird es **auf dem
Server** geführt.

### Die Strecke

Der Server hat den Speicher dafür schon: `RunStore` (doc/spec/90 §AP1.5a) mit
`begin`/`append`/`finish`/`window`, und den Eingang `command_output` (`OutChunk`).  Gebaut
wurde das für den AP1-Einzelbefehl; der Schritt-Pfad **benutzt es mit**, statt einen zweiten
Log-Speicher daneben zu stellen.

1. `claim_step` ruft serverseitig `runs.begin(<stage_id>, agent, command)` — der Lauf-Ordner
   entsteht also beim Zuteilen, nicht beim ersten Byte.  Eine **Neuzuteilung** (F101-7,
   Versuch 2) beginnt ihn neu: das Protokoll zeigt den Versuch, der zählt.
2. Der Agent **schiebt** (`command_output`), während der Schritt läuft: je Takt liest er aus
   seinen eigenen Dateien ab dem letzten gesendeten Offset und schickt höchstens
   `kChunkBytes` (8 KiB) je Strom.
3. Vor `report_step` wird der **Rest** geschickt.  Erst danach gilt der Schritt als fertig —
   sonst fehlte das Ende der Ausgabe genau bei den Schritten, die schnell scheitern.
4. `report_step` ruft `runs.finish(<stage_id>, exit_code)`.

**Der Bezeichner ist die Stufen-Kennung** (`stage_id`), nicht die Lauf-Kennung: zwei Lanes
desselben Laufs arbeiten gleichzeitig, und ihre Ausgaben in eine Datei zu mischen wäre nicht
rückgängig zu machen.  Weil `stage_id` mit der Lauf-Kennung beginnt, bleibt die Zuordnung
ablesbar.

### Wer darf schreiben

`command_output` prüfte: registrierter Agent **und** `current_run_of(agent) == run_ref`.  Für
Schritte ist `current_run` die **Lauf**-Kennung, der Bezeichner aber die Stufe.  Die Regel
heisst darum jetzt: *der Bezeichner muss zum Lauf gehören, den dieser Agent hält* — gleich
oder mit `<run>-` beginnend.  Die Schutzwirkung bleibt (F103-7, §AP1.6a-2): ein übernommener
Agent kann nicht in fremde Läufe schreiben.

### Wiederaufnahme und Grenzen

- Die gesendeten Offsets (`sent_out`, `sent_err`) stehen in der **Schritt-Ablage** (§103.4a),
  nicht nur im Speicher.  Nach einem Agenten-Neustart geht es dort weiter, wo es aufhörte —
  ohne doppelte Zeilen und ohne Loch.
- **Obergrenze je Schritt: 2 MiB** je Strom.  Danach wird einmal
  `… Ausgabe abgeschnitten (Grenze 2 MiB) …` angehängt und nichts mehr geschickt.  Ein
  `yes`-Lauf darf weder den Server füllen noch den Takt des Agenten kosten; die vollständige
  Ausgabe bleibt auf dem Agenten im Schrittverzeichnis.
- Gelesen wird **nie** die ganze Datei in den Speicher: `io.seek` + `io.read` auf dem
  Fenster, wie es `RunStore.window` auf der Leseseite schon tut.

### Lesen

Der Browser fragt Fenster über `read_run_output` (`RunWindowReq`, token-gesichert) — derselbe
Weg wie bei AP1, mit `offset`/`next_offset` für Nachladen und Scrollback.  Es gibt also
**keinen** zweiten Lesepfad und kein Sammeln im Server-RAM.

**Was diese Scheibe nicht tut:** die Ausgabe wandert nicht in den CAS und ist kein
Eingabebaum für Folgeschritte (§103.8, doc/spec/91 §AP2.D).  Sie ist Protokoll zum Ansehen,
nicht Artefakt zum Weiterverarbeiten.

## 103.5 Was der Cache dazwischen tut

Vor der Ausführung fragt der **Server** den ActionCache (doc/spec/92) mit dem Schlüssel
aus dem `StepDef`.  Ein Treffer heisst: `claim_step` liefert den Schritt gar nicht erst
aus, sondern der Server setzt ihn direkt auf `done` und vermerkt `cached = 1`.

**F103-9: Über Wiederverwendung entscheidet der Server, nicht der Agent.**  Sonst
entschiede jeder Knoten für sich, und zwei Knoten kämen bei gleichem Schlüssel zu
verschiedenen Ergebnissen — der Cache wäre nicht mehr eine Aussage über den Schritt,
sondern über den Knoten.

## 103.6 Takt und Rückstau

Der Agent fragt `claim_step` in genau zwei Fällen:
1. direkt nach `report_step` (er hat gerade Platz bekommen), und
2. sonst alle `poll_ms` (Vorgabe 2000).

**F103-10:** Ein leerer `claim_step` kostet eine Nachricht, kein Protokoll.  Ein Agent,
der nichts zu tun hat, darf das Log nicht füllen — sonst ist das Log beim nächsten echten
Fehler unlesbar.

## 103.7 Scheitern, Zeitlimit, Wiederholung

| Fall | Verhalten |
|---|---|
| `exit_code != 0` | Der Schritt ist `failed`. Abhängige Stufen derselben Lane werden `skipped` (F62-117), andere Lanes laufen weiter (F96-32). |
| Zeitlimit des Schritts | Der Agent tötet den Prozessbaum, meldet `exit_code = 124` und **meldet**, dass er abgebrochen hat — nicht „gescheitert" ohne Grund. |
| Lehen abgelaufen, Agent lebt | `report_step` wird mit `accepted = 0` abgelehnt; der Agent verwirft (F103-4). |
| Agent weg | Lehen läuft ab, Schritt wird wieder `pending`. **Mindestens einmal**, nicht genau einmal (F101-5). |

**F103-11:** Ein `opaque` Schritt, der zweimal läuft, ist ein **Risiko des Nutzers**, kein
Versehen des Systems — darum ist `opaque` die Vorgabe und Wiederverwendung die Ausnahme,
die man erklärt.

## 103.8 Was diese Scheibe NICHT tut

Damit die Grenze benannt ist und nicht entdeckt werden muss:

- **Keine Ein-/Ausgabe-Bäume zwischen Schritten.**  `input_tree` bleibt leer; ein Schritt
  sieht die Ergebnisse des vorigen **nicht**.  Das ist die nächste Scheibe (§AP2.D,
  writeset über overlayfs) — und `bwrap` 0.9.0 hat dafür kein `--overlay`.
- **Keine Parallelität je Agent.**  `capacity` wird übertragen, aber der Agent nimmt
  einen Schritt zur Zeit (doc/spec/91 §AP2.B ist die Scheibe dafür).  Die **Ablage** ist
  seit 2026-10-15 mehrzahlfähig (§103.4a) und `resume` geht alle Einträge durch; was noch
  fehlt, ist allein die Obergrenze in `claim`/`tick`.
- **Keine Warteschlange mit Rang.**  `claim` nimmt den ersten zuteilbaren Schritt.

## 103.6 Ein zweiter Anlauf findet die Spuren des ersten (22.10.2026)

- **F103-20: Das Stufen-Verzeichnis gehört dem AKTUELLEN Versuch.**  Der Agent erkennt „fertig"
  daran, dass eine `status`-Datei in `<work>/<lauf>/<stufe>/` liegt.  Der Pfad trägt Lauf und
  Stufe — **nicht** den Versuch.  Ein zweiter Anlauf fand deshalb die Datei des ersten vor,
  meldete im selben Takt dessen Rückgabewert und vergaß den Schritt, **während der echte Befehl
  gerade erst anlief**.  Gemessen an `run-1792672619719`: Wiederholung „zwei" und „drei" je
  0 Sekunden statt 4 — mit unveränderten Ausgabedateien, was von außen wie Arbeit aussah.
  Darum löscht der Agent `status`, `out` und `err`, bevor er startet.
- **F103-21: Das trifft nicht nur „ab hier nochmal".**  Jede zweite Zuteilung nach abgelaufenem
  Lehen (F101-5, „mindestens einmal") lief in dieselbe Falle: der neue Halter hätte den alten
  Ausgang gemeldet, ohne je etwas auszuführen.  Ein Fehlschlag wäre so beliebig oft als
  Fehlschlag bestätigt worden, ein Erfolg als Erfolg — beides ohne Ausführung.
- **F103-22: Gemessen wird an der DAUER, nicht am Ergebnis.**  Der Fehler war unsichtbar, solange
  man nur auf „grün" schaute: die Stufen meldeten Erfolg und hatten plausible Ausgaben (die des
  ersten Laufs).  Erst die Uhrzeiten im Agenten-Protokoll zeigten ihn — 0 statt 4 Sekunden.  Ein
  Schritt, der schneller fertig ist als sein eigener `sleep`, hat nicht gearbeitet.
- **F103-23: Wer horcht, prüft.**  `mirror.listen` gibt `null` zurück, wenn der Port nicht
  bindbar ist.  Der Job-Controller (`job_controller.aiml`) prüfte das als einziger der drei
  Dienste **nicht**: er schrieb „controller listening on port …" und lief in seine
  Ereignisschleife — auf Verbindungen, die nie kommen konnten, weil der Port jemand anderem
  gehörte.  Ein Starter, der auf diese Zeile wartet, hält das für Erfolg.  Gefunden mit `grai`
  über alle `.listen`-Aufrufe (3 Stellen: `cosmos_daemon` ✓, `static_main` ✓, `job_controller` ✗);
  nachgewiesen, indem zwei Controller denselben Port nahmen — der zweite endet jetzt mit
  Begründung und Rückgabewert 1 statt stumm zu warten.
- **F103-24: Ein Feld mehr in der Meldung heißt: Agenten-ABBILD neu.**  `StepReportReq` bekam
  `layer_bytes`/`layer_files` (doc/spec/107 §107.1c).  Der Controller lief danach mit dem neuen
  Modell, der Agent im Container mit dem alten — und jede Meldung endete mit
  „Bericht abgelehnt: decode failed".  Der Schritt lief, schrieb seine Schicht, und das Lehen
  lief ab, als hätte der Agent nie geantwortet; der Lauf wiederholte dieselbe Stufe endlos.
  Der Grund steht in aiml `spec/29`: der Schema-Fingerabdruck deckt die FELDER ab, nicht nur
  die Namen.  Also gehört zu jeder Änderung an einem RPC-Modell nicht nur
  `exodus build -c exodus-agent.json`, sondern auch der Agent INS Abbild
  (`cp agent deploy/rt_image/opt/cosmos/agent`, oder `tools/make_agent_image.sh`) und ein
  Container, der danach neu startet.  Gemessen 22.10.2026 an `run-1792692589403`.
