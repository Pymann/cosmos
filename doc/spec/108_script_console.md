# 108 — Skript-Konsole und Level-System

**Status:** Entwurf, 2026-10-17.  Verdrahtet `test/aiml/spec/65_symbol_clearance.md` (dort
gebaut: Schritte 2–8) mit cosmos.  Wo dieses Kapitel und spec/65 sich widersprechen, **gilt
spec/65** — es ist die Sprachseite, hier steht nur, wie cosmos sie benutzt.

## 1. Was die Konsole ist — und was sie nicht ist

Ein angemeldeter Nutzer schickt **aiml-Quelltext** an den Server, der Server führt ihn unter
**der Freigabe dieses Nutzers** aus und schickt die Ausgabe **nur an ihn** zurück.

Was sie **nicht** ist:
- keine Shell.  Ein Shell-Kommando ist §AP1 (`run_command`) und hat ein anderes
  Sicherheitsmodell: dort läuft ein fremdes Programm, hier läuft Quelltext, dessen
  Sprachmittel der Übersetzer begrenzen kann.
- kein zweiter Ausführungsweg für Schritte.  `kind: "aiml"` aus §AP2.D ist die
  **wiederholbare, inhaltsadressierte** Ausführung auf einem Agenten; die Konsole ist der
  **interaktive** Weg auf dem Server.  Beide benutzen denselben Übersetzer, aber die Konsole
  cacht nichts und schreibt in keinen Tree.
- **kein Ersatz für Isolation.**  Die Begrenzung der Konsole ist eine
  **Übersetzungszeit**-Zulassung (spec/65), keine Sandbox.  Sie verhindert, dass ein Skript
  ein Symbol *nennt*, nicht dass ein zugelassenes Symbol Schaden anrichtet.  Deshalb §7.

## 2. Der Level am Nutzer

**F108-1: Der gespeicherte Wert am `User` IST seine Freigabe (clearance), nicht sein Rang.**
spec/65 F65-4: erreichbar ist ein Symbol, wenn `clearance <= level`.  Die **kleinere** Zahl
ist also das **größere** Recht:

| Wert | Bedeutung |
|---|---|
| `1` | Admin — erreicht jedes annotierte Symbol |
| `7` | Operator (Beispiel) — erreicht Level 7 und darüber |
| `255` | am stärksten eingeschränkt; erreicht nur, was auf 255 angeboten wird |
| `0` | **ungültig** als Freigabe (spec/65 F65-22) |

**F108-2: Der Level kommt in ein EIGENES KV, nicht als Feld an `User`.**  Der erste Entwurf
dieses Kapitels (17.10.2026) wollte `User.level` — das wäre ein Datenverlust gewesen, und der
Befund gehört hierher, damit ihn niemand zweimal macht:

aiml-KV-Blobs tragen einen **Schema-Fingerprint** über `[MAGIC(4)][schema_fp(4)]`
([aiml] `src/sys/ser_runtime.cpp`, `aiml_ser_schema_fp`).  Der Fingerprint läuft über
`kind`, `offset`, `elem_size` **und die Feldzahl** jedes Typknotens.  Ein neues Feld an
`User` ändert ihn also, und bei Mismatch wird der Blob **nicht** mit Null-Defaults gelesen,
sondern mit `SerializationFormatException: incompatible KV blob` **verworfen**.  Folge wäre
nicht „Alt-Konten haben Level 0", sondern **kein bestehendes Konto könnte sich mehr
anmelden** — mit einem Migrationslauf als einziger Rettung.

Dasselbe Problem ist in diesem Dienst schon einmal gelöst worden, und genauso:
`SessionToken` liegt in einem **parallelen** KV (`token → SessionToken`), damit das
`tokens`-KV unverändert bleibt.  Der Level folgt dem Muster:

```
levels:  email → UserLevel { level: i32 }     # neues, eigenes KV
users:   email → User                         # UNVERÄNDERT, kein Fingerprint-Bruch
```

**F108-2a: Ein fehlender Eintrag ist die Vorgabe, und sie ist „am stärksten
eingeschränkt".**  Das ist der eigentliche Gewinn des eigenen KV: die fail-closed-Vorgabe
entsteht aus **Abwesenheit**, nicht aus einer `0`, die man mit „Admin" verwechseln könnte.
Trotzdem gilt die Prüfung auch für den gespeicherten Wert, denn ein `UserLevel`-Blob mit
vergessenem Feld liefert `0`:

Verbindlich: es gibt **eine** Funktion, die aus „Eintrag oder kein Eintrag" eine Freigabe
macht, und sie bildet **fehlend, `0` und jeden Wert außerhalb `1…255` auf `255`** ab.  Kein
Aufrufer liest das Feld direkt — sonst steht die Regel an zwei Stellen und die zweite ist
die falsche.

