# Kapitel 94 — Agenten-Einrichtung über SSH

**Ziel (User, 2026-10-09):** Der Nutzer gibt die `sudo`-Berechtigung **einmal im Server** ein,
und der Server richtet den Knoten selbst ein. Auf dem Knoten ist **nichts** von Hand zu tun.

Abgrenzung: SSH ist hier **Einrichtungs**weg, nicht Ausführungsweg. Ausgeführt wird weiter
über den ws-Agenten (doc/spec/90, AP1) — es gibt bewusst nicht zwei Ausführungswege mit zwei
Sicherheitsmodellen (§AP2.F-4).

## 94.1 Warum es das braucht

Die Isolation nach §AP2.A (rootless + User-Namespace) hat Voraussetzungen, die **root auf dem
Knoten** erfordern und die sich nicht über `exodus pkg` lösen lassen:

| Voraussetzung | Warum root | Warum nicht über exodus |
|---|---|---|
| AppArmor-Profil in `/etc/apparmor.d/` + `apparmor_parser -r` | Kernel-Richtlinie | Profil muss im System liegen, nicht im Cache |
| `uidmap` (`newuidmap`/`newgidmap`) | **setuid-root**-Binaries | entpackt im Cache wäre das setuid-Bit wirkungslos |
| Bereich in `/etc/subuid` + `/etc/subgid` | Systemdatei | — |
| Eigener unprivilegierter Dienstnutzer | Nutzerverwaltung | — |
| Dienst-Einheit, die den Agenten startet | systemd | — |

Ohne diese fünf Dinge ist der Agent entweder nicht isoliert oder läuft gar nicht. Sie dem
Nutzer als Befehlsliste zu geben ist die heutige Lage — und genau die soll verschwinden.

## 94.2 Was die Einrichtung tut

Reihenfolge ist bindend; jeder Schritt ist **idempotent** (zweimal ausführen darf nichts
kaputt machen) und die Kette ist **fail closed** (bricht ein Schritt ab, wird der Agent
**nicht** gestartet, und die Oberfläche nennt den Schritt).

1. **Verbinden** — SSH zum Knoten, Host-Key prüfen (§94.3). Authentifizierung per Passwort
   oder Schlüssel, in dieser **Reihenfolge: erst Schlüssel, dann Passwort** (wie das Beispiel
   in aiml `spec/32_6` §4). Ein gesetztes Passwort schaltet den Schlüsselweg **nicht** ab:
   ein Knoten, der beide Verfahren anbietet, soll nicht daran scheitern, dass im Formular ein
   Passwort steht. Schlägt **beides** fehl, nennt die Meldung **beide Versuche und libsshs
   eigene Begründung** (`sess.last_error`) — „Anmeldung abgelehnt" allein sagt dem Menschen
   nicht, ob das Passwort falsch war oder das Verfahren gar nicht angeboten wird. Die
   Begründung stammt von libssh und enthält kein Geheimnis; §94.3 S1–S3 bleiben unberührt.
2. **Dienstnutzer anlegen** — eigener unprivilegierter Systemnutzer (z. B. `cosmos-agent`),
   ohne Login-Shell. Least privilege nach §AP2.A: der Agent läuft nie als root und nie als
   der Mensch, der ihn einrichtet.
3. **ID-Bereich** — Eintrag in `/etc/subuid`/`/etc/subgid` für diesen Nutzer (Bereich wie
   `100000:65536`), damit der Namespace mehr als eine ID abbilden kann.
