# Offene Fragen — Stand 2026-10-13 (Nachtlauf)

> **Kurz:** 22 Fragen in fünf Blöcken (D2 hat sich erledigt — Richtigstellung steht dort).  Blockierend ist **keine** — zu jeder steht, wie ich
> vorläufig entschieden habe, damit die Arbeit weiterlief.  Die wichtigsten vier, wenn die Zeit
> knapp ist: **A2** (Mounts auf Knoten überhaupt?), **C1** (ein Kern statt drei Sprachen),
> **C2** (kein Zustandsspeicher — tragen wir die Folge?) und **E2** (Aufbewahrungsfristen).

Eine Datei, eine Durchsicht.  Jede Frage nennt **worum es geht**, **was ich entschieden habe,
solange keine Antwort da ist** (damit nichts blockiert), und **woran die Antwort etwas ändert**.
Wo ich etwas gemessen habe, steht die Zahl dabei — Fragen, die eine Messung beantwortet, stehen
hier nicht.

---

## A — Netzlaufwerke (aiml `spec/63`)

**A1. Testserver für SMB.**
Ohne einen Server im Testprozess ist jeder Netz-Test eine Umgebungswette; bei SSH gibt es dafür
den Testserver aus `spec/32_6` §7.  Für SMB sehe ich zwei Wege: (a) ein echter `smbd` in einem
Wegwerf-Verzeichnis, als Testabhängigkeit installiert, oder (b) ein eingebauter Mini-Server, der
nur das spricht, was `netfs` benutzt.
*Vorläufig:* (a), weil ein halber SMB-Server schnell mehr Fehler hat als der Code, den er prüfen
soll.
*Ändert:* ob `libsmbclient` überhaupt gegen echte Serverantworten getestet wird oder nur gegen
meine Annahmen.

**A2. Mounts auf Knoten — überhaupt?**
Weg B (Kernel-Mount) braucht root und steht damit gegen „Agent nicht als root".  Weg A
(Client-Bibliothek, kein root) plus Weg C (FUSE, kein root) deckt alles ab, was aiml-Code selbst
tut; ein Mount wird nur gebraucht, wenn **fremde Programme** im Schritt den Pfad sehen müssen
(`cmake`, `gcc`, `tar`).
*Vorläufig:* kein Mount; FUSE, wenn fremde Programme den Pfad brauchen.
*Ändert:* ob die Knoten-Einrichtung (`doc/spec/94`) um Mount-Schritte wächst — mit allem, was
daran hängt (Anmeldedaten auf dem Knoten, Neustart-Festigkeit, `_netdev`).

**A3. `user_allow_other` auf Knoten.**
Ohne diese Zeile in `/etc/fuse.conf` sieht **nur der mountende Benutzer** einen FUSE-Pfad
(gemessen: auf dieser Maschine nicht gesetzt).  Ein Schritt, der als Dienstnutzer läuft und ein
Programm als anderen Benutzer startet, sieht den Pfad dann nicht.
*Vorläufig:* nicht setzen; alles läuft als derselbe Dienstnutzer.
*Ändert:* ob die Einrichtung eine systemweite Datei anfasst — das ist eine Rechte-Entscheidung,
keine Bequemlichkeit.

**A5. Zeitgrenze für Netzzugriffe — welcher Wert?**
Gemessen: `netfs.connect` kehrt sofort zurück (nur Schema + Anmeldedaten), der erste **Zugriff**
auf einen nicht erreichbaren Server blockierte über zwei Minuten — libsmbclient bringt eigene,
großzügige Fristen mit.  Ohne Grenze belegt ein Schritt an einem toten Dateiserver sein Lehen,
bis es abläuft, und sieht bis dahin aus wie Arbeit (`spec/63` F63-12).
*Vorläufig:* Grenze an der Verbindung, Vorgabe eher klein (10 s).
*Ändert:* wie lange ein Bauschritt auf ein langsames, aber lebendes Netzlaufwerk warten darf —
zu klein bricht echte Übertragungen ab.

