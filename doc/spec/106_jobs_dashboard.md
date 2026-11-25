# 106 — Jobs, Läufe und die Übersicht (die Jenkins-Form)

Auftrag (User, 2026-10-14): *„mache den cosmos-Server ein bisschen mehr jenkins-like:
jobconfig, jobruns, im main screen eine Übersicht was zzt läuft, die Agents unten
aufzuzählen ohne Namen ist nicht so passend."*

## 106.0 Was heute fehlt

| Begriff | Jenkins | cosmos heute |
|---|---|---|
| **Job** (dauerhafte Definition) | `Job` mit Konfiguration, überlebt jeden Lauf | **fehlt** |
| **Lauf** (eine Ausführung) | `Build` mit Nummer, gehört zu einem Job | `PipelineRun` — existiert, aber **ohne Job** |
| **Übersicht** | Dashboard: alle Jobs, letztes Ergebnis | **fehlt** (Hauptbildschirm ist ein Menü) |
| **Ausführende** | Executor-Leiste: Agent **mit Namen** + woran er arbeitet | nur eine Zahl („2/3 Agenten") |

Heute entsteht ein Lauf aus eingereichtem YAML und ist danach für sich allein. Zweimal
dasselbe starten erzeugt zwei unverbundene Läufe; eine Frage wie *„wie oft ist `api-main`
zuletzt gescheitert?"* lässt sich nicht stellen, weil es `api-main` als **Sache** nicht gibt.

## 106.1 Der Job ist die Sache, der Lauf ist ein Ereignis

**F106-1: Ein Job ist dauerhaft, ein Lauf vergänglich.** Der Job trägt Name und Quelle und
überlebt jeden Lauf; ein Lauf gehört **immer** zu einem Job und trägt eine **Nummer**
(`#1`, `#2`, …), die nie neu vergeben wird. Ein Lauf ohne Job ist ein Fehler, keine
Abkürzung — sonst entsteht wieder Geschichte, die niemandem gehört.

```
JobDef   job_id, name, source, enabled, created_ms,
         next_build, last_run_id, last_status, last_ms, runs_total, runs_failed
```

`last_*` sind **abgeleitete** Felder, die beim Melden eines Laufs fortgeschrieben werden.
Sie stehen im Job, weil die Übersicht sonst für jede Zeile die ganze Lauf-Geschichte lesen
müsste — eine Dashboard-Zeile darf keinen Scan kosten.

**F106-2: Die Nummer vergibt der Server**, nicht der Einreicher (`next_build`, monoton).
Zwei gleichzeitige Starts bekommen zwei Nummern, nie dieselbe.

## 106.2 Was die Übersicht beantwortet

Der Hauptbildschirm beantwortet drei Fragen, in dieser Reihenfolge:

1. **Was läuft gerade?** — je laufendem Lauf: Job, Nummer, seit wann, auf **welchem Agenten**.
2. **Was gibt es?** — je Job: Name, letztes Ergebnis, Dauer, wie oft gescheitert.
3. **Wer könnte arbeiten?** — je Agent: **Name**, Anwesenheit, aktueller Schritt.

**F106-3: Kein Agent wird ohne Namen aufgezählt.** Eine Zahl („3 Agenten") beantwortet keine
der drei Fragen — sie sagt nicht, wer bereitsteht, wer hängt und wem eine Störung gehört.
Das ist die Oberflächen-Seite von F101-13 (ohne Agent keine Zuordnung) und verschärft
doc/spec/104 F104-4 für diese Ansicht: hier steht der Name **immer**, nicht nur die
Anwesenheit.

**F106-4: Leerer Zustand ist eine Aussage.** „Kein Job angelegt" und „kein Agent verbunden"
werden ausgeschrieben. Eine leere Fläche sieht aus wie ein Fehler der Oberfläche.

## 106.3 Job-Konfiguration

Ein Job wird mit `save_job` angelegt oder geändert: `name` + `source` (das Pipeline-Dokument
aus spec/62). Die Quelle wird **geprüft wie beim Einreichen** (doc/spec/96 F96-30) — ein Job,
dessen Quelle nicht läuft, darf gar nicht erst entstehen.

**F106-5: Speichern prüft, Starten prüft nicht erneut.** Sonst scheitert ein Start an etwas,
das beim Speichern schon bekannt war, und der Mensch sucht am falschen Ende.

**F106-6: Ein Job wird abgeschaltet, nicht gelöscht** (`enabled: 0`). Löschen würde die
Lauf-Geschichte entwerten, die auf ihn zeigt.

**F106-9: Die Kennung wird aus dem Namen ABGELEITET, nicht übernommen.**  Bis 2026-10-15 war
`job_id` wörtlich der Name.  Daraus bauen sich Lauf-Kennung, Stufen-Kennung, KV-Schlüssel und
— seit doc/spec/103 F103-19 — der Name der Protokolldatei; ein Job „my/job" hätte also einen
Schrägstrich in jeden Dateipfad getragen.  Die Ableitung (`Ids.slug`) lässt Buchstaben,
Ziffern, `-` und `_` stehen, ersetzt alles andere durch `-` und kürzt auf 96 Zeichen.  Der
**Name** bleibt daneben unverändert erhalten: er ist die Beschriftung, die Kennung ist der
Bezeichner, und beides zu vermischen war der Fehler.

**F106-13: Eine Build-Nummer ist das Versprechen eines Laufs.**  Sie wird erst gezogen, wenn
die Quelle angenommen ist — vorher kam sie zuerst, und ein abgelehnter Start verbrauchte sie
trotzdem.  Gemessen am 16.10.2026: vier Versuche mit einer veralteten Quelle zählten den Job
von #6 auf #10 hoch, ohne dass ein einziger Lauf entstand.  Dazu kam, dass eine **abgelehnte**
Anfrage gar nichts ins Protokoll schrieb: wer auf „Starten" drückte, sah nichts geschehen und
fand auch nichts, wenn er nachsah.  Beides gilt für den Knopf **und** den Zeitplan.

## 106.3a Die Quelle eines Jobs — was cosmos heute annimmt

Die Sprachseite ist aiml `spec/62`.  Dieser Abschnitt sagt, **welcher Ausschnitt davon heute
wirklich geparst und ausgeführt wird** — denn bis zum 15.10.2026 wich die Implementierung an
vier Stellen ab, ohne dass es irgendwo stand, und widersprach dabei auch `doc/spec/01` §1.5
(dort ist `required_label` das Feld, das `agent:` füllt).

```yaml
- pipeline:
    name: demo_build
    agent: linux                   # Vorgabe für alle Stufen (F62-146); optional
    timeout: 1800000               # ms, Vorgabe für alle Stufen (F62-40); optional
    params:                        # optional; ohne params hat die Pipeline eine Lane
      - [arch, string, [x86_64, arm64]]
      - [mode, string, [debug, release]]
    exclude:                       # optional (F62-4)
      - { arch: arm64, mode: release }
    steps:                         # Liste von STUFEN (F62-57)
      - stage:
          name: build
          agent: builder-1         # schlägt die Pipeline-Vorgabe
          timeout: 300000          # ms, schlägt die Pipeline-Vorgabe
          run: "make -j4"          # cosmos-Übergangsform, siehe unten
```

**Die vier Abweichungen sind beseitigt** (15.10.2026): `stages:` heisst `steps:`, `label:`
heisst `runs_on:` (seit 25.10.2026 `agent:`, aiml F62-146), `timeout_s:` heisst `timeout:` und zählt **Millisekunden**, und `params`
ist die typisierte Liste `[name, typ, domäne]` statt einer Abbildung.  Die alten Schlüssel
werden **nicht** zusätzlich akzeptiert: zwei Schreibweisen für dieselbe Sache sind genau die
Redundanz, die später niemand mehr auflöst.  Stattdessen nennt die Fehlermeldung die alte
Form und ihren Ersatz — eine einmalige Hilfe beim Umstellen, die nichts dauerhaft kostet.

### `run:` — die Übergangsform, und warum sie hier steht und nicht in spec/62

`spec/62` F62-6 ist eindeutig: ein Schritt ist ein `def`, sein Rumpf ist aiml-Code, und die
Pipeline-Form „contributes no way of writing code".  Ein Shell-Befehl als Schrittform
**gehört dort nicht hinein** — er ist kein Sprachmittel, sondern das, womit cosmos anfängt,
solange aiml-Rümpfe noch nicht über `sys.bundle` zum Agenten reisen (doc/spec/103 §103.3).

Darum steht `run:` **hier**, als Form des Hosts, mit Ablaufdatum:

- **F106-10** `run:` ist ein Shell-Befehl an einer **Stufe** und die einzige heute
  ausführbare Schrittform.  Er läuft im Sandkasten (doc/spec/103 §103.4) mit gebauter
  Umgebung (F103-14); die Lane-Achsen stehen darin als Variablen, `run: "echo $arch"` ist
  also die vorgesehene Verwendung.
- **F106-11** Eine Stufe trägt `run:` **oder** `steps:` (aiml-Schritte), nie beides.  Das
  `steps:` einer Stufe wird heute **geprüft, aber nicht ausgeführt** — der Prüfer verlangt
  eindeutige Namen, `needs` nur auf Frühere und bekannte `per`/`cache`-Werte (F62-9/F62-115).
  Das ist Absicht: die Form soll stimmen, bevor der Ausführungspfad sie einlöst.
- **F106-12** `run:` verschwindet, sobald aiml-Rümpfe ausführbar sind.  Dann ist eine Stufe
  ohne `steps:` ein Fehler, und dieser Abschnitt schrumpft auf einen Verweis nach `spec/62`.

### Was von `spec/62` heute NICHT gilt

Damit die Grenze benannt ist und nicht entdeckt werden muss: `parallel`, `per`, `needs`,
`cache`, `on_fail`, `retry`, `pause_before`, `resolve`, `host`, `args`, `exec_defaults` und
`return` werden am **Schritt** geprüft, aber von der Ausführung noch nicht beachtet; am
**Stufen**-Eintrag kennt der Ausfalter `name`, `agent`, `timeout` und `run`.

## 106.4 Die RPCs

| RPC | Zweck |
|---|---|
| `save_job` | Anlegen/Ändern; prüft die Quelle (F106-5) |
| `run_job` | Startet einen Lauf dieses Jobs, vergibt die Nummer (F106-2) |
| `set_job_enabled` | An/Aus (F106-6) |

Gelesen wird **nicht** per RPC: die Jobs reisen im Cluster-Schnappschuss mit
(doc/spec/104 F104-1), wie Knoten, Läufe und Agenten. Ein eigener Lese-Kanal wäre die
zweite Quelle, die dieses Projekt schon einmal teuer bezahlt hat (§104.0).

## 106.5 Reihenfolge

1. `JobDef` + Store + `save_job`/`run_job`, Jobs im Schnappschuss.
2. Übersicht im Hauptbildschirm (die drei Fragen aus §106.2).
3. Ausführenden-Leiste mit **Namen** (F106-3).
4. Lauf-Geschichte je Job (Nummer, Dauer, Ergebnis).

## 106.6 Job-Parameter — Werte aus der Oberfläche, nicht aus dem Quelltext

**Vorgabe des Nutzers (25.10.2026):** *„bei jedem Job Parameter hinzufügen, aber nicht im
Pipeline-Quelltext, sondern über das UI … Text, String, Boolean oder auch Dateiparameter … in
einem separaten Reiter … diese Symbole müssen dann dem Pipeline-Lauf hinzugefügt werden, also der
Compiler-Instanz, wenn der Job startet"*, dazu: *„alle diese Parameter sind konstant, sobald die
Pipeline losläuft"* und *„die Symbole landen in einem eigenen Namensraum, der PRM heißt"*.

### 106.6a Die Oberfläche: ein Reiter am Job

Aus dem heutigen Knopf „Quelle…" wird eine **Reiterleiste**: eine Stelle sagt, welche Sicht auf
den Job man vor sich hat.

```
 Job: aiml vom Base-Image
 [ Läufe ][ Quelle ][ Parameter ]                      [Starten] [← Jobs]
 ───────────────────────────────────────────────────────────────────────────
  Parameter                                                   [+ neu     ]
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ Name         Typ        Wert                                           │
 │ branch      [Text   ▾]  [ main________________________ ]          [x]  │
 │ anmerkung   [Langtext▾]  [ mehrzeilig…                 ]          [x]  │
 │ tiefe       [Zahl   ▾]  [ 8__ ]                                   [x]  │
 │ mit_tests   [Bool   ▾]  [x] ja                                    [x]  │
 │ keystore    [Datei  ▾]  keystore.p12 · 4,2 KB  [Ersetzen…]        [x]  │
 └─────────────────────────────────────────────────────────────────────────┘
  Im Quelltext lesbar als   ${prm.branch}  ${prm.tiefe}  ${prm.keystore}
  Gilt ab dem NÄCHSTEN Lauf; laufende Läufe behalten ihre Werte.
```

- **F106-14: Der Reiter gehört zum JOB, nicht zum Lauf.**  Ein Job hat eine Quelle und eine
  Parameter-Liste; ein Lauf hat die **Werte von damals**.  Darum steht die Liste beim Job (wo man
  sie pflegt) und die Werte im Lauf (wo man sie nachlesen kann), und darum sagt die Seite
  ausdrücklich „gilt ab dem nächsten Lauf" — eine Änderung, die in einen laufenden Lauf
  durchschlägt, wäre ein Lauf, dessen Protokoll nicht mehr zu seinem Ergebnis passt.
- **F106-15: Drei Spalten, kein Formular je Typ.**  Name, Typ, Wert — und der Typ wählt das
  Bedienelement in der dritten Spalte (Feld, Schalter, Dateiknopf).  Ein eigenes Formular je Typ
  hätte fünf Stellen, an denen dasselbe passiert.
- **F106-16: Gelesen wird aus dem Schnappschuss, geschrieben per RPC** — wie bei allem anderen
  (§104.0, F104-1).  Die Parameter reisen im Cluster-Schnappschuss mit; `set_job_params` schreibt.

### 106.6b Die fünf Typen

| Typ | im Quelltext | wird zu |
|---|---|---|
| `text` | `${prm.branch}` | `string`, eine Zeile |
| `langtext` | `${prm.anmerkung}` | `string`, mit Zeilenumbrüchen |
| `zahl` | `${prm.tiefe}` | `i64` |
| `bool` | `${prm.mit_tests}` | `bool` (`true`/`false` im Text) |
| `datei` | `${prm.keystore}` | `string` — der **Pfad** der Datei im Lauf |

- **F106-17: Eine Datei ist kein Wert, sie ist ein Ort.**  Der Inhalt liegt im CAS (doc/spec/92),
  der Parameter trägt den **Pfad**, unter dem die Datei im Lauf zu finden ist
  (`/work/<lauf>/params/<name>`).  Alles andere würde einen Schlüsselbund als Zeichenkette durch
  die Befehlszeile schieben — sichtbar im Protokoll, abgeschnitten bei der ersten Grenze.
- **F106-18: Ein Parametername ist ein aiml-Bezeichner und keine Achse.**  Er wird ein Symbol
  (F106-19), also gelten dieselben Regeln wie überall; und ein Name, der auch eine `params:`-Achse
  ist, hätte zwei Quellen für denselben `${name}` — das wird beim Speichern abgelehnt, nicht beim
  Start.

### 106.6c Wie sie in den Lauf kommen: der Namensraum `prm`

Beim Start erzeugt der Controller **ein eigenes Bundle** und gibt es demselben Compiler-Kontext
wie die Einreichung — die Parameter **zuerst**, die Pipeline danach:

```yaml
# erzeugt, nicht geschrieben:
- namespace: prm
- def: { name: branch,    return: string, body: [{ return: "main" }] }
- def: { name: tiefe,     return: i64,    body: [{ return: 8 }] }
- def: { name: mit_tests, return: bool,   body: [{ return: true }] }
- def: { name: keystore,  return: string, body: [{ return: "/work/lauf-12/params/keystore.p12" }] }
```

```yaml
# die Einreichung, unverändert:
- pipeline:
    name: aiml_vom_base
    steps:
      - stage: { name: bauen, run: "git checkout ${prm.branch} && make -j${prm.tiefe}" }
```

- **F106-19: FUNKTIONEN, keine Globalen — und darum konstant.**  Ein Parameter ist eine Funktion
  ohne Argumente, die ein Literal liefert.  Zwei Gründe, und beide sind Messungen:
  1. **Konstanz durch Bauart.**  An eine Funktion kann man nichts zuweisen.  „Konstant, sobald die
     Pipeline losläuft" ist damit keine Zusage, die jemand einhalten muss, sondern eine Form, die
     nichts anderes zulässt.
  2. Ein **Global** wäre zur Laufzeit zu initialisieren, und das heißt `__aiml_init` rufen — in
     einem Bundle, dessen oberste Ebene vom **Einreicher** stammt (F96-28).  Gemessen am
     25.10.2026: ein Modul-Global im `cx.load`-Pfad las überall seine Null
     (`git checkout  && make -j0`), weil nichts es initialisiert hatte.  Eine Klasse mit
     `const`-Membern hat dasselbe Problem: Member-Initialisierer laufen beim Konstruieren.
- **F106-20: Ein eigenes BUNDLE, nicht an die Quelle gehängt.**  `- namespace: prm` gilt für die
  **ganze Datei** (aiml spec/21 §1).  Angehängt hätte es die Pipeline mit umbenannt — gemessen:
  der Kontext kannte danach `prm.aiml_vom_base` und die Funktion unter ihrem eigenen Namen war
  „deklariert, aber nirgends definiert".  Zwei Bundles in einem Kontext lösen das, weil Funktionen
  zwischen Bundles sichtbar sind (aiml F29_2-…f).
- **F106-21: `${prm.name}` ist ein Lesezugang, kein Aufruf-Schreibstil.**  aiml ruft einen
  gepunkteten Namen ohne Argumente in einer Einsetzung wie einen Wert (aiml spec/09_1, Nachtrag
  25.10.2026) — sonst müsste in jeder Befehlszeile `${ { call: [prm.branch] } }` stehen, und das
  liest niemand gern in einer Shell-Zeile.
- **F106-22: Die Werte sind SCHLÜSSELMATERIAL.**  Ein Parameter verändert den Befehl einer Stufe,
  also verändert er, was herauskommt.  Er geht damit in den Schichten-Schlüssel ein (doc/spec/96):
  `branch: main` und `branch: next` teilen keine Schicht.  Ohne das würde der Cache einer Stufe aus
  dem einen Lauf im anderen wiederverwendet — der teuerste denkbare Fehler, weil er **grün**
  meldet.
- **F106-23: Ein Parameter ist KEIN Geheimnis.**  Sein Wert steht in der Befehlszeile der Stufe und
  damit im Protokoll (doc/spec/103 F103-19).  Wer ein Token braucht, nimmt einen `datei`-Parameter
  (der Inhalt liegt im CAS, nur der Pfad reist) — und auch dann liest der Schritt ihn selbst.
  Eine Zeile „Parameter sind sicher" wäre eine Zusage, die diese Oberfläche nicht halten kann.

### 106.6d Gespeichert wird im Beiwagen

- **F106-24: Kein neues Feld in `JobRecord`.**  Ein Feld mehr ändert den Schema-Fingerabdruck, und
  alle gespeicherten Jobs wären unlesbar (doc/spec/108 F108-2).  Die Liste liegt daher unter einem
  eigenen Schlüssel (`job_params/<job_id>` → `JobParams`), wie die Schichten eines Laufs
  (`run_layers`, doc/spec/110).  Der **Lauf** bekommt seine Werte auf demselben Weg
  (`run_params/<run_id>`) — das ist der Schnappschuss aus F106-14.

### 106.6e Stand (25.10.2026) und was noch fehlt

| Stück | Lage |
|---|---|
| `JobParams`/`ParamRow` + Beiwagen (`job_params`, `run_params`) + Schnappschuss | **da** — `cluster_bootstrap`, `cluster_view` |
| `set_job_params` (RPC) samt Prüfung beim Speichern | **da** — `job_handlers`, `param_problem` |
| `prm`-Bundle beim Start, Werte im Befehl | **da** — `pipeline_submit.prm_bundle`; gemessen in `test/test_job_params.aiml`: `git checkout main && make -j7 TESTS=true < /work/lauf-1/params/keystore` |
| Schnappschuss je Lauf (F106-14) | **da** — `freeze_run_params` beim Start, vor dem Bauen |
| Reiterleiste + Parameter-Seite | **da** — `JobParamsScene`/`JobParamsScreen`, Aufnahme: `doc/spec/ui/shots/JobParamsScene.png` |
| `datei`: hochladen, im CAS ablegen, in den Lauf bringen | **offen** — der Knopf sagt das auch, statt so zu tun als ginge es |
| `langtext`: mehrzeiliges Feld | **offen** — die Oberfläche nimmt den Typ an und zeigt ein einzeiliges Feld; das mehrzeilige Eingabefeld mit Cursor entsteht gerade an anderer Stelle |
| Werte im Schlüsselmaterial (F106-22) | **offen** — der Schichten-Schlüssel kennt sie noch nicht; bis dahin teilt ein Lauf mit anderen Werten Schichten mit seinem Vorgänger |

### 106.6f Reihenfolge der Umsetzung

1. `JobParams`/`ParamRow` + Beiwagen-Speicher + `set_job_params` (RPC) + Schnappschuss.
2. Erzeugung des `prm`-Bundles beim Start + Schnappschuss in `run_params` (hier hängt alles
   Weitere dran, und es ist ohne Oberfläche prüfbar).
3. Reiterleiste + Parameter-Seite (`text`, `zahl`, `bool`).
4. `datei`: Hochladen in den CAS, Ablegen unter `/work/<lauf>/params/`, Freigabe in den Container.
5. `langtext`: braucht das mehrzeilige Eingabefeld mit Cursor — das baut die andere Sitzung
   gerade; bis dahin nimmt die Oberfläche den Typ an, zeigt aber ein einzeiliges Feld.