4. **`uidmap` installieren** — Paketverwaltung des Knotens.
5. **Binary und Laufzeit ausbringen** — über SFTP nach `/opt/cosmos/agent`, Modus `0755`,
   Eigentümer root, **und** die **ganze Ladekette** nach `/opt/cosmos/lib/` — ein Archiv
   (`deploy/collect_runtime.sh` → `deploy/runtime.tar.gz`, 44 Dateien, 284 MB entpackt,
   91 MB gepackt), auf dem Knoten ausgepackt. Das Binary findet sie über
   `RUNPATH $ORIGIN/lib`, also **neben sich**. Auf dem Knoten darf nichts vorausgesetzt werden
   (User 2026-10-13): zuvor zeigte der RUNPATH in den Entwicklerbaum zurück — auf einem fremden
   Knoten nicht vorhanden, und selbst lokal für den Dienstnutzer nicht durchquerbar
   (`/media/<user>` ist `drwxr-x---`), was als
   `error while loading shared libraries: libaiml.so` auffiel. Beide Dateien werden als **Pfad**
   gestreamt, nicht als Zeichenkette — eine 83-MB-Bibliothek gehört nicht in den Speicher.

   **Eigentümer von `lib/` und `bwrap`: `root:root`** — `bwrap` trägt die userns-Berechtigung
   des AppArmor-Profils; gehörte es einem unprivilegierten Nutzer, wäre diese Berechtigung
   übertragbar (§94.3). Der Wert steht in `ProvisionConfig.runtime_owner` und ist **nur**
   deshalb konfigurierbar, weil der Abnahme-Lauf (`test/test_provision_run.aiml`) ohne
   Privilegien fährt und `chown root:root` dort scheitert; leer bedeutet `root:root`. Wer ihn
   auf einem echten Knoten ändert, hebt die Trennung auf.

   **Was mitreist, entscheidet nicht dieser Rechner.** Mitgeliefert wird die tatsächliche
   Ladekette von `libaiml.so` **und** `agent` — auch `libLLVM-18`, `libGL`, `libGLEW`, `libglfw`,
   X11 und `libopenblas`, selbst wenn sie auf dem Entwicklungsrechner zufällig systemweit
   installiert sind. Nur die **universelle Basis** (`libc`, `libm`, `libstdc++`, `libgcc_s`,
   `ld-linux`, `libnss_*`) bleibt dem Knoten überlassen: eine fremde libc neben dem eigenen
   Lader ist keine Portabilität, sondern ein Absturz. Entwickler-Symlinks ohne Versionsnummer
   und Linker-Skripte wie `libc.so` bleiben ebenfalls draußen — alles Deklarierte blind zu
   kopieren ergab 828 MB samt `libc.so`.

   > **Offene Grenze, nicht verschwiegen.** Dass 44 Bibliotheken mitreisen müssen, ist die Folge
   > davon, dass die aiml-Laufzeit ein **Monolith** aus Compiler (LLVM), Grafikstapel und
   > Kernlaufzeit ist: ein headless Build-Knoten lädt `libGL` und `libglfw`, die er nie benutzt.
   > Statisch binden löst es **nicht** — gemessen 2026-10-13 fehlten 593 Symbole (GL, GLEW,
   > cblas), weil `builtin_registry` alle Builtins registriert und der Linker den headless Teil
   > nicht herauslösen kann. Die saubere Lösung ist, die aiml-Laufzeit in einen headless Kern und
   > eine optionale Grafikschicht zu trennen (wie es der wasm-Build mit seiner kuratierten
   > Quellenliste und `tensor_stub_wasm.cpp` vormacht). Das ist eine aiml-Architekturentscheidung
   > und steht aus; bis dahin kostet sie 91 MB je Einrichtung.
   (der Dienstnutzer soll sein eigenes Programm nicht überschreiben können).
6. **AppArmor-Profil ausbringen** — **zwei** Anbindungspfade, beide aus Schritt 5: der Agent
   **und** die mitgelieferte `bwrap`-Kopie, dann `apparmor_parser -r`. Das Profil bindet an den
   Binärpfad; weil Binaries und Profil hier zusammen ausgebracht werden, können die Pfade nicht
   auseinanderlaufen (der Grund, warum das Entwickler-Profil mit `{,*/}agent` für den Betrieb
   nicht taugt).

   **Warum zwei.** Den User-Namespace erzeugt nicht der Agent, sondern **`bwrap`** — und
   AppArmor berechtigt das Programm, das ihn erzeugt. Ein Profil nur für den Agenten hätte genau
   das falsche Binary berechtigt, und ob sich ein Profil auf Kindprozesse vererbt, ist eine
   Frage, auf die sich eine Sicherheitsgrenze nicht stützen sollte. Mit der **eigenen Kopie**
   unter `<install_dir>/bwrap` hängt das Profil direkt an dem Programm, das den Namespace
   erzeugt. Das systemweite `/usr/bin/bwrap` bleibt **unberechtigt**: `userns` dort zu erlauben
   gälte für jeden Nutzer des Rechners. Gemessen 2026-10-13: `bwrap` (0.9.0) ist **nicht**
   setuid und scheitert ohne eigenes Profil mit `setting up uid map: Permission denied` —
   dieselbe Wand wie ein blankes `unshare` (§AP2.A.1).
