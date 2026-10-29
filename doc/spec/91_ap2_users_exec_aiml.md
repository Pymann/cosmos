# AP2 — Ausführung: Identität, Parallelität, Schritte

**Status:** Entwurf.  Fasst deine Entscheidungen vom 2026-10-09 (§AP2.0) und beschreibt,
was daraus folgt.  Das eigentliche Nachdenken steckt in §AP2.D (Schritt-Modell) — dort
hängt auch „aiml an den Agenten senden" dran, statt als Einzelfeature entschieden zu werden.

## AP2.0 Entschieden (User, 2026-10-09)

1. **„User-Verwaltung" meint die Ausführung, nicht Web-Konten.**  Es geht darum, unter
   welcher **Systemidentität** die Prozesse eines Agenten laufen (least privilege, wie bei
   Containern nicht als root) → §AP2.A.  Die **Kontenverwaltung in cosmosd** (Rollen,
   Einladungen, Nutzerliste) wird **zurückgestellt** → §AP2.E.
2. **Global vorgemerkt:** es braucht eine **durchgängige Möglichkeit, UI-Elemente für
   bestimmte Nutzer zu verbergen** → §AP2.C.  (Wird gebraucht, sobald Rollen kommen; als
   Querschnittsfunktion jetzt festgehalten, damit die Oberfläche nicht später umgebaut
   werden muss.)
3. **Parallelität: echte aiml-Threads im Agenten** (gegen meine Empfehlung; Konsequenzen
   in §AP2.B offen benannt).
4. **aiml-Ausführung nicht isoliert entscheiden:** jeder Schritt soll **abgespeichert**
   werden „wie ein Docker-Layer", mit **prüfbarer Vertauschbarkeit** und
   **Wiederholbarkeit**, inhaltsadressiert; und statt direkt einen Agenten zu wählen
   später eine **Node-Closure/Label-Auswahl wie bei Jenkins** → §AP2.D.
5. **SSH dient der EINRICHTUNG eines Knotens, nicht der Ausführung** (User, 2026-10-09).
   Der Nutzer gibt die `sudo`-Berechtigung **einmal im Server** ein, und der Server richtet
   den Agenten auf dem Knoten selbst ein — Binary, AppArmor-Profil, `uidmap`, Dienst,
   Token.  Ziel: der Nutzer muss auf dem Knoten **nichts** von Hand tun.
   Ausgeführt wird weiterhin über den **ws-Agenten** (AP1); SSH ersetzt ihn nicht.
   Umsetzung über `libssh` als aiml-FFI-Bindung — begründet in → doc/spec/94.
6. **writeset bleibt overlayfs** (User, 2026-10-09).  Die Variante „writeset über
   CAS-Bäume" (`put_tree` vor/nach dem Schritt, Differenz = writeset) wurde erwogen und
   **zurückgestellt**: sie bräuchte keine Kernel-Privilegien und damit kein AppArmor, ist
   aber erst sinnvoll, wenn eine **git-artige Schicht** da ist, die Änderungen ohnehin
   ohne Kernel-Hilfe erkennt.  Bis dahin sammelt der Kernel den writeset.

## AP2.A Ausführungs-Identität (least privilege)

**Ist-Stand, am Quelltext geprüft — und er ist dünner als erhofft:**
- `sys.exe` kennt `cwd`, `env`, `shell`, `timeout`, `capture`, `stdout`, `stderr`,
  `detach`, `status_file` — **keine** `user`/`uid`/`gid`-Option (spec/23 §5.1).
- `process_runtime.cpp` enthält **kein** `setuid`/`setgid`/`initgroups`.
- Folge: **jeder** Job läuft unter der Identität des Agenten.  Startet jemand den Agenten
  als root, läuft fremder Build-Code als root.  AP1.6 sagt „Agent nicht als root" — das ist
  heute die **einzige** Schutzmaßnahme und reine Betriebsdisziplin.

**Zwei Wege (Entscheidung offen, §AP2.F-1):**

