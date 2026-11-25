# 96 — Layer-Cache: Pipelines wiederholbar machen

Status: Entwurf.  Sprachseite: aiml `spec/62_pipelines.md`.  Speicherseite: `92_cas.md`.
Schließt den offenen Punkt 6 von `01_domain_model.md` („Pipelines sind deklarativ, aber nicht
ausführend").

## 96.1 Warum

Ein Image-Build bildet Layer und wiederholt deshalb nichts zweimal.  Eine Pipeline bildet keine
Layer und gilt als nicht wiederholbar — also wird dasselbe apt-Paket wieder installiert, dasselbe
Repository wieder geklont, derselbe Ordner wieder angelegt.  Beides zu vereinen ist der Zweck
dieses Kapitels.

Was dabei **nicht** behauptet wird, steht in aiml `spec/62` §1.1: ob ein Schritt dasselbe
erzeugt, ist im Allgemeinen nicht entscheidbar.  Dieses Kapitel baut keinen Beweis, sondern die
drei Mechanismen, die die Behauptung ehrlich halten — Sonde, aufgezählte Eingaben, Nachmessung.

## 96.2 Wo was liegt (Grundsatz)

**Job-Inhalte liegen nicht auf dem Server.**  Der Server ist Koordinator; der Inhalt entsteht und
bleibt dort, wo gearbeitet wird.

| Was | Wo | Begründung |
|---|---|---|
| Workspace, Layer-Inhalte, Blobs | **Agent**, lokaler CAS | dort entstehen sie; Übertragung kostet |
| `PipelineRun`/`PipelineStage`, Logs, Exit-Codes | Server | Zustand des Laufs, nicht sein Inhalt |
| `step_key → output_tree` + **welche Knoten den Layer haben** | Server | Koordination, kein Inhalt |
| lokaler Lauf (JIT, ohne Server) | Entwicklerrechner, `.aiml_pipeline/` | aiml spec/62 §12 — gleiche Schlüssel, also später teilbar |

Daraus folgt eine Eigenschaft, die über das Zeitsparen hinausgeht: weil der Server weiß, *wer*
einen Layer hat, kann die Knotenwahl einen Knoten bevorzugen, der den Layer schon besitzt
(Affinität).  Ein Treffer ohne Übertragung ist der billigste Fall, und er fällt hier nebenbei an.

Hat ihn kein geeigneter Knoten, zieht Knoten B ihn von Knoten A — inhaltsadressiert, also nur die
Blobs, die B fehlen.  Der Server vermittelt die Adresse und sieht den Inhalt nie.

**Abgrenzung zum heutigen Stand:** `92_cas.md` beschreibt den CAS als Server-Instanz
(`cas_root: "cas"` in `init_server_state`), und `sources/agent/` enthält **keinen** CAS-Code.  Das
ist die Abweichung, die dieses Kapitel auflöst: der CAS wandert in den Agenten, der Server behält
nur die Zuordnungstabelle.

## 96.3 Layer = overlayfs-upper

Ein Schritt läuft mit `lowerdir` = Stapel der Layer seiner Eingaben und einem frischen
`upperdir`.  Nach dem Schritt **ist** der `upperdir` die Differenz, also der Layer.  Seine Adresse
ist der Baum-Hash dieser Differenz (`92_cas.md` §92.2).

Damit ist ein Treffer kein Kopiervorgang, sondern ein Mount: die Layer der Eingaben plus der
getroffene Layer werden untergelegt, der Schritt läuft nicht.

- **F96-1** Ein Layer wird nie beschrieben, nachdem seine Adresse gebildet wurde.  Schreiben geht
  ausschließlich in den `upperdir` des laufenden Schritts.  (Entspricht der
  Unveränderlichkeitsregel §92.5/C8: kein geteilter Inhalt zwischen Store und Arbeitsdatei.)

## 96.4 Zwei Baumarten — Befund gegen die heutige Spec

`sources/models/cas_tree.aiml` trägt pro Eintrag **nur** `name/kind/exec/addr` und begründet das
ausdrücklich: Zeitstempel und uid/gid machen Builds unreproduzierbar.  Für einen **Workspace** ist
das richtig.  Für einen **Systemlayer** ist es falsch, und zwar zweifach:

1. **Eigentümer und Modi fehlen.**  `dpkg` setzt uid/gid und Modi; bei einem apt-Layer sind sie
   Verhalten, nicht Rauschen.  Ein wiederhergestellter Layer mit falschem Eigentümer ist kaputt.
2. **Löschung ist nicht darstellbar.**  `TreeKind` kennt `file|dir|symlink`, aber kein Whiteout.
   Ein Schritt, der eine Datei löscht, ist als Layer nicht ausdrückbar — ein Layerstapel kann
   heute nur wachsen.

- **F96-2** Es gibt zwei Baumarten: `WorkspaceTree` (wie heute, metadatenarm) und `LayerTree`
  (zusätzlich `uid`, `gid`, `mode`, plus `TreeKind.whiteout`).  Sie sind nicht dasselbe Modell mit
  optionalen Feldern, weil ihre Adressen unterschiedlich gebildet werden müssen: beim Workspace
  wäre uid/gid Rauschen, beim Layer ist es Inhalt.

Das ist ein Widerspruch zur vorhandenen Begründung in `cas_tree.aiml` und wird dort als
Querverweis vermerkt, nicht stillschweigend aufgeweicht.

## 96.5 `verify` — das Unbeweisbare messbar machen

Ein Modus, der einen Schritt **trotz Treffer** ausführt und die Ausgabebäume vergleicht.

- **F96-3** Bei Abweichung: der Lauf schlägt **nicht** fehl, aber beide Adressen werden mit
  `step_key`, Pipeline, Schritt und Knoten protokolliert, und der Eintrag wird als unzuverlässig
  markiert.
- **F96-4** `verify` ist stichprobenartig schaltbar (Anteil je Lauf), damit es dauerhaft
  mitlaufen kann, ohne den Zeitgewinn aufzufressen.
- **F96-5** Ein als unzuverlässig markierter `step_key` trifft nicht mehr, bis er von Hand
  freigegeben wird.  Ein Schritt, der einmal gelogen hat, ist kein Kandidat für „vielleicht
  stimmt es ja diesmal".

Nach einigen Wochen ist damit belegt, welche Deklarationen tragen — statt es zu glauben.

## 96.6 Abfolge eines Schritts

1. Sonde ausführen (`resolve:`, aiml `spec/62` §9) — immer, nie aus dem Cache.
2. `step_key` bilden (`spec/62` §8, Längenpräfix-Kodierung wie §92.2).
3. Server fragen: `step_key` bekannt?  Wenn ja, mit welcher `output_tree`-Adresse und auf welchen
   Knoten?
4. Treffer und Layer lokal vorhanden → untermounten, Schritt **nicht** ausführen.
5. Treffer, Layer fremote → Blobs holen, die fehlen; dann wie 4.
6. Kein Treffer → `upperdir` anlegen, Schritt ausführen, `upperdir` als Layer aufnehmen,
   `step_key → Adresse` beim Server melden.
7. `cache: opaque` → Schritte 3–5 entfallen vollständig.

## 96.7 Abnahme

- **A96-1** Derselbe Lauf zweimal: der zweite überspringt alle `pure`- und `resolved`-Schritte,
  führt alle `opaque`-Schritte aus.  Nachweis über Schrittdauer und Ausführungszähler.
- **A96-2** Ein `resolved`-Schritt (`git clone` auf einen Branch) wird nach einem Commit auf dem
  Branch **erneut** ausgeführt, ohne Commit nicht.  Nachweis mit einem lokalen Repo, auf das
  zwischen den Läufen committet wird.
- **A96-3** Ein Schritt, der eine Datei löscht, liefert nach Wiederherstellung aus dem Layer
  einen Workspace ohne diese Datei (Whiteout, F96-2).
- **A96-4** `verify` mit einem absichtlich lügenden Schritt (`pure` deklariert, schreibt
  `date`) erzeugt den Abweichungs-Eintrag und sperrt den `step_key` (F96-3/F96-5).
- **A96-5** Ein Layer wird von Knoten A nach Knoten B übertragen, und B überträgt nur die Blobs,
  die ihm fehlen.  Nachweis über die Byte-Zahl gegen die Layergröße.
- **A96-6** Der Server hält nach einem vollständigen Lauf **keinen** Workspace-Inhalt — nur
  Lauf-Metadaten und die `step_key`-Tabelle.  Nachweis: Größe des Server-Datenverzeichnisses
  wächst nicht mit der Workspace-Größe.
- **A96-7** Derselbe Schritt, lokal im JIT-Modus und auf einem Agenten ausgeführt, erzeugt
  **denselben** `step_key` (aiml spec/62 F62-21).  Nachweis: Schlüssel beider Läufe vergleichen.
  Schlägt dieser Test fehl, ist der Layer-Cache in zwei Inseln zerfallen und der lokale Lauf
  nützt dem Cluster nichts.

## 96.8 Voraussetzung, die heute fehlt

`apt install` in einen Layer zu schreiben braucht root **innerhalb** des Namespace: `dpkg`
schreibt `/usr` und `/var/lib/dpkg` und führt Trigger aus.  Ohne echte Isolation (rootless
userns) geht dieser Teil nicht — und genau dieser Nachweis steht auf diesem Rechner noch aus
(`94_agent_provisioning.md`, Schritt 9: `unshare: /proc/self/uid_map: Vorgang nicht zulässig`;
`uidmap` fehlt, `newuidmap` ist setuid-root und kann nicht über exodus kommen).

Reihenfolge daraus, und sie ist durch den lokalen Lauf (aiml spec/62 §12) besser als gedacht:

1. **Lokal, JIT, ohne Server und ohne Agent.**  Workspace-Layer — Ordner anlegen, klonen,
   kompilieren — brauchen kein root und keinen Namespace.  A96-1, A96-2 und A96-4 sind damit
   vollständig lokal nachweisbar.  Das ist auch für sich nützlich: ein Entwickler spart die
   Wiederholungen auf seinem eigenen Rechner, ohne irgendetwas aufzusetzen.
2. **Verteilt**, mit Agent und Knotenwahl (A96-5, A96-6, A96-7).
3. **Systemlayer** (`apt install`) erst nach der Isolationsarbeit.

Der Isolations-Blocker hält also nur Punkt 3 auf, nicht die Hauptsache: `git clone` und `mkdir`
sind die Schritte, die in jeder Pipeline stehen.

## 96.9 Nachtrag: Lanes

aiml `spec/62` ist überarbeitet: eine Pipeline ist nicht eine Folge von Schritten, sondern ein
parametrisierter Graph über einem Parameterraum.  Ein Punkt darin ist eine **Lane**, und der
Schlüssel gilt je **(Schritt, Lane)**, nicht je Schritt.  Folgen für dieses Kapitel:

- **F96-6** Die Einheit der Verteilung ist die Lane, nicht der Lauf.  Lanes teilen keinen
  Workspace und hängen nicht voneinander ab (`spec/62` §4.3/§6), also sind sie ohne weitere
  Vorkehrung auf verschiedene Knoten verteilbar — die Parallelität kommt aus der Matrix, nicht aus
  dem Scheduler.
- **F96-7** `PipelineStage` (§1.5) ist damit zu grob: ein Zustand pro Stufe kann sechs Lanes nicht
  abbilden.  Nötig ist ein Zustand je (Stufe, Lane) samt Lane-Bindung, damit die UI zeigen kann,
  *welche* Spalte fehlgeschlagen ist.  Bei einer Matrix ist das Muster der Fehlschläge die
  Information (`spec/62` F62-12) — ein kaputter Compiler sieht anders aus als eine kaputte
  Architektur.
- **A96-8** Eine Matrix mit zwei Achsen läuft verteilt, eine Achse wird um einen Wert erweitert,
  und **nur** die neuen Lanes werden ausgeführt.  Nachweis über die Ausführungszähler je Lane.

Das Schlüsselmaterial hat jetzt sechs Bestandteile (`spec/62` §8), darunter die Lane-Bindung und
die Schlüssel der `needs`-Schritte.  Letztere machen eine Schrittkette transitiv — genau das, was
einen Layer-Stapel ausmacht, ohne dass der Cache davon wissen muss.

## 96.10 Status: sechs Werte — Widerspruch zum heutigen Modell

aiml `spec/62` §5.7 legt den Status eines Schritts als Enum mit **sechs Werten** fest, benannt nach
den drei additiven Grundfarben und ihren paarweisen Mischungen: `red`, `green`, `blue`, `yellow`,
`cyan`, `magenta`.  **Was die einzelnen Werte bedeuten, ist dort ausdrücklich offen** (`spec/62`
§15 Punkt 6); fest sind: sechs Werte, die Mischungsnamen, eine **totale Rangfolge** für Aggregate
statt additiver Mischung, und die Trennung von Ergebnis und Lebenszyklus.

Für dieses Kapitel zählt vor allem, dass das Enum genug Werte hat, um **Erfolg mit Ausführung von
Erfolg ohne Ausführung** zu unterscheiden — das ist die Unterscheidung, um die es beim Layer-Cache
geht, und `success/unstable/failure` kann sie nicht treffen.  Die Abnahme A96-1 („der zweite Lauf
überspringt") wird damit am Status **ablesbar** statt an Schrittdauern.

**Widerspruch, der aufzulösen ist (nicht aufzuweichen):** `01_domain_model.md` §1.5 führt
`StageStatus` als `pending | running | succeeded | failed | skipped` und §1.4 `PipelineStatus` als
`queued | running | deploying | succeeded | failed`.  Beide vermischen **Lebenszyklus** und
**Ergebnis** in einem Enum — `running` und `failed` sind keine Alternativen derselben Art, und
deshalb lässt sich für sie keine Aggregationsregel angeben.  Derselbe Befund wie aiml F62-44.

- **F96-8** Zwei Enums statt einem: `StageState` = `pending | running | done` (Lebenszyklus) und
  `StepStatus` = die sechs Werte aus `spec/62` (Ergebnis, gültig ab `done`).  `deploying` ist ein
  Lebenszyklus-Zustand und gehört zu `StageState`, nicht zum Ergebnis.  Die Zuordnung der heutigen
  Werte (`succeeded`, `failed`, `skipped`) auf die sechs folgt, sobald deren Bedeutung festgelegt
  ist.
- **F96-9** Der Status eines Laufs ist **nicht** die additive Mischung seiner Lanes, sondern die
  erste Übereinstimmung in einer totalen Rangfolge über die sechs Werte (aiml F62-43).  Alle drei
  Facetten zusammen wären ein siebter Wert, und „ist etwas fehlgeschlagen" wäre nicht mehr auf
  einen Blick beantwortbar.
- **A96-9** Ein zweiter Lauf einer unveränderten Matrix meldet jede Lane mit dem Status für
  „Erfolg ohne Ausführung"; nach Änderung einer Achse melden die neuen Lanes „Erfolg mit
  Ausführung", und der Lauf übernimmt diesen (Ausführung schlägt Wiederverwendung in der
  Rangfolge).

Dazu kommt aus `spec/62` §5.6/§5.7 die Mechanik, die der Lauf abbilden muss: **was ein Fehlschlag
zerstört, ist Eigenschaft des Schritts** (`on_fail: lane | pipeline | continue`), und ein
Schritt-Rumpf kann es überschreiben (`set_status`, `fail_lane`, `fail_pipeline`).  Für einen
verteilten Lauf heißt das: `fail_pipeline` muss die Knotenwahl anhalten, `fail_lane` nur die
betroffene Lane beenden, und bei einem `per: once`-Schritt werden alle abhängigen Lanes
übersprungen.

- **F96-10** Der Server muss `fail_pipeline` **knotenübergreifend** umsetzen: ein Agent, dessen
  Lane das aufruft, kann die anderen Knoten nicht selbst anhalten.  Das ist Koordination und damit
  Server-Aufgabe (§96.2) — und der erste Punkt, an dem dieses Kapitel mehr braucht als eine
  Schlüsseltabelle.

## 96.11 Steuerung: anhalten, fortsetzen, Knotenwahl

aiml `spec/62` §5.8/§5.9 legt die Mechanik fest; dieses Kapitel sagt, wer sie bedient.

**Anhalten und Fortsetzen gehören an den Server, ohne neue Agent-Fähigkeit.**  Der Agent
entscheidet nie, ob es weitergeht — er fragt nach dem nächsten Schritt.  Anhalten heißt deshalb:
der Server hört auf, Schritte herauszugeben.

- **F96-11** `pause_run`, `resume_run` und `abort_run` sind **authentifizierte** RPCs.  Jede
  Prüfung steht serverseitig; ein ausgegrauter Knopf ist Bequemlichkeit, keine Sicherheit (Leitsatz
  aus `90_ap1_agent_exec.md`).  Wer einen Lauf anhalten darf, ist dieselbe Frage wie wer ihn
  starten darf, und wird genauso beantwortet.
- **F96-12** Das Tor sitzt bei der Zuteilung, nicht beim Agenten.  Ein angehaltener Lauf bekommt
  keine neuen Schritte zugewiesen; laufende Schritte dürfen fertig werden (aiml F62-55).  Damit
  braucht der Agent für Pause/Resume **keine** zusätzliche Fähigkeit — nur `abort_run` greift
  wirklich auf dem Knoten ein (`process.kill()` auf die Prozessgruppe, `spec/23` §5.2).
- **F96-13** Der Pausen-Zustand ist dauerhaft: er gehört zum Lauf-Datensatz, nicht in den
  Speicher des Daemons.  Sonst setzt ein Controller-Neustart einen bewusst angehaltenen Lauf
  stillschweigend fort — das Gegenteil dessen, wofür ein Freigabe-Tor da ist.
- **F96-14** Fortsetzen braucht keinen eigenen Zustand: der Lauf wird aus den schon
  aufgezeichneten `(Schritt, Lane)`-Schlüsseln und ihren `output_tree`s fortgesetzt (aiml F62-56).
  Das ist dieselbe Tabelle, die der Cache ohnehin hält — ein Resume nach Controller-Neustart ist
  deshalb kein Sonderfall, und eine Lane darf auf einem **anderen** Knoten weiterlaufen.

**Knotenwahl.**  `agent:` (aiml F62-146, früher `runs_on:`) trifft auf das vorhandene `required_label` von
`PipelineStage` (§1.5) — kein neues Konzept, nur pro Lane aufgelöst.  Weil `agent:` Parameter
interpolieren darf (`agent: "${arch}"`), kann **eine Lane mehrere Knoten überspannen**.

- **F96-15** Überspannt eine Lane Knoten, muss der `output_tree` des Vorgängerschritts auf dem
  Zielknoten vorliegen.  Damit ist die inhaltsadressierte Übertragung aus §96.2 **Pflicht**, nicht
  Optimierung (aiml F62-48) — und die Affinität aus §96.2 wird von einer Sparmaßnahme zum
  Normalfall: der Server bevorzugt einen Knoten, der die Eingabe schon hat.
- **F96-16** `agent:` ist **kein** Schlüsselbestandteil (aiml F62-49).  Wo ein Schritt lief, darf
  seinen Schlüssel nicht ändern, sonst zerfällt der Cache pro Maschine.  Folge für die Knoten-
  Verwaltung: was am Knoten das Ergebnis beeinflusst (Architektur, Toolchain), muss als Parameter
  oder `host:`-Wert deklariert sein — ein Label allein trägt diese Information nicht.

**Der Agent bekommt ein `Code`-Bundle.**  aiml F62-50/F62-51: zum Knoten wandert ein Bundle
(`sys.bundle`), das der Agent mit `sys.exec` ausführt — kein Quelltext für einen Kommandozeilen-
Compiler und kein übersetztes Objekt.  Ein Bundle trägt seine Abhängigkeiten transitiv, ist also
von sich aus vollständig, und es ist ein gewöhnlicher serialisierbarer Wert, der über den
vorhandenen RPC-Weg reist.

Der Compiler ist dafür **schon da**: `libaiml.so` enthält LLVM und exportiert `aiml_exec_code` und
`aiml_set_active_context`.  Was fehlt, ist der **isolierte JIT-Kontext** in einem AOT-Binary — der
Agent ist ein `exodus build`-Binary, dort gibt `sys.exec` heute `-2` zurück (aiml `spec/29_2` §11,
offener Punkt §12).  Das ist die **eine** Lücke zwischen hier und verteilter Ausführung, und es ist
eine fehlende Verdrahtung in einem vorhandenen Mechanismus, kein neues Teilsystem.

- **F96-17** Die Agent-Einrichtung (`94_agent_provisioning.md`) muss **libaiml** auf dem Knoten
  bereitstellen — nicht das `aiml`-Compiler-Binary.  Der Agent linkt die Bibliothek ohnehin; sie
  bringt den Compiler mit.  Das erweitert die Vertrauensgrenze **nicht der Art nach** — ein Knoten, der
  Schritte annimmt, führt schon beliebige Kommandos aus (`90_ap1_agent_exec.md`) —, aber dem Grad
  nach, weil ein aiml-Rumpf mehr Builtins erreicht als eine Shell-Zeile.  Die Antwort darauf ist
  Isolation (§96.8), nicht eine kleinere Nutzlast.

- **A96-10** Ein Lauf wird an einem Schritt angehalten, der Controller neu gestartet, dann
  fortgesetzt: der Lauf bleibt angehalten (F96-13), setzt nach der Freigabe fort und führt die
  bereits erledigten Schritte **nicht** erneut aus.
- **A96-11** Eine Lane mit `agent: "${arch}"` über zwei Knoten überträgt nur die Blobs, die dem
  Zielknoten fehlen (zusammen mit A96-5 nachweisbar).

## 96.13 `run_pipeline` — einreichen, prüfen, ausfalten

Der Startknopf aus §98 schickt **Quelltext**, nicht einen Auftrag.  Dazwischen liegen drei
Schritte, und die Reihenfolge ist die ganze Aussage: **prüfen, ausfalten, erst dann anlegen.**

- **F96-28** Der Controller **führt eingereichten Quelltext nicht aus**, auch nicht „nur zum
  Prüfen".  Ein Schritt-Rumpf läuft im selben Prozess wie der Wirt, wenn man ihn dort startet:
  `io`, `db`, `sys.exe` und die exportierten Symbole des Prozesses sind dann erreichbar, und ein
  eigener `LLVMContext` ändert daran nichts (aiml `spec/29_2` F29_2-22b — die Trennung ist
  lexikalisch, keine Sandbox).  Eingereichte Pipelines laufen deshalb ausschliesslich dort, wo
  ohnehin fremder Code läuft: auf einem **Agenten**, über ein Bundle (§96.11).
- **F96-29 (neu gefasst 25.10.2026): geprüft wird vom ÜBERSETZER, in einem Kontext.**
  Vorgabe des Nutzers: *„Die Idee ist, dass die Pipeline zur Laufzeit einen neuen
  Compiler-Kontext öffnet und laufen lässt.  Ohne extra Kommandozeile?!"* — also kein
  Unterprozess und keine zweite Prüfung im Controller:

  1. `ctx.new` + **`cx.load`** (aiml spec/29_2 §14b, F29_2-…n) übersetzt die Einreichung und
     hängt sie ein, **ohne** einen Einstiegspunkt zu rufen.  Damit bleibt F96-28 gewahrt: der
     eingereichte Code **läuft** nicht, er wird nur übersetzt.
  2. Scheitert das, gehen die Meldungen des Übersetzers **unverändert** an den Anfrager
     (`cx.errors`, F29_2-…l).  Eine eigene Formulierung daneben wäre eine zweite Wahrheit.
  3. Gelingt es, baut der Controller die Pipeline (`cx.call(name, "fn() -> pipeline")`) und
     **liest** sie (aiml spec/62 §20.4).  Was dabei läuft, ist der vom Übersetzer **erzeugte**
     Erbauer, der nur `pipeline`/`stage`-Werte zusammensetzt (aiml F62-108) — kein Schritt-Rumpf.

  Was der Controller danach noch selbst prüft, ist die **Lage** und nur sie: kennt dieser Cluster
  das Abbild (`known_image`)?  Die **Form** — Schlüssel, Achsen, Verweise, Widersprüche, alte
  Namen — gehört dem Übersetzer (aiml F62-150).  Grund: zwei Leser derselben Sprache laufen
  auseinander, und zwar leise.  Vorher hatte diese Datei 180 `yaml.*`-Aufrufe und kannte
  `agent:`/`steplayer:`/`shares:`, während der Übersetzer die Reinheit und den Schlüssel kannte;
  ein Schlüssel, den der eine kennt und der andere nicht, ist entweder still wirkungslos oder
  abgelehnt ohne Grund.
- **F96-29a Der Preis und die Grenze.**  In-process übersetzen heißt: der Übersetzer selbst muss
  robustes Verhalten bei feindlicher Eingabe haben, und er ist **keine** Sicherheitsgrenze
  (aiml F29_2-…e).  Zwei Dinge sind deshalb umgesetzt statt angenommen: der erzeugte Quelltext
  **maskiert** eingesetzte Werte (sonst schleust ein `image: "a\"]\n- call: …` Code ein), und
  ein Argument, das sich nicht übersetzen ließ, bringt den Übersetzer nicht mehr zum Absturz
  (aiml F62-158 — gefunden mit `cache: haeufig`, einer Einreichung, die den Dienst beendet
  hätte).  Für wirklich feindliche Einreichungen bleibt die Grenze ein eigener **Prozess**
  (aiml spec/65 F65-15); dass der Rumpf beim Agenten läuft, ändert sich nicht (F96-28).
- **F96-30** Scheitert die Prüfung, entsteht **kein** Lauf-Datensatz.  Ein Lauf, der nie laufen
  kann, wäre eine Zeile, die jemand später aufräumen muss, und eine Statusfarbe, die nichts
  bedeutet.  Die Meldungen gehen an den **Anfrager**, nie als Broadcast (Leitsatz aus
  `90_ap1_agent_exec.md` §AP1.2 Punkt 5).
- **F96-31** Ausgefaltet wird **beim Einreichen**, nicht bei der Zuteilung: aus dem Kreuzprodukt
  der Achsen (aiml §4) entsteht je (Lane, Stufe) ein `PipelineStage` mit `status: pending`.  Grund:
  danach ist der Lauf **ohne den Quelltext** lesbar — die Oberfläche zeigt die Matrix, und die
  Zuteilung braucht nur noch die Liste.  Ein Lauf, dessen Gestalt erst beim Ausführen entsteht,
  lässt sich weder anzeigen noch anhalten.
- **F96-32** Der Quelltext gehört **in den Lauf**: ohne ihn kann ein Resume (F96-14) oder ein
  `verify` (§96.5) die Schlüssel nicht nachrechnen.  Abgelegt wird er als CAS-Blob (§96.2), der
  Lauf trägt dessen Adresse — damit ist er unveränderlich und wird nicht zweimal gespeichert.
- **F96-34** Der Lauf-Datensatz trägt die **Achsen** (Name und Werte, in Deklarationsreihenfolge)
  und jeder Eintrag seine **Bindungen** als eigenes Feld — nicht nur in der Beschriftung.  Das
  folgt aus F96-31: wenn der Lauf ohne den Quelltext lesbar sein soll, muss auch seine *Gestalt*
  darin stehen.  Eine Matrix-Darstellung (`97` §97.7, F97-14) braucht genau diese beiden Angaben;
  sie aus Anzeigetext zurückzulesen wäre eine stille Abhängigkeit von einem Beschriftungsformat.
- **F96-33** `run_pipeline` ist **authentifiziert** wie `pause_run`/`resume_run` (F96-11): wer
  einen Lauf starten darf, ist dieselbe Frage wie wer ihn anhalten darf.  Ohne gültiges Token
  entsteht nichts, und die Antwort nennt keinen Grund, der einem Unbefugten etwas verrät.

## 96.12 Container-Images — Vorklärung, eigenes Thema

**Nicht im kritischen Pfad dieses Kapitels.**  Gehört in `13_container.md` (`00_overview.md` §130
sieht es vor) und ist von der Pipeline-Programmierung unabhängig: die stage/step-Form braucht
dafür keine Änderung, höchstens ein weiteres Stufen-Attribut, und das unterliegt dann aiml
`spec/62` F62-64 (jedes neue Attribut muss erklären, ob es Schlüsselmaterial ist).  Festgehalten
ist hier nur, was beim Nachsehen schon herauskam, damit es nicht zweimal erarbeitet wird.

### 96.12.0 Ist ein Schritt-Ergebnis schon ein Container-Image?

Die Frage liegt nahe, weil die Konstruktion dieselbe ist: inhaltsadressierte Blobs, ein Baum über
deren Adressen, ein Stapel von Differenzen.  Genau so ist ein OCI-Image aufgebaut.  Die Antwort
ist trotzdem **nein, noch nicht** — und der Unterschied ist einer, nicht fünf.

**Der entscheidende Unterschied: ein Workspace ist ein Projektverzeichnis, kein Wurzel-Dateisystem.**
In `build-x86_64-gcc-release/` gibt es keine libc, keine Shell, kein `/usr`.  Ein Image ist ein
Wurzel-Dateisystem **plus** die Angabe, wie darin ein Prozess startet.  Aus einem Workspace-Baum
lässt sich kein Container starten, egal wie korrekt er adressiert ist.

Damit hängt die Frage an derselben Voraussetzung wie §96.8: **Systemlayer**.  Sobald ein Schritt
`apt install` in eine eigene Schicht schreiben kann (root im Namespace), ist ein Stapel aus
Basis-Layer + Systemlayer + Workspace-Layer genau das, was ein Image ist.  Dann fällt auch die
Vereinheitlichung an, um die es in diesem Kapitel von Anfang an geht: ein Image-Build **ist** eine
Pipeline, deren Stufen Layer erzeugen, der Layer-Cache **ist** der Schritt-Cache, und „push" ist
ein Export.

Vier weitere Lücken, alle benennbar und keine davon grundsätzlich:

- **F96-18** Die Layer-Serialisierung ist nicht dieselbe.  Ein OCI-Layer ist ein tar(+gzip/zstd),
  und die Digest ist die des **tar-Blobs**, nicht die unseres Baums.  `tree_id` ist deshalb nie
  gleich einer Layer-Digest; es braucht eine Zuordnungstabelle `tree_id → layer_digest`.
- **F96-19** Der vorhandene `compress.tar_gz` (aiml `spec/33_2`) genügt dafür **nicht**: er nimmt
  einen Pfad und lässt Eintragsreihenfolge, mtime und uid/gid offen, also ergeben zwei Läufe mit
  identischem Inhalt verschiedene Digests.  Nötig ist ein deterministischer tar-Schreiber über den
  **Baum** (kanonische Reihenfolge wie §92.2, feste mtime, deklarierte uid/gid) — die
  Reproduzierbarkeits-Eigenschaft, die ein Image erst teilbar macht.
- **F96-20** Löschungen fehlen in beiden Richtungen: OCI markiert sie mit `.wh.`-Einträgen, und
  `TreeKind` kennt kein Whiteout (F96-2).  Ohne das kann ein Layer-Stapel nur wachsen.
- **F96-21** Metadaten fehlen: tar trägt uid/gid/mode/mtime, `WorkspaceTree` lässt sie absichtlich
  weg (§96.4).  Für einen Workspace richtig, für einen Image-Layer falsch — derselbe Befund wie
  F96-2, hier noch einmal von der anderen Seite bestätigt.

Was an Mitteln vorhanden ist: `compress.gzip`/`zstd`/`tar_entries` für das Format, `http` + `tls`
für das OCI-Distribution-Protokoll.  Es ist Arbeit, kein Hindernis.

**Die billigere und vermutlich wertvollere Richtung ist die umgekehrte.**  Ein Image **ziehen** und
als Basis eines Stufen-Workspace auslegen (`image:` an der Stufe) braucht nur Pull, Entpacken und
die Layer-Materialisierung, die §96.3 schon beschreibt — kein Push-Protokoll, keine
Config-Erzeugung.  Das liefert sofort hermetische Builds („diese Stufe läuft in *diesem* Image"),
und es ist der Anknüpfungspunkt, den `00_overview.md` mit `image_ref` + `stage_kind` schon
vorsieht.

- **A96-12** Derselbe Baum zweimal als Layer serialisiert ergibt **dieselbe** Digest (F96-19).
  Erst wenn das gilt, ist ein Export teilbar; vorher ist er nur eine Kopie.

### 96.12.1 Der Transport ist schon da — die Körnung ist es nicht

Richtig ist: es sind inhaltsadressierte Datenblobs, die ohnehin zwischen Knoten wandern (§96.2,
A96-5).  Push ist dieselbe Handlung mit anderem Protokoll, und ein Registry ist selbst nichts
anderes als ein inhaltsadressierter Blob-Speicher mit HTTP davor.  Insofern ist „pushen"
**im Prinzip** keine neue Infrastruktur, sondern ein Adapter.

Der eine Punkt, an dem es nicht dasselbe ist, ist die **Körnung**:

- Intern ist ein Blob **eine Datei**.  Ändert sich eine Datei, wandert ein Blob.
- Ein OCI-Layer ist **ein tar-Blob** für die ganze Schicht.  Ändert sich eine Datei, wandert die
  **ganze Schicht** neu, weil ihre Digest sich ändert.

- **F96-22** Der interne Weg bleibt der feinere und wird nicht durch Push ersetzt.  Push ist dafür
  da, Ergebnisse **nach außen** zu geben; zwischen Knoten bleibt die Datei die Einheit.  Deshalb
  ist der gepushte Blob auch nicht derselbe wie die internen: er entsteht erst durch die
  tar-Serialisierung (F96-19), weshalb `tree_id → layer_digest` gemerkt werden muss (F96-18) —
  die Digest lässt sich nicht ohne das tar ausrechnen.

- **F96-23** Umgekehrt kann ein Registry als **gemeinsamer Cache-Speicher** dienen, statt Knoten
  untereinander zu übertragen: moderne Registries nehmen beliebige Artefakte (`artifactType`),
  nicht nur Images.  Vorteil: vorhandene Infrastruktur, überall schon betrieben, Authentifizierung
  und Quoten inklusive.  Nachteil: die gröbere Körnung aus F96-22, und der Cache liegt dann außerhalb
  des Clusters — was der Grundsatz aus §96.2 (Job-Inhalte nicht beim Koordinator) nicht verbietet,
  weil ein Registry kein Koordinator ist.  Offen, welche der beiden Wege der Normalfall wird; sie
  schließen sich nicht aus.

Was also wirklich fehlt, ist nicht der Transport, sondern zweierlei: die **deterministische
Serialisierung** (F96-19, A96-12) und ein **Wurzel-Dateisystem**, in dem ein Prozess starten kann
(§96.12 oben).  Das Zweite ist das Erheblichere und hängt an den Systemlayern aus §96.8.

### 96.12.2 Zielbild: `image:` und `push:` an der Pipeline

aiml `spec/62` §16 legt die Form fest — hier steht, was die Steuerebene dafür tun muss.  Beides
ist **optional**; fehlt es, ändert sich nichts.

- **F96-24** Tag → Digest auflösen ist eine **Sonde** im Sinne von §96.6 Schritt 1: ein
  Manifest-Request gegen das Registry (`HEAD`/`GET` mit `Accept: …manifest…`, der
  `Docker-Content-Digest`-Header bzw. der Hash des Manifests) liefert `sha256:…`.  Billig, läuft
  **jedes Mal**, nie aus dem Cache — denn `ubuntu:24.04` bewegt sich.  In den Schlüssel geht die
  Digest (aiml F62-68), nie der Tag.
- **F96-25** Ein Image **ziehen** und als Basis auslegen benutzt die Materialisierung aus §96.3:
  Layer-Blobs holen, die fehlen, und untermounten.  Das ist dieselbe Mechanik wie der
  Layer-Cache — ein gezogenes Image ist für diesen Speicher nur ein Baum, dessen Blobs von
  auswärts kamen.
- **F96-26** Registry-Zugangsdaten gehen über `host:`-**Namen** (aiml F62-17/F62-70) und werden
  **nie** protokolliert — weder der Token noch die Kommandozeile, die ihn tragen könnte (Leitsatz
  aus `90_ap1_agent_exec.md`).  Sie sind kein Schlüsselmaterial: ein rotierter Token darf keinen
  Build entwerten, dessen Ergebnis nicht von ihm abhängt.
- **F96-27** Push ist ein **Außeneffekt** und gehört deshalb dem Server, nicht dem Agenten: wer
  pushen darf, ist dieselbe Frage wie wer einen Lauf starten darf, und wird serverseitig
  beantwortet (F96-11).  Die **Serialisierung** dagegen passiert dort, wo der Baum liegt — also auf
  dem Knoten —, weil sonst der ganze Baum zum Server wandern müsste, was §96.2 gerade vermeidet.
- **A96-13** Ein Lauf mit `image: "…:<tag>"` wird zweimal ausgeführt; bewegt sich der Tag
  zwischendurch nicht, treffen alle Schritte, nach einem neuen Push auf den Tag laufen sie neu
  (F96-24 + aiml F62-68).  Das ist der `git clone`-Nachweis A96-2 für Images.