**F108-3a: Die Form ist `--grant-email <mail> --grant-level <n>`, nicht zwei Positionen.**
Zwei Werte gleichen Typs in fester Reihenfolge sind der klassische Vertauscher; benannte
Flags sind es nicht.  Das Projekt-Idiom dafür ist `sys.arg_dump(cfg)` (spec/23), wie beim
Agenten — jedes Feld eines Modells wird ein Flag.

**Nebenwirkung, gemessen 2026-10-17:** dadurch lehnt `cosmosd` jetzt ein **unbekanntes**
Flag mit `UnknownArgumentException` ab, statt es wie bisher stillschweigend zu ignorieren.
Geprüft: alle Aufrufer (`run_*.sh`, `deploy/`) starten `cosmosd` **ohne** Argumente, es
bricht also keinen.  Und ein vertipptes Flag fällt nun auf, statt wirkungslos zu bleiben.

**F108-3: Level 1 wird nur serverseitig und ausdrücklich gesetzt.**  Nicht bei der
Registrierung, nicht über eine RPC, die ein Client erreichen kann, und nicht über eine
Umgebungsvariable, die im Container landet.  Der erste Admin entsteht durch eine
**Betriebshandlung** am Server (`cosmosd --grant-level <email> <n>`), die im Protokoll
auftaucht.  Begründung: eine Selbstvergabe von Rechten ist Selbstbeglaubigung (spec/65
F65-6), und das gilt auf der cosmos-Ebene genauso wie in der Sprache.

**F108-4: Ein Nutzer darf seine eigene Freigabe LESEN, nie schreiben.**  Lesen ist nötig,
damit die Oberfläche eine brauchbare Meldung geben kann statt einer Übersetzer-Diagnose;
Level sind nicht geheim (spec/65 F65-16).  Geschrieben wird nur von jemandem mit
`can_manage_users` — und ein Nutzer darf **nie eine Freigabe vergeben, die stärker ist als
seine eigene** (`ziel >= eigene`, spec/65 F65-27 auf der Kontenebene).

## 3. Warum die Konsole einen EIGENEN PROZESS braucht

**F108-5: Je Ausführung ein eigener aiml-Prozess.**  Das ist keine Vorsichtsmaßnahme,
sondern folgt aus drei gemessenen Eigenschaften:

1. **spec/65 F65-25**: der Übersetzer hält **einen** JIT-Kontext zur Zeit;
   `aiml_isolated_exec` sichert die Prozess-Globals (`g_active_context`, `g_active_ee`,
   `g_fptable_current`) und stellt sie zurück — also **sequenziell**.  Zwei Nutzer
   gleichzeitig in einem Prozess wären ein Datenrennen an der Symboltabelle, und das ist
   genau die Stelle, an der die Zugriffsprüfung hängt.
2. **Der Server ist AOT.**  `sys.exec` mit `context: false` liefert in AOT `-2`
   (spec/29_2 §3.1) — ein AOT-Wirt kann gar nicht nachladen.  Und ein Übersetzer ist im
   Server nicht eingebunden; ihn einzubinden hieße, den ganzen LLVM in den Serverprozess zu
   holen, der dann fremden Quelltext im selben Adressraum übersetzt.
3. **§AP2.B**: ein abstürzender Thread nimmt den Server mit.  Bei fremdem Quelltext ist der
   Fehlerradius „alle Nutzer" nicht hinnehmbar; bei einem Prozess ist es „dieser Lauf".

Die Ausführung ist damit: Quelltext in eine Datei, `sys.exe` auf das **aiml-Binary** mit
`capture: true` und `timeout`, Ausgabe zurück an den Aufrufer.  Derselbe Mechanismus, den
`agent_isolation.aiml` schon benutzt.

## 4. Die Übergabe — drei Umgebungsvariablen und nichts in der Quelle

**F108-6: Die Richtlinie setzt der WIRT, nie das Skript** (spec/65 F65-6/F65-20):

| Variable | Inhalt | spec/65 |
|---|---|---|
| `AIML_CLEARANCE` | die Freigabe dieses Nutzers (`1…255`) | F65-20 |
| `AIML_EXPORTS` | Pfad auf die Angebots-Tabelle des Wirts (`Name\|Level` je Zeile) | F65-23 |
| `AIML_STATIC_CLEARANCE` | `1` — Flussprüfung und Write-down an | F65-17/F65-34 |

`AIML_CREATE_LEVEL` und `AIML_REPLACE_LEVEL` werden **nicht gesetzt**: sie sind dann `0` =
niemand, und ein Konsolen-Skript hat im Wirt nichts anzulegen und nichts zu ersetzen.  Wenn
das je gebraucht wird, ist es eine eigene Entscheidung mit eigener Begründung — nicht ein
Nebeneffekt davon, dass eine Variable vergessen wurde.