| Weg | Wie | Preis |
|---|---|---|
| **1. `sys.exe({user: …})`** — aiml-Erweiterung: zwischen fork und exec `setgid` + `initgroups` + `setuid` | klein und verständlich; je Job ein eigener Systemnutzer möglich | der **Agent braucht Privilegien** (root oder `CAP_SETUID`), um sie abzugeben — genau das, was du vermeiden willst, nur verlagert |
| **2. rootless + User-Namespace** (Recherche 04) | Agent bleibt **unprivilegiert**; je Job ein User-Namespace, drinnen „root", draußen eine subuid; `idmapped mounts` löst die Volume-Ownership | kein root auf dem Host nötig, echte Isolationsgrenze, Grundlage für Container und für die Snapshots aus §AP2.D | braucht `newuidmap`/subuid-Setup und die Container-Schicht — deutlich mehr Arbeit |

**Entschieden (User, 2026-10-09): Weg 2, direkt — bestätigt am selben Tag**, nachdem die
privilegienfreie Alternative (writeset über CAS-Bäume statt overlayfs) erwogen und auf eine
spätere git-artige Schicht verschoben wurde (§AP2.0 Punkt 6).  Weg 1 wird nicht gebaut — er bräuchte
einen privilegierten Agenten und würde von Weg 2 ohnehin überholt (dieselbe Schicht trägt
die overlayfs-Snapshots aus §AP2.D; Recherche 03: „eine Schicht, zwei Zwecke").
**Nicht** verwendet wird auch „`su`/`setpriv` in die Shell-Zeile": dann steckt die
Privilegienabgabe im Nutzer-Kommando und ist nicht durchsetzbar.

### AP2.A.1 Betriebsvoraussetzungen auf dem Host (gemessen 2026-10-09)

Auf dem Entwicklungsrechner (Ubuntu, Kernel 7.0.0-34-generic) geprüft:

| Voraussetzung | Stand | Folge |
|---|---|---|
| `/etc/subuid` + `/etc/subgid` | **vorhanden** (`nikolai:100000:65536`) | ID-Bereich zum Abbilden ist da |
| `newuidmap` / `newgidmap` (Paket `uidmap`) | **fehlen** | ohne sie lässt sich nur **eine** ID abbilden, kein Bereich → zu installieren |
| `kernel.unprivileged_userns_clone` | `1` | Namespace-Erzeugung grundsätzlich erlaubt |
| `kernel.apparmor_restrict_unprivileged_userns` | **`1`** | **der Knackpunkt**, siehe unten |
| Helfer | `bwrap`, `unshare`, `setpriv` da; `podman`/`crun` fehlen | bwrap hat **kein** AppArmor-Profil |

**Der AppArmor-Mechanismus und warum er uns direkt betrifft:** Ein *unconfined* Prozess,
der einen unprivilegierten User-Namespace erzeugt, wird dabei in das mitgelieferte Profil
`/etc/apparmor.d/unprivileged_userns` überführt.  Dieses Profil enthält
`audit deny capability` — **innerhalb des Namespace gibt es keine Capabilities**.  Damit
kann der Job dort **nicht mounten**, und `mount -t overlay` ist genau das, was §AP2.D für
die Snapshots braucht.  Deshalb bringt `podman` ein **eigenes** Profil mit.

**Konsequenz für cosmos:** der Agent braucht ein **eigenes AppArmor-Profil**, das `userns`
erlaubt **und** die innen benötigten Capabilities (mindestens `CAP_SYS_ADMIN` für Mounts im
eigenen Namespace) nicht wegnimmt.  Das Profil ist damit ein **Auslieferungsartefakt** von
cosmos, kein Nebenschritt — und es gehört in die Abnahme (A4 unten).  Die Alternative, den
sysctl systemweit auf `0` zu setzen, schwächt den ganzen Rechner und ist deshalb keine.

### AP2.A.2 Abhängigkeiten — wie sie gebunden sind

**Regel (User):** Abhängigkeiten werden über die `exodus-*.json` deklariert, nicht per Hand
installiert.  `exodus pkg add` + `pkg install` lädt per `apt-get download` und entpackt mit
`dpkg-deb -x` nach `__exodus_cache/apt/<name>/<arch>/<version>/payload/` — **keine
Systeminstallation, kein `sudo`**, und Version + sha256-Digest landen in der Konfiguration.

**Gebunden (2026-10-09, in `test/aiml/exodus.json`):**
| Paket | Version | Zweck |
|---|---|---|
| `libcap-dev` (+ `libcap2`) | `1:2.66-5ubuntu2.4` | Capabilities im Namespace gezielt abgeben |
| `libseccomp-dev` (+ `libseccomp2`) | `2.5.5-1ubuntu3.1` | Syscall-Filter deny-by-default (Recherche 03) |

Beide mit Digest; Header (`sys/capability.h`, `seccomp.h`) und `libcap.so`/`libseccomp.so`
liegen im Cache.  **Noch nicht** in `linker.libraries` — das kommt mit dem Code, der sie
benutzt, damit nicht jeder Build zwei unbenutzte Bibliotheken linkt (und der wasm32-Build
nicht an nativen Libs scheitert).  `exodus build --all` nach dem Binden unverändert grün.

**Warum in aiml und nicht in cosmos:** die Namespace-/Mount-/Seccomp-Primitive werden
aiml-Builtins; cosmos konsumiert sie nur.  (Der dabei gefundene Mangel, dass die
`exodus pkg`-Unterbefehle keine Ziel-Konfiguration ansprechen konnten, ist **behoben** —
siehe unten.)

**Werkzeug-Fixes am Rande (exodus, 2026-10-09).**  Beim Binden fiel auf, dass sich
Abhängigkeiten für Projekte mit mehreren Zielen gar nicht deklarieren liessen:
1. `exodus pkg {list,add,remove,install,add-conan,remove-conan,install-conan-configured}`
   kannten **kein** `-c/--config` und arbeiteten fest auf `exodus.json`; cosmos hat aber
   nur `exodus-<ziel>.json`.  Jetzt haben alle `-c/--config` **und** `--all` (fan-out über
   alle erkannten Projekt-Konfigurationen), mit denselben Regeln wie `build`.
2. `Project.save()` schrieb bei jedem Speichern **alle Defaults** aus: eine handgeschriebene
   29-Zeilen-`exodus-<ziel>.json` kam als 114 Zeilen Defaults zurück.  Jetzt bleiben nur
   die Felder, die die Datei hatte, plus die tatsächlich geänderten — rekursiv, auch in
   `compiler`/`linker`, und in der Reihenfolge der Datei.  Eine **neue** Datei bekommt
   weiterhin das vollständige Gerüst.
   *Dabei zwei eigene Fehler gefunden und behoben:* `exclude_unset` allein hätte ein
   frisch hinzugefügtes Paket **stillschweigend verworfen** (die Aufrufer mutieren die
   Liste in place, was pydantic nicht als „gesetzt" vermerkt), und das Kürzen hätte beim
   **Anlegen** einer Datei `$schema` entfernt, womit `discover_config_names` sie nicht
   mehr erkannt hätte.  Exodus-Testsuite danach: 69 bestanden, 3 Fehler — **dieselben
   drei wie auf unberührtem HEAD** (analyze ×2, sbom ×1, beide vorbestehend).

**Was sich NICHT so binden lässt** (und deshalb Betriebsvoraussetzung bleibt):
1. **`uidmap` (`newuidmap`/`newgidmap`).**  Diese Helfer funktionieren nur **setuid root**.
   Aus einem entpackten Cache-Payload, der dem Nutzer gehört, ist das prinzipiell nicht
   herstellbar — ein deklariertes `uidmap` würde eine erfüllte Abhängigkeit nur
   *vortäuschen*.  Deshalb **nicht deklariert**.  Gebraucht würde es erst, wenn ein
   Namespace **mehrere** IDs abbilden muss; die erste Scheibe bildet nur **eine** ab
   (Agent-uid → 0 innen) und braucht daher keinen Helfer.
2. **Die AppArmor-Richtlinie.**  Ein Profil ist Systemkonfiguration, kein Paket.  cosmos
   liefert es als Artefakt mit (§AP2.A.1), eingespielt wird es beim Aufsetzen des Hosts.

**Belegt (2026-10-09), nicht mehr vermutet.**  `probe_isolation.sh` prüft die Kette und
liest die Verweigerung aus dem Kernel-Log.  Ergebnis auf diesem Host:
- Einen User-Namespace **erzeugen** ist erlaubt (`unshare -U` läuft).
- Die **ID-Abbildung schreiben** wird verweigert — und das Audit-Log benennt die Ursache
  eindeutig als AppArmor, nicht als Umgebung:
  ```
  apparmor="DENIED" operation="capable" profile="unprivileged_userns" capname="setpcap"
  apparmor="DENIED" operation="open"    profile="unprivileged_userns"
                    name="proc/<pid>/uid_map" requested_mask="wr" denied_mask="wr"
  ```
  (ebenso `capname="sys_admin"` für `unshare`, und `bwrap` scheitert identisch).
  `info="Failed name lookup - disconnected path"` erklärt, warum selbst das
  `allow file rwlkm /**` dieses Profils nicht greift.

**Gewähltes Mittel: bubblewrap mit eigener Kopie (2026-10-13).** Den Namespace erzeugt
`bwrap`, nicht der Agent — es bringt `--ro-bind`, `--tmpfs`, `--proc`, `--dev`,
`--die-with-parent` und Seccomp fertig mit, statt dass cosmos sie nachbaut. Gemessen: `bwrap`
0.9.0 ist **nicht** setuid und scheitert unprofiliert mit `setting up uid map: Permission
denied`, also an derselben Wand. Die Einrichtung bringt deshalb eine **eigene Kopie** nach
`<install_dir>/bwrap` aus und berechtigt im Profil genau diesen Pfad; das systemweite
`/usr/bin/bwrap` bleibt unberechtigt, und die Sicherheitsgrenze hängt nicht an der Frage, ob
sich ein AppArmor-Profil auf Kindprozesse vererbt. **Grenze:** 0.9.0 hat **kein** `--overlay`
— der writeset-Mechanismus aus §AP2.D braucht weiterhin einen eigenen Mount im Namespace.

**Also ist Weg 2 ohne eigenes Profil blockiert** — nicht teilweise, sondern am ersten
Glied.  Ein Prozess mit EIGENEM Profil wird nicht nach `unprivileged_userns` überführt;
`userns` erlaubt ihm das Erzeugen, `flags=(unconfined)` schränkt darüber hinaus nichts ein
(die Einschränkung des Jobs leistet der Namespace, nicht AppArmor).

**Artefakte dazu im Repo:**
- `deploy/apparmor/cosmos-agent` — das Profil samt Begründung, Einspiel- und Prüfanleitung.
  Pfad muss an das Agent-Binary angepasst werden (AppArmor bindet an den Binärpfad).
- `probe_isolation.sh` — prüft ID-Bereiche, Politik, Namespace, overlayfs und das writeset;
  meldet bei Fehlschlag das konkrete fehlende Glied samt Audit-Zeile.
- `sources/agent/agent_isolation.aiml` — **dieselbe Kette im Agenten** (Abnahme A5), erreichbar
  als `agent --verify-isolation`: Rückgabe 0 und `ISOLATION_OK`, sonst 1 und der Name des
  fehlenden Glieds.  Sie gehört in den Agenten, weil AppArmor an den **Binärpfad** bindet —
  nur ein Prozess, der *dieses* Binary ist, trägt das Profil und darf `userns`.  Deshalb ruft
  auch Schritt 9 der Einrichtung (doc/spec/94) dieses Flag auf statt eines blanken `unshare`.
  Gemessen 2026-10-13 ohne Profilabdeckung: Glied „User-Namespace + ID-Abbildung", Meldung
  `unshare: Schreiben fehlgeschlagen /proc/self/uid_map` — die Probe zeigt also an, was sie soll.

**Nächster Messpunkt:** nach dem Einspielen des Profils muss die Probe „TRÄGT" melden —
inklusive Schritt 4 (overlayfs im Namespace) und Schritt 5 (writeset aus der
upper-Schicht).  Erst dann ist §AP2.D Scheibe 2 baubar.

**Abnahme.**  A1 Ein Job kann nicht auf Dateien zugreifen, die nur dem Agent-Nutzer
gehören.  A2 Der Agent läuft nachweislich unprivilegiert (`id` im Job zeigt eine andere,
unprivilegierte Identität als die des Agenten).  A3 Zwei Jobs sehen die
Arbeitsverzeichnisse des anderen nicht.  A4 Der Agent kann im eigenen Namespace
**overlayfs mounten** — mit dem mitgelieferten AppArmor-Profil, **ohne** den systemweiten
sysctl zu verändern.  A5 Fehlt eine Voraussetzung (uidmap, Profil), sagt der Agent beim
Start klar, was fehlt, statt im ersten Job daran zu scheitern.

## AP2.B Parallele Ausführungsplätze — mit aiml-Threads

Deine Entscheidung: echte Threads (spec/26 `spawn`/`join`), nicht nur mehrere
Kindprozesse.  Das ist tragfähig, aber drei Dinge müssen dann **bewusst** gelöst werden,
sonst holt es uns später ein:

1. **Geteilter Zustand.**  spec/47 §2 ist eindeutig: Globals ohne Lock sind das Risiko.
   Der Agent hat heute genau solche (`<.run_ref`, Offsets, `<.ending`).  Pro Platz ein
   eigener `RunSlot` **und** ein Lock um alles, was mehrere Threads anfassen (Senden über
   dieselbe `mirror_session`!).  `session.send_rpc` aus mehreren Threads gleichzeitig ist
   bis zum Beweis des Gegenteils **nicht** sicher — zu prüfen, sonst ein Sende-Lock.
2. **Fehlerradius.**  Ein abstürzender Thread nimmt den Agenten mit und damit **alle**
   Plätze; bei Prozessen wäre nur der eine Job betroffen.  Das ist der Preis — bei
   fremdem Build-Code ist er hoch.  Milderung: der Thread **überwacht** weiterhin nur
   einen Kindprozess (`sys.exe detach`), rechnet also nicht selbst.  Dann sind Threads
   reine Parallelisierung der Überwachung/IO und der Radius bleibt klein.
3. **Sende-Budget.**  Die Drosselung aus §AP1.7-D7 (max ~1 MB/Tick) gilt **für den Agenten
   insgesamt**, nicht je Thread — sonst feuert er mit N multipliziert und der Server
   trennt die Verbindung wieder (der Fehler, den wir gerade gefunden haben).

**Weiter nötig:** `--executors N`; `AgentInfo.exec_total`/`exec_busy` statt `current_run`
(Liste zeigt „2/4"); serverseitiger Deckel `min(Agent, Policy)`; Ablehnung mit Grund statt
Warteschlange (Scheduling bleibt draußen); `RunStore`-Handle-Cache für mehrere
gleichzeitig schreibende Läufe; **UI-Folge:** die Ausgabe zeigt heute einen Lauf — bei N
Läufen braucht es eine Lauf-Liste je Agent und eine Auswahl, welchem der Live-Tail folgt.

**Abnahme.**  B1 Drei gleichzeitige Kommandos, drei vollständige, getrennte Ausgaben.
B2 Der vierte wird mit Grund abgelehnt.  B3 Policy-Deckel schlägt Agent-Angebot.
B4 **Kriterium 10 neu gemessen** (kein RAM-Wachstum) bei drei parallelen Grossausgaben.
B5 Ein abgestürzter Platz räumt sich auf.  B6 Kein Datenrennen: Lauf-Ausgaben vermischen
sich nie (unter valgrind/helgrind oder gleichwertig geprüft).

## AP2.C Querschnitt: UI-Elemente je Nutzer verbergen

Vorgemerkt (§AP2.0-2).  Damit das später kein Umbau wird, jetzt die Form festlegen:
- Der Server liefert beim Anmelden eine **Fähigkeiten-Liste** (nicht die Rolle selbst):
  z.B. `can_execute`, `can_manage_tokens`, `can_manage_users`, `can_see_all_runs`.
- Die Oberfläche blendet Elemente anhand dieser Liste aus — eine Stelle je Screen, kein
  verstreutes `if role == …`.
- **Verbindlich:** Verbergen ist Komfort, **keine** Sicherheit.  Jede so verborgene Aktion
  muss **serverseitig** dieselbe Prüfung haben (§AP2.E).  Ein Client kann lügen.

## AP2.D Schritt-Modell — inhaltsadressiert, vertauschbar, wiederholbar

Das ist der Rahmen, in den „aiml an den Agenten senden" gehört.  Grundlage: Recherche 02
(CAS) und 03 (Sandbox/Tracing).

**Schritt (Step).**  Ein Schritt ist eine **inhaltsadressierte Aktion**:
```
step_key = hash( action )
action   = { kind: shell | aiml, body_hash, input_tree_hash, env, cwd, platform_req }
```
`body_hash` ist der Hash der Shell-Zeile **oder der aiml-Quelle** — damit ist ein
aiml-Schritt genauso cachebar und wiederholbar wie ein Shell-Schritt.  **Das ist der
Grund, (C) nicht separat zu entscheiden:** ob der Runner die Quelle per Subprozess
(`aiml job.aiml`), in-process (`sys.exec`, nur JIT — spec/29_2 §3.1, AOT liefert `-2`) oder
als vorkompiliertes Artefakt ausführt, ist eine **Eigenschaft des Knotens**, nicht des
Schritts.  Der Schritt verlangt `aiml`, der Knoten sagt, ob und wie er das kann.

**Snapshot je Schritt.**  Ausführung in overlayfs: `lower` = materialisierter
Input-Tree (read-only), `upper` = Schreibschicht.  Danach ist
`output_tree_hash = hash(merge(lower, upper))` und das **writeset = Diff der upper-Schicht
(gratis)**.  Zurückgehen = den Tree eines früheren Schritts materialisieren; von dort
weiterbauen = neuer Elternknoten.  Das ist dein „Docker-Layer je Schritt", nur ohne
Docker-Schwächen.

**Vertauschbarkeit (dein Kernpunkt).**  Docker-Layer sind **positionsabhängig**: ändert
sich ein unterer, müssen alle oberen neu.  Mit readset/writeset je Schritt gilt
stattdessen Bernstein: zwei Schritte sind vertauschbar, wenn
`W1∩R2 = ∅`, `R1∩W2 = ∅`, `W1∩W2 = ∅`.
Daraus folgt beides, was du willst: **Reihenfolge prüfbar tauschbar**, und ein geänderter
unterer Schritt invalidiert **nur** die Schritte, deren readset sein writeset schneidet —
nicht alles darüber.
- **writeset** ist gratis (upper-Diff).
- **readset** ist das schwierige Stück (fanotify/FUSE, Recherche 03).  Startwert
  **konservativ**: readset = ganzer Input-Tree → korrekt, aber grob (invalidiert zu viel).
  Präzision später; Korrektheit nie opfern.

**ActionCache.**  `step_key → output_tree_hash` als typisiertes KV auf AionDB.  Treffer =
Schritt überspringen, Tree materialisieren.  Das ist der sichtbare Nutzen („perfektes
Caching") und der erste Punkt, an dem man es **messen** kann.

**Knoten-Auswahl (Node-Closure).**  Statt `agent_id` nennt ein Schritt **Anforderungen**
(`platform_req`: os, arch, Labels wie `has-aiml`, `has-docker`, `gpu`), der Planer wählt
**irgendeinen** Agenten, dessen Labels die Anforderung erfüllen.  Die heutige direkte
Agentenwahl aus AP1 bleibt als „expliziter Knoten" erhalten (Debug/Betrieb).
Voraussetzung dafür: `AgentInfo.labels` wird echt genutzt (ist als Feld schon da).

**Kleinste erste Scheibe, die das Modell beweist** (Vorschlag, in dieser Reihenfolge):
1. **CAS-Kern** auf AionDB: Blob put/get per Hash, Directory-Tree (Merkle), Materialisierung.
2. **Ein Schritt in overlayfs** auf einem Agenten ausführen; `output_tree_hash` + writeset
   aus der upper-Schicht.
3. ~~**ActionCache**: derselbe Schritt zweimal → zweiter Lauf ist ein Treffer, messbar.~~
   → **erledigt 2026-10-11**: `sources/models/step.aiml` (`StepDef`, `StepOutcome`),
   `sources/server/step_runner.aiml` (`key_of`, `lookup`, `restore`, `record`),
   Test `test/test_step_runner.aiml` (18 Prüfungen) in `run_tests.sh`.

   Bewusst **ohne Ausführung**: der Runner sagt, ob ein Schritt übersprungen werden darf, und
   hält sein Ergebnis fest — wer ihn ausführt, bleibt aussen. Dadurch ist die Scheibe prüfbar,
   obwohl Scheibe 2 noch am AppArmor-Profil des Knotens hängt: der `output_tree` kommt aus
   `put_tree` des Arbeitsverzeichnisses statt aus einer `upper`-Schicht. Der writeset bleibt
   damit **grob** (ganzer Baum) — konservativ, aber korrekt, wie es dieses Kapitel für den
   readset ohnehin vorgibt.

   Wichtiger als der Treffer selbst: ein Treffer **stellt den Zustand wieder her**
   (`restore` materialisiert den `output_tree`), und der wiederhergestellte Baum hat
   nachweislich dieselbe Adresse. Ein Treffer, der nur „nichts tun" bedeutete, wäre nutzlos.
   Geprüft ist ausserdem, dass **kein falscher Treffer** entsteht: geänderter Rumpf, anderer
   Input-Baum, anderes `cwd`, anderes `kind` sind jeweils Fehlschläge.
4. **Vertauschbarkeits-Analyse** als reine Auskunft („dürfen Schritt 3 und 4 tauschen?"),
   noch ohne automatisches Umsortieren.
5. Erst danach: Labels/Node-Closure, dann readset-Präzision, dann verteilte Ausführung.
Punkt 2 braucht die Isolationsschicht aus §AP2.A Weg 2 — deshalb hängen (a) und (d)
zusammen und sollten gemeinsam geplant werden.

## AP2.E Zurückgestellt: Kontenverwaltung in cosmosd

Bewusst nach hinten (§AP2.0-1).  **Aber als Risiko festgehalten:** heute darf **jeder**
angemeldete Nutzer auf **jedem** Agenten ausführen, Agent-Tokens erzeugen und fremde
widerrufen, und es gibt **keine Spur**, wer was gestartet hat (`RunInfo` trägt keinen
Nutzer).  Zwei Dinge wären auch vor der vollen Rollenverwaltung billig und sinnvoll:
- `RunInfo.started_by` (opake `player_id`) mitschreiben — die Spur fehlt sonst rückwirkend.
- Selbstregistrierung abschaltbar machen (ein Schalter), solange es keine Rollen gibt.

## AP2.F Offene Entscheidungen

- ~~**F-1 Isolationsweg**~~ → **entschieden: Weg 2 (rootless/User-Namespace)**, §AP2.A.
- ~~**F-2 Reihenfolge**~~ → **entschieden (User 2026-10-09): direkt §AP2.D Scheibe 1–3**
  (CAS + Snapshot + ActionCache — der eigentliche Hebel).  Die Ausführungsplätze (§AP2.B)
  kommen danach; ohne Isolation wären sie nur mehr gleichzeitige Jobs unter derselben
  Identität.  AppArmor-Profil: **Entwicklerpfad** (`deploy/apparmor/cosmos-agent`).
- **F-3 `RunInfo.started_by` + Registrierungs-Schalter jetzt mitnehmen (klein) oder mit
  der Kontenverwaltung später?**
- ~~**F-4 Was wird aus dem ws-Agenten, wenn Schritte über SSH laufen?**~~ → **entfällt**:
  SSH ist für die **Einrichtung** gedacht, nicht für die Ausführung (§AP2.0-5).  Der
  ws-Agent bleibt der Ausführungsweg; es gibt keine zwei Sicherheitsmodelle nebeneinander.

  Damit löst sich auch das AppArmor-Pfadproblem: das Profil bindet an den **Binärpfad** des
  Prozesses, der den User-Namespace erzeugt — und weil die Einrichtung Binary **und** Profil
  zusammen ausbringt, zeigt das Profil auf den Pfad, an den der Server das Binary gerade
  gelegt hat (Betrieb: `/opt/cosmos/agent`, nicht der Entwicklerpfad).  Siehe doc/spec/94.