7. **Token ablegen** — der Server erzeugt ein Enrollment-Token (§AP1.9) und schreibt es in
   eine Datei mit Modus `0600`, Eigentümer Dienstnutzer. **Nicht** als Argument der
   Dienst-Einheit: Argumente stehen in der Prozessliste des Knotens (dieselbe Lehre wie bei
   `--agent-token`, §AP1.9).
8. **Dienst-Einheit ablegen** — systemd-Einheit, `User=` der Dienstnutzer,
   `--agent-token-file` auf die Datei aus Schritt 7. **Noch nicht starten.**
9. **Nachweisen** — prüfen, dass die Isolation wirklich trägt: einen User-Namespace erzeugen
   und darin arbeiten. Der Nachweis läuft **durch das Agent-Binary**
   (`<install_dir>/agent --verify-isolation --bwrap-path <install_dir>/bwrap`, doc/spec/91 A5)
   und darin **durch den Sandkasten, mit dem die Jobs später laufen** — nie über ein
   Ersatzmittel: eine Probe, die etwas anderes misst als den Betrieb, ist keine Probe. Ein
   unconfined Programm wird beim Erzeugen des Namespace nach `unprivileged_userns` überführt,
   das die ID-Abbildung verweigert (§AP2.A.1); ein Prüfbefehl mit blankem `unshare` misst damit
   das falsche Programm und scheitert **auch auf einem korrekt eingerichteten Knoten** —
   gemessen 2026-10-13: `unshare: Schreiben fehlgeschlagen /proc/self/uid_map: Vorgang nicht
   zulässig`, während Profil, Binary, Dienstnutzer und subuid-Bereiche alle vorhanden waren.

   Drei Aussagen müssen **zugleich** gelten, sonst ist es keine Isolation: die **ID-Abbildung**
   trägt (innen `uid 0`), der Job hat ein **eigenes `/tmp`**, und die Wurzel des Knotens ist für
   ihn **schreibgeschützt**. Der Selbsttest benennt das fehlende **Glied**, nicht nur den
   Fehlschlag.
10. **Dienst starten** — erst jetzt.
11. **Laufen prüfen** — der Dienst ist tatsächlich aktiv. Erst dieser Schritt entscheidet
    „eingerichtet", nicht das Ausbleiben von Fehlern davor.

**Korrektur gegenüber der ersten Fassung (Befund 5a, 2026-10-11):** dort stand der
Dienststart **vor** dem Nachweis. Scheiterte der Nachweis, lief der Agent trotzdem — also
führte er fremden Code aus, obwohl gerade festgestellt worden war, dass die Isolation nicht
trägt. Das ist das Gegenteil von fail closed, und der Fehler lag in dieser Reihenfolge, nicht
nur im Code. Der Nachweis braucht den Dienst nicht (er prüft Profil, `uidmap` und
ID-Bereich), also kann er davor stehen.

**Zusätzlich:** scheitert **irgendein** Schritt, wird der Dienst vorsorglich gestoppt
(`service_stop_cmd`). Grund: bei einem Wiederholungslauf kann er aus einem früheren,
damals erfolgreichen Lauf noch laufen — ein fehlgeschlagener Lauf darf keinen laufenden
Agenten zurücklassen. Einen nicht laufenden Dienst zu stoppen ist ein No-op, die Regel also
unbedingt anwendbar.

## 94.3 Sicherheit — die Auflagen sind nicht verhandelbar

Über diesen Kanal läuft ein **`sudo`-Passwort**. Das ist das empfindlichste Datum im ganzen
System: es öffnet den Knoten vollständig, und anders als ein Token lässt es sich nicht
widerrufen.

- **S1 — nicht speichern.** Das Passwort wird **nie** persistiert: nicht in AionDB, nicht in
  einer Datei, nicht in einer Konfiguration. Es lebt im Arbeitsspeicher für die Dauer des
  einen Einrichtungslaufs und wird danach überschrieben.
- **S2 — nicht loggen.** Kein Log-Eintrag enthält es, auch nicht gekürzt, auch nicht im
  Fehlerfall. (Wie §AP1.6 für Token und Kommandos.)
- **S3 — nicht als Argument.** Auf dem Knoten wird es `sudo -S` über **stdin** übergeben,
  niemals als argv — Argumente sind in der Prozessliste jedes anderen Nutzers sichtbar.
