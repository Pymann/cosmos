# 98 — UI der cosmos-Webapp

Status: Festlegung.  Grundlage: `2026-05-29_rendering_and_sync_direction.md` (GL-Szene als
Hauptoberfläche, HTML nur als Hülle).  Die Lauf-Ansicht steht in `97_pipeline_scene.md`; dieses
Kapitel legt die **Bedienoberfläche** fest, deren schwieriger Teil der Pipeline-Editor ist.

## 98.1 Ist-Stand, gemessen

| Baustein | Vorhanden? |
|---|---|
| `ui.text_area(id, buffer) → string` | **ja** — mehrzeiliges, editierbares Feld (aiml `spec/44_3` §4.1) |
| `ui.label_colored(text, color)` | **ja** — Text mit eigener RGBA-Farbe |
| Prefab `text_input` | **mehrzeilig**, sobald das Feld höher als ~1.8 Zeilen ist (aiml spec/44_6 §5g) |
| Prefab `textbox` | mehrzeilig, scrollbar, **nur lesbar** |
| Caret, Auswahl, UTF-8, Clipboard | **ja**, im `text_input`/`text_area`-Pfad (Byte-Offsets, Ctrl+A/C/V/X) |
| Monospace-Font | `ui.load_font` / `ui.ttf` — nur ein passendes TTF nötig |
| Zeilennummern-Spalte | **ja** — `gutter: true` (aiml spec/44_6 §5g); zählt QUELLzeilen, nicht Umbrüche |
| Farb-Läufe **innerhalb** eines Textfeldes | **ja** — `set_color_runs` (aiml spec/44_6 §5e/§5g) |
| Maschinenlesbare Compiler-Diagnostik | **nein** — Flags sind `--check`, `--emit-main`, `--log-level`, `--prefab-report`, `--run`, `--target`, `-o`, `--asset-roots=`; Befunde kommen nur als Logzeilen |