**F108-7: Ein `level:` oder `grants:` im eingeschickten Quelltext ist ein Fehler.**  Das
leistet spec/65 bereits (`clearance-self-certify`, F65-6/F65-27); cosmos muss es nicht
nachbauen, aber die Oberfläche soll die Diagnose **unverändert** zeigen — sie ist
verständlicher als jede Umschreibung.

## 5. Was der Wirt anbietet

**F108-8: Die Angebots-Tabelle ist eine Datei im Repo, nicht eine Liste im Code.**  Sie ist
die Politik und muss lesbar und prüfbar sein (`deploy/clearance/console_exports.txt`).  Jede
Zeile ist `Name|Level`, und das Level ist **die Freigabe, die man mindestens braucht** —
`255` heißt „jeder angemeldete Nutzer", `1` heißt „nur Admin".

**Erste Scheibe, bewusst winzig** (die Erweiterung ist eine Politik-Entscheidung, nicht eine
Bauaufgabe):

```
# Nur Auskunft, kein Zustand.  Alles andere ist von Grund auf zu (spec/65 F65-35).
cosmos_cluster_summary|255
cosmos_whoami|255
```

Was **nicht** in der ersten Scheibe ist und je einzeln begründet werden muss, bevor es
hineinkommt: Lauf-Steuerung, Agent-Verwaltung, Token-Operationen, alles mit `db.`, `io.`,
`net.`, `sys.`.  Die Builtins sind in spec/65 F65-35 ohnehin von Grund auf zu; offen sind
nur `math`, `hash`, `enums`, `compress`, `cascade`, `log` — ein Skript kann also rechnen und
etwas sagen, und sonst nichts, bis der Wirt etwas anbietet.

**F108-9: Der Wirt ist der aiml-Compiler selbst; das Angebot ist eine Shared Library plus
die Tabelle, und das Skript erreicht es über `extern`.**

Der erste Entwurf (17.10.2026) wollte „ein kleines Wirtsprogramm, das den Nutzer-Quelltext
als Bündel ausführt".  **Das kann nicht gehen, und zwar aus demselben Grund, der am selben
Tag `clearance-create` in spec/65 unerreichbar gemacht hat:** `sys.bundle` nimmt den
**Namen einer Funktion, die der Wirt selbst übersetzt hat** (spec/29_2 §16).  Ein
Quelltext, der zur Laufzeit ankommt, ist damit nicht bündelbar — ein Wirtsprogramm könnte
nur seine eigenen Funktionen ausführen, nie die des Nutzers.  Die Falle ist, dass
`sys.export_symbol` + `sys.bundle` nach einem vollständigen Wirtsmodell aussehen; sie sind
es nur für Code, den der Wirt beim Übersetzen schon hatte.

Also der Weg, den spec/65 für genau diesen Fall vorsieht (F65-13, Probe `08_extern_admitted`):

```
aiml <script.aiml> -r        # der Übersetzer IST der Wirt
  AIML_CLEARANCE=<n>         # die Freigabe dieses Nutzers
  AIML_EXPORTS=<tabelle>     # welche Namen auf welchem Level angeboten sind
  LD_PRELOAD=libcosmos_console.so   # woher die ADRESSEN kommen
```

- **Name und Level** kommen aus der Tabelle; sie entscheiden die Zulassung des `extern`.
- **Die Adresse** kommt aus der Shared Library im Prozess (`LoadLibraryPermanently(nullptr)`
  sieht sie).  Beide Hälften der Übergabe aus F65-24 sind damit da, nur auf anderem Weg als
  bei `sys.export_symbol`.
- **Die Deklaration** schreibt nicht der Nutzer: die Konsole stellt dem Skript eine
  **Präambel** mit dem `extern: "C"`-Block voran.  Die Präambel trägt **kein** `level:` —
  das wäre Selbstbeglaubigung (F65-6) und würde den ganzen Lauf ablehnen.  Die Level stehen
  ausschließlich in der Tabelle, also beim Wirt.

**F108-9a: Dieser Weg ist GEMESSEN (17.10.2026), nicht angenommen.**  „Zugelassen" ist
nicht „aufrufbar", und Probe `08` belegte nur das Erste.  Die Messung steht im Labor
`tests/clearance/`, wo sie hingehört, und ist in spec/65 als **F65-39** festgehalten:

- `14_extern_preloaded_callable` — Symbol auf Level 7 angeboten, Sitzung mit Freigabe 7:
  der Aufruf geht durch und liefert den Wert der Bibliothek (42).
- `neg/n28_preloaded_symbol_too_low` — **dieselbe** Bibliothek, Symbol auf Level 2: mit
  `clearance-denied` abgelehnt, obwohl die Adresse im Prozess liegt.  Das ist die wichtigere
  der beiden: die Zulassung hängt an der **Tabelle**, nicht an der Auffindbarkeit.