**A6. Ein Anmeldedaten-Satz je Prozess?**
Die heutige Bindung nutzt die globale libsmbclient-Schnittstelle: eine Rückfrage-Funktion, ein
aktiver Satz Anmeldedaten.  Zwei Verbindungen zu verschiedenen Servern mit verschiedenen Konten
gehen damit nicht gleichzeitig.
*Vorläufig:* ein Satz je Prozess.
*Ändert:* ob die Bindung auf `smbc_new_context` umgestellt wird (mehr Symbole, echte
Mehrfachverbindungen).

**A4. Kerberos/AD.**
`libsmbclient` kann Kerberos.  In einer Firmenumgebung ist das oft der einzige erlaubte Weg; es
bringt aber Ticket-Lebensdauern, Keytabs und Uhrzeit-Abhängigkeit mit.
*Vorläufig:* Benutzer/Passwort aus einer Datei mit `0600`.
*Ändert:* ob `netfs_cred` ein zweites Gesicht bekommt (Keytab statt Passwort) und wer die Tickets
erneuert.

---

## B — Sichtbarkeit (cosmos `doc/spec/97`, `99`)

**B1. 3D jetzt oder später?**
Das Lane-Gitter steht in 2D (gemessen, Bild in `doc/spec/ui/shots/RunsScene.png`), und `97` §97.7
hält fest, dass die Abbildung in 3D **dieselbe** ist — nur die Kamera kommt dazu.  3D bringt ab
drei Achsen echten Gewinn, darunter kaum.
*Vorläufig:* 2D ausbauen (Auswahl, Fenster, Agenten/Speicher), 3D erst, wenn eine echte Matrix mit
drei Achsen im Betrieb läuft.
*Ändert:* ob ich Kamera, Projektion und Maus-Auswahl im Raum baue — das ist ein eigener Brocken,
kein Zusatz.

**B2. Welche Zelle ist „die Lane"?**
Im Gitter steht je (Lane, Stufe) ein Eintrag.  Beim Klick auf eine Zelle: zeigt das Detailfeld den
**Schritt** (es kann mehrere je Stufe geben) oder die **Stufe**?
*Vorläufig:* die Stufe, weil der Lauf-Datensatz heute je (Lane, Stufe) einen Eintrag hat (`96`
F96-31).
*Ändert:* ob `PipelineStage` auf Schritt-Ebene aufgelöst wird — also mehr Einträge je Lauf.

**B3. KV-Sicht: welche Kennzahlen sind es wert?**
`99` F99-5 nennt WAL-Größe und letzten Schreibvorgang, weil genau die in 9rooms eine Fehlsuche
über Tage verursacht haben.  Mehr ginge (Lesezahl, Treffer, Fragmentierung), kostet aber je Zahl
eine Stelle, die sie pflegt.
*Vorläufig:* nur die zwei.
*Ändert:* wie viel Zählwerk in die KV-Schicht wandert — und das ist ein heißer Pfad.

**B4. Darf die Oberfläche eingreifen?**
`99` F99-11 sagt: die Sicht ist lesend, Eingriffe sind eigene RPCs mit Bestätigung.  Die Frage ist,
**welche** Eingriffe es überhaupt geben soll (Agent trennen? Speicher schließen? Lauf abbrechen?).
*Vorläufig:* nur Lauf-Steuerung (`96` F96-11), kein Eingriff in Agenten oder Speicher aus der UI.
*Ändert:* die Angriffsfläche — jeder Eingriff ist ein RPC, den jemand missbrauchen kann.

---

## C — Sprachen: Pipeline-Katalog, Konfiguration, Infrastruktur (`doc/spec/100`)