- **S4 — Host-Key verbindlich prüfen.** Kein stilles Akzeptieren. Ein bekannter Knoten mit
  **geändertem** Key ist ein Abbruch, keine Rückfrage. Begründung: weil über diesen Kanal das
  `sudo`-Passwort geht, würde ein blindes Akzeptieren es jedem Zwischenmann aushändigen.

  **Zwei Phasen statt eines Schalters (Befund 5b, 2026-10-11).** `run()` ohne erwarteten
  Fingerprint bedeutet „ich kenne diesen Knoten noch nicht": es verbindet, liest den
  Fingerprint, **authentifiziert nicht** und kehrt mit `failed_step = "host_key_unconfirmed"`
  und gefülltem `fingerprint` zurück. Die Oberfläche zeigt ihn, der Mensch bestätigt, und der
  Aufruf wird mit diesem Fingerprint wiederholt. Damit gibt es **keinen** Weg, blind zu
  vertrauen — die erste Fassung nahm einen leeren Fingerprint stillschweigend an, was S4
  genau widersprach. (Auf aiml-Ebene ist `accept_host("")` weiterhin die *ausgeschriebene*
  TOFU-Entscheidung; cosmos trifft sie nicht von sich aus.)
- **S5 — nur der angemeldete Nutzer.** Einrichtung ist eine authentifizierte Aktion wie jede
  andere (§AP1.6); ein ungültiges Token bricht ab, bevor irgendetwas verbunden wird.
- **S6 — Umfang benennen.** Die Oberfläche sagt vor dem Start, **was** auf dem Knoten
  verändert wird (die neun Schritte). Eine Einrichtung, die mehr tut als angekündigt, ist
  ein Fehler.

**Alternative ohne Passwort** (für wen sie mag): SSH-Schlüssel plus ein `NOPASSWD`-Eintrag in
`sudoers` für die benötigten Befehle. Das vermeidet S1–S3 vollständig, kostet aber genau den
einen manuellen Schritt, den das Ziel vermeiden will. Beide Wege bleiben zulässig; der
Passwortweg ist der vorgesehene.

## 94.4 Warum `libssh` und nicht das System-`ssh`

Entschieden (User, 2026-10-09): FFI-Bindung an `libssh`. Für diesen Anwendungsfall ist das
nicht Geschmack, sondern Eignung:

| Gebraucht | `libssh` | System-`ssh` über `sys.exe` |
|---|---|---|
| **Passwort-Authentifizierung** | API-Aufruf | braucht `sshpass` oder ein Pseudo-Terminal — ein weiteres Werkzeug und das Passwort in einer Prozessumgebung |
| **Fingerprint für die UI-Bestätigung** | abfragbar, bevor man vertraut | nur über `known_hosts`-Dateien und Textausgabe |
| **Dateien ausbringen** | SFTP im selben Kanal | zweiter Prozess (`scp`) mit erneuter Authentifizierung |
| **`sudo`-Passwort über stdin** | Kanal-Schreibzugriff | möglich, aber durch zwei Prozessebenen |

`libssh-dev` wird über `exodus pkg` gebunden (§AP2.A.2) — kein `sudo` auf dem **Server**.
**Gebunden (2026-10-09, in `test/aiml/exodus.json`):** `libssh-dev 0.10.6-2ubuntu0.5` (Header
`libssh/libssh.h`, `server.h`, `sftp.h`) und `libssh-4 0.10.6-2ubuntu0.5` (`libssh.so.4`).

Dabei zwei Dinge gelernt, die beim Nachbauen Zeit sparen: `libssh-dev` enthält nur
`libssh.a` (statisch), und die bräuchte zusätzlich **GSSAPI** (`gss_*` als undefinierte
Symbole) neben OpenSSL und zlib — gegen die geteilte `libssh.so.4` zu linken vermeidet diese
Extra-Abhängigkeit. Ausserdem hatte exodus für `libssh-4` eine Version aus einem älteren
Index eingetragen (`0.10.6-2ubuntu0.3`), die es im Repo nicht mehr gibt; der Eintrag musste
auf `…ubuntu0.5` berichtigt werden, sonst scheitert `pkg install` mit „Version konnte nicht
gefunden werden".

## 94.5 Was in aiml fehlt

aiml hat **keinen** SSH-Client. Die einzige SSH-Erwähnung in der Spec ist der umgekehrte
Fall: ein von außen gestarteter `ssh -D`-Tunnel, durch den aiml per SOCKS5 spricht
(aiml-spec/32_5). Gebraucht wird also eine neue Schnittstelle, mindestens:

- Sitzung öffnen/schliessen, Zeitüberschreitung
- Host-Key als Fingerprint abfragen; Verbindung erst nach Bestätigung nutzen
- Authentifizierung: Passwort **und** öffentlicher Schlüssel
- Kommando ausführen: stdout/stderr getrennt, **Exit-Code**, stdin beschreibbar (für S3)
- SFTP: Datei hochladen mit Modus

Das gehört in die aiml-Spec, bevor Code entsteht (eigenes Kapitel dort), und ist der
umfangreichste Posten dieses Arbeitspakets.

## 94.5a Der Weg aus der App (Zielbild, User 2026-10-11)

Der Befehl kommt **aus der cosmos-App**: der Nutzer gibt Host, Konto und `sudo`-Passwort ein,
drückt „Agent einrichten", und AppArmor-Profil, Binary und Dienst sind danach erledigt. Auf
dem Knoten ist nichts von Hand zu tun.

**Zwei Strecken, nicht eine.** Die Installation läuft über SSH — der RPC ersetzt ihn nicht,
sondern geht ihm voraus:

```
Browser (WASM)  --mirror-RPC-->  cosmosd  --SSH (libssh)-->  Knoten
   "Knopfdruck"                            "Installation"
```

Der Browser kann kein SSH sprechen: dort gibt es keine TCP-Sockets, und aiml liefert auf
wasm32 für jeden SSH-Aufruf `null` (aiml-spec/32_6 §8). Der Knopfdruck braucht also einen Weg
zum Server, und der einzige ist der mirror-RPC.