**F108-9c: Die Angebotsfunktionen können in aiml geschrieben werden** — gemessen
2026-10-17, und es war nicht selbstverständlich: für `.aiml` → `.so` gab es keinen
Präzedenzfall (`exodus2.json` baut libaiml, also C++).  `output_type: "shared_lib"` mit
einer `.aiml`-Quelle erzeugt eine Bibliothek, deren `def`s unter ihrem **einfachen
C-Namen** exportiert sind (`nm -D`: `T cosmos_probe_offer`).  Damit braucht die Konsole
keine C-Schicht, und das Angebot steht in derselben Sprache wie der Rest von cosmos.

**Die ganze Kette ist gemessen** (`probe/solib/`, 2026-10-17) — aiml-`.so` vorgeladen,
Tabelle gesetzt, Skript in eingeschränkter Sitzung:

| Abnahme | Lage | Ergebnis |
|---|---|---|
| C1 | Symbol auf 255 angeboten, Nutzer 255 | Aufruf geht durch, Wert kommt an |
| C2 | Skript ruft `db.open_kv` | `clearance-builtin` |
| C3 | `extern` auf einen nicht angebotenen Namen | `clearance-extern` |
| C3b | **dasselbe** Symbol auf Level 7, Nutzer 255 | `clearance-denied` |
| C4 | Skript mit eigenem `level:` | `clearance-self-certify` |
| F108-15 | Angebot auf Level 1, Freigabe 7 bzw. 255 | beide `clearance-denied` |
| F108-16 | Tabellenzeile `|1` → `|7` | Freigabe 7 kommt durch, 255 bleibt draussen |

C3b ist der Beweis, dass die Tabelle die Politik trägt: dieselbe Bibliothek, dieselbe
Adresse im Prozess, nur eine andere Zeile in der Tabelle — und der Zugriff fällt.

**F108-9d: Eine Angebotsfunktion muss Werte aus `sys.env` KOPIEREN.**  Gefunden als eigener
Fehler, 2026-10-17, und spec/23 sagt es ausdrücklich: ein Wert aus `envm.get(key)` lebt
**nur so lange wie die Map** — die in spec/61 zugesagte `incref` für String-Werte findet
nicht statt.  Die erste Fassung von `cosmos_whoami` gab ihn direkt zurück; die Map stirbt
beim Verlassen, der Aufrufer bekam also einen **dangling String**.  Dass die Probe den
richtigen Wert zeigte, war Glück — der Speicher war noch nicht überschrieben.  Der in der
Spec genannte Weg ist die Interpolation (`- return: "${raw}"`), weil sie kopiert.

Das ist die Art Fehler, die eine Konsole besonders teuer macht: der Rückgabewert einer
Angebotsfunktion landet im Skript eines **Nutzers**, und ein dangling String dort ist nicht
nur ein Absturz, sondern fremder Speicherinhalt in fremder Hand.  Für jede weitere Zeile der
Tabelle gilt deshalb: **erst spec/23 und spec/61 lesen, dann exportieren.**

**F108-9e: ~1 KB Leck je Lauf, und das ist hier in Ordnung — aber nur hier.**  Gemessen
(valgrind, Differenz gegen einen identischen Lauf ohne die Angebotsaufrufe): +1.125 Bytes in
62 Blöcken, keine Invalid-Access.  Es sind die zwei `sys.env`-Maps, nicht die Strings; die
Map ist ein gewöhnliches Local, das nicht vollständig freigegeben wird (spec/23 nennt ihre
Lebensdauer selbst als Abweichung von spec/61).  Hinnehmbar ist es, weil **je Skript ein
eigener Prozess** läuft (F108-5) und der sofort endet — es akkumuliert nichts.
**Nicht** hinnehmbar wäre es, wenn Angebotsfunktionen je in einen langlebigen Prozess
wanderten; wer das vorhat, muss das Leck vorher schließen.

**F108-9b: Fehlt die Bibliothek, stürzt der Lauf heute ab** (spec/65 F65-40, am selben Tag
gemessen: ohne `LD_PRELOAD` endet die Probe mit SIGSEGV statt mit einer Diagnose).  Für die
Konsole heißt das: der Pfad der Bibliothek ist ein **Auslieferungsartefakt** wie das
AppArmor-Profil, und die Konsole muss ihn beim Start prüfen — nicht erst beim ersten Skript
eines Nutzers, das dann als Absturz zurückkommt.  Bis spec/65 F65-40 gebaut ist, ist das
cosmos' Aufgabe.

## 6. Spur und Ausgabe

**F108-10: Jede Konsolen-Ausführung wird mit `player_id`, Zeit und Quelltext-Hash
protokolliert**  — und dieselbe `player_id` ist auch das, was das SKRIPT über seinen
Aufrufer erfährt (`cosmos_whoami`).  Nicht die E-Mail: die pid ersetzt sie als Identität
in allem, was den Prozess verlässt (`sources/models/user.aiml`), und ein Konsolen-Skript
ist genau das.  Die erste Fassung reichte die E-Mail durch; der eigene e2e-Test hat es
aufgedeckt, weil er eine pid erwartete.  Gemessen danach:
`u_ec122408…` statt `admin-e2e@example.com`. — nicht mit dem Quelltext selbst und **nie** mit einem Token.  Das ist die
Lücke aus §AP2.E (`RunInfo.started_by` fehlt) und bei der Konsole nicht aufschiebbar: eine
Ausführungsfläche ohne Spur ist nicht betreibbar.