**C1. Ein Kern statt drei Sprachen — einverstanden?**
`100` F100-1/F100-2 legt fest: keine zweite Grammatik, alles ist aiml (Daten + Code), und jede
Domäne hat dieselben vier Verben (`declare`/`plan`/`apply`/`read`).  Das ist die Entscheidung, an
der alles andere hängt.
*Vorläufig:* so gebaut.
*Ändert:* alles — mit drei Sprachen sieht jede Domäne anders aus.

**C2. Kein Zustandsspeicher — tragen wir die Folge?**
`100` F100-6: cosmos führt **keine** `state`-Datei wie Terraform, sondern liest das Ist aus dem
laufenden System.  Das nimmt eine ganze Fehlerklasse weg (Sperren, veralteter Zustand, Geheimnisse
in der Datei), **verlangt aber**, dass jede Domäne ein ehrliches `read` hat.  Für Knoten ist das
machbar (`94` prüft ohnehin nach).  Für eine künftige Domäne „Cloud-Ressourcen" wäre es schwer.
*Vorläufig:* kein Zustandsspeicher; Domänen ohne `read` kommen nicht in den Kern.
*Ändert:* ob cosmos je Dinge verwalten kann, die sich nicht zurücklesen lassen.

**C3. Wer darf `apply`?**
`apply` ändert Knoten und Controller-Konfiguration.  Das ist mächtiger als `run_pipeline`.
*Vorläufig:* eigene Rolle (`operator` darf laufen lassen, `apply` braucht mehr).
*Ändert:* das Rollenmodell aus `100` §100.4 — und ob es überhaupt mehr als zwei Rollen gibt.

**C4. Katalog: ziehen oder geschoben?**
`from_repo` kann heißen: cosmos klont regelmäßig (ziehen), oder ein Haken im Repo meldet Änderungen
(schieben).  Ziehen ist einfach und langsam, Schieben schnell und braucht einen erreichbaren
Endpunkt.
*Vorläufig:* ziehen, Intervall konfigurierbar.
*Ändert:* ob cosmos von außen erreichbar sein muss — eine Sicherheitsfrage, keine Geschmacksfrage.

**C5. Was passiert mit laufenden Läufen bei `apply` auf den Katalog?**
Eine Pipeline, die gerade läuft, verschwindet aus dem Katalog.
*Vorläufig:* der Lauf läuft zu Ende (er trägt seinen Quelltext, `96` F96-32), nur neue Läufe sind
nicht mehr startbar.
*Ändert:* ob `apply` jemals etwas abbricht — ich würde das ungern einbauen.

---

## E — Zuteilung und Maßstab (`doc/spec/101`, `102`)

**E1. Faire Verteilung — welche Regel?**
Heute gilt: wer zuerst fragt, bekommt zuerst (`101` F101-1).  Das genügt bei gleichen Agenten.
Sobald schnelle und langsame Knoten gemischt sind, braucht es eine Regel (nach Label? nach
Warteschlangenlänge? nach letzter Dauer desselben Schlüssels?).
*Vorläufig:* wer zuerst fragt.
*Ändert:* ob der Server Last kennen muss — und damit, ob Agenten mehr melden als einen Takt.

**E2. Aufbewahrungsfristen.**
Läufe, Ausgabebäume und Cache-Einträge wachsen monoton (`102` F102-6).  Ohne Regel ist die erste
echte Grenze die Plattengröße, und sie kommt ohne Vorwarnung.
*Vorläufig:* nichts wird gelöscht.
*Ändert:* ob `verify` (§96.5) und `resume` (F96-14) auf alte Läufe noch anwendbar sind — eine
Aufbewahrungsfrist nimmt genau diese Möglichkeit weg.

**E3. Mehrere Controller — jemals?**
`102` F102-3/F102-5 hält den Weg offen (Lauf = Verteilungseinheit, CAS unveränderlich geteilt,
sonst nichts gemeinsam), baut aber nichts.
*Vorläufig:* ein Controller.
*Ändert:* ob Agenten mehrere Adressen kennen müssen und ob der Katalog zentral bleibt.