> **Korrektur 2026-10-17.**  Diese Tabelle stand bis heute mit „einzeilig / keine
> Zeilennummern / keine Farb-Läufe" — alles drei war überholt, und sie hat bereits zu einer
> falschen Statusaussage geführt (ich habe am 17.10. behauptet, der Editor brauche diese
> Mittel noch; der Nutzer hat korrigiert: *„die pipeline-script textbox hat schon
> zeilennummern"*).  Richtig ist: `client/prefabs.aiml` benutzt `gutter: true` am `src_box`
> der `PipelineScene` seit dem Umbau, und aiml hat die Mehrzeiligkeit samt Farb-Läufen in
> spec/44_6 §5g dokumentiert — inklusive der Korrektur, dass die Einzeiligkeit **nie** der
> Implementierung entsprach.  **Eine Ist-Tabelle, die nicht nachgezogen wird, ist schlimmer
> als keine:** sie wird geglaubt.

Der schwierige Teil eines Editors — Caret, Auswahl, UTF-8-Grenzen, Clipboard — **ist schon
geschrieben**.  Was fehlt, ist die Darstellung: eine Gutter-Spalte und Farbe pro Token.

## 98.2 Editor: die vorhandene Hälfte nicht neu bauen

- **F98-1** Der Editor wird **nicht** in cosmos aus `label_colored` plus eigener Eingabelogik
  gebaut.  Das würde Caret, Auswahl, UTF-8-Behandlung und Clipboard nachbauen — die Teile, die im
  `text_input`-Pfad schon korrekt sind (Byte-Offsets, keine gespaltenen Codepoints) — nur um die
  einfache Hälfte (Gutter, Farbe) zu bekommen.  Die schwere Hälfte neu zu schreiben, um an die
  leichte zu kommen, ist verkehrt.
- **F98-2** Nötig ist deshalb eine **aiml-Erweiterung**: `ui.text_area` bekommt (a) eine optionale
  Zeilennummern-Spalte und (b) **Farb-Läufe** — eine Liste von `(byte_start, byte_len, color)`,
  die das Feld beim Zeichnen anwendet.  Alternativ ein eigenes `ui.code_area` mit derselben
  Eingabelogik.  Das gehört in aiml `spec/44_3`, nicht hierher: ein Codefeld ist kein
  cosmos-Begriff.
- **F98-3** Farb-Läufe werden als **Byte-Bereiche** übergeben, passend zu den Byte-Offsets, mit
  denen Caret und Auswahl schon arbeiten.  Zeichen- oder Spaltenindizes wären eine zweite
  Zählweise im selben Widget und damit eine Fehlerquelle an jeder Mehrbyte-Stelle.

## 98.3 Hervorhebung: ein Lexer, kein Parser

aiml ist YAML, also ist die Hervorhebung eine YAML-Hervorhebung — kein eigener Sprach-Lexer.
Aber **nicht** über `yaml.parse`:

- **F98-4** Hervorhebung braucht einen **fehlertoleranten Lexer**, keinen Parser.  Während des
  Tippens ist der Text fast immer ungültig, und ein Parser liefert dann gar keinen Baum; genau in
  diesem Zustand wird die Hervorhebung aber am meisten gebraucht.  Ein Parser verwirft außerdem
  **Kommentare**, die eingefärbt werden müssen.
- **F98-5** Der Lexer gehört nach aiml als `yaml.tokens(text) → list<YamlToken>` mit
  `(byte_start, byte_len, kind)`: YAML zu zerlegen ist allgemein und fehlertolerant zu machen ist
  fummelig.  cosmos bildet dann nur noch `kind → Farbe` ab — das ist die eine Sache, die wirklich
  Produktgeschmack ist.
- **F98-6** Zusätzlich zu den YAML-Token hebt cosmos die **Pipeline-Schlüsselwörter** hervor
  (`pipeline`, `params`, `stage`, `step`, `cache`, `on_fail`, `agent`, `resolve`, …, aiml
  `spec/62`).  Das ist eine Liste von Namen über den YAML-Token, kein zweiter Lexer.

## 98.4 Kompilations-Ausgabe: muss auf den Server

- **F98-7** Im Browser kann **nicht** übersetzt werden.  Der Client ist WASM, der aiml-Compiler
  ist LLVM-basiertes C++ — er läuft nicht im Client.  Die Prüfung ist deshalb ein **RPC**:
  `check_pipeline(source) → list<Diagnostic>`.
- **F98-8** ✅ **gebaut** (`aiml --check`, aiml `spec/49`).  Der Compiler braucht dafür einen **Prüfmodus ohne Ausgabe** — Präzedenz ist
  `--prefab-report`, das schon „analysis-only, emit no objects/binary" ist.  Nötig: `--check` mit
  maschinenlesbarer Ausgabe, eine Zeile je Befund mit Datei, Zeile, **Spalte**, Schweregrad, Code
  und Text.
- **F98-9** ⚠️ **teilweise.**  `fmtLoc(node)` gibt die Spalte jetzt aus; rund die Hälfte der Befunde läuft aber über `fmtLoc()` ohne Knoten und meldet `0`.  Das zu schließen hieße, den AST eine Quell-**Spalte** neben `sourceLine` tragen zu lassen (aiml `spec/49`).  Ursprünglicher Befund:  `fmtLoc` setzt `datei:zeile: `, und die Spalte steht in
  `node.Mark()` zur Verfügung, wird aber nicht ausgegeben.  Ohne Spalte kann die Oberfläche einen
  Befund nur der Zeile zuordnen, nicht dem Token — also keine Unterstreichung an der richtigen
  Stelle.  Das ist ein aiml-Befund, kein UI-Problem.
- **F98-10** `check_pipeline` ist **authentifiziert und begrenzt**: Übersetzen ist teuer, also ist
  ein offener Prüf-Endpunkt ein Erschöpfungsangriff.  Rate-Limit pro Benutzer, Größenobergrenze
  für die Quelle, Zeitlimit je Prüfung.
- **F98-11** Die Quelle einer Pipeline darf übertragen und gespeichert werden, **weil** sie keine
  Geheimnisse enthält: `host:` führt nur Namen, nie Werte (aiml F62-17).  Das ist kein Zufall,
  sondern der Grund, warum diese Regel dort so steht.

## 98.5 Aufteilung der Oberfläche

Vorhanden sind `login_screen`, `main_menu_screen`, `cluster_screen`, `agents_screen`.  Neu:

| Ansicht | Inhalt |
|---|---|
| `pipeline_editor_screen` | Codefeld mit Gutter + Hervorhebung (§98.2/§98.3), Datei-/Pipeline-Auswahl, Prüf-Knopf, Lauf-Knopf |
| `diagnostics_panel` | Befundliste unter dem Editor: Schweregrad, `zeile:spalte`, Text; Klick springt an die Stelle und markiert sie |
| `run_scene_screen` | die 3D-Lauf-Ansicht aus `97_pipeline_scene.md` |

- **F98-12** Der Editor und die Befundliste sind **eine** Ansicht, nicht zwei Bildschirme: ein
  Befund ohne die Zeile daneben ist nutzlos, und ein Sprung, der die Ansicht wechselt, verliert den
  Kontext.
- **F98-13** Die Befundliste ist **leer**, solange nicht geprüft wurde, und zeigt nie einen
  veralteten Stand: sobald der Text sich ändert, werden die Befunde als überholt markiert.  Eine
  Unterstreichung an einer Stelle, die inzwischen anders lautet, ist schlimmer als keine.

## 98.6 Abnahme

- **A98-1** Eine Pipeline-Quelle wird im Editor angezeigt, mit Zeilennummern, Monospace und
  Hervorhebung von Schlüsseln, Werten, Kommentaren und Pipeline-Schlüsselwörtern.
- **A98-2** Die Hervorhebung bleibt bei **ungültigem** Text erhalten (F98-4) — nachgewiesen mit
  einer Quelle, die mitten in einem Schlüssel abbricht.
- **A98-3** Bearbeiten über eine Mehrbyte-Stelle hinweg (Umlaut, Emoji) verschiebt Caret, Auswahl
  und Farb-Läufe **gemeinsam** korrekt (F98-3).
- **A98-4** Ein statischer Fehler (z. B. unbekanntes Step-Attribut, aiml F62-65) erscheint in der
  Befundliste mit `zeile:spalte`, und ein Klick markiert genau dieses Token (F98-9).
- **A98-5** Nach einer Textänderung sind die alten Befunde sichtbar als überholt markiert (F98-13).
- **A98-6** `check_pipeline` ohne gültige Anmeldung wird abgewiesen; wiederholte Aufrufe greifen in
  das Limit (F98-10).

## 98.7 Was zuerst

1. aiml: `yaml.tokens` (F98-5) — ohne Token keine Hervorhebung.
2. aiml: Farb-Läufe + Gutter in `ui.text_area` (F98-2/F98-3).
3. aiml: `--check` mit Spalte (F98-8/F98-9).
4. cosmos: `pipeline_editor_screen` + `diagnostics_panel`, Prüfung über RPC (F98-7/F98-10).

Die ersten drei sind aiml-Arbeit und blockieren die vierte.  Reihenfolge nicht tauschen: ein
Editor, der ohne Token und ohne Spalten gebaut wird, bekommt beides nachträglich nicht sauber
eingezogen.

## 98.8 Nachtrag aus der ersten Aufnahme

Die Prefab-Scenes sind gebaut und headless aufgenommen (`tools/ui_shot.sh`, Bilder in
[ui/shots/](ui/shots/)).  Zwei Dinge, die erst im Bild sichtbar wurden:

- **F98-14** ✅ **behoben.** Der `textbox` verschluckte führende Leerzeichen.  Die YAML-Einrückung der
  Beispiel-Pipeline ist in [ui/shots/PipelineScene.png](ui/shots/PipelineScene.png) vollständig
  weg — `name: build_matrix` steht auf derselben Spalte wie `- pipeline:`.  Für Chat- und
  Ereignisprotokolle, wofür der `textbox` gedacht ist, ist das harmlos; für Quelltext macht es ihn
  unbrauchbar.  Behoben in `wrap_text_lines` (aiml `src/sys/prefab_runtime.cpp`): der führende
  Leerzeichen-Lauf einer Quellzeile bleibt erhalten, nur Leerraum **zwischen** Wörtern fällt noch
  zusammen, und eine durch Umbruch entstandene Folgezeile beginnt ohne Einrückung.  Die
  Auswahl-Abbildung (`tb_build_caret_stops`) zieht mit: in der Einrückung 1:1, danach wie bisher
  ein gerendertes Leerzeichen je zusammengefasstem Lauf.  Dokumentiert in aiml `spec/44_6`.
  Das bleibt ein unabhängiger Grund für F98-2 — Einrückung **erhalten** ist etwas anderes als
  einfärben können.
- **F98-15** ✅ **behoben.** Der Standard-Font ist proportional, und das Prefab-System hatte
  **einen globalen** Font (`prefab_set_font`) — die TTF allein genügte also nicht.  Neu in aiml:
  `engine.prefab_add_font(name, font)` plus `font: "<name>"` am Kind (`spec/44_6`).  cosmos legt
  `assets/fonts/mono.ttf` (DejaVu Sans Mono) ab, registriert ihn unter `mono` und setzt ihn auf
  `src_box` und `diag_box`.  Ein unbekannter Name fällt auf den Szenen-Font zurück.  Ohne das
  stimmten Spaltenangaben aus `--check` (F98-9) optisch nicht mit dem Text überein.

Der Rahmen um die drei Boxen ist nachgetragen, weil leere `textbox`-Felder sonst unsichtbar sind
und das Layout im Bild nicht lesbar war.

## 98.9 Ansichts-Inventar der ganzen App

Dieses Kapitel hat bisher den Editor festgelegt.  Hier steht die **Gesamtheit** der Ansichten,
abgeleitet aus dem, was die Kapitel 90–97 an Begriffen eingeführt haben.  Alles, was nicht hier
steht, ist auch nicht vorgesehen.

### 98.9.1 Navigationsmodell: durchgehende Hülle statt Nabe

Heute ist die App eine **Nabe**: das Hauptmenü ist ein eigener Bildschirm, jede Ansicht ersetzt
ihn, „Zurück" führt dorthin.  Das passt zu einem Spiel-Hauptmenü, aber nicht zu einer
Steuerebene, deren Daten sich **laufend** ändern: wer einen Lauf beobachtet und nebenbei einen
Knoten prüfen will, verliert beim Wechsel den Kontext und muss zweimal navigieren.

- **F98-16** ✅ **gebaut** (`ShellScene` + `client/shell_screen.aiml`).  Die Oberfläche bekommt eine **durchgehende Hülle**: Kopfzeile mit den Hauptbereichen,
  linke Spalte mit dem Inhalt des aktuellen Bereichs, Statuszeile unten.  Ansichten wechseln
  **innerhalb** der Hülle; es gibt kein Hauptmenü als Bildschirm mehr und kein „Zurück" als
  Grundbewegung.  Layout-Referenz: [ui/01_shell.svg](ui/01_shell.svg).
- **F98-17** ✅ **gebaut** (`set_status`: Verbindungspunkt, Agentenzahl, Laufzeile).  Die Hülle zeigt dauerhaft drei Dinge, weil sie den Zustand des Systems ausmachen und
  nicht in einer Unteransicht versteckt gehören: Verbindungszustand zum Server, Zahl der
  verbundenen Agenten, und ob ein Lauf aktiv ist.
- **F98-18** ✅ **gebaut** (Bereich 4 = Start/Account).  `MainMenuScene` bleibt als **Startbildschirm nach dem Login** erhalten (Logo,
  Einstieg), wird aber nicht mehr Durchgangsstation.  Die vorhandenen vier Knöpfe werden zu den
  vier Bereichen der Kopfzeile.

### 98.9.2 Bereiche und Ansichten

| # | Ansicht | Zweck | Quelle | Stand |
|---|---|---|---|---|
| 1 | `login` | Anmelden, Token speichern | `90` Auth | **da** |
| 2 | `shell` | Kopfzeile, Bereichswechsel, Statuszeile | — | **da** |
| 3 | `pipelines/list` | Pipelines eines Projekts | `62` | **da** (Teil von `PipelineScene`) |
| 4 | `pipelines/edit` | Quelle bearbeiten, prüfen, starten | `62`, §98.2–98.4 | **teilweise** — editierbar mit Gutter und Hervorhebung; Prüfung noch nicht angebunden |
| 5 | `pipelines/diagnostics` | Befundliste mit Sprung an die Stelle | §98.4 | **teilweise** — Platzhalter |
| 6 | `runs/list` | Läufe mit Status, Dauer, Trefferquote | `96` §96.10 | **da** (Teil von `RunsScene`) |
| 7 | `runs/matrix` | die Matrix als 3D-Szene | `97` | fehlt |
| 8 | `runs/step` | ein (Schritt, Lane): Log, stderr, Exit-Code, Schlüssel, Treffer/Lauf | `96` §96.6 | **da** (Teil von `RunsScene`) |
| 9 | `runs/control` | anhalten, fortsetzen, abbrechen, Freigabe-Tor | `96` §96.11 | **teilweise** — Knöpfe da, RPCs fehlen |
| 10 | `cluster/overview` | Knoten, Workloads, Pipelines | `01` | **da** (nur lesend) |
| 11 | `cluster/node` | ein Knoten: Labels, Slots, Agent-Version, Isolationsstand | `94` | fehlt |
| 12 | `agents/list` | Agenten live, Kommando, Ausgabe | `90` | **da** |
| 13 | `agents/provision` | Einrichten über SSH+sudo, Entfernen | `94` | **da** (Overlay) |
| 14 | `agents/tokens` | Token anlegen, widerrufen | `90` §323 | **da** (Overlay) |
| 15 | `cache/overview` | Layer-Cache: Größe, Trefferquote, unzuverlässige Schlüssel | `96` §96.5 | fehlt |
| 16 | `hosts/values` | `host:`-**Namen** verwalten und Werte setzen | `62` F62-17 | fehlt |
| 17 | `audit` | wer hat gestartet, angehalten, abgebrochen, eingerichtet | `96` F96-11 | fehlt |
| 18 | `account` | E-Mail, Passwort, Sprache | — | **da** (Overlay) |

- **F98-19** `runs/step` (8) ist die wichtigste **fehlende** Ansicht.  Alles andere zeigt Zustand;
  diese zeigt, **warum** etwas fehlgeschlagen ist, und ohne sie ist die 3D-Matrix hübsch und
  nutzlos (F97-10).  Sie kommt vor (7).
- **F98-20** `hosts/values` (16) zeigt **Namen und Herkunft**, niemals Werte.  Ein gesetzter Wert
  erscheint als „gesetzt am …", nie im Klartext und nie beim Bearbeiten erneut — Werte gehen nur
  **hinein**.  Das ist dieselbe Regel wie F98-11 von der anderen Seite: die Pipeline-Quelle ist
  harmlos, **weil** die Werte woanders liegen, und dieses „woanders" darf sie nicht wieder
  ausgeben.
- **F98-21** `cache/overview` (15) zeigt auch die als **unzuverlässig** markierten Schlüssel aus
  dem verify-Modus (F96-5) und erlaubt ihre Freigabe.  Ohne Oberfläche dafür ist die Markierung
  eine Sackgasse: ein Schritt, der einmal gelogen hat, bliebe für immer gesperrt.

### 98.9.3 Durchgehende Regeln

- **F98-22** Jede Ansicht sagt, **wie alt** ihre Daten sind.  Live-Ansichten (Läufe, Agenten,
  Cluster) laufen über Mirror-Push; wo das abreißt, erscheint der Zustand als *veraltet*, nicht
  als aktuell.  Eine Steuerebene, die stillschweigend alte Zahlen zeigt, ist schlimmer als eine,
  die „keine Verbindung" sagt.
- **F98-23** Zerstörende Handlungen — Lauf abbrechen, Agent entfernen, Token widerrufen,
  Cache-Eintrag löschen — brauchen eine Bestätigung, die **benennt, was getroffen wird** („Agent
  `builder-arm` entfernen, 1 laufende Lane") statt „Sind Sie sicher?".
- **F98-24** Ausgegraute oder fehlende Knöpfe sind **Bequemlichkeit, keine Sicherheit**: jede
  Handlung wird serverseitig erneut geprüft (F96-11).  Die Oberfläche darf nie die einzige Stelle
  sein, an der eine Berechtigung durchgesetzt wird.
- **F98-25** Fehler erscheinen **an der Stelle, an der sie entstanden sind** — ein fehlgeschlagener
  RPC am auslösenden Knopf, ein Compile-Befund an seiner Zeile —, nicht als globale Meldung, die
  man wegklickt und dann nicht mehr findet.

### 98.9.4 Reihenfolge

1. **Hülle** (2) — alles Weitere hängt daran, und sie zu verschieben heißt, jede neue Ansicht
   zweimal einzuhängen.
2. **`runs/list` (6) + `runs/step` (8)** — damit wird ein Lauf überhaupt nachvollziehbar.
3. **Editor** (4/5) nach §98.7 Schritte 1–3 (aiml-Arbeit: `yaml.tokens`, Gutter + Farb-Läufe,
   `--check`).
4. **`runs/control` (9)**, dann **`cluster/node` (11)** und **`cache/overview` (15)**.
5. **`runs/matrix` (7)** — die Szene zuletzt, weil sie ohne (8) nur schön ist.
6. **`hosts/values` (16)** und **`audit` (17)** mit der ersten Mehrbenutzer-Nutzung.


## 98.10 Nachtrag aus dem Bau der Hülle

- **F98-26** Der aktive Bereich **muss** in der Kopfzeile erkennbar sein.  Ohne Markierung ist eine
  Hülle nur eine Leiste: man sieht, wohin man kann, aber nicht, wo man ist.  Umgesetzt über
  `set_bg_color`/`set_border_color`/`set_color` am Bereichsknopf.
- **F98-27** Die Bereichs-Scenes liegen bei `y=48` und dürfen lokal höchstens **636** hoch sein
  (Kopfzeile 48, Statuszeile 36).  `ClusterScene`, `AgentsScene` und `PipelineScene` sind darauf
  eingekürzt; neue Ansichten werden gleich für 1280×636 entworfen.
- **F98-28** „Zurück" entfällt als Grundbewegung.  Ein Bereich wechselt über die Kopfzeile; der
  `back_btn` der `PipelineScene` ist entfernt.  Wo eine Ansicht eine echte Rückkehr braucht (aus
  einem Schritt-Detail in die Lauf-Liste), ist das eine Bewegung **innerhalb** des Bereichs und
  heißt nicht „Zurück", sondern nennt das Ziel.

- **F98-29** `runs/list` und `runs/step` sind **eine** Ansicht (`RunsScene`), aus demselben Grund
  wie Editor und Befundliste (F98-12): ein Schritt-Detail ohne seinen Lauf daneben ist nicht
  einzuordnen, und ein Sprung, der die Ansicht wechselt, verliert den Zusammenhang.
- **F98-30** Der Status steht dort vorerst als **Wort**, nicht als Farbe.  Die Bedeutung der sechs
  Werte ist in aiml `spec/62` §15 Punkt 6 offen; sie nebenbei durch die Oberfläche festzulegen
  wäre die falsche Reihenfolge.