**F108-11: Die Ausgabe geht ausschließlich an den anfragenden Nutzer.**  Kein Broadcast,
kein Eintrag in eine gemeinsame Lauf-Liste, keine Ausgabe in das Server-Log.  Begründung:
die Ausgabe kann enthalten, was der Nutzer gerade gelesen hat, und das ist seine Sicht,
nicht die aller.

## 5d. Der Lauf gehört in einen eigenen FADEN

**F108-18: `console_exec` nimmt an und antwortet sofort; das Skript läuft in einem
eigenen Faden, und der Client fragt nach.**

Die erste Fassung rief `proc.wait` **im Ereignisloop** des Servers.  Das ist genau der
Fehler, den §AP2.B beim Provisioner benennt — *„neun Sekunden lang die ganze Steuerebene
still"* — und aus demselben Grund ist der Provisioner schon ein Faden.  Ein
Konsolen-Skript darf bis zu 10 Sekunden laufen; so lange hätte **kein** anderer Nutzer
eine Antwort bekommen, kein Heartbeat wäre verarbeitet worden, kein Live-Push gelaufen.
Dass es im Test nicht auffiel, lag nur daran, dass die Probe-Skripte 40 ms brauchen.

```
console_exec { source }          → { success:1, finished:0, run_id:N, message:"angenommen" }
console_exec { poll_id: N }      → { finished:0, message:"laeuft" }  … bis
console_exec { poll_id: N }      → { finished:1, exit_code, output, diagnostics, … }
```

Derselbe RPC in zwei Zeitpunkten statt zweier RPCs: es ist dieselbe Frage.

**Gemessen, nicht behauptet (17.10.2026):** während ein Konsolen-Skript **3588 ms** lief,
hat der Server fünf andere Anfragen beantwortet, die langsamste in **82 ms**.  Vorher
hätte jede davon die volle Laufzeit gewartet.

**Und die Messung prüft ihre eigene Voraussetzung mit** — das ist der Teil, der zweimal
gefehlt hat: die ersten beiden Fassungen des Probe-Skripts liefen 241 ms bzw. 184 ms, also
kürzer als der Abstand zwischen den Anfragen.  Die Probe war grün und zeigte **nichts**;
ein blockierender Server wäre genauso unauffällig gewesen.  Jetzt scheitert sie, wenn das
Skript unter einer Sekunde bleibt.  (Zählschleifen taugen dafür nicht — der Übersetzer
rechnet sie weg; es braucht echte Arbeit, hier `hash.sha256`.  `time.*` steht einem Skript
nicht offen, schlafen geht also nicht.)

**F108-18a: Ein Lauf zur Zeit.**  `begin` lehnt ab, solange einer läuft.  Mehr braucht
eine Admin-Konsole nicht, und zwei gleichzeitige Übersetzer im selben Arbeitsverzeichnis
wären eine eigene Frage.  Damit ist auch C7 beantwortet: Ausgaben können sich nicht
vermischen, weil es nie zwei gibt.

**F108-18b: Das Ergebnis kommt als RÜCKGABEWERT, nicht über einen `ref<>`-Parameter.**
Gemessen 17.10.2026: der Faden war nachweislich fertig (`run #1 fertig rc=0 in 63 ms`),
und die Abfrage sah trotzdem nichts — ein ganzes Modell in einen `ref<>`-Ausgabeparameter
zu schreiben kam beim Aufrufer nicht an.  `take_result(id)` gibt eine Kopie zurück und
`finished` sagt, ob sie gilt.  Eine **fremde** Kennung liefert nichts, sonst sähe ein
zweiter Nutzer das Ergebnis eines fremden Laufs.

**Die Sperre muss stehen, bevor der erste Faden sie anfasst** — eine Klasse, deren `lock`
erst später entsteht, killt den Prozess beim ersten Zugriff (cosmos 2026-10-15, SIGSEGV in
`pthread_mutex_lock`).  Darum `arm` an jedem Einstieg.  Und der Faden hält die Sperre
**nicht** während des Laufs: sonst blockierte die Abfrage genau so lange wie vorher der
ganze Server.

## 6a. Die beanstandete Zeile