**E4. Aufräumen nach Knotenausfall mitten im Schritt.**
`101` regelt, dass das Lehen abläuft und neu zugeteilt wird — nicht, wer den halb geschriebenen
Arbeitsbereich auf dem toten Knoten wegräumt.
*Vorläufig:* der nächste Lauf auf diesem Knoten überschreibt ihn.
*Ändert:* ob Arbeitsbereiche eine Lebensdauer brauchen (und damit einen Aufräumdienst).

**E5. `opaque` und doppelte Ausführung.**
Zustellung ist mindestens einmal (`101` F101-5).  Für `pure`/`resolved` ist das harmlos, für
`opaque` nicht: ein `opaque`-Schritt kann zweimal laufen (z.B. zweimal deployen).
*Vorläufig:* so dokumentiert, nicht verhindert.
*Ändert:* ob es eine Schrittart „höchstens einmal" geben muss — die wäre dann nicht
wiederholbar und damit bei jedem Netzfehler endgültig kaputt.

---

## D — Sonstiges, das mir aufgefallen ist

**D2. ~~`ref<Modell>` als METHODEN-Parameter trägt nicht.~~ — ERLEDIGT, war meine Fehldiagnose.**
Nachgeprüft mit einem minimalen Nachbau (`aiml/tests/test_ref_model_method_arg.aiml`):
`ref<Modell>` an einer Methode **trägt** — lesend, ändernd, und auch für ein Modell in einem
Modell (`pair.left`).  Die IR-Meldung „Call parameter type does not match function signature" kam
in Wahrheit vom **Literal-Breiten-Fehler** (D3b): ein `i32`-Literal an einem `i64`-Parameter.  Ich
hatte zwei Dinge auf einmal geändert und daraus den falschen Schluss gezogen.
Die Umgehung im Zuteiler („Liste statt Modell") ist zurückgenommen, `StepScheduler` nimmt wieder
`ref<PipelineRun>`, 18/18 grün.  Der Nachbau bleibt als Regressionstest stehen.
*Keine Frage mehr — nur die Richtigstellung, weil die vorherige Fassung das Gegenteil behauptete.*

**D3. Zwei Compiler-Fehler gefunden und behoben (nur zur Kenntnis).**
(a) Zwei Klassen mit gleichnamiger Methode und verschiedenem Rückgabetyp brachten den Compiler
zum Absturz (`render` void vs. `render` string) — die Auflösung ging über den blanken
Methodennamen statt über die Klasse des Empfängers.
(b) Ein ganzzahliges **Literal** an einem `i64`-Parameter einer **Methode** kam als `i32` an; die
IR-Prüfung scheiterte.  Für freie Funktionen war die Angleichung schon da.
Beide mit Regressionstest in `aiml/tests/`.  Keine Frage, nur damit es nicht untergeht.

**D1. `test_mem_render_probe.aiml` blockiert die aiml-Suite.**
Der Test öffnet ein Fenster und wartet; `run_all_tests.sh` hat **gar keinen** Timeout.  Mit
Display hängt die Suite dort, bis man den einen Prozess beendet (gemessen: 28 min, 43 s CPU).
*Vorläufig:* ich beende ihn im Lauf per Wächter.
*Ändert:* ob der Test ein Abbruchkriterium bekommt (Bildzähler) oder `# Requires: display` plus
ein Timeout in der Suite.

---

# Block F — Architektur Ausführungskette und Oberfläche (Nacht 2026-10-13/14)

Entstanden aus zwei Vorwürfen: *„die UI ist unsauber, der Agenten-Zustand steht nicht
überall"* und *„ich habe nicht kapiert, wie die Pipeline auf dem Agenten laufen könnte."*
Beides ist jetzt spezifiziert (doc/spec/103, doc/spec/104) und zum Teil gebaut. Was offen
bleibt, steht hier — **nichts davon ist stillschweigend entschieden**.

## F1 — Ein Schritt ist heute eine Shell-Zeile, kein aiml-Rumpf

Das eingereichte Pipeline-Dokument (spec/62) beschreibt Schritte als **aiml-Rümpfe**
(`step: { name, args, body }`). Ausführbar gemacht habe ich zunächst `run:` — eine
Shell-Zeile am Schritt —, weil der Sandkasten das direkt ausführt und die Kette damit heute
Ende-zu-Ende läuft.
*Vorläufig:* `run:` fehlt → Schritt gilt als nicht ausführbar und sagt das (F103-1).
*Ändert:* ob aiml-Rumpf-Schritte über `sys.bundle`/`sys.exec` nachgezogen werden (die
Vorarbeit aus spec/29_2 liegt da) **oder** ob `run:` die vorgesehene Form bleibt und spec/62
entsprechend nachzieht. Beides ist vertretbar, aber es sind zwei verschiedene Produkte.

## F2 — Das Netz im Sandkasten ist offen

`--unshare-net` ist bewusst **nicht** gesetzt (F103-8): ein Build, der seine Abhängigkeiten
nicht laden kann, ist kein Build.
*Ändert:* ab wann fremde Schritte laufen sollen. Für eigene, vertrauenswürdige Agenten ist
offen richtig; beim ersten fremden Nutzer ist es die größte verbleibende Lücke.

## F3 — Keine Daten zwischen Schritten

`input_tree` bleibt leer, ein Schritt sieht die Ergebnisse des vorigen nicht (§103.8).
`bwrap` 0.9.0 hat **kein** `--overlay`, der writeset-Mechanismus aus §AP2.D braucht also
einen eigenen Mount im Namespace.
*Ändert:* ob die nächste Scheibe overlayfs selbst mountet (Namespace-Primitive als
aiml-Builtins, wie spec/91 §AP2.A.2 vorsieht) oder ob Artefakte über das CAS wandern.

## F4 — Ein Agent nimmt einen Schritt zur Zeit

`capacity` wird übertragen, aber nicht benutzt (§103.8). Parallelität je Agent ist spec/91
§AP2.B und braucht Sende-Lock, Fehlerradius-Entscheidung und eine Lauf-Liste je Agent in
der Oberfläche.
*Ändert:* ob Durchsatz über mehr Agenten oder über mehr Plätze je Agent wächst.

## F5 — `subscribe_agents` ist jetzt doppelt

F104-1 sagt: EIN Schnappschuss. `ClusterView` trägt die Agenten inzwischen mit
(`snapshot_live`), der eigene Agenten-Kanal existiert aber noch.
*Vorläufig:* beide laufen; der Agenten-Bildschirm nutzt weiter den alten Kanal.
*Ändert:* ob `subscribe_agents` entfällt (dann ist der Agenten-Bildschirm umzustellen) oder
als schmaler Kanal für hochfrequente Anwesenheit bleibt. Ich empfehle entfallen — zwei
Kanäle sind genau die Ursache des ursprünglichen Vorwurfs.

## F6 — Tests schreiben in das echte KV

`test_step_dispatch` öffnet dieselben persistenten Stores wie der Server (`db.open_kv
"pipelines"`). Ein Lauf hinterlässt Spuren im nächsten, und ein Schema-Wechsel macht
**beide** unbrauchbar.
*Gemessen heute Nacht:* genau das ist passiert.
*Ändert:* ob Tests einen eigenen Store-Pfad bekommen (Umgebungsvariable) oder ob `db.open_kv`
einen `{persist: false}`-Modus für Tests vorsieht.

## F7 — Ein unverträgliches KV war ein Absturz, jetzt ist es leer

Die Erkennung („schema fp stored≠expected") war da und meldete sauber — danach stürzte der
Prozess beim ersten `.len` ab, weil das genullte Modell **null-Container-Handles** hatte.
Behoben (aiml `db_runtime.cpp`: `aiml_ser_init_empty_containers` auf allen Fehlerpfaden, nicht
nur in `get_copy_at`).
*Offen:* ein unverträgliches KV liefert jetzt **stillschweigend leere Datensätze**. Das ist
besser als ein Absturz, aber immer noch keine Migration.
*Ändert:* ob cosmos beim Start einen Schema-Wechsel erkennt und sagt „diese Stores sind
veraltet, hier ist der Rettungsweg" (vgl. 9rooms-KV-Migration) statt leer weiterzulaufen.

## F8 — Die 91 MB je Einrichtung

Der Agent braucht die ganze aiml-Laufzeit samt LLVM, GL und X11, weil `builtin_registry`
alle Builtins registriert.
*Ändert:* ob die Laufzeit in einen headless Kern und eine optionale Grafikschicht getrennt
wird. Danach wäre ein **einzelnes statisches Binary** möglich (ssl/crypto/z haben statische
Archive, GL/GLEW/glfw/assimp/zip/ssh nicht) — und die Einrichtung bräuchte kein Archiv mehr.

---

# Block G — Globals-Umzug und Jenkins-Form (Nacht 2026-10-14/15)

## G1 — Der letzte Global hängt an `engine.run`

`g_cosmos_app` ist die Rückruf-Brücke: `engine.run(win, update, render)` nimmt nackte
Funktionszeiger ohne Kontext, also findet `cosmos_update` die App nur über ein Global.
9rooms landet aus demselben Grund bei demselben einen Global.
*Festgehalten:* aiml `spec/44_1`, Abschnitt „Offen: `engine.run` trägt keinen Kontext".
*Ändert:* ob der additive Kontext-Parameter gebaut wird — danach sind es **null** Globals in
beiden Projekten. Dein Entscheid war „jetzt nicht".

## G2 — Ein Job ohne Zeitplan ist nur ein halber Job

doc/spec/106 kennt Job, Lauf, Nummer und Übersicht — aber keinen **Auslöser**. Jenkins hat
Cron, SCM-Polling und Hooks.
*Ändert:* ob als nächstes ein Zeitplan (`schedule: "H/15 * * * *"`) oder ein Webhook kommt.
Ohne beides muss jeder Lauf von Hand gestartet werden.

## G3 — Lauf-Geschichte je Job fehlt noch

`JobDef` trägt nur das **letzte** Ergebnis (F106-1, damit die Dashboard-Zeile keinen Scan
kostet). Eine Liste „die letzten 20 Läufe mit Nummer, Dauer, Ergebnis" gibt es nicht.
*Ändert:* ob die Läufe im Schnappschuss mitreisen (teuer, aber eine Quelle) oder per RPC
nachgeladen werden (billig, aber ein zweiter Kanal — §104.0 warnt davor).

## G4 — Jobs anlegen geht nur per RPC, nicht in der Oberfläche

`save_job`/`run_job` sind da und geprüft; der Pipeline-Bildschirm schickt aber weiterhin
`run_pipeline` (Lauf ohne Job).
*Ändert:* ob der Pipeline-Bildschirm zum **Job-Editor** wird (Name + Quelle speichern,
starten) — dann verschwindet `run_pipeline` als Nutzerweg.

## G5 — `note_run_result` hat noch keinen Aufrufer

Der Server schreibt das Ergebnis eines Laufs **noch nicht** in den Job zurück: die Methode
ist da und geprüft, aber `report_step` ruft sie nicht, weil ein Lauf erst „fertig" ist, wenn
**alle** Stufen fertig sind.
*Ändert:* wo der Lauf-Abschluss erkannt wird (im Scheduler beim letzten `report`, oder in
einem Durchlauf über die Läufe). Bis dahin bleiben `last_status`/`runs_total` auf 0.
