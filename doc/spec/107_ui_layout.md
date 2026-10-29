# 107 — Der Aufbau der Oberfläche

Auftrag (User, 2026-10-15): *„du schreibst irgendwie lauter Text in lauter Felder, Zielbild
ist aber ein jenkins-like UI: jobfolders on top, andauernde Prozesse rechts, oben rechts
System und User Settings als Buttons. Im Moment haben wir ein ziemliches Durcheinander, die
großen Buttons im Hauptmenü haben keine Funktion."*

## 107.0 Was schiefgelaufen ist

Die Oberfläche ist gewachsen, statt entworfen zu werden: jede neue Aussage bekam ein neues
Textfeld, und der Hauptbildschirm blieb ein **Startmenü** mit vier großen Knöpfen, die
nirgends hinführen. Das Ergebnis ist eine Sammlung von Kästen, kein Werkzeug.

**F107-1: Textfelder sind das letzte Mittel, nicht das erste.**  Ein Textkasten ist richtig
für Fliesstext (Quelle, Protokoll). Für Listen mit Zustand — Jobs, Läufe, Agenten — ist er
eine Notlösung: nicht sortierbar, nicht anklickbar, ohne Zustand je Zeile. Wo eine Liste
gemeint ist, gehört eine Liste hin.

## 107.1 Die Flächenaufteilung

Eine Anordnung, überall gleich, damit man nicht in jedem Bildschirm neu suchen muss:

```
┌──────────────────────────────────────────────────────────────┬───────────┐
│ cosmos   Jobs · Läufe · Cluster · Agenten        [System][Ich]│           │  Kopf 56px
├──────────────────────────────────────────────────────────────┤  Läuft    │
│ [ alle ] [ build ] [ deploy ] [ + ]                           │  gerade   │  Ordner 40px
├──────────────────────────────────────────────────────────────┤           │
│                                                               │  je Agent:│
│   Hauptfläche: Jobliste, Lauf, Gitter, Editor …               │  Name     │  rechte
│                                                               │  Zustand  │  Spalte
│                                                               │  Tätigkeit│  320px
├──────────────────────────────────────────────────────────────┴───────────┤
│ Stand: vor 2 s · 3/4 Agenten verbunden · 2 Läufe aktiv                    │  Fuss 28px
└───────────────────────────────────────────────────────────────────────────┘
```

**F107-2: Der Kopf trägt die Navigation, nicht die Hauptfläche.**  Die vier großen Knöpfe
entfallen; ihre Ziele werden Einträge im Kopf. Ein Startmenü, das nur weiterleitet, ist eine
Station ohne Inhalt — und genau das waren sie.

**F107-3: System und Konto sitzen oben rechts**, immer an derselben Stelle, als Knöpfe mit
Beschriftung. Ihre **Stelle** ist nicht die Reiterleiste — das eine ist Arbeit, das andere
Verwaltung.  Ihr **Weg** ist seit §107.6 derselbe wie bei jedem Reiter: ein Bereichswechsel,
kein Overlay.

**F107-4: Die rechte Spalte gehört dem Dauerzustand.**  Was gerade läuft und wer daran
arbeitet, bleibt **immer** sichtbar — in jeder Ansicht, auch im Editor. Das ist der Grund,
warum sie eine Spalte ist und kein Bildschirm: man schaut ständig hin, ohne wegzunavigieren.
Sie nennt Agenten **mit Namen** (doc/spec/106 F106-3).

**F107-5: Die Ordnerleiste zeigt Job-Ordner**, mit „alle" als erstem Eintrag. Ein Ordner ist
ein Namenspräfix (`build/api`, `deploy/web`), kein eigenes Modell — Jenkins macht daraus
einen Baum, wir beginnen mit einer Leiste, weil ein Baum ohne Ordner-Verwaltung nur ein
leerer Baum wäre.

**F107-6: Die Fusszeile trägt den Stand des Schnappschusses** (doc/spec/104 F104-6) und die
zwei Zahlen, die man im Blick behält: verbundene Agenten, aktive Läufe.

**F107-8: Die Hülle besitzt ihre Ränder, der Bildschirm die Mitte.**  (Seit F107-12 ohne
rechte Spalte: die Inhaltsfläche reicht bis x 1260.)  Kopf (y 0–48),
Ordnerleiste (y 48–84), rechte Spalte (x 960–1280) und Fußzeile (y 684–720) gehören der
Hülle.  Ein Bildschirm zeichnet **ausschließlich** in die Inhaltsfläche **x 20–940,
y 92–676** und hat dort **keinen eigenen Kopf mit Navigation** — die steht oben.

Das ist keine Formsache: die Bildschirme entstanden vor der Hülle, für die ganze Fläche
von 1280×720.  Nach dem Einziehen der Hülle lagen ihre Kopfzeilen (y 24–64) **unter** der
Navigationsleiste und ihre rechten Spalten **hinter** der Dauerzustands-Spalte.  Gemessen am
2026-10-15: 36 Kinder über fünf Szenen lagen außerhalb, darunter der **Start-Knopf** des
Job-Editors — der Benutzer konnte ihn nicht finden, weil er nicht fehlte, sondern verdeckt
war.  Ein Knopf, den die Oberfläche zeichnet und niemand erreicht, ist schlimmer als keiner.

**F107-9: Jobs und Läufe stehen unter einem Hut.**  Ein Lauf gehört immer zu einem Job
(doc/spec/106 §106.1); zwei gleichrangige Reiter „Pipelines" und „Läufe" zerreißen diesen
Zusammenhang und zwingen zum Hin- und Herspringen.  Darum wie bei Jenkins:

- **Jobs** ist die Startfläche: die Liste.
- Ein Klick öffnet die **Job-Seite** — Quelle, Auslöser **und die Läufe dieses Jobs**
  zusammen auf einem Schirm.
- **Läufe** war als *globaler* Strom über alle Jobs gedacht.  **Gestrichen am 15.10.2026**
  (F107-10): er war der Ort, an dem Läufe doch wieder ohne ihren Job standen, und die Frage
  „was passiert gerade?" beantwortet die **Fußzeile** auf jedem Schirm (F107-6) — mit Namen
  dann die Job-Seite.

Der eigene Reiter „Pipelines" entfällt: die Job-Seite erreicht man über ihren Job.  Damit
ein frischer Server nicht ohne Weg dasteht, trägt die Jobliste einen **Neuer Job**-Knopf —
ohne ihn wäre der Editor nur über einen Job erreichbar, den es noch nicht gibt.

## 107.1a Die Lauf-Ansicht: drei Spalten (F107-10)

Vorgabe des Nutzers (15.10.2026).  Die Job-Seite **ist** die Lauf-Ansicht:

```
┌──────────────── Kopf: Job-Name · Starten · Quelle… ────────────────┐
│ Läufe            │ Ausgabe                      │ Pipeline        │
│ #12  15.10 21:03 │ + make -j8                   │  ┌────┐ ┌────┐  │
│ #11  15.10 20:41 │ cc -c main.c                 │  │chk │→│bld │  │
│ #10  14.10 23:12 │ …                            │  └────┘ └────┘  │
│ (Datum+Nummer)   │ (tail, mono)                 │ (klickbar)      │
└───────────────────────────────────────────────────────────────────┘
```

- **Links: alle Läufe dieses Jobs**, neueste oben, je Zeile **Nummer und Datum** plus
  Ergebnis.  Ein Klick wählt den Lauf.
- **Mitte: die Ausgabe** — `stdout`/`stderr` des gewählten **Schritts**, vom Server
  (doc/spec/103 F103-19), nachgeladen in Fenstern und am Ende festgehalten (`tail`).
- **Rechts: die Pipeline des gewählten Laufs** als Gitter aus Knoten, mit der Farbe ihres
  Zustands.

**F107-11: Der Graph ist das Auswahlmittel für die Ausgabe.**  Ein Klick auf einen Knoten
füllt die Mitte mit der Ausgabe genau dieses Schritts.  Damit ist die Frage „warum ist der
Lauf rot?" ein Klick weit entfernt, nicht ein Login auf dem Agenten.  Ohne Auswahl zeigt die
Mitte den **ersten nicht erfolgreichen** Schritt — das ist fast immer der gesuchte.