**F108-16a: Ein Befund ohne Stelle ist eine Suchaufgabe.**  Der Übersetzer meldet Datei
und Zeile; die Oberfläche kann färben (`set_color_runs`, aiml spec/44_6 §5e).  Dazwischen
fehlt nur die Umrechnung — und die ist nicht trivial, weil die Konsole dem Quelltext eine
**Präambel** voranstellt (F108-9).  Eine Meldung zu Zeile 14 der erzeugten Datei meint
Zeile 14 **minus Präambel** im Text des Nutzers.  Ohne diesen Abzug zeigt die Markierung
um einen festen Betrag daneben, und ein Editor, der auf die falsche Zeile zeigt, ist
schlimmer als einer, der auf keine zeigt.

`ConsoleExecResult.error_line` trägt die Zeile **im Quelltext des Nutzers**, `0` heißt
„keine Fundstelle".  Gemessen 17.10.2026: ein Skript mit `db.open_kv` in seiner Zeile 5
liefert `error_line = 5`, ein sauberer Lauf `0`.

**F108-16b: Das ist eine NÄHERUNG, und sie steht hier als solche.**  Die Laufzeit liest
die Meldungen des Übersetzers als **Text** (`<datei>:<zahl>:`), weil es keine
maschinenlesbare Form gibt — doc/spec/98 §98.1, der einzige dort verbliebene offene
Punkt.  Findet sie nichts, markiert die Oberfläche nichts.  Wer dem Übersetzer eine
maschinenlesbare Diagnose gibt, soll diese Näherung ersetzen und nicht ergänzen.

**F108-12: Kein Geheimnis im Protokoll.**  Keine Tokens, keine Passwörter, keine
Kommandozeilen mit Inhalten.  Das war schon die Auflage am Agenten und gilt hier genauso.

## 7. Grenze, die dieses Kapitel NICHT schließt

**F108-13: Ohne Isolation ist die Konsole nur für eigene, vertrauenswürdige Nutzer.**  Die
Zulassung aus spec/65 wirkt zur **Übersetzungszeit**: sie entscheidet, welche Namen ein
Skript nennen darf.  Sie verhindert nicht, dass eine zugelassene Funktion zu viel tut, und
sie verhindert gar nichts, wenn ein Skript den Übersetzer selbst zum Absturz bringt.

Für **fremde** Nutzer ist die Voraussetzung dieselbe wie bei §AP2.A: ein eigener
User-Namespace je Lauf (rootless, bwrap mit eigener Kopie und eigenem AppArmor-Profil).  Das
ist gebaut genug, um darauf aufzusetzen, aber die Konsole darf nicht freigeschaltet werden,
bevor sie **in** diesem Namespace läuft.  Bis dahin gilt: Konsole nur für Konten, denen man
ohnehin traut, und das steht hier, statt in einer Betriebsanleitung zu verschwinden.

**F108-14: Der Konsolen-Prozess läuft nicht als root.**  Wie AP1.6 für den Agenten — und
hier zusätzlich, weil er fremden Quelltext übersetzt.

## 8. Abnahme

- **C1** Ein Nutzer mit Freigabe 255 kann ein Skript ausführen, das rechnet und etwas sagt,
  und bekommt die Ausgabe.
- **C2** Dasselbe Skript mit `db.open`/`sys.exe`/`io.write` wird abgelehnt, und die Meldung
  nennt `clearance-builtin`.
- **C3** Ein Skript, das ein Symbol nennt, das der Wirt auf einem niedrigeren Level
  anbietet, wird mit `clearance-denied` abgelehnt — und zwar als VERWEIGERUNG, nicht als
  „unbekannte Funktion" (spec/65 F65-12).
- **C4** Ein Skript mit eigenem `level:` wird mit `clearance-self-certify` abgelehnt.
- **C5** Ein Konto **ohne Eintrag im `levels`-KV** wird als Freigabe 255 behandelt, nicht
  als 0 und nicht als Admin — ebenso ein `UserLevel` mit `level = 0` oder außerhalb
  `1…255`.  Und: das `users`-KV bleibt lesbar, nachdem der Level eingeführt ist (der
  Fingerprint-Befund aus F108-2 ist damit auch gemessen, nicht nur begründet).
- **C6** Kein RPC kann die eigene Freigabe erhöhen; ein Versuch wird abgelehnt und
  protokolliert.
- **C7** Zwei gleichzeitige Konsolen-Ausführungen vermischen ihre Ausgaben nicht.
  ✅ **durch Bauart und gemessen**: `begin` lehnt einen zweiten Lauf ab, solange einer
  läuft (F108-18a), geprüft in `test_console`.  Es gibt also nie zwei, die sich
  vermischen könnten — und der Server bleibt trotzdem bedienbar, weil der eine Lauf in
  einem Faden sitzt.

