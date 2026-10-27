# 92 — Inhaltsadressierter Store (CAS), Snapshots, ActionCache

**Status:** Entwurf.  Umsetzung von doc/spec/91 §AP2.D Scheibe 1–3 (User-Entscheid F-2:
„der eigentliche Hebel").  Grundlage: Recherche 02 (CAS) und 03 (Sandbox/Tracing).

## 92.1 Zweck und Abgrenzung

Ziel ist die Grundlage für „jeder Schritt wird abgespeichert wie ein Docker-Layer, aber
vertauschbar und wiederholbar": Inhalte werden **über ihren Hash** adressiert, ein Schritt
wird über seine **Eingaben** adressiert, und ein zweiter Lauf mit gleichen Eingaben wird
**übersprungen**.

**In dieser Scheibe:** Blob-Ablage, Verzeichnis-Bäume (Merkle), Materialisierung,
ActionCache.
**Nicht in dieser Scheibe** (bewusst später): Garbage Collection/Retention,
Chunking/Dedup unterhalb der Datei, verteilte Ausführung, readset-Präzision.  Die
overlayfs-Ausführung selbst ist Scheibe 2 (§AP2.D) und setzt die Isolation aus §AP2.A
voraus (AppArmor-Profil, `probe_isolation.sh`).

## 92.2 Datenmodell

**Blob** — eine Datei-Inhaltsfolge.  `blob_id = sha256(Inhalt)` als 64 Hex-Zeichen.
Keine Metadaten im Hash: zwei Dateien mit gleichem Inhalt und verschiedenem Namen oder
Zeitstempel sind **derselbe** Blob.  Das ist der Dedup.

**Tree** — ein Verzeichnis.  Ein Eintrag ist `{name, kind, exec, id}`:
| Feld | Bedeutung |
|---|---|
| `name` | Dateiname **ohne** Pfad, nie `.`/`..`, nie `/` |
| `kind` | `file` \| `dir` \| `symlink` |
| `exec` | `0`/`1` — nur das Ausführbar-Bit, sonst **keine** Modi |
| `id` | `blob_id` (file), `tree_id` (dir) oder das Linkziel (symlink, als Blob abgelegt) |

`tree_id = sha256(kanonische Serialisierung)`.  **Die Serialisierung ist Teil der Spec**,
sonst sind Hashes zwischen Läufen nicht stabil:
```
Einträge nach `name` sortiert (byte-weise, nicht locale-abhängig), je Eintrag eine Zeile:
  <kind> <exec> <id> <name>\n
kind: f = file, d = dir, l = symlink
```
Sortiert wird mit `list<string>.sort()`, das per `strcmp` vergleicht — byte-weise und
locale-unabhängig (spec/10), also unabhängig von Umgebung und Einlese-Reihenfolge.
Ein Feld-Trenner ist genau ein Leerzeichen; `name` steht am Ende (darf Leerzeichen
enthalten, aber kein `\n`).  Das leere Verzeichnis serialisiert zu `""` und hat damit
einen definierten, konstanten `tree_id`.

**Bewusst NICHT im Hash:** Zeitstempel, uid/gid, vollständige Modi.  Sie machen Builds
unreproduzierbar (derselbe Inhalt müsste denselben Hash geben) und spielen für die
Wiederherstellung keine Rolle.  Das Ausführbar-Bit bleibt, weil es das Verhalten ändert.

**ActionCache** — `step_key → ActionResult`:
```
feld(s)      = <byte-laenge von s> ":" s
step_key     = sha256( feld(kind) feld(body_hash) feld(input_tree) feld(cwd)
                       feld(anzahl env) feld(env[0]) feld(env[1]) …
                       feld(cache_class) feld(resolve_out) )
ActionResult = { output_tree, exit_code, out_bytes, err_bytes, created_ms }
```
`kind`/`body_hash` aus §AP2.D (Shell-Zeile ODER aiml-Quelle), `env` = die berücksichtigten
Variablen als `k=v`, nach Schlüssel sortiert (byteweise).

**Klasse und Sonde im Schlüssel (2026-10-12).**  `cache_class` ist `opaque|resolved|pure`
(dieselben Werte wie aiml `CacheClass`, `spec/62` §7), `resolve_out` ist die Ausgabe der Sonde
(§96.6 Schritt 1).  Beide gehören ins Material, und zwar aus getrennten Gründen:

- **Die Klasse ist Teil der Behauptung, kein Schalter daneben.**  Derselbe Rumpf einmal als `pure`
  und einmal als `resolved` sind **nicht** derselbe Schritt: der eine behauptet, nur von
  gehashten Eingaben zu hängen, der andere lässt eine Sonde entscheiden.  Teilten sie einen
  Eintrag, erbte die eine Behauptung das Ergebnis der anderen.  (Entspricht aiml `spec/62`
  F62-15.)
- **Die Sondenausgabe ist die aufgelöste Adresse.**  Sie steht im Schlüssel, damit ein bewegter
  Name (Branch, `latest`-Tag, Paketversion) den Schlüssel bewegt — das ist der ganze Zweck der
  Sonde (§96.6).
- **Eine LEERE Sondenausgabe trifft nie.**  `resolve_out == ""` heißt „nicht aufgelöst", und ein
  unbekannter Schlüssel darf nicht treffen — sonst wird aus „ich konnte nicht nachsehen"
  stillschweigend „es hat sich nichts geändert".  Das ist eine Regel in `lookup`, nicht im
  Schlüssel: ein Schlüssel kann nicht ausdrücken, dass er ungültig ist.
- **`opaque` trifft überhaupt nicht.**  Auch das entscheidet `lookup` und nicht der Schlüssel —
  der Eintrag darf durchaus geschrieben werden (für `verify`, §96.5), er wird nur nie gelesen.
- **Die Sonde selbst (`resolve`, der Befehl) ist NICHT im Schlüssel.**  Im Schlüssel steht ihr
  **Ergebnis**.  Zwei verschiedene Sondenbefehle, die dieselbe Adresse liefern, beschreiben
  denselben Eingabestand; den Befehl mitzuhashen würde Wiederverwendung verlieren, sobald jemand
  die Sonde umformuliert, ohne dass sich etwas am Ergebnis ändert.

**Die UMGEBUNG gehört in den Schlüssel (Befund 5, 2026-10-21).**  `image_digest` fehlte, und
damit traf ein Eintrag aus `ubuntu-base` auch in `debian-base`: derselbe Befehl, dasselbe
Material, derselbe Schlüssel — ein falscher Treffer, der am Ergebnis nicht zu sehen ist.  Die
Umgebung ist Schlüsselmaterial (aiml spec/62 §18, F62-66/67); das Etikett (`runs_on:`) ist es
nie (F62-49), denn WO ein Knoten steht, ändert das Ergebnis nicht.  Im Schlüssel steht die
**Digest** des Abbilds, nicht sein Name oder Pfad (F62-130) — ein Name bewegt sich, der Inhalt
nicht.  `""` heißt „gegen den Rechner", und das ist auch eine Umgebung.  Geprüft in
`test/test_step_runner.aiml` (zwei Digests → zwei Schlüssel; dieselbe Digest → derselbe
Schlüssel, sonst wäre der Cache nur sicher und nicht mehr nützlich).

> **Offen, und darum hier notiert:** `StepRunner` hängt noch nicht an der Zuteilung — der
> laufende Weg (`cluster_bootstrap` → Agent) fragt den ActionCache nicht.  Es gibt also heute
> keinen falschen Treffer; das Feld ist da, bevor es gebraucht wird, und nicht danach.  Wer
> die beiden verbindet, **muss** `image_digest` aus der Stufe füllen (`PipelineStage.image`
> → Digest des geschriebenen Layouts, nicht der Name).  Ein leeres Feld bei gesetztem
> `image:` wäre genau der Fehler, den dieser Befund beschreibt.

**Längencodiert, nicht trennzeichengetrennt (Befund 4, 2026-10-11).** Die frühere Fassung
verkettete die Felder mit `\n`. Damit ergaben **eine** Variable `A="x\nB=y"` und **zwei**
Variablen `A=x`, `B=y` dasselbe Material und denselben Schlüssel — zwei verschiedene
Umgebungen, ein Cache-Eintrag, also ein falscher Treffer. Jedes Trennzeichen hat dieses
Problem, weil es im Inhalt vorkommen kann; eine Längenangabe hat es nicht. Die Anzahl der
Variablen geht mit ein, damit auch „eine Variable weniger" den Schlüssel ändert.  Ein Treffer ersetzt die
Ausführung; `exit_code != 0` wird **auch** gespeichert (ein reproduzierbarer Fehlschlag ist
ein Ergebnis — sonst läuft jeder kaputte Schritt endlos neu).

## 92.3 Ablage — Dateien für Inhalte, KV für Metadaten

| Was | Wo | Warum |
|---|---|---|
| Blobs | `cas/objects/<hh>/<restliche 62 hex>` | Grossdaten gehören nicht in den RAM und nicht in KV-Werte (Lehre aus §AP1.5a).  Zwei-Ebenen-Fanout hält Verzeichnisse klein.  Dateien braucht ohnehin `read_window` (Ansehen ohne Laden) und der overlayfs-`lower`. |
| Trees | KV `cas_trees`: `tree_id → Tree` | klein, strukturiert, braucht Iteration |
| ActionCache | KV `cas_actions`: `step_key → ActionResult` | klein, Treffer-Abfrage O(1) |

Ein Blob wird **atomar** eingefügt: in `cas/tmp/<zufall>` schreiben, dann `io.rename` auf
den Zielpfad.  Ein halb geschriebener Blob darf nie unter seinem Hash sichtbar sein.
Existiert das Ziel schon, ist der Inhalt per Definition identisch → der temporäre Pfad
wird verworfen (idempotentes Einfügen, kein Überschreiben).

## 92.4 Hashing — und die eine aiml-Lücke

`hash.sha256(buffer<u8>)` ist binärsicher und längenbewusst (spec/33_1; Known-Vector-Tests
inkl. `sha256(0x00)`), also das richtige Primitiv.  **Aber es gibt kein inkrementelles
Hashen**: die Runtime ruft `EVP_DigestUpdate` genau einmal, der ganze Inhalt muss im
Speicher liegen.  Für ein 1-GB-Artefakt widerspricht das direkt §AP1.5a.

**Umgesetzt (2026-10-09): `hash.sha256_file(path)` in aiml** — streamt die Datei in
1-MiB-Blöcken.  Geplant war eine Handle-API (`sha256_init/update/final`); der Datei-Hash
ist der kleinere Eingriff und deckt den Bedarf vollständig ab: **kein neuer Handle-Typ**,
kein Zustand in aiml, ein Builtin statt drei.  Preis: Bytes, die wir gerade selbst
geschrieben haben, werden zum Hashen **einmal zusätzlich gelesen** — sequenziell und
speicherneutral, also vertretbar.  Eine Handle-API bleibt nachrüstbar, falls einmal ein
Strom gehasht werden muss, der nicht als Datei vorliegt.
Begründung für sha256-des-Inhalts (unverändert):
- Der `blob_id` bleibt **sha256 des reinen Inhalts**.  Das ist, was Bazel/REAPI verwenden
  (Recherche 02 nennt REAPI als Blaupause) → späteres Zusammenspiel bleibt möglich, und
  ein `sha256sum` von aussen liefert dieselbe ID.
- Die Alternative „Blob-ID = Merkle über Chunks" (casync-Stil) würde die ID von der
  Ablage-Strategie abhängig machen.  **Chunking bleibt damit eine reine
  Speicher-Optimierung**, die später ohne ID-Wechsel nachrüstbar ist.
- Die portable Implementierung in `sha256.cpp` hat `init/update/final` schon intern —
  derselbe Algorithmus für nativ und wasm32, also garantiert identische Digests.

Gelesen wird in Blöcken von **1 MiB** (`io.read_bytes`); der Speicherbedarf beim Einfügen
und Prüfen ist damit unabhängig von der Dateigrösse — und das wird **gemessen**, nicht
behauptet (Abnahme C5).

## 92.5 Materialisierung

**Regel (Befund 1, 2026-10-11): ein Objekt im Store teilt NIE eine Inode mit einer Datei
ausserhalb des Stores.** Weder beim Aufnehmen noch beim Materialisieren wird hart verlinkt.

Begründung — ein Hardlink teilt die Inode, und das bricht die Zusage, auf der alles
Weitere steht: ein Objekt unter seiner Adresse ist unveränderlich.

- **Beim Aufnehmen** (`put_file`): verlinkte der Store die Quelle, änderte ein späteres
  Überschreiben der Quelle den Inhalt **unter dem schon vergebenen Hash**. Snapshots und
  Cache-Treffer wären dann nicht mehr verlässlich — die Adresse stimmte nicht mehr mit dem
  Inhalt überein. (Nachgewiesen reproduzierbar, siehe doc/spec/95 Befund 1.)
- **Beim Materialisieren**: verlinkte das Ziel auf das Objekt, änderte ein Schritt, der
  seine Arbeitsdatei in place bearbeitet, **den Store**. Das ist derselbe Fehler in der
  anderen Richtung und wiegt schwerer, weil ein Build-Schritt genau das tut.

Die frühere Fassung erlaubte Hardlinks und schützte nur den Sonderfall „Ausführbar-Bit
passt nicht" — das war zu eng gedacht: nicht der Modus ist das Problem, sondern der
geteilte Inhalt.

Damit entfällt auch die Sonderbehandlung des `exec`-Bits: eine Kopie hat ihre eigene
Inode, also darf das Bit immer am Ziel gesetzt werden.

`materialize(tree_id, ziel)` baut den Baum im Dateisystem auf:
- `dir` → `io.mkdir_all`
- `file` → **blockweise Kopie** vom Objektpfad auf das Ziel, dann `exec`-Bit setzen
- `symlink` → Link anlegen
Das Ergebnis ist der `lower` für overlayfs in Scheibe 2. Ein Schritt soll ihn weiterhin
nicht beschreiben (dafür ist `upper` da, und es liefert das writeset) — aber täte er es,
wäre jetzt nur seine eigene Kopie betroffen, nicht der Store.

**Preis und Ausweg.** Kopieren kostet I/O und Platz, wo ein Hardlink nichts kostete. Der
richtige Ausweg ist **kein** Hardlink, sondern ein **Reflink** (copy-on-write,
`FICLONE`): eigene Inode, geteilte Datenblöcke, Schreiben bricht sie auf. Das setzt
btrfs/XFS voraus; der Entwicklungsrechner fährt ext4, dort gibt es ihn nicht, und aiml
kennt noch kein `io.clone_file`. Festgehalten als Optimierung, nicht als Voraussetzung:
Korrektheit zuerst, und die Messung C5 zeigt, dass der Kopierpfad speicherflach ist.

## 92.6 Schnittstelle (aiml)

Klasse `CasStore` (`sources/server/cas_store.aiml`), Methoden:
`init(root)`, `put_file(pfad) → blob_id`, `put_bytes(buffer) → blob_id`,
`has(blob_id) → i32`, `blob_path(blob_id) → string`, `read_window(blob_id, offset, len)`
(wie §AP1.5a, damit die UI Artefakte ansehen kann, ohne sie zu laden),
`put_tree(pfad) → tree_id` (rekursiv), `get_tree(tree_id) → Tree`,
`materialize(tree_id, ziel) → i32`.
Klasse `ActionCache`: `init()`, `key(kind, body_hash, input_tree, cwd, env) → string`,
`lookup(step_key) → ActionResult`, `record(step_key, ergebnis)`.

Der 3-Typen-Cap (spec/49 §14) erzwingt die Aufteilung in mehrere Dateien plus Barrel —
wie beim AP1-Protokoll.

## 92.7 Abnahme (testbar)

1. **C1 Determinismus:** derselbe Inhalt → derselbe `blob_id`; dieselbe
   Verzeichnisstruktur → derselbe `tree_id`, auch bei anderer Einlese-Reihenfolge und
   anderen Zeitstempeln.
2. **C2 Dedup:** zwei Dateien gleichen Inhalts unter verschiedenen Namen → ein Objekt;
   `put_file` zweimal → idempotent, keine zweite Datei.
3. **C3 Binärsicherheit:** Inhalt mit `0x00`, `\n` und hohen Bytes überlebt
   put→materialize **byte-exakt** (Vergleich über `blob_id` des Ergebnisses).
4. **C4 Grenzfälle:** leere Datei, leeres Verzeichnis, Name mit Leerzeichen, verschachtelte
   Bäume, Symlink, `exec`-Bit erhalten.
5. **C5 Speicher:** eine grosse Datei (≥ 200 MB) einfügen und materialisieren, ohne dass
   der RSS mit der Dateigrösse wächst — gemessen wie in §AP1.5a (zwei Durchläufe,
   Zuwachs darf nicht mit der Grösse skalieren).

   Gemessen wird der **Spitzenwert** (`/usr/bin/time -f %M` = `rusage.ru_maxrss`), nicht
   der momentane RSS: ein Puffer, der vor Prozessende wieder freigegeben wird, bleibt im
   momentanen Wert unsichtbar — und wäre doch genau der Fehler.

   Zwei Phasen, die sich seit Befund 1 nur noch in der Lage der Quelle unterscheiden
   (same-fs gegen tmpfs): weil `put_file` und `materialize` jetzt **immer** kopieren,
   messen beide denselben Pfad. Früher erzwang Phase 2 über `EXDEV` den Kopierpfad gegen
   den Hardlink — diese Begründung ist entfallen, die Messung bleibt.

   Ergebnis (20 MB gegen 220 MB, Budget 10 % der Grössendifferenz = 20480 kB):

   | Phase | klein | gross | Zuwachs |
   |---|---|---|---|
   | 1 — Quelle am selben Dateisystem | 64812 kB | 64772 kB | **−40 kB** |
   | 2 — Quelle auf tmpfs | 64852 kB | 64868 kB | **+16 kB** |

   Beide flach. Dass die Grundlast in Phase 1 von ~61,7 MB (Messung mit Hardlink) auf
   ~64,8 MB gestiegen ist, ist der jetzt immer benutzte Kopierpuffer — fix 1 MiB, nicht
   inhaltsabhängig, und der Nachweis, dass die Umstellung greift.
6. **C6 ActionCache:** gleicher Schritt zweimal → zweiter Lauf ist ein Treffer und liefert
   denselben `output_tree`; eine Änderung am `kind`, `body_hash`, `input_tree`, `cwd` oder an
   einer berücksichtigten Env-Variablen ist ein Fehlschlag (kein falscher Treffer).
   Ebenfalls geprüft: Env-**Reihenfolge** ändert den Schlüssel nicht (kanonisch sortiert),
   eine weggelassene Variable ist eine Änderung, `exit_code != 0` wird getroffen, und die
   Schlüsselteile sind **längencodiert** — geprüft an den beiden Fällen, die eine
   Trennzeichen-Verkettung kollidieren liesse: `("ab","c")` gegen `("a","bc")` **und**
   eine Variable `A="x\nB=y"` gegen zwei Variablen `A=x`, `B=y` (Befund 4).
   `lookup` meldet den Fehlschlag über `output_tree == ""` — eindeutig, weil jeder echte
   Baum 64 Hex hat, auch der leere.
7. **C7 Atomizität:** ein Abbruch während `put_file` hinterlässt **kein** Objekt unter dem
   Zielhash (nur eine Datei in `cas/tmp/`).
8. **C8 Unveränderlichkeit (Befund 1):** in BEIDEN Richtungen prüfbar, und beides muss
   gelten, sonst stimmt die Adresse irgendwann nicht mehr mit dem Inhalt überein:
   - Quelle nach `put_file` überschreiben → der Blob im Store ist **unverändert**
     (gleicher Inhalt, gleiche Grösse).
   - eine materialisierte Datei überschreiben → das Objekt im Store ist **unverändert**,
     und der Baum ergibt beim erneuten `put_tree` wieder dieselbe Adresse.
   Gleichwertig formuliert: kein Objekt im Store hat nach einer Aufnahme oder
   Materialisierung einen Link-Zähler > 1 auf eine Datei ausserhalb des Stores.

## 92.8 Reihenfolge der Umsetzung

1. ~~Hashing-Lücke in aiml~~ → **erledigt**: `hash.sha256_file` (spec/33_1 dokumentiert,
   `tests/test_hash_sha256_file.aiml`: leere Datei, `abc`-Vektor, 0x00-Inhalt binärsicher,
   3 MiB über Blockgrenzen, gleicher Inhalt/anderer Name → gleiche Adresse, fehlende
   Datei → `""`).  Streaming- und Ein-Rutsch-Pfad liefern nachweislich dasselbe.
2. ~~`CasStore`: Blobs~~ → **erledigt**: `sources/server/cas_store.aiml`
   (`init`, `blob_path`, `has`, `size_of`, `put_file`, `put_bytes`, `read_window`,
   `copy_blocks`), Test `test/test_cas_blobs.aiml` in `run_tests.sh` gebündelt.
   Dafür nötig und ebenfalls erledigt: **`io.link`** in aiml (harter Link, spec/42,
   `tests/test_io_link.aiml`) — ohne ihn müsste jede Aufnahme den Inhalt kopieren,
   und die Materialisierung in Schritt 3 bräuchte ihn ohnehin.
   ~~`put_file` versucht zuerst den Hardlink~~ → **überholt durch Befund 1** (§92.5):
   `put_file` kopiert immer blockweise über `tmp` + `rename`.  Der Hardlink war billiger,
   teilte aber die Inode mit der Quelle — ein Überschreiben der Quelle änderte das Objekt
   unter seinem Hash.  `io.link` bleibt in aiml (es war für diesen Zweck nötig und ist
   anderswo brauchbar), wird vom Store aber nicht mehr verwendet.
3. ~~Trees~~ → **erledigt**: `sources/models/cas_tree.aiml` (TreeKind/TreeEntry/Tree),
   `sources/server/cas_trees.aiml` (`serialize`, `put_tree` rekursiv, `get_tree`,
   `materialize`), Test `test/test_cas_trees.aiml` — C1 (gleiche Struktur an anderem Ort
   und in anderer Einlese-Reihenfolge → gleiche Adresse; Änderung → andere Adresse;
   Rundlauf materialize→put_tree ergibt dieselbe Adresse), C4 (leeres Verzeichnis =
   `sha256("")`, Name mit Leerzeichen, Verschachtelung, Symlink, Ausführbar-Bit).
   Dafür in aiml ergänzt: `io.set_exec`, `io.symlink`, `io.is_symlink`, `io.read_link`
   (spec/42, `tests/test_io_symlink_exec.aiml`).
   Beim Bauen von zwei Static-Checks gestoppt, die beide berechtigt waren: Feldname `id`
   zu kurz (→ `addr`), und **borrow-escape** — der geborgte `ptr<CasStore>` lag in einem
   besitzenden Member; jetzt `ref<CasStore>` als schwache Rückkante (spec/61 §6.2).
4. ~~`ActionCache` + Test C6~~ → **erledigt**: `sources/models/cas_action.aiml`
   (`ActionResult`), `sources/server/action_cache.aiml` (`init`, `key`, `lookup`,
   `record`), Instanz `actions` in der `CosmosRuntime` (doc/spec/93 F93-1 — ein neuer
   Dienst wird eine Instanz, kein Global).  Test `test/test_cas_actions.aiml`, in
   `run_tests.sh` gebündelt (5/5).
   Kernpunkt der Abnahme ist nicht der Treffer, sondern der **ausbleibende falsche
   Treffer**: alle fünf Schlüsselteile werden einzeln variiert, dazu der Fall einer
   WEGGELASSENEN Env-Variablen und eine Verkettungs-Probe (("ab","c") gegen
   ("a","bc") — ohne Trennzeichen derselbe Schlüssel).
   `Kv` hat kein `size`; die geplante `count`-Methode wurde fallen gelassen statt über
   einen Iterator nachgebaut, weil sie niemand braucht.
5. ~~Messung C5~~ → **erledigt**: `run_cas_mem_check.sh` (Verfahren wie §AP1.5a:
   zwei Grössen, entscheidend ist die Skalierung, nicht der Absolutwert).
Erst danach Scheibe 2 (Schritt in overlayfs, writeset) — die hängt am AppArmor-Profil.

## 92.9 Nachtrag: zwei Baumarten, und der CAS wandert zum Agenten

Zwei Festlegungen aus §96, die diesem Kapitel widersprechen und es ersetzen:

1. **Der CAS ist nicht Server-, sondern Agent-seitig.**  §92 beschreibt ihn als Server-Instanz
   (`cas_root` in `init_server_state`).  Job-Inhalte gehören nicht auf den Server; er hält nur
   `step_key → output_tree` plus die Knotenliste (§96.2).  Der bestehende Server-CAS bleibt
   vorerst als Testfläche, ist aber nicht das Ziel.
2. **`Tree` reicht nur für Workspaces.**  Für Systemlayer fehlen `uid`/`gid`/`mode` und ein
   Whiteout (§96.4, F96-2).  Die Begründung in `sources/models/cas_tree.aiml` — Metadaten machen
   Builds unreproduzierbar — bleibt für Workspace-Bäume richtig und wird für Layer-Bäume
   ausdrücklich nicht übernommen.