**Der Quelltext bleibt eine eigene Seite** („Quelle…" im Kopf).  Drei Spalten *und* ein
Editor auf 584 px Höhe hiesse, beides zu quetschen; das Bearbeiten ist ausserdem der
seltenere Vorgang.  Ein Lauf braucht die Quelle nicht, um lesbar zu sein — er braucht seine
Ausgabe.

**F107-12: Die rechte Spalte ist gestrichen** (15.10.2026, Vorgabe des Nutzers).  F107-4 hatte
sie als Dauerzustand gedacht: „Läuft gerade" und „Ausführende" immer sichtbar, ohne
wegzunavigieren.  Gemessen am Platz war das ein schlechter Tausch — **320 px auf jedem
Schirm**, meist leer, während die drei Spalten der Lauf-Ansicht (F107-10) sich auf 920 px
drängten.  Ausgabe und Pipeline sind das, was man liest; eine Spalte, die in den meisten
Augenblicken „Nichts läuft gerade." sagt, ist es nicht.

Was davon bleibt und wo:

| Frage | jetzt |
|---|---|
| Läuft gerade etwas? | Fußzeile, dauerhaft (F107-6) |
| Welcher Lauf, welche Stufe? | Job-Seite: Läufe-Spalte und Graph (F107-10) |
| Wer führt aus? | Reiter **Agenten** — dort steht ohnehin die ganze Verwaltung |

Die Inhaltsfläche ist damit **x 20…1260**; F107-8 gilt sonst unverändert (Kopf, Fußzeile).

## 107.1b Die Pipeline in 3D — Kugeln, Rohre, Trommeln (F107-13)

Vorgabe des Nutzers (15.10.2026): die Pipeline-Spalte soll **räumlich** sein, mit echten
Rohren und Kugeln; Datenbanken (KV) und Knoten gehören ebenfalls ins Bild.

### Die Bildsprache

| Ding | Form | Warum diese Form |
|---|---|---|
| Schritt | **Kugel** | ein Zustand an einem Ort — keine Richtung, keine Kante, nichts zu lesen |
| Verbindung | **Rohr** | Reihenfolge ist Fluss; ein Rohr hat eine Richtung, eine Linie nicht |
| Lane | Reihe von Kugeln entlang **+X** | die Matrix bleibt als Gitter lesbar (doc/spec/97) |
| KV-Speicher | **Trommel** (Zylinder) | das verbreitete Datenbank-Zeichen, auch ohne Beschriftung erkannt |
| Knoten / Agent | **Quader** mit Einschüben | eine Maschine, kein Datending |

**F107-13: Die Form trägt die Art, die Farbe den Zustand.**  Wer den Schirm von der Seite
sieht, soll *Pipeline* erkennen, bevor er ein Wort liest.  Die sechs Farben sind dieselben
wie in der Liste links (`status_color`) — zwei Farbsprachen auf einem Schirm wären eine zu
viel.

**F107-14: Bewegung bedeutet genau eine Sache — es läuft.**  Im Rohr vor einer laufenden
Stufe wandern helle Bänder; alles andere steht still.  Eine Oberfläche, die dauernd
animiert, sagt nichts mehr aus; eine, die sich nur bei Arbeit rührt, ist von weitem lesbar.

Ein fließendes Rohr ist deshalb eine **eigene Art** (`kind 5`) und kein Flag neben der Art:
die Art steuert ohnehin schon Körper und Shader-Zweig, ein zweiter Schalter für dieselbe
Entscheidung wäre einer zu viel.

Geprüft wird das **gemessen**, nicht nach Augenschein: `tools/pipe3d_flow_check.sh` nimmt
zwei Phasen auf und vergleicht die Pixelsumme aus `gl.read_rgba8`.  Der Umweg lohnt, weil
der Augenschein hier getrogen hat — siehe unten.

### Technik

- **Ein Shader für alles**, mit `uKind` (Kugel / Rohr / Trommel / Quader): Lambert + Rim,
  und für Rohre ein Fluss-Band entlang der Rohrachse.  Zwei Programme für zwei Formen wären
  zwei Orte für dieselbe Beleuchtung.
- **Einheits-Meshes, viele Instanzen**: je Form ein Mesh, gezeichnet mit `uModel`/`uColor`
  je Objekt.  Bei unter hundert Objekten ist das die ehrliche Wahl — `draw_elements_instanced`
  spart hier nichts und kostet einen Attribut-Puffer, der mitgepflegt werden muss.
- **Gezeichnet wird NACH der 2D-Oberfläche**, in `gl.viewport` auf das Pipeline-Feld, mit
  eigenem `gl.clear_depth`.  Der Prefab-Pass kennt keine Tiefe; die Reihenfolge ist deshalb
  die einfachste Trennung und braucht weder Framebuffer noch Scissor.
- **Auswahl analytisch**: Strahl gegen Kugel.  Eine Kugel ist in geschlossener Form
  schneidbar — eine Pick-Textur (zweiter Pass, Rücklesen, Synchronisationspunkt) wäre für
  dieses Bild Aufwand ohne Gewinn.  Der Klick wählt denselben Schritt wie vorher (F107-11),
  die Ausgabe in der Mitte bleibt die Antwort.

**F107-15: Der Raum hat zwei Größen.**  In der Spalte ist er 350 px breit — genug, um den
Zustand zu sehen, zu wenig, um zu drehen und zu lesen.  Der Schalter **groß** gibt ihm die
ganze Inhaltsfläche; Läufe und Ausgabe treten so lange zurück.  Sie **verschwinden**, statt
zu schrumpfen: eine halb sichtbare Spalte ist schlechter als keine, und der Weg zurück ist
ein Klick.

Dabei gilt: die **Auswahl** des Laufs bleibt bestehen, nur seine Liste wird geleert.  Ein
Container spawnt nach seiner Liste, nicht nach der Sichtbarkeit seiner Fläche — wer nur die
Fläche versteckt, hat die Zeilen weiterhin im Bild (und unter dem Zeiger).

### Eine Lehre über Prüfstände

Der Fluss schien stundenlang stillzustehen, und die Suche ging durch Shader, Uniforms und
Modellfelder.  Keines davon war schuld: das **Aufnahme-Werkzeug** startete `Xvfb` auf einer
festen Anzeigenummer, und wenn der Vorlauf sie noch hielt, scheiterte der neue Lauf mit
`glfwInit failed` — der Bildschirmgreifer kopierte daraufhin seelenruhig das **alte** Bild.
Zwei Aufnahmen waren dann byteweise gleich, und jede Messung „bewies" Stillstand.

Daraus zwei Regeln, die hier gelten:

- **Ein Prüfstand, der stillschweigend das letzte Ergebnis wiederholt, ist schlimmer als
  keiner.**  `tools/pipe3d_shot.sh` nimmt jetzt eine freie Anzeigenummer, wartet auf den
  Server und **bricht ab**, wenn die Probe nicht durchlief.
- **Gemessen wird am Ergebnis, nicht am Fenster.**  Die Pixelsumme kommt aus
  `gl.read_rgba8`; sie kann nicht von einem Fenstergreifer verwechselt werden.

### Die Meshes kommen aus ShapeML, wo es sich lohnt

Kugel und Rohr sind **parametrisch** erzeugt (Breiten-/Längengrade, Ringe): für zwei
Grundkörper ist eine Formel kürzer, genauer und braucht keine Datei neben dem Programm.
Trommel und Quader-Rack sind **Modelle** — Fasen, Einschübe, Füße —, und dafür gibt es
ShapeML (`test/shaper`).  Die Regel: **was eine Formel vollständig beschreibt, bleibt
Formel; was ein Mensch entwirft, wird ein Modell.**

## 107.1c Die Schichten, die ein Lauf hinterlässt (F107-30 ff.)

Vorgabe des Nutzers (22.10.2026): im Raum soll auch zu sehen sein, **was dabei entsteht** — die
Schichten, und darunter die, die beim nächsten Lauf schon feststehen.

Die Pipeline-Syntax sagt das Bild bereits vor:

> „A changed input changes the key transitively, **which is what makes a chain of steps behave
> like a stack of layers**."  (aiml `spec/62` §8)

Gezeichnet wird also nichts Erfundenes, sondern diese Kette — mit dem Vokabular, das die Syntax
schon hat: `cache: pure | resolved | opaque` (Vorgabe `opaque`, aiml §7) und der Frage, ob der
Schlüssel heute einen Eintrag hat.

### Die Bildsprache, erweitert

| Ding | Form | Warum |
|---|---|---|
| Schicht einer Stufe | **Platte** unter ihrer Kugel | ein Dateisystem-Zuwachs ist flach und liegt auf dem, was vorher da war |
| Stapel | Platten nach **−Y**, in Laufreihenfolge nach **+X** | der Stapel wächst nach unten, während der Lauf nach rechts läuft |

- **F107-30: Die Platte sagt die GRÖSSENORDNUNG, nicht die Bytes.**  Die Schichten eines echten
  Laufs liegen zwischen 0 B (`basis_zeigen`) und 1,5 GB (`aiml_bauen`) — linear wäre alles außer
  der Bau-Schicht unsichtbar, und eine Zahl liest man im Raum sowieso nicht.  Darum eine **Leiter**
  mit sechs Stufen (leer, <1 MB, <10 MB, <100 MB, <1 GB, ≥1 GB).  Wer Bytes braucht, klickt die
  Platte an; wer hinsieht, soll „die Bau-Stufe ist das Dicke hier" in einer Sekunde haben.
- **F107-31: Die Oberfläche trägt die HERKUNFT.**  Form sagt die Art, Farbe den Zustand
  (F107-13) — für „liegt schon im Speicher" ist damit kein Kanal frei, und eine zweite Farbsprache
  wäre eine zu viel.  Also die Oberfläche: eine **gerillte** Platte liegt bereits als Block im
  Speicher (inhaltsadressiert, beim nächsten Lauf nicht neu zu schreiben), eine **glatte** ist in
  diesem Lauf entstanden.  Die Rillen sind dasselbe Zeichen wie an der Trommel (§107.1b) — dort
  heißen sie Speicher, hier auch.
- **F107-32: Was NIE wiederverwendbar ist, liegt neben dem Stapel.**  Eine Stufe mit
  `cache: opaque` (die Vorgabe!) kann nach aiml §7 nicht wiederverwendet werden — ihre Platte
  liegt deshalb leicht **versetzt** neben der Achse des Stapels und schließt ihn nicht.  Das ist
  die ehrlichste Form der Vorgabe „nichts wird wiederverwendet, bis jemand es behauptet": man
  sieht am Bild, dass der Stapel an dieser Stelle nicht trägt.
- **F107-33: Keine Bewegung an Schichten.**  Bewegung heißt genau eine Sache — es läuft (F107-14).
  Eine Schicht, die beim nächsten Lauf feststeht, ist das Gegenteil von Bewegung; sie ist still.

### Woher die Daten kommen (seit 22.10.2026: aus dem Lauf)

Jede Stufe bekommt ihren eigenen overlayfs-`upper` (doc/spec/110 F110-93); der `upper` **ist**
die Schicht.  Die Kette, Ende zu Ende:

1. **Der Agent misst.**  Nur er kann es — die Schicht liegt auf seinem Wirt.  `DirScan`
   (`sources/shared/dir_stat.aiml`) zählt Bytes und Dateien des `upper`, direkt bevor der
   Bericht rausgeht.
2. **Der Bericht trägt sie.**  `StepReportReq.layer_bytes/layer_files` — kein zweiter Kanal für
   denselben Umstand, und kein zweiter Augenblick.
3. **Der Controller legt sie NEBEN den Lauf.**  KV `run_layers`, Datensatz `RunLayers`.  Nicht
   in `PipelineRun`: ein neues Feld dort ändert den Schema-Fingerprint, und jeder gespeicherte
   Lauf wäre unlesbar (doc/spec/108 F108-2).
4. **Der Schnappschuss nimmt sie mit.**  `ClusterView.layers`, im gleichen Push wie die Läufe
   (§104.0), und die Push-Signatur sieht sie (F107-44), sonst wäre das Bild per Bauart veraltet.
5. **Die Ansicht zeichnet sie.**  `JobRunsScreen.rebuild_bodies` siebt die Zeilen des gewählten
   Laufs heraus und ruft `PipeScene.layers_of` — dieselbe Rechnung, die `test_pipe_scene`
   fensterlos prüft.

- **F107-50: Gemessen wird die LOGISCHE Größe, nicht der belegte Platz.**  Blockgröße und
  Dateisystem sind Eigenschaften des Wirts; dieselbe Schicht wäre auf zwei Rechnern verschieden
  groß, und die Platte im Bild würde eine Aussage über den Wirt machen, wo sie eine über die
  Stufe machen soll.  Ein Symlink zählt als Datei, nicht als Bytes — sein Ziel liegt woanders.
- **F107-51: Eine Stufe hat EINE Platte, auch nach dem Wiederlauf.**  Meldet dieselbe Stufe
  erneut, wird ihre Zeile ERSETZT, nicht angehängt (doc/spec/110 F110-97).  Zwei Platten für
  eine Stufe wären ein Bild, das es nicht gibt.
- **F107-52: `reuse` und `stored` bleiben, was die Pipeline SAGT — nichts.**  Die Vorgabe ist
  `opaque` (aiml `spec/62` §7), und `stored = 0` heißt „niemand hat im Speicher nachgesehen".
  Eine 1 dort wäre eine Behauptung über den nächsten Lauf, für die es heute keine Messung gibt;
  die Rillen aus F107-31 bleiben darum vorerst ungenutzt, statt falsch zu stehen.

- **F107-34: Die Szene ist DATEN und wird ohne Fenster geprüft.**  Wie MatrixView und Dashboard
  (§107.1b): `PipeScene.layers_of` rechnet Platten aus Stufen + Schichtangaben, und
  `test/test_pipe_scene.aiml` prüft Lage, Dicke und Oberfläche ohne GL.  Ein Bild beweist, dass
  es *aussieht* wie gemeint; der Test beweist, dass es *gemeint* ist.

## 107.1d Haltepunkte: Flaggen an den Rand (F107-35 ff.)

Vorgabe des Nutzers (22.10.2026): *„wenn man so eine Art Flaggen auf die Kugel setzen könnte,
um ähnlich wie in einem Debugger Breakpoints zu setzen"* — und gleich darauf die Korrektur:
*„wir machen die Flagge lieber auf die Pipe, weil sonst ist nicht deutlich, wo angehalten
wird."*

Die Korrektur trifft die Sache genauer als der erste Entwurf: ein Lauf hält **am Stufen-Rand**
(aiml `spec/62` F62-53), und der Rand **ist** das Rohr.  Eine Flagge an der Kugel ließe offen,
ob davor oder danach gehalten wird; am Rohr ist es eindeutig.

- **F107-35: Die Flagge steht am Rohr, das in die Stufe führt.**  Damit auch die **erste** Stufe
  einen Rand hat, bekommt jede Lane ein kurzes **Einlaufstück** — ohne es hätte eine Flagge vor
  der ersten Stufe nichts, woran sie hängt.
- **F107-36: Die Flagge weht — und das ist eine ANNAHME der Regel F107-14.**  Dort steht:
  Bewegung bedeutet genau eine Sache, es läuft.  Eine Flagge, die nicht weht, wird aber nicht als
  Flagge gelesen (Vorgabe des Nutzers), und ihr Wehen behauptet keinen Fortschritt: es ist
  **örtlich**, klein und sagt „hier ist ein Zeichen", nicht „hier arbeitet etwas".  Die Regel
  gilt weiter für alles, was einen Zustand trägt — Rohre, Kugeln, Platten stehen still, wenn
  nichts läuft.  Nachgewiesen wird das Wehen **gemessen**, nicht nach Augenschein: `P3D_SCENE=flagge`
  rendert nur die Flagge, zwei Phasen, Pixelsummen 250 437 vs. 250 294 (die Lehre aus §107.1b —
  in der vollen Szene bewegt sich auch der Fluss, und dann beweist eine Differenz nichts).
- **F107-37: Das Tuch ist entworfen, der Rest gerechnet.**  Ein Quader weht nicht; eine Bahn
  braucht Unterteilungen, damit eine Welle über sie laufen kann.  Darum `shapes/cosmos_flag.shaml`
  (ShapeML 2, `type: surface` mit `subdivisions: 5`) → `assets/shapes/cosmos_flag.glb`, Mast und
  Knauf gleich mit: ein Modell, das sich zusammen bewegt, wenn die Kamera schwenkt.  Die
  Auslenkung wächst **quadratisch** mit `u` — am Mast sitzt das Tuch fest, zur Spitze schlägt es
  aus; linear sah es aus, als hinge es schief.
- **F107-38: Violett ist der sechste Zustand.**  `paused` brauchte eine eigene Farbe, weil
  grün/gelb/blau/rot vergeben sind — ein Zustand ohne eigene Farbe ist einer, den man nicht
  sieht.  Die Flagge trägt genau diese Farbe, also bleibt es **eine** Farbsprache (F107-13).

### Was die Flagge im Hintergrund ist

Keine zweite Liste neben den Stufen (die wäre die zweite Wahrheit), sondern der **Zustand der
Stufe dahinter**: `paused` heißt „diese wird nicht zugeteilt" — damit steht das Tor der Zuteilung
schon, ohne eine Zeile Sonderbehandlung.  Dabei fiel auf, dass ein neues Wort nicht genügt, es
muss auch **rückwärts** lesbar sein: `pipe_status_of` kannte `paused` nicht und gab `unknown`
zurück — eine Stufe mit Flagge war damit zustandslos, der Lauf hieß „wartet auf einen Agenten",
und drei Prüfungen fielen um, bis das Wort an **einer** Stelle vollständig war (genau die Regel,
für die `pipe_status.aiml` angelegt wurde).

## 107.1e Was im Bild NICHT hilft (22.10.2026)

Drei Beschwerden des Nutzers am ersten vollständigen Rendering im Browser, und alle drei
stimmten.

- **F107-41: Die Speicher gehören dem Controller, nicht dem Lauf.**  Die Lauf-Ansicht zeigte
  jeden KV-Speicher als Trommel — als es drei waren (§107.1b), war das Beiwerk; inzwischen sind
  es rund zwanzig, und sie standen als **endlose Reihe bis über den Boden hinaus**.  Welche KVs
  der Controller führt, sagt über einen Lauf nichts: sie sind jetzt nur noch im Cluster-Bild
  (§107.5a), wo der Controller das Thema ist.  Dort brechen sie nach acht je Zeile um, statt
  geradeaus weiterzulaufen — eine Reihe, die über die Fläche hinausragt, ist kein Diagramm mehr.
- **F107-42: Ein Name, der nicht lesbar ist, ist kein Name.**  F107-16 bleibt gültig — **jeder**
  Körper trägt seinen Namen, sonst ist er im Raum anonym.  Gezeichnet wird das Schild aber nur,
  wo es etwas nützt: an großen Körpern, am Gewählten und an dem, was der Zeiger berührt.
  Zwanzig Schilder auf Briefmarkengröße ergaben keinen Text, sondern einen weißen Streifen quer
  durchs Bild.  Die Regel steht beim **Zeichnen**, nicht in den Daten: ein Test, der prüft, dass
  jeder Körper benannt ist, muss weiter gelten (`test_pipe_scene`).
- **F107-43: Die Quelle war eine Sackgasse.**  Von der Job-Seite führt „Quelle…" zum Quelltext,
  zurück führte nichts — nur die Navigation, und die landet bei der Job-LISTE statt bei dem Job,
  den man vor sich hatte.  Jetzt gibt es „← Job"; der Bildschirm **merkt** den Wunsch, der Wirt
  führt ihn aus (dasselbe Muster wie `take_src`/`take_back`).

## 107.1f Drei Dinge, die „irgendwie komisch" waren (22.10.2026)

- **F107-44: Was die Ansicht zeigt, muss die Signatur sehen — auch die STUFEN.**  Der Server
  pusht einen Schnappschuss nur, wenn seine Signatur sich ändert; die enthielt je Lauf aber nur
  `run_id:status:ended_ms`.  Während ein Lauf läuft, wechseln die **Stufen**, der Lauf bleibt
  `running` — also kein Push.  Die Oberfläche zeigte die erste Kugel gelb und sprang beim Ende
  des Laufs mit einem Schlag auf „alles fertig".  Jetzt gehen Zustand, Versuch und Agent jeder
  Stufe in die Signatur ein.  Das ist **dieselbe** Regel, die am 18.10. schon einmal für die
  Jobliste nachgetragen werden musste; geprüft in `test/test_live_push_sig.aiml` (eine Stufe
  weiter, und ein zweiter Anlauf derselben Stufe).
- **F107-45: Nach „Starten" gehört man zum neuen Lauf.**  `JobAck` trägt die Nummer längst mit,
  der Client benutzte sie nur nicht: die Auswahl blieb auf dem alten Lauf stehen, und das Neue
  passierte unsichtbar daneben.  Beide Startwege (Jobliste und Lauf-Ansicht) springen jetzt
  dorthin — samt Zurücksetzen von Stufe und Protokoll, denn die gehörten dem alten Lauf.
- **F107-46: „Stand vor 497 965 h" war wieder da.**  `got_ms` blieb 0, weil `subscribe_cluster`
  die Sicht **direkt** setzte statt durch `adopt` zu gehen — genau der Fehler, den der Kommentar
  an dieser Stelle seit dem 15.10. beschreibt.  Es gibt EINEN Weg hinein, und wer daran
  vorbeischreibt, bricht die Zeitrechnung: die Fußzeile maß dann gegen 1970.

- **F107-47: Die Mitte läuft der Arbeit hinterher, bis jemand wählt.**  Die Ausgabe blieb bei
  Stufe eins stehen, während Stufe drei arbeitete — man musste von Hand umschalten.  Grund:
  `pick_stage` wählte **einmal** (solange nichts gewählt war) und rührte sich danach nie wieder.
  Jetzt gilt: ohne eigene Wahl zeigt die Mitte den **jetzt** interessanten Schritt
  (`current_stage`: gescheitert → laufend → zuletzt fertig → erster), und ein **Klick** hält sie
  an — wer liest, will nicht weggeschaltet werden.  Ein neuer Lauf fängt wieder an mitzulaufen.
  Der Unterschied zu `first_interesting` ist das Ende: dort kommt nach dem letzten Schritt wieder
  der **erste**, was für eine einmalige Wahl taugt und fürs Mitlaufen nicht.  Geprüft in
  `test/test_dashboard.aiml`.

- **F107-48: Der BEFEHL einer Stufe ist einblendbar, und er darf die Ausgabe verdecken.**
  Vorgabe des Nutzers (22.10.2026): *„ich möchte auch, dass man das kommando irgendwie
  einblenden kann, die ausgabe kann ruhig etwas verdeckt werden."*  Knopf „Befehl" über der
  Ausgabe, Tafel darüber; beim Wechsel der Stufe schließt sie sich, denn ein alter Befehl über
  neuer Ausgabe wäre eine Lüge.  Der Text kommt aus der gewählten Stufe, nicht aus einer zweiten
  Quelle (F104-1).
- **F107-49: Eine Einblendung startet GESCHLOSSEN — deklariert, nicht im ersten Rahmen.**  Ich
  hatte `visible: false` am Prefab weggelassen (in der Annahme, es gäbe das nicht) und wollte
  stattdessen zur Laufzeit verstecken.  Ergebnis: die Tafel lag von Anfang an über der Ausgabe,
  und ein Klick auf eine Stufe „zeigte keine Ausgabe" — sie war verdeckt.  `visible:` gibt es
  (aiml spec/44_6), und die Spec sagt auch warum: *„Declaring the start state beats
  instantiating visible and hiding it in the first frame — that shows one frame of the wrong
  thing."*  Gefunden mit `tools/ui_shot.sh JobRunsScene` — eine headless-Aufnahme beantwortet
  „was zeichnet der Client wirklich?" in zwanzig Sekunden, ohne jemanden zu fragen.

## 107.2 Was in die Hauptfläche kommt

| Ansicht | Inhalt |
|---|---|
| **Jobs** (Vorgabe) | Tabelle: Name, letztes Ergebnis, Dauer, Fehlschläge — eine Zeile je Job |
| **Job-Seite / Lauf** | drei Spalten: Läufe · Ausgabe · Pipeline (F107-10) |
| **Job-Editor** | Name, Quelle, Zeitplan — eigene Seite, über „Quelle…" |
| **Cluster** | Knoten mit Anwesenheit (doc/spec/104) |
| **Agenten** | Einrichten, Token, Rückbau |

**F107-7: Ein Klick auf eine Zeile öffnet sie.**  Eine Liste, die man nicht anklicken kann,
ist eine Tabelle zum Ansehen — und dann braucht sie keine Auswahlmarke, die etwas anderes
verspricht. Solange das Bedienelement fehlt, **nennt** die Ansicht den fehlenden Weg
(„Auswahl folgt"), statt eine Marke zu zeigen, die nichts tut.

## 107.3 Reihenfolge

1. ✅ Kopf mit Navigation + System/Konto (F107-2, F107-3); die vier großen Knöpfe entfallen.
2. ✅ Rechte Spalte „Läuft gerade" in die gemeinsame Hülle (F107-4).
3. ✅ Jobs als Hauptfläche statt Startmenü.
4. ✅ Ordnerleiste (F107-5).
5. ✅ Zeilen anklickbar (F107-7).
6. ✅ Inhaltsfläche einhalten (F107-8) + Jobs/Läufe unter einem Hut (F107-9).
7. ✅ Lauf-Ansicht in drei Spalten, Reiter „Läufe" entfällt (F107-10, F107-11).
8. ✅ Rechte Spalte entfällt, Inhaltsfläche nutzt die volle Breite (F107-12).
9. ✅ Pipeline räumlich: Kugeln, Rohre, Trommeln, Knoten (F107-13, F107-14), mit
   Auswahl per Strahl, Hover-Beschriftung und Vollbild-Schalter (F107-15).

### Umsetzung von Schritt 4 (2026-10-15)

Die Reiter entstehen **aus den Daten**: ein `container` mit `spawn: FolderTab`, gebunden an
`ShellScreen.folders` — „alle" plus jedes Namenspräfix vor dem ersten `/`, das wirklich
vorkommt.  Trägt kein Job ein Präfix, gibt es genau einen Reiter; das ist die Wahrheit über
den Bestand, nicht ein leerer Baum.  Neu aufgebaut wird die Leiste nur bei **echter**
Änderung (Länge oder ein Name) — ein Container, der jeden Schnappschuss neu aufspannt,
verliert den Hover unter der Maus.  Verschwindet der gewählte Ordner, fällt die Auswahl auf
„alle" zurück.

Die Auswahl gehört der Hülle, nicht dem Bildschirm: `take_folder` / `selected_folder`, der
Wirt gibt sie an `MainMenuScreen.set_folder` weiter.  Die Liste filtert danach und die
Fußzeile sagt „3 von 12 Jobs (Ordner build)" — eine gefilterte Liste, die ihre Grundmenge
verschweigt, lässt den Leser glauben, der Rest sei weg.

Dabei nötig geworden: mit Filter ist die **Zeilennummer nicht mehr die Jobnummer**.  Darum
hält der Bildschirm eine eigene Zuordnung (`row_idx`), und ein Klick meldet den *Job*-Index,
nicht die Zeile — genau daran gehen gefilterte Listen sonst kaputt.

### Umsetzung von Schritt 5 (2026-10-15)

Die Jobliste ist kein Textfeld mehr, sondern ein `container` mit `spawn: JobRow`
(aiml spec/44_6 §5c), `scrollable: true`.  Eine Zeile trägt Zustandspunkt, Namen,
letzten Lauf, Bilanz und einen **Starten**-Knopf; die ganze Zeile ist der Klick
(`click_area` unter den Beschriftungen), der Starten-Knopf liegt darüber und fängt
seinen Klick selbst ab — sonst hieße „starten" versehentlich „öffnen".

Die gebundene Liste (`row_ids`, `list<string>`) gibt nur der Zeilen**anzahl** ihre
Wahrheit; der Inhalt kommt bei jedem Rahmen aus dem Schnappschuss.  Eine zweite Kopie
der Jobs im Bildschirm wäre die zweite Quelle, die §104.0 schon einmal teuer bezahlt hat.

Ein Klick **ruft nicht selbst** den Server: der Bildschirm merkt den Wunsch
(`take_open` / `take_start`, einmal abholbar), der Wirt führt ihn aus (doc/spec/105) —
öffnen heißt `PipelineScreen.select_job(idx)`, das die Quelle des Jobs in den Editor
lädt, starten heißt `PipelineState.start_job(job_id)`.

Nebenbefund beim Umbau: zwei Aufrufe adressierten Kinder, die mit den vier großen
Knöpfen verschwunden waren (`logo_img`, `build_lbl`).  Im WASM-Build ist das kein
Fehlschlag, sondern ein Programmabbruch — der Prefab-Kindnamen-Check in aiml deckte
die Form „Szene im Klassen-Attribut" nicht ab und tut es jetzt (aiml spec/44_8
Tier 2b).  Der Build-Stempel sitzt seither in der Fusszeile der Hülle, wo er hingehört:
er gilt für die Anwendung, nicht für einen Bildschirm.

## 107.4 Nachbesserungen vom 18.10.2026 (User)

Drei Befunde aus dem Betrieb, alle mit derselben Wurzel: **etwas stand da, wo es nicht
hingehört, oder stand gar nicht da.**

**F107-16: Die Jobs-Ansicht war nicht aktuell — und der Fehler lag im SERVER.**
Die Push-Signatur (doc/spec/93) entscheidet, ob ein Schnappschuss überhaupt verschickt
wird.  Sie enthielt `last_status` und `last_started_ms`, aber **nicht** `last_ms`,
`runs_total`, `runs_failed` und `last_run_id` — genau die Zahlen, die in jeder Zeile der
Jobliste stehen.  Endete ein Lauf mit **demselben Status** wie der vorige, änderte sich
nichts, was die Signatur sah: kein Push, alte Dauer, alte Bilanz.

> **Die Regel, die daraus folgt:** die Signatur muss alles abdecken, was die Ansicht
> **zeigt**.  Was sie zeigt und die Signatur nicht sieht, ist per Bauart veraltet — und
> sieht für den Benutzer aus wie ein Fehler im Server.

Auch der **Quelltext** eines Jobs gehört dazu (er steht im Editor); er geht als
`sha256`-Hash ein, nicht als Text — er ist das größte Feld, und die Signatur entsteht
alle 400 ms.  Eine Längenprüfung hätte nicht gereicht: zwei Fassungen gleicher Länge sind
beim Bearbeiten der Normalfall.  Geprüft in `test_live_push_sig` (Fälle 6–8, erst rot).

**F107-17: Der Controller hat einen eigenen Reiter.**  Seine Last stand in der Fußzeile
zwischen den Agenten-Zahlen und wurde dort nicht als *seine* gelesen.  Jetzt: vier
Kennzahlen (Prozessor, Arbeitsspeicher, Agenten verbunden, Läufe aktiv) als Stat-Tiles —
eine einzelne Kennzahl braucht keine Achse —, darunter die Skript-Konsole.
Beschriftungen in gedämpftem Text, Werte in Haupttext; Statusfarben bleiben dem Zustand
vorbehalten und stehen nie allein.

**F107-18: Ein Bedienelement, das man nur sieht, wenn man das Recht schon hat, kann
niemand finden, der es noch nicht hat.**  Der Konsolen-Reiter war für Nicht-Admins
ausgeblendet — Antwort des Nutzers: *„wo die script-console zu finden ist, weiß ich
generell nicht"*.  Verbergen war nie die Sicherheit (doc/spec/91 §AP2.C), hier war es
Schaden.  Der Reiter ist jetzt **immer** da und nennt bei fehlender Freigabe den Weg:
`./cosmosd --grant-email <konto> --grant-level 1`.
Die **Kontenliste** bleibt dagegen verborgen: sie ist kein Werkzeug, sondern eine
Auskunft darüber, wer überhaupt existiert.

**F107-19: Die Ordnerleiste gehört zur Jobliste und nirgendwo sonst.**  Auf Lauf-Ansicht,
Editor, Cluster, Agenten und Controller filtert sie nichts — sie stand dort und sah
trotzdem bedienbar aus.  `show_folder_bar` blendet sie außerhalb von Bereich 4 aus.

## 107.5 Der Cluster-Reiter als NETZ (18.10.2026)

Auftrag (User): *„dort sehen wir eine visualisierung der netzwerke mit den geöffneten KV,
verbundenen agenten und der controller instanz."*

**F107-20: Für „wer hängt woran" ist Fließtext die schlechteste Form.**  Hier standen drei
`textbox`-Blöcke nebeneinander — Nodes, Workloads, Speicher.  Jeder für sich lesbar, und
die **Beziehung** kam in keinem vor: dass die Speicher *dem Controller* gehören und die
Agenten *an ihm hängen*, musste der Leser sich denken.  Das ist F107-1 in seiner reinsten
Form.

Jetzt ein Knoten-Kanten-Bild: der Controller in der Mitte, seine Speicher links, die
Agenten rechts, verbunden durch sichtbare Linien.  Linien sind dünne `rect`s — einen
Linientyp gibt es nicht —, und **jede Zeile bringt ihren eigenen Stummel mit**, der den
Stamm trifft.  Dadurch entsteht die Kante ohne Geometrie je Zeile: der Container legt die
Zeilen, der Stamm sammelt sie ein.

**F107-21: Das rechte Drittel lag brach.**  Seit F107-12 die rechte Spalte strich, endete
der Inhalt bei x=940 — 340 px ungenutzt, in jedem Cluster-Aufruf.  Eine Streichung ist
erst fertig, wenn der freigewordene Platz vergeben ist.

**F107-22: Zustand mit Wort, nicht nur mit Farbe.**  Jeder Agent trägt einen Punkt **und**
„verbunden" bzw. „nicht verbunden", dazu seine Last (doc/spec/109).  Eine Farbe allein ist
für einen Teil der Leser keine Aussage, und im Graustufendruck für niemanden.

**Ein veraltetes Bild im Repo ist ein falsches Bild.**  `ClusterScene.png` stammte vom
15.10. und zeigte noch die rechte Spalte, die am selben Tag gestrichen wurde — ich habe es
dem Nutzer als aktuellen Stand gezeigt, und er hat es bemerkt (*„die beiden prefabs rechts
sehe ich im übrigen nicht"*).  Dieselbe Fehlerklasse wie die veraltete Ist-Tabelle in
doc/spec/98 §98.1: **eine Aufnahme, die nicht nachgezogen wird, wird geglaubt.**  Wer eine
Szene ändert, nimmt sie neu auf.

## 107.5a Dasselbe Netz räumlich (18.10.2026)

Auftrag (User, direkt nach §107.5): *„Ich wölte gerne eine 3d darstellung wie bei der
pipeline mit opengl es."*

**F107-23: Dieselbe Maschinerie, nicht eine zweite.**  Die Lauf-Ansicht hat seit §107.1b
Kugeln, Rohre und Trommeln — gerechnet in `PipeScene`, gezeichnet von `Pipe3D`.  Der
Cluster bekommt kein eigenes 3D, sondern eine weitere **Rechnung** in derselben Klasse:
`PipeScene.of_cluster(view, agents)` liefert `list<SceneItem>`, und `Pipe3D` zeichnet sie
mit dem Code, der schon da ist.  Die Formensprache bleibt gültig (F107-13): Quader ist
Rechner, Trommel ist Speicher, Rohr ist Zugehörigkeit.

Die Anordnung trägt die Aussage, die ein Listenpaar nur behaupten kann:

| Körper | Lage | Farbe |
|---|---|---|
| Controller (`cosmosd`) | Mitte, Ursprung | nach **eigener Last**: ruhig blau, ab 40 % warm, ab 80 % heiß (doc/spec/109) |
| Speicher | dahinter (−z), um die Mitte zentriert | violett; leer = stumpf.  **Höhe = Füllstand** (`fill_height`, logarithmisch) |
| Agenten | davor (+z) | verbunden leuchtet, abwesend ist Blech — dieselben Farben wie `add_agents` |
| Kanten | Controller → jeder Körper | Rohr; zu einem abwesenden Agenten blass, weil die Zugehörigkeit nur noch nominell ist |

**F107-24: Die Zahlen bleiben.**  Das Bild zeigt *Struktur*, nicht Werte.  Die beiden
Listen (Speicher links, Agenten rechts) bleiben stehen und behalten ihre Stämme; die
Kennzahlen des Controllers stehen **unter** dem Ausschnitt, nicht darin — der 3D-Pass
zeichnet über den Prefab-Pass, Text im Ausschnitt wäre weg.

**F107-25: Ein Rad-Wert, mehrere Abnehmer.**  Beim Verdrahten fiel auf, dass in der
Lauf-Ansicht der 3D-Ausschnitt *genau auf* dem scrollbaren `graph_rows` liegt: eine
Radbewegung zoomte die Kamera **und** rollte die unsichtbare Spurenliste darunter
(aiml spec/44_0 §3.2).  Wo GL zeichnet, ist die Liste jetzt weg; ohne GL bleibt sie als
Rückfall.  Im Cluster-Reiter liegt unter dem Ausschnitt deshalb nichts Scrollbares.

**F107-26: Eine Quelle für die Speicher.**  `ClusterView` trug sie **zweimal** —
`stores: list<StoreInfo>` (§107.1b) und `live.stores: list<KvStoreInfo>` (doc/spec/99),
beide in `snapshot()` aus demselben `db.open_*` gefüllt.  Genau die zweite Wahrheit, die
doc/spec/104 §104.0 teuer bezahlt hat.  `StoreInfo` ist gestrichen; es gilt
`live.stores`.

**Aufnahmen.**  [ui/shots/ClusterScene.png](ui/shots/ClusterScene.png) zeigt den Reiter
(Listen + Ausschnitt + Controller-Karte), [ui/shots/Cluster3D.png](ui/shots/Cluster3D.png)
nur das Netz formatfüllend (`P3D_SCENE=cluster tools/pipe3d_shot.sh`).  In den Aufnahmen
fehlen die schwebenden Namen: `NodeTag` gehört dem Bildschirm, und die Harness baut die
Szene selbst.  Im Client stehen sie über den Körpern.

**Zwei Dinge, die erst im Bild zu sehen waren** (und wieder: ohne Aufnahme hätte ich beide
behauptet statt bemerkt):
- Die Rohre lagen auf Körperhöhe und **spießten** den Controller auf, statt ihn zu
  verbinden.  Jetzt liegen sie als Kabel am Boden (y = −2,72, r = 0,05).
- Die Aufnahme-Harness setzte `online` nie und beschriftete die Zeilen nach `res_seen`:
  die Liste sagte „verbunden", die Quader waren Blech.  **Ein Feld für beide** — dasselbe,
  das der echte Bildschirm liest (doc/spec/104 F104-3).

**F107-27: Ein Test, der eine Zahl prüft, prüft das Layout von heute.**  `test_pipe_scene`
verlangte „jede Kante ist länger als 3,0" und fiel um, als das Bild kompakter wurde —
obwohl nichts kaputt war.  Jetzt prüft er die BEZIEHUNG: die Mitte eines Rohrs muss der
Mittelpunkt der Strecke Controller→Körper sein (`pos_z = axis_z/2`).  Die überlebt jede
Umstellung der Maße und fängt trotzdem jede Kante, die ins Leere zeigt.


## 107.6 Konto und Konten sind Bereiche (18.10.2026)

Auftrag (User, nach der Rückfrage „warum sind die konten nun in einem eigenen overlay?!"):
*„es geht um beides, mache so wie bei den anderen menües, wie agenten und jobs"*.

**F107-28: Konto und Konten sind BEREICHE, keine Overlays.**  Beide lagen mit Schleier und
X über dem, was man gerade tat, und beide beriefen sich auf dieselbe Begründung („eine
Handlung an der Seite").  Die trägt hier nicht: wer sein Passwort ändert oder Freigaben
setzt, **arbeitet** dort — er braucht den Platz, er will daneben nichts Halbes sehen, und er
will über dieselbe Navigation zurück wie überall.  Jetzt verhalten sie sich wie Agenten und
Jobs: eigener Bereich (**7 = Konten**, **8 = Konto**), eigener undurchsichtiger Hintergrund,
Rückweg über den Kopf.  Schleier und X entfallen — ein X neben einer Reiterleiste ist ein
zweiter Rückweg, der etwas anderes tut als der erste.

**Aufnahmen.**  [ui/shots/UsersScene.png](ui/shots/UsersScene.png) (Konten mit drei
Freigaben: 1 / 7 / 255) und [ui/shots/AccountScene.png](ui/shots/AccountScene.png).  Die
erste Aufnahme zeigte die Zeilen **leer** und die Kopfzeile versetzt: die Harness füllte
die Liste EINMAL vor dem ersten Rahmen (`container_row` liefert erst, wenn der Container
die Zeilen aufgespannt hat), und die Spaltenköpfe standen als eine Beschriftung mit
Leerzeichen dazwischen — bei jeder Schriftbreite woanders.  Beides gefixt; drei Köpfe
stehen jetzt genau über den Spalten von `UserRow`.

**F107-29: Ein Bereich ohne Zweig ist ein schwarzes Bild.**  Beim Umbau fiel auf, was vorher
tatsächlich geschah: `poll_area` lieferte für „Konten" die 7, der Wirt rief damit `show_area(7)`
— und `show_area` kannte keinen Zweig 7, machte also **alles** unsichtbar.  Erst ein zweiter
`poll_area`-Aufruf weiter unten im Rahmen zeigte das Overlay darüber.  Sichtbar war: ein
Overlay vor einer leeren Fläche, und nach dem X eine leere Fläche.  Dass der zweite Aufruf
denselben Klick noch sah, liegt daran, dass `child_clicked` ein **Rahmen**-Zustand ist
(`clicked_frame`) und nicht beim Lesen verbraucht wird — bequem, aber es verdeckte den
Fehler.  Jeder Bereich braucht seinen Zweig in `show_area`, und `poll_area` wird **einmal**
je Rahmen gefragt.

## 107.1g Der Grund eines Fehlschlags stand auf stderr — und die Ansicht las ihn nicht (22.10.2026)

Meldung des Nutzers: *„stage 2 ist nun fehlgeschlagen, warum steht da nicht"*.

- **F107-53: Die Ausgabe-Box las nur `stream: 0`.**  `read_run_output` kennt beide Ströme, der
  Client fragte immer stdout.  Ein Schritt kann ohne eine einzige Zeile auf stdout scheitern —
  und genau die interessante Zeile (`E: The repository … is not signed`) stand auf stderr.  In
  der Ansicht blieb die Box leer und die Kugel rot: „es ist kaputt, und ich sage dir nicht,
  warum."  Die Box holt jetzt **beide** Ströme mit eigenem Versatz und zeigt sie hintereinander,
  getrennt durch eine Zeile `── Fehlerausgabe (stderr) ──`.  Zusammenmischen wäre gelogen: es
  sind zwei Dateien, die Reihenfolge zwischen ihnen ist nicht aufgezeichnet.
- **F107-54: Eine laufende Stufe, die schweigt, sieht aus wie eine, die hängt.**  Gemessen am
  22.10.2026 an `aiml-vom-Base-Image-5`: die Ausgabe stand zwei Minuten still, und zwar
  **überall** — im Container, beim Server und in der Ansicht.  `apt` schreibt je Paket EINE
  `Get:`-Zeile, wenn es anfängt; bei `libllvm18` (27,5 MB) folgt daraus eine lange Stille ohne
  Fortschrittsbalken, weil stdout kein Terminal ist.  Der Lesepfad war nachweislich in Ordnung
  (`COSMOS_LOG=<stufe> ./submit_work`: 26 631 B in drei Fenstern, so viel wie die Datei hat).
  Die Ansicht sagt deshalb jetzt, **wie lange** sie schon still ist — „· seit 42s still" neben
  dem Stufennamen, ab 5 Sekunden.  Eine Zahl, die man beobachten kann, ist der Unterschied
  zwischen Warten und Rätselraten.