**Stand 17.10.2026:** C1–C5 sind gemessen (`test_console`, 11 Prüfungen), C2–C4 zusätzlich
gegen den **echten RPC-Weg** (`run_e2e_console.sh`, zwei Phasen mit der Betriebshandlung
dazwischen: ohne Freigabe abgelehnt mit Grund, nach `--grant-level 1` läuft das Skript und
der Wirt beantwortet `cosmos_whoami`).  C6 folgt aus der Bauart (es gibt keinen RPC, der
die eigene Freigabe hebt — `set_level` prüft serverseitig gegen die eigene).  C8–C10 sind
im Code erfüllt und einzeln nicht erzwungen.
- **C8** Die Ausgabe erscheint bei keinem anderen angemeldeten Nutzer.
- **C9** Ein Skript, das nicht endet, wird nach dem `timeout` beendet und meldet das.
- **C10** Das Protokoll einer Ausführung enthält `player_id`, Zeit und Quelltext-Hash — und
  kein Token.

## 9. Reihenfolge

1. Dieses Kapitel, dann die Abnahmeproben, dann Code (Arbeitsprinzip 3).
2. Das `levels`-KV + die **eine** Umrechnungsfunktion (F108-2/F108-2a) + `cosmosd
   --grant-level`.  ✅ **gebaut 2026-10-17** und gemessen: 17 Prüfungen in
   `test/test_auth_cluster.aiml` (dort statt in einer neuen Datei, weil jede Testdatei einen
   eigenen Übersetzungslauf kostet), isoliert grün und wiederholbar; eine Mutation
   (`clearance_of(0) == 0` erwartet) hat belegt, dass die Prüfungen wirklich greifen.
   `User` wurde **nicht angefasst** — jede Änderung daran kostet einen Migrationslauf.
   Dateien: `sources/models/user_level.aiml`, `sources/models/daemon_cfg.aiml`,
   `clearance_of`/`valid_level` in `auth_helpers.aiml`, vier Methoden an `AuthService`
   (`clearance_for_email`, `clearance_for_pid`, `grant_level`, `set_level`), `run_grant` in
   `daemon_main.aiml`.
3. Das Angebot als **vorgeladene Bibliothek** (nicht als Wirtsprogramm — siehe F108-9):
   eine `.aiml`-Quelle mit `output_type: "shared_lib"`, dazu die Tabelle und die Präambel.
   ✅ **Mechanismus gemessen 2026-10-17** (`probe/solib/`, Tabelle F108-9c): C1–C4 greifen.
   Offen ist nur noch, die zwei echten Funktionen der ersten Scheibe mit Inhalt zu füllen —
   und dafür ist zu entscheiden, WOHER sie ihre Daten nehmen (zwei Prozesse auf demselben
   KV sind nicht vorgesehen; ein **Schnappschuss**, den der Server schreibt, ist der
   naheliegende Weg und von Bauart nur lesend).
4. ✅ **gebaut 17.10.2026** — der RPC-Handler (`console_exec`): authentifizieren,
   Admin-Tor (F108-15), Prozess starten, Ausgabe nur an den Anfragenden.  Der Lauf selbst
   steckt in `ConsoleRunner` (`sources/server/console_runner.aiml`), damit der Handler
   nur noch übersetzt, was der Dienst entscheidet.  Gemessen: `test_console` (9 Prüfungen,
   Admin-Pfad und Level-Diskriminator) und `e2e_rpc_surface` über den **echten** RPC-Weg
   (`console_exec ohne Admin abgelehnt`, mit dem Grund im Klartext).
5. ✅ **gebaut** — die Spur (F108-10): `[console] run #N actor=<pid> sha256=<hash>
   bytes=<n>`, ohne Token und ohne Quelltext.
6. ✅ **gebaut** — Oberfläche: `ConsoleScene` (Editor mit Gutter, Ausgabe und Befunde
   getrennt), `ConsoleScreen`, Reiter „Konsole" nur für Admin-Konten, und das
   Konten-BEREICH (`UsersScene`) für die Rechtevergabe — seit doc/spec/107 §107.6 ein
   Bereich wie Agenten und Jobs, kein Overlay.
   Renderings: `doc/spec/ui/shots/ConsoleScene.png`, `UsersScene.png`, `ShellScene.png`.

   **Der Editor ist nicht neu gebaut:** `src_box` trägt dieselbe Konfiguration wie das
   Quelltextfeld der `PipelineScene` (`text_input`, `font: "mono"`, `gutter: true`), und
   die Hervorhebung läuft über denselben Weg (`yaml.tokens` + `set_color_runs`).  Der
   Nutzer hat darauf hingewiesen, und er hatte recht — doc/spec/98 §98.1 behauptete noch,
   diese Mittel fehlten.

   **Nachtrag 18.10.2026 — das Feld konnte zwei Dinge nicht, die ein Editor können muss.**
   Gemeldet: *„in der textbox der console war noch immer was komisch, die rücktaste löschte
   immer 2 zeichen."*  Beides lag in aiml, nicht hier:
   - Im Browser reihte die versteckte DOM-Brücke für die mobile Tastatur Steuertasten ein
     **zweites** Mal ein (`Delete`, `Enter`, Pfeile — gemessen mit echtem Browser).  Jetzt
     gilt aiml `spec/44_0 §3.1`: ein Druck = genau ein Ereignis.
   - `Enter` fügte im mehrzeiligen `text_input` **nie** einen Zeilenumbruch ein — man konnte
     im Editor keine neue Zeile anfangen, obwohl aiml `spec/44_6 §5g` mehrzeiliges
     Bearbeiten zusagt.  Behoben, Nachweis `tests/test_prefab_backspace.aiml`.