Zwei weitere Gründe, die beiden nicht zusammenzulegen, selbst wenn der Browser es könnte:
das **Enrollment-Token** kann nur der Server erzeugen (er hält den Token-Store, §AP1.9) — ein
direkt sprechender Browser müsste das Geheimnis erst bekommen und dann weitergeben. Und
**Autorisierung** („nur ein angemeldeter Nutzer darf einrichten") ist eine Server-Prüfung; ein
Browser am Knoten umgeht sie.

**RPC `provision_agent`** — `ProvisionReq → ProvisionResp`, authentifiziert wie jeder andere
Aufruf (§AP1.6; ein ungültiges Sitzungs-Token bricht ab, bevor irgendetwas verbunden wird).

Der Ablauf ist **zweiphasig**, weil die Fingerprint-Bestätigung es verlangt (§94.3 S4):

| Phase | Aufruf | Antwort | Oberfläche |
|---|---|---|---|
| 1 | `expected_fp` leer | `failed_step = "host_key_unconfirmed"`, `fingerprint` gefüllt, **kein** Schritt ausgeführt | zeigt den Fingerprint, fragt „ist das dein Knoten?" |
| 2 | `expected_fp` = der bestätigte Wert | `success`, sonst `failed_step` + `message` + `steps_done` | zeigt Erfolg oder den Schritt, an dem es hing |

Damit ist der eine Weg, blind zu vertrauen, nicht etwa abgeschaltet — es gibt ihn nicht.

**Das Enrollment-Token erzeugt der Server selbst** (§AP1.9) und schreibt es als Datei auf den
Knoten (Schritt 7). Die Antwort nennt nur die `token_id`, nie das Geheimnis: es verlässt den
Server ausschliesslich über den SSH-Kanal zum Knoten. Der Nutzer muss damit **nichts**
kopieren — das war beim bisherigen Weg (Token im UI erzeugen, von Hand am Agenten eintragen)
der unangenehme Teil.

**Woher die Knoten-Konfiguration kommt.** Alles außer Host/Konto ist Betriebsvorgabe und
kommt aus der Umgebung des Servers, mit Produktionswerten als Standard:

| Variable | Standard |
|---|---|
| `COSMOS_AGENT_BINARY` | `./agent` (das Binary, das der Server ausbringt) |
| `COSMOS_PROV_INSTALL_DIR` | `/opt/cosmos` |
| `COSMOS_PROV_SERVICE_USER` | `cosmos-agent` |
| `COSMOS_PROV_STAGE_DIR` | `/tmp/cosmos-stage` |
| `COSMOS_PROV_APPARMOR_DIR` | `/etc/apparmor.d` |
| `COSMOS_PROV_SYSTEMD_DIR` | `/etc/systemd/system` |
| `COSMOS_PROV_SUDO` | `sudo -S -p '' ` |
| `COSMOS_PROV_PKG_CMD` | `apt-get install -y uidmap` |
| `COSMOS_PROV_EXEC_URL` | die Bind-Adresse des Servers |
| `COSMOS_AGENT_RUNTIME` | `./deploy/runtime.tar.gz` (Laufzeit neben dem Binary, Schritt 5) |
| `COSMOS_PROV_WORK_DIR` | `/var/lib/cosmos-agent` |
| `COSMOS_PROV_RUNTIME_OWNER` | `root:root` (Besitzer von `lib/` und `bwrap` nach dem Auspacken) |
| `COSMOS_PROV_SUBUID_FILE` / `COSMOS_PROV_SUBGID_FILE` | `/etc/subuid` / `/etc/subgid` |
| `COSMOS_PROV_VERIFY_PREFIX` | `sudo -S -p '' -u cosmos-agent ` |
| `COSMOS_PROV_APPARMOR_CMD` / `COSMOS_PROV_APPARMOR_UNLOAD` | `apparmor_parser -r` / `apparmor_parser -R` |
| `COSMOS_PROV_SERVICE_CMD` | `systemctl daemon-reload && systemctl enable cosmos-agent && systemctl restart cosmos-agent` |
| `COSMOS_PROV_CHECK_CMD` / `COSMOS_PROV_STOP_CMD` / `COSMOS_PROV_RELOAD_CMD` | `systemctl is-active --quiet cosmos-agent` / `systemctl disable --now cosmos-agent` / `systemctl daemon-reload` |

Die Abnahme-Läufe (`run_e2e.sh`, `run_e2e_provision.sh`) setzen **jede** Zielpfad-Variable auf
ein Verzeichnis unter ihrem Arbeitsordner: ein Test, der als root läuft, darf sonst nach
`/var/lib/cosmos-agent` oder `/opt/cosmos` des Rechners schreiben (gemessen 2026-11-25:
`run_e2e.sh` setzte `COSMOS_PROV_WORK_DIR` nicht).

Der Wert **`-`** bedeutet bei `COSMOS_PROV_SUDO`, `COSMOS_PROV_VERIFY_PREFIX` und
`COSMOS_PROV_STOP_CMD` ausdrücklich **leer** (kein sudo, kein Nutzerwechsel, kein
Stopp-Versuch). Ein leerer Variablenwert taugt dafür nicht: in aiml ist er derzeit nicht
verlässlich auslesbar (`sys.env` legt eine dichte Map ohne `occupied`-Bitmap an, der
Lesepfad erwartet aber eine — gemeldet in aiml-spec/23). Unabhängig davon ist die
ausgeschriebene Konvention klarer, weil sie „nicht gesetzt" von „absichtlich leer" trennt.

Das ist **keine** Testverzweigung: welche Paketverwaltung und welche Pfade ein Knoten hat, ist
offen (§94.7), und die Abnahme nutzt dieselben Variablen, um einen Lauf gegen ein
Wegwerf-Verzeichnis zu fahren — der Produktionscode kennt keinen Testfall.

**Zwei Passwortfelder, aber normalerweise eine Eingabe.** `login_password` meldet am Knoten
an, `sudo_password` erhöht dort die Rechte — zwei verschiedene Dinge, die aber meist
dasselbe Konto betreffen und damit dasselbe Passwort sind. Darum gilt: **bleibt das
sudo-Feld leer und ist ein SSH-Passwort gesetzt, wird dieses auch für `sudo` verwendet.**
Getrennt bleiben die Felder, weil sie auseinanderfallen können (eigenes sudo-Passwort, oder
SSH per Schlüssel — dann *muss* das sudo-Passwort angegeben werden, weil es keines zum
Übernehmen gibt).

**Das `sudo`-Passwort** steht im Request und unterliegt damit §94.3 S1–S3 auch hier: es wird
nicht gespeichert, nicht geloggt (auch nicht gekürzt, auch nicht im Fehlerfall) und geht auf
dem Knoten über stdin. Es lebt für die Dauer des einen Aufrufs im Arbeitsspeicher.

### Das Fenster schliesst sich — aber nur bei Erfolg (F94-13)

Vorgabe des Nutzers (15.10.2026): ist die Prozedur durch, soll der Dialog zugehen.  Er tat es
nicht und blieb mit „Eingerichtet. Schritte: N" stehen, bis jemand „Schliessen" drückte.

**Bei Erfolg**: das Ergebnis steht kurz im Dialog (1,5 s), wandert in die **bleibende
Statuszeile** des Agenten-Bildschirms und der Dialog schliesst sich selbst.  Die Zeile ist
wichtig: ein Fenster, das sich schliesst, nimmt seine Nachricht mit, und dann wäre nicht mehr
nachzulesen, ob gerade eingerichtet oder zurückgebaut wurde.

**Bei Fehlschlag bleibt er offen.**  Dort steht der Schritt, an dem es hing, und die Meldung
des Knotens — genau das, was man braucht, um ein Feld zu korrigieren und es erneut zu
versuchen.  Ein Dialog, der sich nach einem Fehler schliesst, wirft die Diagnose weg und
zwingt zum Neuanfang.

Dasselbe gilt für den **Rückbau** (§94.5b): er läuft synchron und meldet sein Ergebnis
genauso — Erfolg schliesst, Fehlschlag bleibt stehen.

## 94.5b Rückbau — alles rückgängig machen (User 2026-10-11)

**RPC `deprovision_agent`**, gleiche Modelle wie die Einrichtung, zusätzlich `token_id`.
Entfernt auf dem Knoten alles, was die Einrichtung hinterlassen hat, und widerruft das
Enrollment-Token am Server.

Reihenfolge, und sie ist nicht die Umkehrung der Installation:

1. **Token widerrufen** (am Server, §AP1.9) — **zuerst**. Das ist der eigentliche
   Ausschalter: eine gelöschte Datei auf dem Knoten macht das Token nicht ungültig, und
   solange es gilt, kann sich dort jederzeit wieder ein Agent anmelden. Alles andere ist
   Aufräumen, das hier ist Sicherheit.
2. **Dienst stoppen und deaktivieren** — danach läuft kein Agent mehr.
3. **Dienst-Einheit entfernen** + `daemon-reload`.
4. **Token-Datei entfernen.**
5. **Binary entfernen.**
6. **AppArmor-Profil entladen** (`apparmor_parser -R`) **und die Datei entfernen** — in
   dieser Reihenfolge: eine entfernte Datei entlädt das Profil nicht, es bliebe im Kernel.
7. **ID-Bereich** aus `/etc/subuid` und `/etc/subgid` streichen.
8. **Dienstnutzer löschen.**
9. **Zwischenablage entfernen.**

**Bewusst NICHT zurückgebaut: das Paket `uidmap`.** Es kann auf dem Knoten von anderem
benutzt werden; es zu entfernen würde fremde Dinge beschädigen. Ein Rückbau darf nur
wegnehmen, was die Einrichtung selbst angelegt hat.

**Umgekehrte Fehlerpolitik: best effort statt fail closed.** Die Einrichtung bricht beim
ersten Fehlschlag ab, weil Weitermachen gefährlich wäre. Der Rückbau macht das Gegenteil und
**läuft weiter**: ein Abbruch in der Mitte liesse mehr Rückstände zurück als ein Durchlauf
mit einem Fehler. Die Antwort meldet `success = 1` nur, wenn **alle** Schritte gelungen sind,
und nennt sonst den ersten gescheiterten samt Zahl der gelungenen.

Jeder Schritt ist **idempotent**: ein zweiter Rückbau darf nicht scheitern, nur weil schon
nichts mehr da ist (`rm -f`, `userdel` nur wenn der Nutzer existiert, `grep`-gestütztes
Streichen der ID-Zeilen).

**Rückbau während einer Einrichtung (F94-14, 2026-11-25).**  Die Einrichtung läuft nebenher
(`provision_status`), ein Rückbau kann also eintreffen, während sie noch Schritte ausführt.
Dann widerruft er das Token wie immer **zuerst** (Schritt 1 — der Ausschalter darf nicht
warten), führt aber **keinen** Schritt am Knoten aus und antwortet `failed_step = "busy"`.
Zwei Ketten gleichzeitig auf demselben Knoten ließen Reste zurück, die keine von beiden
kennt (gemessen 2026-11-25: der Schritt `work_dir` der Einrichtung lief nach dem Rückbau).
Wer zurückbauen will, wartet das Ende der Einrichtung ab (`running = 0`) und ruft erneut.

## 94.6 Abnahme (testbar)

- **P1 Idempotenz:** zweimal einrichten → derselbe Endzustand, kein Fehler.
- **P2 Fail closed:** schlägt ein Schritt fehl, läuft **kein** Agent (der Dienst wird
  vorsorglich gestoppt), und die Meldung nennt den Schritt. Insbesondere: scheitert der
  Nachweis, wurde der Dienst nie gestartet.
- **P8 Fingerprint-Bestätigung:** `run()` ohne erwarteten Fingerprint führt **keinen** Schritt
  aus, meldet `host_key_unconfirmed` und liefert den Fingerprint zum Anzeigen.
- **P9 Rückbau:** nach Einrichtung + Rückbau sind Binary, Profil, Token-Datei, Dienst-Einheit
  und der ID-Bereich **weg**, und das Enrollment-Token ist am Server **widerrufen** (eine
  Anmeldung damit wird abgelehnt). Zweimal zurückbauen scheitert nicht. `uidmap` bleibt
  installiert.
- **P10 Rückbau während der Einrichtung (F94-14):** solange `provision_status` `running = 1`
  meldet, antwortet `deprovision_agent` `busy` mit `steps_done = 0`, und das Token ist
  widerrufen (`test/e2e_provision.aiml`).
- **P3 Kein Geheimnis in Logs:** nach einem Lauf enthält **keine** Log-Datei das Passwort —
  prüfbar durch Suche nach dem verwendeten Wert.
- **P4 Kein Geheimnis in der Prozessliste:** während des Laufs taucht das Passwort in
  `ps`-Ausgabe auf dem Knoten **nicht** auf.
- **P5 Host-Key:** geänderter Key eines bekannten Knotens → Abbruch, keine Rückfrage.
- **P6 Nachweis der Isolation:** Schritt 9 schlägt an, wenn Profil oder `uidmap` fehlen —
  eine Einrichtung ohne diesen Nachweis gilt nicht als erfolgreich.
- **P7 Token nicht in argv:** die erzeugte Dienst-Einheit übergibt eine Token-**Datei**.

## 94.7 Offen

- **Welche Paketverwaltung?** Schritt 4 ist `apt` auf Ubuntu/Debian. Andere Knoten (RHEL,
  Alpine) brauchen entweder eine Erkennung oder eine ausdrückliche Beschränkung auf
  Debian-artige Systeme. Vorschlag: zunächst beschränken und das klar melden.
- ~~**Wie wird ein Knoten wieder entfernt?**~~ → **festgelegt in §94.5b** (RPC
  `deprovision_agent`): Token zuerst widerrufen, dann Dienst, Einheit, Token-Datei, Binary,
  Profil (entladen *dann* löschen), ID-Bereich, Nutzer, Zwischenablage. `uidmap` bleibt.
- ~~**Test gegen einen echten sshd.**~~ → **geklärt:** `libssh` bringt eine Server-Seite mit
  (`libssh/server.h`: `ssh_bind`, `ssh_handle_key_exchange`). Der Test spannt seinen eigenen
  sshd **im Testprozess** auf — kein `sudo`, kein `openssh-server`, kein fremder Rechner.
  (Auf dem Entwicklungsrechner läuft keiner: Port 22 leer, `openssh-server` nicht
  installiert.) Die Server-Seite gehört damit in die aiml-Schnittstelle aus §94.5, sonst ist
  der Client nicht prüfbar.

## 94.7 Nachtrag: aiml auf dem Knoten (aus §96.11, F96-17)

Die elf Schritte von §94.2 richten einen Prozess-Starter ein.  Sobald Pipeline-Schritte verteilt
werden, genügt das nicht: zum Knoten wandert ein **`Code`-Bundle** (`sys.bundle`), das der Agent
mit `sys.exec` ausführt (aiml `spec/62` F62-50/F62-51).  Die Einrichtung muss also **libaiml**
mitbringen — nicht das Compiler-Binary, denn die Bibliothek enthält den Compiler bereits.

Warum ein Bundle und nicht übersetzter Code: der Schlüssel eines Schritts **ist** der Hash seines
Quelltexts (`spec/62` §8).  Würde übersetzter Code wandern, wären das ausgeführte und das
geschlüsselte Artefakt zwei verschiedene Dinge.  Außerdem müsste der Controller für jede
Knoten-Architektur übersetzen — genau das, was `agent: "${arch}"` vermeidet.  Ein Bundle trägt
seine Abhängigkeiten transitiv und ist damit von sich aus vollständig.

Folge für die Vertrauensgrenze: der Art nach keine Änderung (ein Knoten, der Schritte annimmt,
führt schon beliebige Kommandos aus, `90_ap1_agent_exec.md`), dem Grad nach schon, weil ein
aiml-Rumpf mehr Builtins erreicht als eine Shell-Zeile.  Die Antwort ist Isolation (§96.8), nicht
eine kleinere Nutzlast — und damit hängt dieser Nachtrag an derselben Voraussetzung wie Schritt 9.