7. **Nicht** vor der Isolation: Freischaltung für fremde Nutzer (F108-13).

## 10. Entschieden (User, 2026-10-17)

**F108-15: Die Konsole ist zunächst NUR für Admin-Konten (Freigabe 1).**  Der RPC-Handler
lehnt jeden ab, dessen Freigabe nicht 1 ist — vor jeder anderen Prüfung und unabhängig
davon, was die Tabelle anbietet.  Begründung: die Isolation aus §AP2.A trägt noch nicht
(F108-13), und ein Admin ist ein Konto, dem man ohnehin traut.  Die Oberfläche kann damit
schon gebaut werden; das Öffnen für Operatoren ist später eine Zeile.

**F108-16: Das Angebot steht auf Level 1 — und zwar AUSDRÜCKLICH, nicht über den Default.**
Hier ist eine Begründung zu korrigieren, weil sie das Ergebnis umdreht (User-Annahme
2026-10-17: „der Admin kann ja direkt alles, weil 0 für alle Symbole der Default beim
Einschalten ist"):

- Richtig ist: beim Einschalten ist **jedes** Symbol Level 0 (spec/65 F65-5).
- Falsch ist die Folge: `0` heißt **niemand**, auch nicht der Admin.  F65-4 ist
  `clearance <= level`; der Admin hat Freigabe 1, und `1 <= 0` ist falsch.  Geprüft in
  `tests/clearance/neg/n14_level_zero_unreachable` und `05_admin_is_not_trusted`
  (Freigabe 1 erreicht Level 1 und 255, **nicht** 0).  spec/65 F65-22 nennt das die
  Asymmetrie der Null: am Symbol das geschlossene Ende, als Freigabe ungültig.

Der Default erteilt also nichts, er verweigert alles — und das ist der Sinn: eine Konsole
legt nicht versehentlich Interna frei.  Damit der Admin etwas kann, muss der Wirt es
anbieten, und für eine Admin-Konsole heißt das **Level 1 je Zeile**.  Ein späteres Öffnen
für Operatoren ist `1 → 7` in derselben Zeile; nichts anderes muss sich ändern.

## 10a. Ein geteiltes Modell zu ändern heißt, ALLE Sprecher neu zu bauen

**F108-17 (Betriebsregel, am eigenen Leib gemessen 17.10.2026):** `ConsoleExecResult` bekam
das Feld `error_line`; cosmosd wurde neu gebaut, der e2e-Client nicht.  Der RPC-Fingerprint
([aiml] `aiml_ser_rpc_fp`) wies die Antwort zurück — *„response is not the expected
`set_result` payload"*.  Das ist **der Schutz, der funktioniert hat**: ohne ihn hätte der
Client eine Struktur mit vertauschten Feldern gelesen.

Die Lehre ist nicht „den Fingerprint lockern", sondern: ein Lauf, der zwei Binaries
gegeneinander prüft, **baut beide**.  `run_e2e_console.sh` tut das jetzt immer
(`--no-build` überspringt es ausdrücklich).  Dieselbe Falle trifft Client und Server im
Browser-Betrieb — dort fängt sie niemand ab, weil der Client aus dem Cache kommt.

## 11. Offen: woher die Angebotsfunktionen ihre Daten nehmen

Der Mechanismus ist gemessen (F108-9c), aber was eine angebotene Funktion **tun** kann,
hängt daran, wie sie an cosmos-Zustand kommt — und zwei Prozesse auf demselben KV sind
nicht vorgesehen.  Deshalb in zwei Scheiben:

1. **Lesend über einen Schnappschuss** (erste Scheibe).  Der Server schreibt den Zustand
   in eine Datei, die Bibliothek liest sie.  Von Bauart nur lesend, kein zweiter Schreiber,
   und die Konsole sieht den Cluster „zum Zeitpunkt des Schnappschusses" — was ehrlicher
   ist als es aussieht, denn ein Konsolen-Skript ist ohnehin eine Momentaufnahme.
2. **Wirkend über eine RPC zurück an den Server** (zweite Scheibe).  Ein Lauf starten heißt
   nicht, das KV anzufassen, sondern dem Server einen Auftrag zu geben — dieselbe Grenze,
   die ein Client auch benutzt.  Damit bleibt der Server der einzige Schreiber.

Diese Trennung ist nicht Vorsicht, sondern folgt aus dem KV-Modell.  Wer sie umgeht, baut
den zweiten Schreiber.
