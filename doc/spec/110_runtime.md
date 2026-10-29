# 110 — cosmos-rt: eine eigene Container-Runtime

**Auftrag (User, 2026-10-18):** *„wir bauen eine ganz neue runtime, crossplatform mit allen
extras, die man sich wünschen kann. das wird ein riesiges projekt, was nicht schlimm ist, ich
habe Zeit dafür. man kann als zielbild sehen, dass sowohl ein container auf dem raspberry pi
als auch auf einem x86 zu cosmos verbinden. und teste, welche d-bus brauchen und alle
erdenklichen schwierigkeiten mit screen interaktion oder netzwerkproblemen sich lösen lassen."*

Damit ist die Empfehlung aus `doc/research/04` und `13` (Runtime leihen, nur Adapter bauen)
**bewusst verworfen**.  Das ist in Ordnung — aber es ist eine Entscheidung mit Konsequenzen,
und die stehen hier, damit sie später nicht neu erfunden werden müssen.

**Zielbild:** Ein Container auf einem Raspberry Pi und einer auf x86 verbinden sich zu
demselben cosmos — mit Bildschirm, mit D-Bus, durch jedes Netz, das dazwischen liegt.

---

## 110.0 Drei Befunde, die alles andere bestimmen

Am Repo geprüft, bevor eine Zeile geplant wurde:

**F110-1: aiml kann die nötigen Syscalls nicht allein erreichen.**  Die FFI (`spec/35`) kennt
feste Signaturen, Zeiger, bekannte Struct-Layouts und Callbacks — aber **keine varargs**.
`syscall(2)` ist variadisch; `pivot_root`, `seccomp`, `clone3` und `mount_setattr` haben gar
keinen glibc-Wrapper.  Dazu die aiml-Grenze von **fünf Argumenten**, die `mount(2)` exakt
ausschöpft.  → Es braucht eine **dünne C-Schicht mit festen Signaturen** (`exodus`
`pre_compilation` baut sie, wie `libclearance_host.so` in den clearance-Tests).  Sie ist kein
Fremdkörper, sondern die Übersetzung von „variadisch" nach „typisiert"; sie enthält **keine
Politik**, nur Aufrufe.

**F110-2: Die Runtime muss ein eigener, einfädiger Prozess sein.**  `unshare(CLONE_NEWUSER)`
scheitert mit `EINVAL` in einem Prozess mit mehreren Fäden — und der cosmos-Agent hat Fäden
(die Konsole fährt einen, doc/spec/108 F108-18).  Die Runtime darf also **nicht** in den Agenten
hinein.  Sie ist eine eigene Binärdatei (`cosmos-rt`), die der Agent per `sys.exe` startet —
dieselbe Trennung, die runc/crun haben, und aus demselben Grund.

**F110-3: Die Sicherheitsgrenze erbt man mit.**  Was hier gebaut wird, ist die Grenze selbst.
Die Fehlerklassen sind bekannt und werden hier namentlich geführt, damit jede gegen einen
Test antritt (§110.6): `/proc/self/exe`-Überschreiben (CVE-2019-5736), geleakte
Dateideskriptoren ins Containerinnere (CVE-2024-21626), Symlink-Rennen beim Mounten,
Masked-Paths, Reihenfolge von `no_new_privs`/caps/seccomp.

## 110.1 Schnitt: was eigen ist, was Vertrag ist

```
cosmos-Agent ──sys.exe──> cosmos-rt  (eigene Binärdatei, einfädig)
                            │
                            ├── Kern (aiml):   Bundle lesen, Zustandsautomat, Policy,
                            │                  Logs, Ressourcen, Fehlerbilder
                            └── Boden (C-Shim, ~200 Zeilen): unshare, mount, pivot_root,
                                               seccomp, capset, prctl, waitpid
```

**Eingabeformat ist die OCI-Runtime-Spec** (`config.json` + `create/start/kill/delete/state`).
Nicht aus Bescheidenheit, sondern weil sie ein *geschriebener, versionierter* Vertrag ist:
damit erbt cosmos-rt eine fertige Testsammlung (oci-runtime-tools), kann gegen crun/runc
**differenziell** geprüft werden (§110.6) und bleibt im Notfall austauschbar.  Alles
„Extra" lebt in einer eigenen Erweiterung (`org.cosmos.*` im `annotations`-Feld), nicht als
Abweichung vom Standard.

## 110.2 Plattform-Matrix (Zielbild und Stufen)

| Ziel | Mechanik | Stufe |
|---|---|---|
| Linux x86_64 | namespaces + cgroup v2 + seccomp | **M2** |
| Linux aarch64 (Raspberry Pi) | dasselbe, **anderer seccomp-Bytecode** | **M3** |
| Linux armhf (32 bit) | 32-bit-Syscall-Tabelle, `compat`-Filter | M6 |
| macOS / Windows | **keine** Namespaces — nur über eine VM (Virtualization.framework / HCS) | M8, eigener Rückwand-Typ |

**Der seccomp-Filter ist pro Architektur ein anderer Bytecode** (`AUDIT_ARCH_X86_64` vs.
`AUDIT_ARCH_AARCH64`, abweichende Syscall-Nummern).  Ein Profil, das auf x86 „dicht" ist,
ist auf dem Pi eine offene Tür — darum wird der Filter **erzeugt**, nie abgeschrieben, und
jeder Lauf prüft `AUDIT_ARCH` gegen die laufende Maschine.

**Raspberry-Pi-Fallen, die vorab bekannt sind:** `memory`-cgroup ist auf Raspberry Pi OS
standardmäßig **aus** (`cgroup_enable=memory cgroup_memory=1` in `cmdline.txt` nötig);
overlayfs auf einer vfat/exfat-Karte trägt nicht; 64-bit-Kernel mit 32-bit-Userland kommt
vor; I/O ist langsam, also kostet das Auspacken von Schichten echte Zeit.

## 110.3 Die „Extras" — und wie jedes davon geprüft wird

Jedes Extra ist eine eigene Probe mit einem **Ja/Nein**, nicht eine Absichtserklärung.

| Extra | Mechanik | Probe (Abnahme) |
|---|---|---|
| **D-Bus** | Sitzungsbus im Container selbst starten; Systembus des Hosts nur über einen **filternden Proxy** (Flatpak-Muster: `talk`/`own`/`see`-Regeln) — niemals den rohen Socket durchreichen | ein Dienst im Container spricht `org.freedesktop.DBus.Peer.Ping` gegen den Sitzungsbus; ein verbotener Name wird nachweislich abgelehnt |
| **Bildschirm** | X11: `/tmp/.X11-unix` + eigenes MIT-MAGIC-COOKIE; Wayland: Socket + `XDG_RUNTIME_DIR`; GPU: `/dev/dri/renderD*`; headless: Xvfb | **cosmos kann das schon messen**: `tools/ui_shot.sh` nimmt unter Xvfb auf — dieselbe Harness läuft im Container und das PNG muss Pixel haben |
| **Ton** | PipeWire/Pulse-Socket durchreichen (optional) | später |
| **Netz** | ausgehend genügt dem Agenten → rootless `pasta`/`slirp4netns`; eingehend erst mit veth+bridge; DNS aus `/etc/resolv.conf` des Containers; **MTU** explizit setzen | Agent im Container meldet sich beim Controller; ein Lauf über eine Strecke mit MTU 1400 bricht nicht ab |
| **Ressourcen** | cgroup v2: `memory.max`, `cpu.max`, `pids.max` | gemessen gegen doc/spec/109 (der Agent misst sich ohnehin selbst) |

## 110.4 Meilensteine

Jeder Meilenstein hat eine Abnahme, die **ohne Fenster und ohne Wohlwollen** prüfbar ist.

| M | Inhalt | Abnahme |
|---|---|---|
| **M0** | **Fähigkeitsbericht** (`rt_probe`): was kann dieser Host? userns, cgroup-v2-Delegation, seccomp, idmapped mounts, overlay, DRI, X11/Wayland/D-Bus-Sockets, `pasta`/`slirp4netns` | läuft ohne root auf x86 **und** auf dem Pi und druckt dieselbe Tabelle mit anderen Werten |
| **M1** | C-Shim + aiml-Kern: `unshare(CLONE_NEWUSER\|NEWNS\|NEWPID\|NEWUTS\|NEWIPC)`, `uid_map`/`gid_map`, `fork`+`waitpid` | ein Prozess läuft im eigenen Namespace, `id` zeigt innen `uid 0`, außen die eigene UID |
| **M2** ✅ | rootfs + `pivot_root` + `/proc`, Masked-Paths, caps drop, `no_new_privs`, seccomp (x86_64) | erreicht 18.10.2026, §110.13/§110.14 — Ausbruchsproben scheitern nachweislich |
| **M3** | aarch64: eigener seccomp-Bytecode, Pi-Vorflug (cgroup-Flag, Karte) | derselbe Container startet auf dem Pi; beide melden sich bei **einem** cosmos |
| **M4** ✅ | cgroup v2: Grenzen setzen und messen | erreicht 18.10.2026, §110.15 — 256 MB gegen 64 MiB: Exit 137, `oom_kill` zählt |
| **M5** | Netz: `pasta` ausgehend, DNS, MTU; danach veth/bridge | Agent im Container registriert sich; MTU-Strecke hält |
| **M6** | Bildschirm + D-Bus (§110.3) | `ui_shot` im Container liefert ein PNG mit Pixeln; D-Bus-Filter lehnt nachweislich ab |
| **M7** ✅ | Lebenszyklus in cosmos: Kapazitätsschleife, Reaper | erreicht 18.10.2026, §110.21 — starten, zuteilen, abräumen, ohne Rest |
| **M8** | Nicht-Linux über VM-Rückwand | später |

## 110.5 Was NICHT gebaut wird

- **Kein Daemon.**  cosmos-rt wird gestartet, tut eine Sache, beendet sich.  Der Agent ist
  die Aufsicht — er existiert schon.
- **Kein eigenes Image-Format.**  Schichten kommen als `tar.gz`/`zstd` (aiml kann beides),
  Inhalte adressiert über `hash.sha256`; kanonisch bleibt der CAS (doc/research 02/03).
- **Kein Scheduler** im K8s-Sinn, solange der Agent **zieht** (doc/spec/103 F103-2).
- **Keine Vertrauensgrenze für fremden Code**, bis §110.6 vollständig grün ist — bis dahin
  gilt unverändert: nur eigene, vertrauenswürdige Nutzer.

## 110.6 Die Ausbruchsproben (das eigentliche Gütesiegel)

Eine Runtime ist nicht fertig, wenn ein Container startet, sondern wenn er **nicht ausbricht**.
Diese Proben gehören von M2 an in jeden Lauf, jede mit einem erwarteten Fehlschlag:

1. `/proc/self/exe` aus dem Container überschreiben → muss scheitern (Binärdatei wird
   versiegelt kopiert bzw. über `memfd` ausgeführt).
2. Ein vom Host geerbter Dateideskriptor im Containerinneren → darf nicht existieren
   (`O_CLOEXEC` überall, Zähler über `/proc/self/fd` vor `exec`).
3. Symlink-Rennen: ein Mount-Ziel, das während der Einrichtung zum Symlink wird → muss
   scheitern (Auflösung nur über `openat2(RESOLVE_NO_SYMLINKS)`-Äquivalent).
4. `/proc/sysrq-trigger`, `/sys/firmware` & Co. → maskiert, Schreibversuch scheitert.
5. Ein Syscall außerhalb des Profils → `EPERM`, und zwar **auf beiden Architekturen**.
6. Differenz gegen crun: dasselbe `config.json`, beide Runtimes, gleicher Exit-Code,
   gleiche sichtbare Umgebung (`id`, `mount`, `capsh --print`).

Probe 6 ist der günstigste Qualitätshebel des ganzen Projekts: crun als **Orakel**, nicht als
Konkurrent.

## 110.7 Ort und Form

`cosmos/runtime/` mit eigener `exodus-rt.json`, eigenem Spec-Kapitel (dieses) und eigenen
Tests — so geschnitten, dass es sich später ohne Umbau als eigenes Projekt herauslösen lässt.
Der Agent kennt nur den Pfad zur Binärdatei und die OCI-Schnittstelle.

---

## 110.8 M0 — gebaut und gemessen (18.10.2026)

`runtime/shim/rt_shim.c` (117 Zeilen C) + `runtime/rt_probe.aiml` + `runtime/build_rt.sh`.
Der Weg aiml → FFI → Kernel trägt auf Anhieb; F110-1 ist damit nicht mehr Vermutung,
sondern Messung.

**Befund auf dem Entwicklungsrechner (x86_64, Kernel 7.0.0-38):**

| | |
|---|---|
| `AUDIT_ARCH` | 3221225534 = `0xC000003E` (x86_64) — der Wert, der später den seccomp-Bytecode bestimmt |
| userns erzeugbar | **nein** — scheitert beim Schreiben der ID-Abbildung |
| cgroup v2 delegiert | **cpu memory pids** (ohne root) — M4 trägt hier |
| seccomp | alle Aktionen inkl. `user_notif` |
| overlay | **nicht geladen** (`/proc/filesystems`) — unprivilegiert auch nicht nachladbar |
| Bildschirm | `/dev/dri` + `renderD128`, X11-Socket, `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0` |
| D-Bus | Sitzungs- **und** Systembus vorhanden |
| Werkzeuge | `newuidmap`, `bwrap` da; `crun`/`runc`/`pasta`/`slirp4netns` **nicht** |

**F110-4: „Der Host kann nicht" und „dieses Binary darf nicht" sehen gleich aus.**  Der erste
Bericht schloss aus dem Fehlschlag „dieser Host trägt M1 nicht" — falsch.  Gegenprobe mit dem
nackten Werkzeug (`unshare -U --map-root-user id`) scheiterte identisch: es ist Ubuntus
`apparmor_restrict_unprivileged_userns=1`, das *unconfined* Prozesse beim Erzeugen des
Namespace nach `unprivileged_userns` überführt — dokumentiert seit doc/spec/91 §AP2.A und in
`deploy/apparmor/cosmos-agent` erklärt.  Der Bericht unterscheidet die beiden Fälle jetzt und
nennt die Abhilfe (**eigenes Profil für die Binärdatei**, niemals den sysctl umlegen).
`cosmos-rt` braucht damit dasselbe Profil wie der Agent — ein Punkt für M1.

**F110-5: `/proc/filesystems` listet nur GELADENE Dateisysteme.**  „overlay: nein" heißt hier
nicht „kann nicht", sondern „niemand hat es geladen" — und unprivilegiert lädt es auch
niemand.  Für M2 heißt das: entweder lädt die Einrichtung das Modul (root, einmal), oder die
Materialisierung kommt ohne overlay aus (einfaches Verzeichnis aus dem CAS, §110.5).

**Nächster Schritt (M1):** AppArmor-Profil für `cosmos-rt` nach dem Vorbild des Agenten, dann
derselbe Bericht erneut — er muss dann „userns erzeugbar: ja" sagen.  Erst danach lohnt
`pivot_root`.

---

## 110.9 Bauen: Schritt-Cache, Vertauschbarkeit, Vor- und Zurückgehen

**Auftrag (User, 2026-10-18):** *„Die Anforderungen an das Containerbauen bleiben.  Ich möchte,
dass die Schritte einzeln cachebar sind und gegebenenfalls als permutierbar.  Und dass ich den
Bauvorgang an gegebener Stelle wieder starten kann oder auch Schritte zurückgehen kann."*

Der Befund vorweg: **drei der vier Forderungen sind schon entworfen**, eine ist neu, und eine
davon hat einen Haken, der hier zum ersten Mal auftaucht.

### Was schon steht

| Forderung | Stand |
|---|---|
| Schritte einzeln cachebar | **entworfen + teils gebaut**: `step_key → output_tree` (aiml `spec/62 §8`, doc/spec/96), `ActionCache`, CAS-Bäume, Klassen `pure`/`resolved`/`opaque` |
| An gegebener Stelle fortsetzen | **entworfen**: F96-14 — fortgesetzt wird aus den aufgezeichneten `(Schritt, Lane)`-Schlüsseln; „Resume nach Neustart ist kein Sonderfall" |
| Vertauschbarkeit | **benannt, nicht gebaut**: `doc/research/03` nennt die *Bernstein-Vertauschbarkeit* als Ziel der read/write-Erfassung |
| Schritte **zurück**gehen | **neu** |

**F110-7: Der Schlüssel ist schon ein DAG, keine Kette — das ist die halbe Miete.**  Docker
hängt jeden Layer an die *Id des Vorgängers*; darum macht ein geänderter Schritt 2 alle
folgenden ungültig, und Umsortieren hilft nie.  `spec/62 §8` nimmt stattdessen
`input_keys` = „die Schlüssel der unter `needs` genannten Schritte, **sortiert**".  Zwei
Schritte, die einander nicht brauchen, haben damit Schlüssel, die **voneinander unabhängig**
sind: ihre Reihenfolge in der Datei ändert nichts, und das Umstellen kostet keinen
Cache-Treffer.  Die Vertauschbarkeit ist am Schlüssel also **schon erreicht**.

### Was neu ist: Vertauschbarkeit ist eine Aussage über das MATERIAL, nicht über den Schlüssel

Der Schlüssel ist unabhängig — die **Materialisierung** ist es nicht.  Laufen A und B
nebeneinander und schreiben beide in den Arbeitsbaum, ist das Ergebnis von C (das beide
braucht) nur dann reihenfolgefrei, wenn A und B sich nicht in die Quere kommen.  Das ist
genau die Bernstein-Bedingung:

> A und B sind vertauschbar ⟺ `schreibt(A) ∩ schreibt(B) = ∅` **und**
> `schreibt(A) ∩ liest(B) = ∅` **und** `liest(A) ∩ schreibt(B) = ∅`.

- **F110-8: Vertauschbarkeit wird GEMESSEN, nicht erklärt.**  Ein `permutable: true` im
  Pipeline-Text ist eine Behauptung wie `cache: pure` — und für die gibt es seit doc/spec/96
  §96.5 `verify`.  Dieselbe Linie gilt hier: wer vertauscht, muss die Schreibmengen kennen.
  Ein ungeprüftes `permutable` wird als **unbelegt** geführt und darf keinen Treffer
  begründen.
- **F110-9: Die Schreibmenge ist gratis, die Lesemenge nicht.**  Läuft ein Schritt mit
  `lowerdir` = Eingabe und frischem `upperdir` (§96.3), **ist** der `upperdir` die
  Schreibmenge — ohne Zusatzaufwand.  Die Lesemenge braucht Beobachtung (fanotify oder ein
  FUSE-Overlay, `doc/research/03`).  Darum die Stufung:
  1. **Stufe 1 (billig):** nur Schreibmengen vergleichen.  Überschneiden sie sich, sind die
     Schritte **nicht** vertauschbar — eine sichere, einseitige Aussage.
  2. **Stufe 2 (vollständig):** mit Lesemengen die Bernstein-Bedingung ganz prüfen.
  Stufe 1 genügt für den häufigsten Fall (zwei `apt install`, zwei `git clone` in
  verschiedene Ordner) und kostet nichts, weil der Diff ohnehin entsteht.

### Zurückgehen: fällt fast umsonst ab — wenn man nichts löscht

- **F110-10: Zurückgehen ist Vorwärtsgehen mit einem anderen Startpunkt.**  Weil jeder Schritt
  seine Ausgabe als **unveränderlichen, inhaltsadressierten Baum** hinterlässt (F96-1), heißt
  „zurück auf Schritt 3": einen neuen Lauf eröffnen, der die Einträge bis 3 übernimmt und ab
  4 neu rechnet.  Es wird **nichts** verworfen — die späteren Ergebnisse bleiben unter ihren
  `step_key`s liegen und werden wiedergefunden, falls man wieder vorwärts geht.  Ein „Undo",
  das Daten zerstört, wäre hier nicht nur unnötig, sondern falsch.
- **F110-11: Die Körnung des Zurückgehens ist der Schritt.**  Mitten in einem Schritt gibt es
  keinen Haltepunkt (der Prozess läuft, sein `upperdir` ist unfertig).  Wer feiner steuern
  will, schneidet die Pipeline feiner — das ist dieselbe Antwort, die auch für Cache-Treffer
  gilt, und sie macht beide Wünsche mit einem Mittel wahr.
- Ein Lauf bekommt damit eine **Historie** statt eines Zustands: die Tabelle
  `(Index, step_key, output_tree, Dauer, Treffer/Lauf)` ist zugleich Cache, Resume-Punkt und
  Rückwärtsgang.  Die Oberfläche braucht dafür keine neue Quelle — sie zeigt diese Tabelle.

### Der Haken (neu gemessen, betrifft auch den heutigen Agenten)

- **F110-12: §96.3 setzt overlayfs voraus — und M0 hat gemessen, dass es unprivilegiert nicht
  zu haben ist.**  Auf dem Entwicklungsrechner ist `overlay` nicht einmal geladen
  (`/proc/filesystems`), und ein unprivilegierter Prozess lädt kein Modul.  Damit steht der
  „Layer = overlay-upper"-Mechanismus **nicht** auf jedem Host zur Verfügung — das trifft den
  geplanten Layer-Cache des Agenten genauso wie die neue Runtime.  Drei Auswege, in dieser
  Reihenfolge zu prüfen:
  1. Das Modul **einmal** bei der Einrichtung laden (root, in `94_agent_provisioning` zu
     ergänzen) und im Fähigkeitsbericht erzwingen.
  2. **Ohne overlay**: Eingabebaum kopieren, nach dem Schritt gegen den Ausgangsbaum
     **diffen**.  Teurer, aber liefert dieselbe Adresse — der Vertrag bleibt der Baum-Hash,
     nicht das Mittel.
  3. **FUSE-Overlay** (liefert nebenbei die Lesemenge aus F110-9, Stufe 2).
  **Der Baum-Hash ist der Vertrag, nicht overlayfs.**  Wird das verwechselt, hängt der ganze
  Cache an einem Kernelmodul.

### Abnahme

- **A110-1** Zwei Läufe derselben Pipeline: der zweite führt `pure`-Schritte nicht aus
  (bestehendes A96-1), **und** eine Umstellung zweier unabhängiger Schritte in der Quelle
  ändert keinen `step_key`.
- **A110-2** Zwei Schritte mit überschneidender Schreibmenge, als `permutable` deklariert:
  der Lauf meldet den Konflikt und verweigert die Vertauschung (F110-8).
- **A110-3** „Zurück auf Schritt N": der neue Lauf übernimmt die Einträge ≤ N, rechnet ab
  N+1 neu, und ein anschließendes Vorwärts findet die alten Ergebnisse wieder (nichts wurde
  gelöscht).
- **A110-4** Derselbe Schritt auf einem Host **mit** und einem **ohne** overlayfs erzeugt
  denselben `output_tree`-Hash (F110-12).

---

## 110.10 Gebaut: Bundle-Leser (18.10.2026)

`runtime/rt_model_{process,linux,config}.aiml` + `runtime/rt_bundle.aiml` + `runtime/test_rt.aiml`
(22 Prüfungen, grün).  Drei Typen je Datei, weil aiml `spec/49 §14` nicht mehr zulässt.

**F110-13: `sys.deserialize` liest FREMDES JSON — gemessen, aber nicht zugesagt.**  Das
Serialisierungsformat von aiml trägt ein `__type`-Feld (`spec/29 §5.2`); eine OCI-`config.json`
hat keines.  Die Messung zeigt: wird der Typname als Argument übergeben, genügt das —
verschachtelte Modelle (`process.user.uid`), Listen von Modellen (`mounts[].options`), Listen
von Strings und `bool` kommen korrekt an.  **Damit ist das Lesen der OCI-Spec gratis**, und
cosmos-rt braucht keinen eigenen JSON-Parser.

Der Haken: `spec/29` *verspricht* das nicht.  Ein Umbau der yyjson-Anbindung könnte es
stillschweigend nehmen, und cosmos-rt stünde ohne Eingabeformat da.  **Offener Punkt:**
`spec/29 §5.2` um diese Zusage ergänzen und einen Korpus-Test in aiml dazulegen — bis dahin
ist `test_rt` die einzige Sicherung.

**F110-14: Ein `ref<T>` auf ein Member trägt die IR nicht.**  `config() -> ref<RtConfig>`
scheiterte an der Modul-Verifikation (`Function return type does not match operand type`).
Der direkte Weg (`bund.conf`) tut dasselbe ohne Umweg — die Methode ist entfallen.

## 110.11 Gebaut: Lebenszyklus (18.10.2026)

`runtime/rt_state.aiml` — der OCI-Automat `creating → created → running → stopped` als eigene,
**ohne root prüfbare** Einheit.  `runtime/test_rt.aiml` deckt jetzt 39 Prüfungen ab, grün.

Geprüft werden vor allem die **verbotenen** Kanten, denn dort entstehen Waisen: zweites
`begin` unter belegter Kennung, `start` auf einem laufenden, `start` auf einem beendeten,
`delete` während `running`.  Jede davon wird abgelehnt **und begründet** — eine Ablehnung ohne
Grund führt beim nächsten Mal zu `--force`.

**F110-15 (GELÖST 18.10.2026 — in aiml, nicht hier): Der OCI-Schlüssel `id` kollidierte mit
der aiml-Namensregel.**  Behoben durch **Feld-Aliasse** (aiml `spec/15`): `- [ident, string,
"", { alias: "id" }]`.  Der Alias gilt in beide Richtungen, also liest cosmos-rt jetzt auch
ein von runc geschriebenes `state.json`.  Dazu kam `JsonStyle.bare` (aiml `spec/29 §5.2a`),
das `__type` aus der Ausgabe nimmt — damit ist auch F110-13 keine geduldete Zufälligkeit mehr,
sondern eine zugesagte Eigenschaft mit Test (`tests/test_ser_alias_bare.aiml`).
Der ursprüngliche Befund zur Nachvollziehbarkeit:  `state.json` nennt
das Feld `id`; aiml verbietet Namen unter drei Zeichen, also kann die Zuordnung über den
Feldnamen (F110-13) genau hier **nicht** greifen.  Das Modell heißt daher `ident`, `to_json`
schreibt den richtigen Schlüssel — und beim Lesen eines **fremden** `state.json` muss dieses
eine Feld von Hand geholt werden.  Allgemein: die Gratis-Zuordnung aus F110-13 endet bei jedem
fremden Namen mit weniger als drei Zeichen.

**F110-16: `state.json` ist eine Schnittstelle, kein Abbild.**  Deshalb von Hand gebaut und
nicht über `sys.serialize` — dessen `__type` hat in einer Datei, die fremde Werkzeuge lesen,
nichts zu suchen.  Der Test prüft genau das (`kein __type`, `"status":"stopped"`,
`"id":"rt-1"`).

## 110.12 M1 erreicht (18.10.2026)

AppArmor-Profil `deploy/apparmor/cosmos-rt` eingespielt (eine Erlaubnis: `userns`), danach
meldet `rt_probe`:

```
mein AppArmor-Profil  cosmos-rt (unconfined)
userns erzeugbar      ja
+ mount im userns     ja
── M1: Prozess im Namespace ──
innen uid 0           ja
ohne userns NICHT     ja
eigener Mount drin    ja
```

`runtime/shim/rt_shim.c` (202 Zeilen) kann jetzt `unshare` + ID-Abbildung + `execve` +
`waitpid`; `runtime/rt_exec.aiml` rechnet aus dem Bundle, WAS verlangt wird.

**F110-17: Der Gegenversuch gehört zur Messung.**  „Innen uid 0" allein beweist nichts — eine
Shell, die als root läuft, sagt dasselbe.  Erst der zweite Lauf **ohne** `CLONE_NEWUSER`, der
scheitern MUSS, macht den ersten zur Aussage.  Beide stehen im Bericht nebeneinander.

**F110-18: Der lebende Nachweis gehört in den Bericht, nicht in den Test.**  `test_rt` prüft,
was ohne Rechte prüfbar ist (Bits aus dem Bundle, Argumentaufbau, Lebenszyklus) und läuft
überall; `rt_probe` misst, was dieser Host wirklich tut, und wird vom AppArmor-Profil gedeckt.
Ein Test, der ein Profil braucht, wäre auf jedem fremden Rechner rot, ohne dass etwas kaputt
ist.

**Argumente und Umgebung sammelt die C-Schicht** (`rt_args_push`/`rt_env_push`): `execve`
verlangt ein `char* const[]`, das die aiml-FFI nicht kennt (F110-1).  Statisch auf 128
begrenzt — ein Bundle mit mehr Argumenten ist ein Fehler, kein Anwendungsfall.

**Nächster Schritt (M2):** `pivot_root` in das rootfs, `/proc`, `/dev`, `/sys`, Masked-Paths,
caps droppen, `no_new_privs`, seccomp (x86_64) — und die Ausbruchsproben aus §110.6, die ab
hier zur Pflicht werden.

## 110.13 M2 — eigene Wurzel steht (18.10.2026)

```
── M2: eigene Wurzel ──
eigene Wurzel   ja — /proc da, alte Wurzel weg, Wurzel schreibgeschützt, Maske hält
```

Gebaut: `rt_mounts.aiml` (OCI-Optionen → `MS_*`-Bits und Datenzeichenkette, Plan aus dem
Bundle) und die Kindsequenz in `rt_shim.c`: Mounts → Wurzelwechsel → Maske/Schreibschutz →
`no_new_privs` → Capabilities abgeben → `execve`.  `test_rt` deckt die Übersetzung ab
(57 Prüfungen, grün), `rt_probe` den lebenden Lauf.

Fünf Befunde, die jeweils einen Fehlschlag gekostet haben — und die zeigen, warum eine
eigene Runtime teuer ist: nicht der Syscall, sondern die Bedingungen, unter denen er **nicht**
gilt.

- **F110-19: `unshare(CLONE_NEWPID)` versetzt nicht den Aufrufer, sondern erst dessen
  Kinder.**  Ohne einen **zweiten `fork`** ist die Nutzlast nicht PID 1 — und ein frisches
  `proc` lässt sich gar nicht einhängen (`mount(proc) → EPERM`; der Kernel verlangt einen
  eigenen, bewohnten PID-Namespace).
- **F110-20: Ein Remount im User-Namespace darf keine gesperrten Flags verlieren.**  Wer nur
  `MS_RDONLY` setzt, scheitert mit EPERM auf jedem Dateisystem, das `nosuid`/`nodev` trägt.
  `locked_flags()` liest sie mit `statvfs` und gibt sie mit.
- **F110-21: `pivot_root(".", ".")` statt `.oldroot`.**  Der Kniff aus `pivot_root(2)` legt
  neue und alte Wurzel auf dasselbe Verzeichnis und hängt die alte ab — so bleibt **kein**
  leeres `.oldroot` zurück, das auf einer schreibgeschützten Wurzel ohnehin nicht mehr
  löschbar wäre.
- **F110-22: Eine Maske ist `/dev/null` — Schreiben gelingt dorthin per Definition.**  Die
  Maske ist nur am **Lesen** nachweisbar, und nur mit Gegenprobe an einer *nicht* maskierten
  Datei.  Dazu: `test -s` taugt in `/proc` nicht, weil procfs Größe 0 meldet und den Inhalt
  erst beim Lesen erzeugt (dieselbe Falle wie `io.read_file`, aiml e6f9eb4).
- **F110-23: Rechte vor dem `exec` abgeben heißt, dass die Nutzlast nicht mounten darf.**  Die
  frühere M1-Prüfung „eigener Mount drin" wurde dadurch zur Zusage „Nutzlast darf **nicht**
  mounten" — dieselbe Messung, umgekehrtes Vorzeichen.

**Und eine Arbeitsregel, die sich sofort bezahlt gemacht hat:** jeder Fehlschlag in der
Kindsequenz nennt sich selbst (`mount(src → dst, typ, flags) scheiterte: …`, `pivot/bind`,
`pivot/readonly`, `pivot/umount`).  Vorher hieß es nur „Fehler −118"; vier der fünf Befunde
oben wurden erst dadurch in Minuten statt Stunden sichtbar.

**Offen für den Abschluss von M2:** seccomp (x86_64-Bytecode, arch-geprüft) und die
Ausbruchsproben aus §110.6 (`/proc/self/exe`, geerbte Dateideskriptoren, Symlink-Rennen).

## 110.14 seccomp und die Ausbruchsproben (18.10.2026)

```
── seccomp ──
ohne Filter gelingt uname  ja
mit Filter scheitert es    ja
Vorgabeprofil, Regeln      23
Nutzlast laeuft weiter     ja
und mount bleibt verwehrt  ja

── M2: eigene Wurzel ──
eigene Wurzel  ja — Wurzel, /proc, Maske; kein /proc/self/exe-Schreiben, keine geerbten fds
```

- **F110-24: Die Syscall-Nummern kommen aus den libc-Headern (`SYS_*`), nicht aus einer
  eigenen Tabelle.**  Damit ist die Architektur-Frage beim Übersetzen beantwortet und kann
  nicht veralten — `SYS_mount` ist auf x86_64 und aarch64 jeweils die richtige Zahl.  Die
  **Auswahl** der verbotenen Aufrufe ist Politik und steht in aiml (`deny_default`,
  23 Regeln, benannt und lesbar).  Ein Profil, das niemand lesen kann, prüft auch niemand.
- **F110-25: Der Filter prüft ZUERST die Architektur.**  Ohne diese drei Befehle am Anfang
  wäre ein auf x86_64 dichtes Profil auf dem Pi eine offene Tür, weil dieselbe Nummer dort
  einen anderen Aufruf bezeichnet.  Stimmt `AUDIT_ARCH` nicht, endet der Prozess
  (`SECCOMP_RET_KILL_PROCESS`), statt ungefiltert weiterzulaufen.
- **F110-26: Die Gegenprobe hat einen Falschbefund gefangen.**  Erster Lauf: „mit Filter
  scheitert es — ja".  Richtig, aber aus dem falschen Grund: der Plan aus M2 war noch
  gesetzt, dessen rootfs aber gelöscht, also scheiterte **jeder** Lauf schon am Mount.  Erst
  die Zeile davor („ohne Filter gelingt `uname`") zeigte es, weil sie **nein** sagte.
  Ohne positiven Gegenlauf hätte das Profil grün gelogen.

**Ausbruchsproben (§110.6), Stand:**

| Probe | Stand |
|---|---|
| 1 `/proc/self/exe` überschreiben | ✅ scheitert |
| 2 geerbte Dateideskriptoren | ✅ keine (≤ 3 + Verzeichnis-fd) |
| 3 Symlink-Rennen beim Mounten | offen |
| 4 maskierte Pfade | ✅ leer beim Lesen, mit Gegenprobe |
| 5 Syscall außerhalb des Profils | ✅ `EPERM`, Architektur geprüft |
| 6 Differenz gegen crun | offen — crun ist auf diesem Host nicht installiert |

**Nächster Schritt:** M3 (aarch64/Pi) — derselbe Bericht auf dem Pi, eigener seccomp-Bytecode,
und die Pi-Fallen aus §110.2 (`cgroup_enable=memory`, overlay auf der Karte).

## 110.15 M4 — Grenzen greifen (18.10.2026)

```
── M4: Grenzen ──
delegierter Knoten      app.slice
memory.max gilt         67108864
pids.max gilt           64
16 MB gehen durch       ja
256 MB: vom Kernel beendet  ja
  Grenze berührt (Treffer)  39
  Exit des Containers       137
Spitzenbedarf gemessen  67108864
```

`runtime/rt_cgroup.aiml` — cgroup v2 ist reines Dateischreiben, also steht es in aiml.  Nur
**eines** muss die C-Schicht tun: das Kind trägt sich SELBST ein, nach dem `fork` und vor
`unshare`/`execve` (der Elternprozess kennt die PID erst nach dem fork, und was danach
entsteht, soll schon auf das Konto des Containers gehen).

- **F110-27: Die cgroup entsteht im nächsthöheren DELEGIERTEN Knoten, nicht in der eigenen.**
  Ein Prozess sitzt in irgendeiner fremden Scope (hier unter der des Terminals); dort lässt
  sich `cgroup.subtree_control` nicht setzen, weil fremde Prozesse darin liegen.  `find_home`
  geht deshalb aufwärts, bis ein Knoten **schreibbar** ist **und** `memory` an seine Kinder
  weiterreicht — der tiefste gewinnt, denn je näher, desto weniger fremde Nachbarn.
- **F110-28: Eine Speichergrenze ohne Swap-Grenze ist WEICH.**  Erste Messung: Spitzenbedarf
  exakt `memory.max`, Prozess lebt weiter, `oom_kill 0` — der Kernel hatte ausgelagert statt
  einzugreifen.  Mit `memory.swap.max = 0` endet der Container wie zugesagt (Exit 137).
  Ein Container, der seine Grenze überschreitet, soll ENDEN, nicht langsam werden.
- **F110-29: Drei Anläufe, bis die Messung wirklich maß.**  `head -c N | tail -c 1` schiebt
  durch und belegt nichts; `tail -c N /dev/zero` springt ans Ende, weil /dev/zero **seekbar**
  ist, und belegt ebenfalls nichts; `cat /dev/zero | tail` endet nie und hängt.  Richtig ist
  eine **begrenzte** Quelle durch eine Pipe.  Und das Urteil liest `memory.events`
  (`oom_kill`, `max`), nicht nur den Exit-Code: ein fehlgeschlagener Befehl kann tausend
  Gründe haben, `oom_kill` zählt genau einen.

**Offen:** `cpu.max` (hier nicht delegiert — `app.slice` reicht nur `memory` und `pids`
weiter), Symlink-Rennen (§110.6 Probe 3), Differenz gegen crun (nicht installiert), M3 (Pi).

## 110.16 Der erste Container-Agent (18.10.2026)

```
cosmos-rt: cosmos-rt-… — 8 Einrichtungsschritte, 7 Argumente
[agent_exec] rt-container-1 registered at ws://127.0.0.1:8765     ← aus dem Container
[agent_reg]  rt-container-1 connected peer=6 new=0                ← am Server
[reaper]     agent rt-container-1 disconnected                    ← Ende ohne Rest
```

Damit steht die erste Hälfte des Zielbilds: ein cosmos-Agent läuft in einem Container, den
**unsere** Runtime gebaut und gestartet hat, meldet sich beim Controller an und verschwindet
rückstandsfrei.  Gebraucht wurden dafür: `runtime/rt_main.aiml` (die Binärdatei `cosmos-rt`),
ein Bundle mit `deploy/runtime.tar.gz` als Nutzinhalt — und drei Befunde.

- **F110-30: Ein Container, der seine Runtime überlebt, ist eine Waise.**  Drei abgebrochene
  Läufe hinterließen drei lebende Agenten, die sich nach einem Server-Neustart prompt wieder
  anmeldeten und Arbeit zogen.  `PR_SET_PDEATHSIG(SIGKILL)` bindet das Kind an die Runtime.
  Der übliche Nachtest gegen die Race (`getppid() != parent`) darf aber **nur** für den
  ersten fork gelten: im neuen PID-Namespace ist der Elternprozess außerhalb nicht sichtbar,
  `getppid()` liefert dort **0** (gemessen: Exit 129).
- **F110-31: Merged-usr lässt sich nicht wegbinden.**  Bindet man `/usr/lib64` auf `/lib64`,
  zerreißt es die **relativen** Symlinks darin: der Lader zeigt auf
  `../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2`, was unter `/lib64` plötzlich das
  Tarball-`/lib` des Containers trifft — `execve` meldet `ENOENT`, obwohl die Datei im
  Verzeichnis **steht**.  Das rootfs muss die Symlink-Struktur des Hosts **spiegeln**
  (`/bin → usr/bin`, `/lib64 → usr/lib64`) statt sie zu überdecken.
- **F110-32: Einrichtung ohne Browser.**  `cosmosd --mint-token <label>` prägt ein
  Enrollment-Token und gibt das Geheimnis **einmal** auf stdout aus (nie ins Log, der Store
  hält nur `sha256`).  Dieselbe Begründung wie bei `--grant-*`: die Autorität sitzt am
  Server, und Container, Pi und CI haben keinen Browser.

**Nebenbefund, eigenes Thema:** der laufende `cosmosd` (seit 12:38) nahm TCP-Verbindungen an,
beantwortete aber **keinen** WebSocket-Handshake mehr — 16 offene, nie bediente Verbindungen,
ein schlafender Ein-Faden-Prozess, Log seit Startzeit still.  Nach dem Neustart lief alles.
Das ist ein Hänger in der Ereignisschleife und gehört untersucht, nicht weggestartet.

**Kleinigkeit mit Folgen:** der Agent im Container loggt **UTC** (14:12), der Server lokal
(16:12) — im rootfs fehlt `/etc/localtime`.  Für die Fehlersuche über Grenzen hinweg sollte
die Zeitzone ins Bundle.

**Nächster Schritt:** M7 — der Controller prägt das Token selbst, startet den Container bei
Bedarf und räumt ihn ab (Kapazitätsschleife + Reaper).  Dann ist aus „ein Container verbindet
sich" ein „cosmos startet sich seine Agenten".

## 110.17 M7 — cosmos startet den Container selbst (18.10.2026, blockiert)

Gebaut: `sources/server/rt_launcher.aiml` + `cosmosd --spawn-agent <id> [--spawn-limit-mb N]`
+ `tools/make_rt_template.sh`.  Der Controller prägt das Token selbst, schreibt das Bundle,
löst `cosmos-rt` ab und kann den Lauf abräumen (Token **widerrufen**, nicht nur Verzeichnis
löschen — dieselbe Lehre wie beim Knoten-Rückbau, doc/spec/94).

```
[rt_launch] rt-auto-1 gestartet (Bundle logs/rt_runs/rt-auto-1, Grenze 256 MB)
cosmos-rt: … — 10 Einrichtungsschritte, 7 Argumente      ← Container läuft
```

- **F110-33: Ein rootfs je Lauf wäre Verschwendung.**  Der Inhalt ist für alle Läufe
  derselbe (285 MB); nur das Token unterscheidet sie.  Die **Vorlage** wird read-only
  untergelegt, das Token kommt als eigener Bind obendrauf — so liegt das Geheimnis nie im
  geteilten Abbild.
- **F110-34: Drei Betriebshandlungen mit demselben `db_dir` sind eine Klasse.**  Der
  aiml-Static-Check (`same_arg`) hat das beanstandet, als `run_spawn` dazukam — zu Recht.
  `DaemonOps` hält den Speicherort als Member; `--grant`, `--mint-token` und `--spawn-agent`
  sind seine Methoden.  Dem Prüfer folgen war hier billiger als ihn abzuschalten.

### Der Blocker: cosmosd hört auf zu bedienen

M7 ist damit **nicht** abgeschlossen: der Container startet, der Agent läuft darin — aber die
Anmeldung kommt nicht mehr durch, weil der Server zum zweiten Mal an diesem Tag stehen
bleibt.  Belege, beide Male gleich:

| Messung | Wert |
|---|---|
| Log | bricht **mitten im Takt** ab (regelmäßige 10-s-Pushes, dann Stille) |
| offene Verbindungen auf :8765 | 16 bzw. 6, keine davon bedient |
| WS-Handshake (curl) | **keine Antwort** |
| Send-Q aller Sockets | **0** → der Server hängt NICHT im Schreiben |
| Recv-Q serverseitig | **8934 B** von einem Peer, 153 B von einem zweiten → er **liest nicht** |
| Prozess | ein Faden, `S (sleeping)`, `wchan = wait_woken` |
| Gegenstelle der 8934 B | **`cosmosd` selbst** (eigener fd 26 → eigener Port) |

Die letzte Zeile ist die interessante: der Server hält eine **Verbindung zu sich selbst** und
hat ihr 8934 Bytes geschickt, die er nie abholt.  Ein einfädiger Server, der auf seine eigene
Antwort wartet, wartet für immer.  `ws://127.0.0.1:8765` steht in `provision_handlers`
(Exec-URL für einen eingerichteten Knoten) und seit heute in meinem Spawn-Pfad — die Quelle
der Selbstverbindung ist damit **noch nicht** benannt und gehört untersucht, bevor M7
weitergeht.

**Das ist kein Nebenschauplatz:** ein Controller, der nach Minuten aufhört zu antworten,
macht jedes Zielbild hinfällig — Container hin oder her.

## 110.18 Der Stillstand, eingekreist (18.10.2026)

**Die Ursache, in einem Satz:** `poll(fd, 0)` meldet **ein** Byte, der Frame-Leser verlangt
daraufhin den **ganzen** Frame mit blockierendem `recv` — und wenn der Rest nie kommt, wartet
ein einfädiger Server für immer.

Die Kette, Schritt für Schritt gemessen:

| Schritt | Messung | Schluss |
|---|---|---|
| 1 | Send-Q aller Sockets = **0** | hängt NICHT im Schreiben (erste Vermutung war falsch) |
| 2 | Recv-Q eines Peers 8934 → **13255 B** | er **liest** nicht mehr |
| 3 | dieser Peer hat keinen sichtbaren Prozess | es ist der Agent im **Container** (eigener PID-Namespace); `fd 26` ist die *Server*-Seite, nicht eine Selbstverbindung |
| 4 | ein Faden, `S`, `wchan = wait_woken` | blockiert in einem `recv` |
| 5 | Log endet **nach** `push.tick`, und der sendet ohne zu warten | die Blockade sitzt in `sess.update()` |
| 6 | `mirror_runtime.cpp:909` ruft `aiml_ws_poll(peer, 0)`, dann `aiml_ws_recv_raw` | gelesen wird nur bei Bereitschaft … |
| 7 | `ws_runtime.cpp:424` `ws_read_n`: `while (done < n) recv(fd, …, 0)` auf **blockierendem** Socket | … aber dann der GANZE Frame, komme was wolle |

Auslöser im Betrieb: ein Sender, der mitten im Frame stehen bleibt — hier die Container-
Agenten, die ich wiederholt mit SIGKILL beendet habe.

**Es ist ein aiml-Laufzeitfehler, nicht einer von cosmos:** jede aiml-Anwendung mit
WebSocket-Server trifft ihn.

**Stopfen (eingebaut):** `SO_RCVTIMEO = 10 s` auf angenommenen Verbindungen — aus „für immer"
wird „nach 10 s abgebrochen", der Server bedient weiter.  **Die Lösung** ist ein
schrittweiser, nicht blockierender Frame-Leser mit Puffer je Verbindung; der Stopfen trennt
einen langsamen, aber ehrlichen Sender genauso wie einen toten.

### Der zweite Befund: KV-Schreibzugriffe anderer Prozesse sind unsichtbar

Nach dem Stopfen lief der Server weiter — und lehnte den Container-Agenten **begründet** ab:
`invalid enrollment token`.  Die Gegenprobe entscheidet:

| Token geprägt | Ergebnis |
|---|---|
| **vor** dem Serverstart | `rt-container-1 connected peer=13 new=1` ✅ |
| von einem **zweiten Prozess**, während der Server läuft | `refused: invalid enrollment token` ❌ |

`AgentTokenStore.verify` liest live aus dem KV — die Klasse cachet nichts.  Unsichtbar ist der
Schreibzugriff eine Ebene tiefer: **AionDB koordiniert zwei Prozesse auf demselben Speicher
nicht.**

- **F110-35: Betriebshandlungen eines zweiten Prozesses wirken erst nach einem Neustart.**
  Das betrifft `--mint-token` **und** sehr wahrscheinlich `--grant-email` (eigene Prüfung
  nötig).  In beiden Fällen gehört ein Hinweis in die Ausgabe, sonst wundert sich jemand
  zu Recht.
- **F110-36: Live-Spawn gehört IN den Server.**  `cosmosd --spawn-agent` kann einem laufenden
  Controller keine Zugangsdaten unterschieben.  M7 braucht den `RtLauncher` **im**
  Server-Prozess — als admin-geschützte RPC oder in der Kapazitätsschleife, mit DESSEN
  Token-Store.  Der CLI-Weg bleibt richtig für die Einrichtung eines Knotens *vor* dem Start.

## 110.19 M7 — der Controller startet sich den Agenten (18.10.2026)

```
[autoscale] an, hoechstens 1 Container
[autoscale] 3 Schritt(e) warten, kein Agent da — starte Container
[rt_launch] rt-auto-1 gestartet (Bundle logs/rt_runs/rt-auto-1, Grenze 512 MB)
[agent_reg] rt-auto-1 connected peer=1 new=1          ← der Container meldet sich an
```

Die Kapazitätsschleife sitzt jetzt **im** Server (`cosmos_daemon`, Sweep-Takt), prägt das
Token über den **eigenen** Store und löst `cosmos-rt` ab.  Damit ist F110-36 eingelöst: das
Token ist für den laufenden Controller sichtbar, weil er es selbst geschrieben hat.
Eingeschaltet wird sie über `COSMOS_RT_AUTOSCALE=1` (Standard **aus** — ein Server, der
ungefragt Container startet, wäre eine Überraschung), begrenzt über `COSMOS_RT_MAX`.

Die Entscheidung ist genau eine, weil der Agent **zieht**: *„es warten Schritte, es ist kein
Agent da, und ich habe noch Platz"*.  `ClusterBootstrap.pending_steps` zählt sie über die
Läufe — keine gepflegte Warteschlange daneben, die auseinanderlaufen könnte.

- **F110-37: Die Regel zählt noch das Falsche.**  Gezählt werden ALLE wartenden Schritte, auch
  solche, die der frisch gestartete Agent gar nicht nehmen darf: die drei im Beispiel gehören
  zur Demo-Pipeline und verlangen `required_label` `build`/`control-plane`.  Der Container
  startet, meldet sich an — und kann nichts tun.  Richtig wäre, nur die Schritte zu zählen,
  die zu den **Labels des Agenten passen**, den man starten würde (`label_ok` gibt es dafür
  schon).  Sonst startet der Controller Helfer, die nicht helfen können.
- **F110-38: Eine Lausch-Adresse ist keine Verbindungsadresse.**  Dem Container wurde
  `ws://0.0.0.0:8765` mitgegeben — „auf allen Schnittstellen lauschen", nicht „dorthin
  verbinden".  Dass es trotzdem ging, war Glück (Linux leitet 0.0.0.0 auf localhost um).
  Jetzt wird die Wähladresse abgeleitet.
- **F110-39: Zwei stille `replace`-Aufrufe kosteten einen Lauf.**  Beim Einbau der Schleife
  griffen zwei von drei Textersetzungen nicht — ohne Prüfung, also ohne Fehler, also ohne
  Hinweis.  Der Server startete, und nur das fehlende `[autoscale] an` verriet es.  Jede
  Ersetzung gehört bestätigt; das ist dieselbe Lehre wie bei den Messungen.

**Nächster Schritt:** `pending_steps` auf label-fähige Schritte einschränken (F110-37), dann
das Abräumen in denselben Takt hängen (Container ohne Arbeit beenden, Token widerrufen).

## 110.20 Die Regel geschärft (18.10.2026)

Nach §110.19 waren zwei Dinge falsch, und beide hat erst der Betrieb gezeigt.

- **F110-40: „Ist ein Agent da?" ist die falsche Frage.**  Die Bedingung lautete
  `online_count == 0` — und blieb stumm, solange irgendein fremder Agent am selben Port
  hing, auch wenn der die wartenden Schritte gar nicht nehmen durfte.  Richtig ist:
  **kann einer der Anwesenden diese Arbeit nehmen?**  Der Controller fragt jetzt je Agent
  `pending_for(seine Etiketten, seine Kennung)` und startet nur, wenn **niemand** zuständig
  ist.
- **F110-41: Wer nichts zu tun hat, geht wieder — und zwar wirklich.**  `reap_idle` beendet
  nach einer Schonfrist (60 s) den Container über `sys.process_attach` + `kill` (Prozess-
  gruppe), widerruft das Token und löscht das Bundle.  Das frühere `reap` nahm den Eintrag
  nur aus der Liste — der Container wäre weitergelaufen.  Die Schonfrist ist nötig, weil ein
  frisch gestarteter Agent ein paar Sekunden bis zur Anmeldung braucht.

**Gemessen, und richtig so:** ein Schritt **ohne** `required_label` löst **keinen** Start aus,
weil ihn jeder Anwesende nehmen darf — im Lauf vom 16:54 hat ihn prompt `agent-1` genommen
(`[dispatch] sagen [arch=x86_64] -> agent-1`).  Der Controller startet nur, wo er gebraucht
wird.

**Offen (der Nachweis mit Etikett):** eine Pipeline mit `runs_on: container` einreichen, die
nur der Container nehmen darf.  Dafür fehlt noch ein Konto: cosmos bremst Registrierungen je
IP (`reg_throttle`, zu Recht), und nach den heutigen Testläufen ist 127.0.0.1 gesperrt.
`test/submit_work.aiml` kann deshalb jetzt ein **vorhandenes** Konto wiederverwenden
(`COSMOS_SUBMIT_MAIL`/`_PW`) — ein Werkzeug, das man mehrmals braucht, darf nicht an einer
Bremse scheitern, die gegen Fremde gedacht ist.

**Neues Werkzeug:** `test/submit_work.aiml` reicht Arbeit ein und geht — im Gegensatz zu
`e2e_pipeline_run`, das ERST auf einen Agenten wartet und DANN einreicht.  Genau das ist mit
einer Kapazitätsschleife unvereinbar: der Client wartet auf den Agenten, der Controller auf
die Arbeit.

## 110.21 M7 vollständig (18.10.2026)

```
17:14:50  [rt_launch] rt-auto-1 gestartet (Bundle logs/rt_runs/rt-auto-1, Grenze 512 MB)
17:14:50  [dispatch]  sagen [arch=x86_64] -> rt-auto-1
17:15:50  [rt_launch] rt-auto-1 hat nichts zu tun — wird abgeraeumt
17:15:50  [rt_launch] rt-auto-1 abgeraeumt, Token widerrufen
          Bundles übrig: 0 · cosmos-rt-Prozesse: 0
```

Eingereicht wird mit `test/submit_work.aiml` (Pipeline mit `runs_on: container`), das Konto
kommt aus `cosmosd --add-user` (§110.22).  Der Controller sieht Arbeit, die **kein**
anwesender Agent nehmen darf, prägt ein Token, startet den Container, der Agent meldet sich
an und zieht den Schritt — und eine Minute später ist alles weg.

**F110-42: Ein Modell, das man einfügt UND zurückgibt, verliert seine Strings.**  `spawn`
legte dasselbe `RtLaunch` in die Liste, das es zurückgab.  Unmittelbar nach dem Einfügen
stand alles richtig drin (**gemessen**) — aber der Rückgabewert nahm die Zeichenketten beim
Freigeben mit, und der Listeneintrag blieb mit leeren Textfeldern zurück.  Folge: das
Abräumen meldete einen **leeren Namen** und löschte das Bundle nicht; dass es überhaupt den
richtigen Eintrag traf, lag nur daran, dass `"" == ""` zufällig passte.  Die Liste bekommt
jetzt einen **eigenen Satz Kopien**.

Der Weg dorthin ist die eigentliche Lehre: **vier Erklärungen, vier Widerlegungen.**
Strings in einer Modell-Liste überleben (Probe), die Schleifen-Form mit `remove` überlebt
(Probe), „einfügen und zugleich zurückgeben" überlebt (Probe), ein Zeiger-Member statt
Wert-Member ändert nichts (Messung).  Erst ein Messpunkt **im echten Starter** hat es
gezeigt.  Besonders lehrreich: die dritte Probe baute den Fall korrekt nach, sah aber **vor**
der Freigabe nach — eine Probe zum falschen Zeitpunkt bestätigt die falsche Antwort.
Alle drei Proben stehen jetzt in `runtime/test_rt.aiml`, damit niemand sie wiederholen muss.

**F110-43: Container überleben den Controller, der sie gestartet hat.**  `PDEATHSIG` bindet
den Container an `cosmos-rt`, nicht an `cosmosd`.  Nach einem Controller-Neustart lief der
Container weiter, meldete sich an und bekam prompt Arbeit — aber der neue Controller kannte
ihn nicht als **seinen**: die Liste lebt nur im Speicher.  Er würde ihn nie abräumen und sein
Token nie widerrufen.  Zu lösen, bevor das produktiv geht: Zustand dauerhaft führen (die
Bundle-Verzeichnisse sind da) oder beim Start einsammeln und bewusst entscheiden —
übernehmen oder beenden.

## 110.22 `cosmosd --add-user` (18.10.2026)

Die Registrierungsbremse (`reg_throttle`) hängt an der **Client-IP**; eine Betriebshandlung
am Server hat keine, also prüft `handle_register` sie gar nicht erst.  `--add-user <mail>
--add-user-pw <pw> --add-user-nick <name>` nutzt genau das — kein Schlupfloch, sondern die
Unterscheidung zwischen „jemand im Netz" und „der Betreiber", dieselbe Linie wie `--grant`
und `--mint-token`.  Die Ausgabe sagt dazu, dass es **erst nach einem Neustart** wirkt
(F110-35).

## 110.23 Bauen statt nur laufen (18.10.2026)

Auftrag (User): eine Pipeline, die einen Container aufbaut — Klon, venv, GCC über apt, dann
ein **Cut**, ab dem die Schritte nicht wiederholt werden, und danach immer wieder
`git checkout origin/HEAD` + bauen.

**Stufe 1 läuft** (`tools/make_build_bundle.sh`, 67 s von der nackten Basis):

```
apt update + git, python3-venv, gcc    ✓
git 2.43.0 · Python 3.12.3 · gcc 13.3.0
python3 -m venv /opt/venv              ✓
git clone aiml → 40 MB                 ✓
```

Ein **Bau**-Container braucht mehr als ein Lauf-Container, und zwar in drei Punkten — jeder
davon kostete einen Fehlschlag:

- **F110-44: Eine einzige Kennung genügt zum Laufen, nicht zum Bauen.**  `dpkg` legt Dateien
  unter verschiedenen Benutzern an; ein `chown` auf eine nicht abgebildete ID scheitert.  Die
  Runtime bildet jetzt den Bereich aus `/etc/subuid` ab (65536 Kennungen) — über
  `newuidmap`/`newgidmap`, weil ein unprivilegierter Prozess mehrzeilige Abbildungen nicht
  selbst schreiben darf.  Das Kind erzeugt den Namespace und **wartet**, der Elternprozess
  ruft die setuid-Helfer, zwei Rohre verständigen beide.
- **F110-45: Ohne `/dev/urandom` stirbt `apt`.**  „Method http has died unexpectedly" —
  gemeint ist ein fehlendes Gerät.  Die sechs üblichen werden gebunden (ohne root kein
  `mknod`).
- **F110-46: Capabilities abgeben ist für einen Bau-Container zu streng.**  `apt` fällt für
  seinen HTTP-Helfer auf `_apt` zurück und braucht `CAP_SETGID`.  `cosmos-rt --build 1`
  behält die Capabilities **im Namespace** — sie gelten gegenüber den abgebildeten
  Kennungen, nicht gegenüber dem Host; `no_new_privs` bleibt in beiden Fällen gesetzt.

## 110.24 Der Cut (18.10.2026)

```
Stufe 1 (nackte Basis)   67 s
Cut                      2,8 s   stufe1 → d755f30d93c293d1   869 MB
Stufe 2 (aus dem Cut)    < 1 s   git 2.43 · gcc 13.3 · venv · Klon · „gcc baut"
```

`tools/cut_bundle.sh` hält den Stand nach einem Bauschritt fest, `tools/materialize.sh` legt
ihn für den nächsten Lauf bereit.  Die Adresse ist der **Inhalt** (sha256 über alle Dateien,
sortiert) — der Vertrag aus doc/spec/96, unabhängig davon, ob der Stand per overlay-upper
oder per Kopie entstand (F110-12).

- **F110-47: Wer einen ID-Bereich abbildet, muss ALLES im Namespace tun.**  Der erste Cut
  scheiterte von außen mit „Keine Berechtigung" an `var/cache/apt/archives/partial` — die
  Datei gehört der abgebildeten Kennung `_apt`, und als gewöhnlicher Benutzer kommt man nicht
  heran.  Schnitt **und** Bereitstellung laufen deshalb selbst in einem Container.  Das ist
  derselbe Grund, aus dem `podman unshare` existiert.

**Was damit steht:** Stufe 1 → Cut → Stufe 2 ab dem Cut.  67 s werden zu unter 1 s.

**Was fehlt (Schritt C/D aus der Schätzung):** die Adresse im CAS ablegen und an den
`step_key` binden (dann entscheidet der Server über Treffer, nicht ein Dateiname), und der
`resolved`-Schritt mit `git ls-remote`, damit „an der Spitze des Branches" automatisch neu
baut und sonst nicht.  Dazu: solange es kein overlay gibt, ist Bereitstellung eine **Kopie**
(869 MB, ~3 s) statt eines Mounts.

## §110.25 Cut ⇄ OCI-Image

Ein Cut ist ein Baum, der über seinen Inhalt adressiert ist.  Ein OCI-Image ist ein Baum aus
Blobs, die über ihren Inhalt adressiert sind.  Das ist **dieselbe Idee in zwei Formaten** —
darum ist die Wandlung eine Umschreibung und kein Übersetzungsverlust, und darum geht sie in
**beide** Richtungen.  `cosmos-oci` (`runtime/rt_oci.aiml`, Ziel `runtime/exodus-rt-oci.json`)
tut genau das:

```
cosmos-oci --cut deploy/rt_cuts/stufe1 --image deploy/oci/stufe1 --ref-name stufe1
cosmos-oci --image deploy/oci/stufe1  --bundle logs/rt_builds/aus-image
```

Gemessen am echten Stufe-1-Cut (18.10.2026):

```
Cut → Image   34 s    869 MB Baum → 343 MB Image (eine Schicht, gzip -6)
Image → Bundle 17 s   wieder 869 MB rootfs + fertiges config.json
Lauf aus dem importierten Bundle: git 2.43.0 · gcc 13.3.0 · Python 3.12.3 · Klon auf d216077
```

Das Layout ist das genormte: `oci-layout`, `index.json`, `blobs/sha256/<hex>` mit Manifest,
Image-Konfiguration und Schicht.  Geschrieben wird es aus aiml-Modellen (`rt_model_oci*.aiml`)
— kein Textbaukasten, kein Python.

- **F110-48: Beide Richtungen, EINE Schicht.**  Ein Cut wird **eine** Schicht; mehr wäre
  erfunden, denn seine Geschichte steht im `step_key` (doc/spec/96), nicht im Baum.
  Umgekehrt kommt ein Image mit N Schichten als **ein** rootfs zurück: der Baum bleibt
  gleich, die Schichtung nicht.  Wer danach wieder exportiert, bekommt wieder eine Schicht.
  Das ist der einzige Verlust der Rundreise, und er ist benannt.
- **F110-49: `diff_id` ≠ Blob-Adresse.**  Die Image-Konfiguration nennt in `rootfs.diff_ids`
  den Digest des **unkomprimierten** Tars, das Manifest den des **komprimierten** Blobs.  Wer
  das verwechselt, baut ein Image, das kein fremder Leser annimmt — und merkt es erst dort.
  `cosmos-oci` rechnet den ersten im Container (`sha256sum` vor `gzip`), den zweiten
  strömend (`hash.sha256_file`), nie über den Speicher: eine Schicht ist hunderte Megabyte.
- **F110-50: Gleicher Baum, gleiche Adresse — nur mit `--sort=name` und `gzip -n`.**  Ohne
  Sortierung hängt der Tar an der Lesereihenfolge des Dateisystems, ohne `-n` steckt ein
  Zeitstempel im gzip-Kopf.  Beides würde denselben Baum zweimal verschieden adressieren und
  den Cache-Vertrag aus doc/spec/96 brechen.
- **F110-51: Whiteouts sind Pflicht, nicht Kür.**  Eine obere Schicht **löscht** über
  `.wh.<name>` und macht über `.wh..wh..opq` einen Ordner opak.  `cosmos-oci` legt jede
  Schicht erst in ein Zwischenverzeichnis, wendet beide Marker auf den **gewachsenen** Baum an
  und mischt dann — in dieser Reihenfolge, sonst käme eine gelöschte Datei zurück.  Das ist
  der häufigste Fehler in selbstgebauten Image-Lesern; `runtime/test_oci.aiml` hält ihn fest
  (zwei Schichten, Marker in der oberen).
- **F110-52: Auch die Wandlung läuft im Namespace** (F110-47).  Tar und Entpacken fassen
  Dateien abgebildeter Kennungen an; `cosmos-oci` schreibt sich dafür selbst ein Bundle (aus
  denselben `RtConfig`-Modellen, die cosmos-rt liest) und ruft `cosmos-rt --build 1` auf.
- **F110-53: Die Plattform steht im Index.**  Ein Index kann dasselbe Image für x86_64 **und**
  aarch64 führen; `--arch` wählt, und ohne Treffer endet der Import mit einem Fehler statt mit
  halber Arbeit.  Das ist die Tür für das Zielbild „Pi und x86 am selben cosmos" (M3).
- **F110-54: Was das Format von aiml verlangte.**  Drei Dinge fehlten und wurden dafür gebaut:
  `JsonStyle.bare` (kein `__type`, spec/29 §5.2a), der Feld-**Alias** für `os` — zwei Zeichen,
  also als aiml-Name unzulässig (spec/15) — und `JsonStyle.skip_empty` (spec/29 §5.2c), weil
  die Image-Spec zu `variant` *SHOULD be omitted* sagt und ein aiml-Modell kein „nicht
  gesetzt" kennt.  Dabei fiel ein stiller Datenverlust auf: **jede** aiml-Map serialisierte
  als `{}` (der Schreiber lief über `capacity` und prüfte ein `occupied`-Byte, das
  `MapImpl::put` nie setzt — aiml F29-22).  Gefunden, weil `annotations` leer blieb.

**Offen:** die Gegenprobe mit einem fremden Werkzeug.  Auf diesem Rechner ist weder `skopeo`
noch `podman` noch `umoci` installiert; geprüft ist das Layout bisher nur gegen die Spec und
gegen den eigenen Leser (`runtime/test_oci.aiml`: Digests nachgerechnet, Rundreise, Whiteouts,
drei Gegenproben).  Die Probe, die fehlt, ist eine Zeile:
`skopeo copy oci:deploy/oci/stufe1:stufe1 docker-daemon:cosmos-stufe1:latest`.

## §110.26 Der Sandkasten IM Container (21.10.2026)

Frage des Nutzers: *„könnte ich jetzt eine Pipeline starten, die einen Agenten startet,
darin aiml kompilieren mit den GitHub-Klonen?"*  Die Kette stand auf dem Papier
(Autoscale → `cosmos-rt` → Agent → `claim_step` → bwrap), war aber nie mit einem
**Shell-Schritt** gelaufen — nur mit `body:`-Schritten.  Sechs Dinge lagen dazwischen,
jedes einzeln gemessen, jedes mit einer Fehlermeldung, die auf etwas anderes zeigte als
auf die Ursache.

- **F110-55: „Nichts zu tun" heißt nicht „nichts wartet".**  Die Kapazitätsschleife fragte
  nur, ob Schritte **warten**.  Ein zugeteilter Schritt wartet nicht mehr — also räumte der
  Controller den Container ab, **während er arbeitete** (Zuteilung 17:38:10, Abräumung
  17:39:09).  Jetzt wird je Container gefragt: hält er einen Schritt (`cluster.agent_busy`)
  **und** wartet einer für ihn (`pending_for`)?  Erst wenn beides nein ist, geht er.
- **F110-56: Eine read-only Wurzel hat kein Arbeitsverzeichnis.**  Der Agent legte seine
  Schritte unter `steps/` relativ zum Arbeitsverzeichnis an — im Container ist das `/`, und
  das ist schreibgeschützt.  Er nahm den Schritt an und fiel still um.  Jetzt gibt es
  `--work-root`, der Launcher bindet `<bundle>/work` nach `/work`, und die Wurzel meldet
  sich, wenn sie nicht anlegbar ist.
- **F110-57: Im Container braucht der Sandkasten keinen zweiten User-Namespace.**  bwrap
  scheiterte an `setting up uid map: Operation not permitted`, mit Capabilities dann an
  `Failed to make / slave`.  Grund ist eine Kernel-Regel: Mounts gehören dem Namespace, in
  dem sie entstanden; aus einem **neuen** User-Namespace heraus sind sie nicht mehr
  umhängbar.  Drinnen ist der Container die Grenze — der Agent lässt `--unshare-user` weg,
  sobald `/proc/self/uid_map` keine Vollabbildung zeigt.
- **F110-58: Wer einsperren soll, muss einsperren dürfen.**  Das seccomp-Profil verbot
  `mount`, `umount2`, `pivot_root` und `unshare` — also genau das, was der Agent für bwrap
  braucht.  Mit vollen Capabilities (`CapEff: 1ffffffffff`) scheiterte `unshare` trotzdem:
  das Verbot kam von uns selbst.  Neu ist `deny_nested` (`--nested 1`): derselbe Satz ohne
  diese vier.  Die Grenze nach außen bleibt der User-Namespace des Containers, seine cgroup
  und die schreibgeschützte Wurzel; der Schritt bekommt eine **zweite** Grenze, keine
  schwächere erste.
- **F110-59: Maskierte Pfade sperren das verschachtelte `/proc`.**  `maskedPaths` und
  `readonlyPaths` sind gesperrte Untermounts; solange sie über `/proc` liegen, verweigert
  der Kernel im inneren Namespace ein frisches `proc` (`Can't mount proc`).  Im
  Agenten-Container entfallen sie — die Maskierung gehört eine Ebene tiefer, wo bwrap dem
  Schritt ein eigenes `/proc` in einem eigenen PID-Namespace vorsetzt.
- **F110-60: DNS steht hinter einem Symlink.**  `/etc/resolv.conf` zeigt auf systemd-
  Rechnern nach `/run/systemd/resolve`.  Ohne dieses Verzeichnis zeigt er ins Leere:
  `getent hosts github.com` blieb stumm, `git` meldete „Could not resolve host".  Container
  **und** Sandkasten binden es jetzt mit (`--ro-bind-try`, weil es das nicht überall gibt).

**Gemessen danach**, in einem Schritt, den eine eingereichte Pipeline in einem vom
Controller gestarteten Container ausgeführt hat:

```
uid=0(root) gid=0(root)            git 2.43.0 · gcc 13.3.0 · Python 3.12.3
/tmp schreibbar (16G tmpfs)        github.com → 140.82.121.4
git ls-remote https://github.com/octocat/Hello-World.git HEAD → 7fd1a60b…
git ls-remote https://github.com/Pymann/aiml.git HEAD → „could not read Username"
```

Der letzte Punkt ist **kein** Fehler: das Repository ist privat, und im Container liegt
kein Zugang.  Netz, TLS und Zertifikate stehen; was fehlt, ist eine Entscheidung darüber,
WIE das Geheimnis hineinkommt (Deploy-Key, Lese-Token als Datei, oder der lokale Klon als
Bind).  Ebenso fehlt für `exodus build` noch `exodus` selbst im Container: der Cut hat
Python und ein venv, aber kein installiertes Paket.

**Nebenbefund (F110-43 bestätigt):** ein Container überlebt den Neustart des Controllers.
Beim Messen hing ein verwaister Agent am neuen Server und bekam einen Schritt zugeteilt,
dessen Arbeitsverzeichnis es nicht mehr gab.  Solange der Launcher seinen Zustand nur im
Speicher hält, ist jeder Neustart eine Gabelung.

## §110.27 Ein Bau-Container ist ein Container, kein Sandkasten im Sandkasten

Der erste Versuch, die Bau-Pipeline zu fahren, lief gegen eine Wand, die erst nach drei
Messungen ihren Namen bekam: `tar` konnte im Schritt keine Eigentümer setzen
(`Cannot change ownership to uid 0, gid 8: Invalid argument`), obwohl der Container
**volle** Capabilities hatte und seine Abbildung 65536 Kennungen umfasst.

- **F110-61: bwrap macht IMMER einen eigenen User-Namespace — und der bildet EINE Kennung
  ab.**  `--unshare-user` wegzulassen genügt nicht: unprivilegiertes bwrap braucht den
  Namespace für seine Mounts und schreibt dann eine Ein-Zeilen-Abbildung
  (`0 <uid> 1`).  Jede andere Kennung ist darin **nicht abgebildet**, und `chown` auf
  `gid 8` scheitert mit `EINVAL` — nicht `EPERM`.  Das ist der Unterschied zwischen „darf
  nicht" und „gibt es nicht", und er zeigt auf die Abbildung, nicht auf die Rechte.
- **F110-62: Im Container führt der Agent den Schritt DIREKT aus.**  Der Container ist
  bereits die Grenze: eigener User-Namespace mit vollem Bereich, eigene cgroup, eigene
  Wurzel.  Ein bwrap darin fügt keine Grenze hinzu, sondern nimmt eine weg — nämlich die
  Abbildung, die `apt`, `dpkg` und `tar` brauchen.  Draußen, auf einem nackten Knoten,
  bleibt bwrap der Sandkasten (dort ist er die einzige Grenze).  Erkannt wird es an
  `/proc/self/uid_map`, nicht an einem Schalter.
- **F110-63: Ein Lauf hat einen Arbeitsplatz.**  Jede Stufe bekam bisher ihr eigenes
  Verzeichnis (Abnahme A3) — eine mehrstufige Bau-Pipeline konnte damit nichts weitergeben:
  was `apt` auspackt, sah die nächste Stufe nicht.  Jetzt liegt unter `/ws` der Arbeitsplatz
  des **Laufs**; das eigene Verzeichnis der Stufe bleibt getrennt.  Er lebt im Container —
  wechselt der Container, ist er weg (siehe F110-43).
- **F110-64: Ein Abbild statt einer geborgten Wurzel** (`COSMOS_RT_IMAGE`).  Die Vorlage
  (`§110.17`) trägt nur den Agenten und borgt sich `/usr` vom Wirt — gut für einen Agenten,
  unbrauchbar für eine Pipeline, die `apt-get install` sagt: sie verändert ihre Wurzel, und
  die muss ihr gehören.  `tools/make_agent_image.sh` baut deshalb ein echtes Ubuntu mit dem
  Agenten unter `/opt/cosmos` (nicht in `/usr`: 10 von 50 Bibliotheken kollidierten dort),
  und der Launcher kopiert es je Lauf in eine **beschreibbare** Wurzel.
- **F110-65: Zwei Türen für Quellen, beide optional.**  `COSMOS_RT_SRC` bindet ein
  Verzeichnis mit lokalen Spiegeln nach `/src` (dieselbe Pipeline klont dann
  `file:///src/…` statt GitHub, ohne Geheimnis); `COSMOS_RT_GIT_CRED` bindet **eine Datei**
  nach `/gitcred`, die der Schritt als `/ws/git-credentials` sieht.  Kein Geheimnis liegt im
  geteilten Abbild — es reist als eigener Bind, wie das Token (F110-30).

Die Grenze nach außen bleibt dabei unverändert: User-Namespace mit abgebildetem
Unterbereich, cgroup mit `memory.max`/`pids.max`, seccomp (`deny_nested`, §110.26), kein
`CAP_SYS_ADMIN` auf dem Wirt.  Was sich ändert, ist die Grenze nach **innen**: der Schritt
darf in seinem eigenen Container tun, was ein Bau braucht.

**Zwei Nachträge aus demselben Lauf:**

- **F110-66: Ein Eintrag ohne Prozess ist kein Container.**  Stirbt ein Container beim
  Start (fehlendes Bind-Ziel, kaputtes Abbild), blieb er in der Liste des Launchers stehen:
  `live_count` zählte ihn, die Kapazitätsschleife startete keinen Ersatz, und der
  Aufräumer liess ihn in Ruhe, weil für ihn ja Schritte warteten.  Ein fehlendes
  `/dev/zero` im Abbild legte so die ganze Schleife still.  `sweep_dead` fragt jetzt vor
  jeder Runde nach, ob der Prozess noch lebt (`sys.process_attach` + `running()`), und gibt
  den Platz frei — mit Verweis auf das Protokoll, das seit §110.26 liegen bleibt.
- **F110-67: Gesagt, nicht erschnüffelt.**  Der Agent entschied anhand von
  `/proc/self/uid_map`, ob er in einem Container steckt.  Die Vermutung war einmal falsch —
  er nahm bwrap, dessen tmpfs-Wurzel keine Paketdatenbank hat, und `apt` meldete fehlende
  Verzeichnisse, die es in der echten Wurzel sehr wohl gab.  Eine Stunde Suche an der
  falschen Stelle.  Jetzt sagt der Launcher es ihm: `--in-container 1`.  Wer den Container
  startet, weiss es; der Agent muss nicht raten.

- **F110-68: Ein wiederverwendeter Container ist kein frisches Base-Image.**  Der Launcher
  lässt einen Container am Leben, solange Arbeit für ihn da ist — der zweite Lauf fand
  darum 232 statt 91 Pakete vor.  Für Tempo ist das richtig, für die Zusage „vom
  Base-Image an" nicht: ein Lauf, der sich auf den Zustand des vorigen stützt, ist nicht
  wiederholbar.  Offen: entweder je Lauf ein eigener Container (teurer, hermetisch) oder
  eine Stufe, die den Ausgangszustand ausdrücklich herstellt.  Solange das offen ist, sagt
  die erste Stufe wenigstens, WAS sie vorfindet (`dpkg -l | grep -c '^ii'`).

## §110.28 Der erste vollständige Bau (21.10.2026)

Eine eingereichte Pipeline, ein vom Controller gestarteter Container, neun Stufen — und am
Ende läuft ein `aiml`, das es vorher nicht gab:

```
basis_zeigen                   0     Ubuntu 24.04.3, 91 Pakete, eigene ext4-Wurzel, uid 0
apt_installieren               0     33 Pakete → 332 installiert (gcc 13.3, llvm 18.1.3, python 3.12)
venv_bauen                     0     /opt/venv, pip 26.2.2
exodus_klonen                  0     exodus ca3b3ea
exodus_installieren            0     pip install -e .
aiml_klonen                    0     aiml d216077, 125 MB
abhaengigkeiten_verknuepfen    0     __exodus_cache/apt/<pkg>/…/payload -> /
aiml_bauen                   287s    aiml-asan · aiml-tests · aiml (80 MB) · libaiml.so (81 MB)
nachweis                       0     „hallo aus dem frisch gebauten aiml"
```

- **F110-69: `exodus deps install` ist ein Stub.**  aiml deklariert ~140 apt-Pakete in
  seiner `exodus.json` und sucht deren Header unter
  `__exodus_cache/apt/<paket>/<arch>/<version>/payload`.  Wer das Projekt frisch klont, hat
  diesen Cache nicht — und es gibt **kein Kommando**, ihn herzustellen: `deps` meldet
  „not implemented" (im Commit: `pass`), `pkg add` lädt genau EIN Paket.  Bis exodus das
  kann, stellt die Pipeline den Cache selbst her: die apt-Stufe installiert dieselben
  Pakete ins System, und je Paket zeigt ein Symlink `payload -> /`.  Das ist ehrlicher als
  eine Kopie — es gibt nur eine Fassung dieser Dateien.
- **F110-70: Ein Bau wird am ERGEBNIS beurteilt, nicht am Rückgabewert.**  `exodus build
  --all` endet hier mit 1, und zwar zu Recht: zwei Repro-Konfigurationen tragen einen
  absoluten Host-Pfad, und der wasm-Lauf braucht emsdk (eine git-Abhängigkeit, die ebenfalls
  niemand wiederherstellt).  Die Stufe nennt beide mit Grund und prüft dann, was zählt:
  `out/aiml/aiml` und `out/libaiml/libaiml.so`.  Ein Abbruch hätte verschwiegen, dass
  Compiler und Bibliothek fertig sind.
- **F110-71: `/ws` liegt im direkten Betrieb in der Wurzel des Containers**, nicht im
  Host-Bind: ohne bwrap gibt es keinen `--bind`, und der Arbeitsplatz ist schlicht das
  Verzeichnis `/ws` des Abbilds.  Das genügt (der Container lebt für den ganzen Lauf), hat
  aber eine Folge, die man wissen muss: er verschwindet mit dem Container, und von aussen
  liegt er unter `logs/rt_runs/<agent>/rootfs/ws`, nicht unter `…/work/<run>/ws`.

**Pipeline:** `pipelines/aiml_vom_base.yaml`, als Job `aiml-vom-Base-Image` im Server.
**Start:** über den Client (Jobs → Quelle… → Starten) oder
`COSMOS_SUBMIT_FILE=… ./submit_work`.

## §110.29 `image:` statt eines Etiketts — die Umgebung gehört in die Pipeline

**Befund des Nutzers (21.10.2026):** *„`runs_on: container` bedeutet wohl, dass er einen CAS
einrichtet?! Das ist ein built-in word oder? Die `runs_on`-Syntax sollten wir hier nicht
verzerren!"* — Er hat in allen drei Punkten recht, und der dritte ist der wichtige.

**Was `runs_on` ist.**  Ein **Knoten-Etikett**, sonst nichts (aiml F62-47).  Kein eingebautes
Wort: unsere Container tragen `container,x86_64,linux`, weil `COSMOS_RT_LABELS` das sagt — ein
Betreiber könnte sie `kiste` nennen.  Es richtet **keinen CAS ein** (der CAS ist der
inhaltsadressierte Speicher aus doc/spec/96 und auf dem Agentenpfad bis heute gar nicht
verdrahtet), und es ist ausdrücklich **kein Schlüsselmaterial** (aiml F62-49, F96-16).

**Was daran falsch war.**  `pipelines/aiml_vom_base.yaml` schrieb `runs_on: container` und
meinte damit: *„ich brauche eine eigene Wurzel, in der ich `apt-get install` sagen darf."*  Das
ist eine Aussage über die **Umgebung**, und die gehört nach aiml `spec/62` §18 in `image:` —
ein Attribut, das **Schlüsselmaterial ist** (F62-67), während ein Etikett es nie sein darf.  Ein
Etikett, das heimlich eine Umgebung meint, zerfällt beim ersten Betreiber, der anders etikettiert,
und der Cache merkt es nicht.

- **F110-72: Der Controller kennt Abbilder beim NAMEN, nicht beim Pfad.**  Eine Pipeline darf
  keinen Wirtspfad tragen (aiml F62-17); sie sagt `image: "ubuntu-base"` oder
  `image: "oci:deploy/oci/builder"`.  Die Zuordnung Name → Ort steht beim Wirt
  (`COSMOS_RT_IMAGES="ubuntu-base=/…/rt_image,builder=/…/oci/builder"`), wie bei jedem anderen
  `host:`-Wert.  Ein unbekannter Name ist ein Fehler **vor** dem Start (aiml F62-131), nicht
  eine Zuteilung, die nie bedient wird.  Geprüft wird der Kopf **und jede Stufe**
  (`image_problem` → `one_image_problem`): ein Tippfehler im `image:` einer Stufe wäre sonst
  der stillste Fehler, den dieses System hat — kein Agent trägt diese Umgebung, also wartet
  die Stufe bis zum Zeitablauf, und das sieht genau wie Arbeit aus.
- **F110-73: Zugeteilt wird nach Abbild, nicht nach Etikett.**  Ein Agent meldet beim Anmelden,
  **welches Abbild** er trägt (`--image <name>`); der Launcher setzt es, weil er es kopiert hat.
  Eine Stufe mit `image:` geht nur an einen Agenten mit genau diesem Abbild; `runs_on` bleibt
  daneben, was es war: das Etikett des Knotens (arm64, gpu, standort-b).
- **F110-74: Fehlt ein Abbild, startet der Controller einen Container damit** — das ist dieselbe
  Kapazitätsschleife wie bisher (§110.26), nur ist die Frage jetzt „wer hat *dieses* Abbild?"
  statt „wer hat *irgendein* Etikett?".
- **F110-75: `push: [{from: <stufe>, to: "oci:<pfad>"}]` schreibt das Ergebnis als
  OCI-Layout** — mit dem Wandler aus §110.25, auf dem Knoten, wo der Baum liegt (aiml F62-123).
  Der Controller merkt sich die **Digest**, nicht den Pfad (aiml F62-130), denn nur sie macht
  „darin weiterbauen" reproduzierbar.

## §110.30 `image:` und `push:` laufen (21.10.2026)

Die Form stand seit dem 11.10. in aiml `spec/62` §18.  Jetzt läuft sie — und zwar als
**drei** Dinge, die zusammengehören:

```yaml
- pipeline:
    name: kausal_probe
    image: ubuntu-base                                   # WORIN (F62-66/67)
    push: [{ from: erste, to: "oci:deploy/oci/zwischenstand" }]
    steps:
      - stage: { name: erste,  run: "echo spur > /spur.txt" }
      - stage: { name: zweite, image: "oci:deploy/oci/zwischenstand", run: "cat /spur.txt" }
```

**Gemessen, in dieser Reihenfolge, ohne dass jemand eine Reihenfolge hinschrieb:**

```
20:36:05  [rt_launch] rt-auto-1: eigene Wurzel aus …/deploy/rt_image
20:36:05  [dispatch]  erste  -> rt-auto-1
20:36:06  [push]      run-…/erste → deploy/oci/zwischenstand (pid 88357)
20:36:30  [push]      run-…/erste fertig: sha256:99332bb9f717…
20:37:19  [rt_launch] rt-auto-2: Wurzel aus dem Abbild oci:deploy/oci/zwischenstand
20:37:19  [dispatch]  zweite -> rt-auto-2
          → „spur der ersten stufe" / „und die zweite"
```

- **F110-76: Die Reihenfolge ist hergeleitet, nicht hingeschrieben** (aiml F62-129).  Der
  Scheduler gibt eine Stufe nicht heraus, solange ihr `image:` ein `push:`-Ziel desselben
  Laufs ist, das noch nicht `done` ist (`image_there`).  Ohne diese Prüfung liefe die zweite
  Stufe gegen das Abbild des **vorigen** Laufs: grün, falsch, beim nächsten Mal anders.
- **F110-77: Ein `oci:<pfad>`-Abbild wird MATERIALISIERT, nicht kopiert.**  Der Launcher legt
  das Layout mit `cosmos-oci --image … --bundle …` als Wurzel aus (§110.25).  Damit ist die
  Rundreise geschlossen: was eine Pipeline schreibt, kann die nächste als Basis nehmen — und
  derselbe Wandler bedient beide Richtungen.
- **F110-78: Push ist abgelöst und je Runde eingesammelt.**  Ein Abbild sind hunderte
  Megabyte; ein Controller, der eine Minute im Tar hängt, beantwortet in dieser Minute keine
  RPC.  Gemessen: 120 MB Layout in 24 s, der Lauf blieb die ganze Zeit bedienbar.
- **F110-79: Die Digest steht im Lauf, nicht der Pfad** (aiml F62-130).  Ein Pfad ist ein
  Name und bewegt sich; die Digest ist der Inhalt.  Erst damit ist „ein Abbild bauen und
  darin weiterbauen" reproduzierbar.
- **F110-80: Eine alte Laufzeit im Abbild fällt als fehlendes Symbol auf.**  Nach dem neuen
  Builtin `sys.require_tools` startete kein Container mehr: `undefined symbol:
  aiml_sys_require_tools` — die `libaiml.so` im Abbild war vom 13.10.  Die Meldung war
  eindeutig, der Weg dahin nicht: der Launcher sah nur „Container lebt nicht mehr".  Seit
  F110-66 nennt er dabei das Protokoll, und dort stand es.  **Ein Abbild altert mit seiner
  Laufzeit** — `deploy/collect_runtime.sh` + `tools/make_agent_image.sh` gehören zu jedem
  aiml-Bau, der die Laufzeit ändert.

## §110.34 Grenzen je Stufe, Schichten je Stufe (22.10.2026)

Zwei Fragen des Nutzers, die dieselbe Wurzel haben: *„können wir dem image ressourcen zuordnen
(kerne, ram, netzlaufwerk)"* und *„entstehen pro schritt die layer, aus dem das image erzeugt
werden kann und die auch verwendet werden um von einer bestimmten stage neu zu starten"*.

### Grenzen (aiml `spec/62` §18.1a)

- **F110-91: Der Wirt setzt, die Pipeline sagt.**  `resources: { cpu, mem, pids }` reist mit der
  Stufe bis zum Launcher; dieser schreibt sie als cgroup-v2-Grenzen des Containers
  (`memory.max`, `pids.max`, **`cpu.max`** — letzteres gab es nicht und kommt hinzu).  Fehlt die
  Angabe, gilt die Vorgabe des Wirts (`COSMOS_RT_LIMIT_MB`), nicht „unbegrenzt": ein Container
  ohne Grenze nimmt sich im Zweifel die Maschine.
- **F110-92: `cpu.max` ist eine Quote, keine Anzahl.**  cgroup v2 schreibt `<quota> <period>`;
  4 Kerne sind `400000 100000`.  Die Pipeline nennt Kerne, weil das die Einheit ist, in der
  Menschen rechnen — die Umrechnung gehört hierher, nicht in die Pipeline.

### Schichten (doc/spec/107 §107.1c, doc/spec/92)

- **F110-93: Eine Stufe bekommt ihren eigenen overlayfs-`upper` — im CONTAINER, nicht daneben.**
  Der Agent führt jeden Schritt in einem eigenen **Mount-Namespace** aus: `lower` ist das Abbild
  plus die `upper` aller vorherigen Stufen (von rechts nach links aufsteigend), `upper` ist das
  Verzeichnis dieser Stufe, dann `pivot_root`.  Was der Schritt schreibt, landet damit **genau**
  in seiner Schicht — inklusive Whiteouts für Gelöschtes, die der OCI-Export schon versteht.
  Ein zweiter User-Namespace entsteht dabei NICHT (F110-61): nur der Mount-Namespace ist neu,
  die Capabilities bleiben, `apt`/`dpkg` können weiter fremde Eigentümer setzen.
- **F110-94: Die Schichten liegen im Arbeitsbereich des LAUFS, nicht im Container-Bündel.**
  `<work>/<lauf>/layers/<nr>/{upper,work,merged}` — **nur die Nummer**, nicht `<nr>-<stufe>`.
  Die Reihenfolge des Stapels muss aus dem NAMEN lesbar sein: der Schnitt zählt 0,1,2,… ab und
  braucht kein Verzeichnislisting, dessen Sortierung bei zweistelligen Nummern ohnehin lügt
  (`10` vor `2`).  Die Nummer ist die Stufen-Nummer aus der Kennung `<lauf>-<lane>-<nr>`; wo es
  keine gibt, gibt es keine Schicht und der Schritt läuft wie vorher.  Damit überlebt eine
  Schicht den Container, der sie erzeugt hat — und genau das macht „ab Stufe X neu starten" zu
  etwas anderem als Glück: die Schichten bis X−1 werden wieder als `lower` aufgelegt, X und
  alles danach werden verworfen.
- **F110-95: Der `push:` schneidet dann den STAPEL, nicht die Wurzel.**  Ein Abbild aus N
  Schichten statt einer 1,5-GB-Scheibe; unveränderte Schichten behalten ihre Digest und werden
  beim nächsten Mal nicht neu geschrieben (inhaltsadressiert, doc/spec/92).
- **F110-96: Ohne Schichten ist der Wiedereinstieg ein Glücksfall.**  Vor dieser Arbeit
  funktionierte er nur, solange der Container lebte; starb er, startete ein frischer aus dem
  Basis-Abbild und alles vor der gewählten Stufe fehlte (gemessen am 22.10.2026).  Das steht
  auch in F101-25/26 — diese Arbeit ist genau das, was dort als Voraussetzung benannt ist.
- **F110-97: Wer eine Stufe erneut laufen lässt, wirft ihre Schicht UND alle späteren weg.**
  Nicht nur die eigene: läuft Stufe 1 noch einmal, ist alles, was Stufe 2 und 3 geschrieben
  haben, überholt.  Bliebe es liegen, wäre das nächste Abbild ein Stapel aus zwei verschiedenen
  Läufen — ein Zustand, den nie jemand gemessen hat.  Das Wegwerfen gehört in den Agenten, zum
  Zeitpunkt des Starts (`StepWorker.drop_from`), nicht in den `rewind_run` des Controllers: der
  Controller kennt den Arbeitsbereich des Wirts nicht, und eine Stufe, die läuft, ist der
  einzige Zeitpunkt, an dem die Aussage „alles ab hier ist ungültig" mit Sicherheit stimmt.
- **F110-98: Der Schnitt verträgt eine Schicht, die nur löscht.**  Geprüft in
  `runtime/test_oci.aiml` Abschnitt 6: drei Stufen → drei Schichten, drei `diff_ids`, drei
  verschiedene Blobs; Stufe 2 löscht nachweislich, was Stufe 0 angelegt hat, und ein leerer
  Stapel wird abgewiesen statt als leeres Abbild geschrieben.
- **F110-99: Zwei Löschformen, eine davon belegt.**  overlayfs markiert eine gelöschte Datei im
  `upper` als **Zeichengerät 0:0** und einen opaken Ordner über das xattr
  `trusted.overlay.opaque`.  Der Schnitt wandelt das erste in `.wh.<name>` (OCI) — **gemessen**
  am 22.10.2026 mit `pipelines/stapel_probe.yaml`: Stufe drei löscht, was Stufe eins angelegt
  hat, das Abbild trägt drei Schichten (177 B / 163 B / 159 B, drei `diff_ids`), und der
  Rückimport zeigt `stufe-zwei` und **kein** `stufe-eins`.  Das zweite wandelt er **nicht** — ein
  `.wh..wh..opq` schreibt er nicht, und eine Stufe, die ein ganzes Verzeichnis ersetzt, kann im
  Abbild untere Reste behalten.  Das bleibt offen und ist hier benannt, nicht vermutet.
- **F110-100: Die Wurzel des Wandlers hatte kein `/dev/null` — und `set -e` machte daraus einen
  Totalausfall.**  `ns_run` setzte die Basis readonly und mountete nur `/src` und `/out`.  Jede
  Umleitung nach `/dev/null` endete mit „cannot create /dev/null: Read-only file system".  Bei
  den ersten beiden Schichten fiel das nicht auf: `cp -al … 2>/dev/null || cp -a …` lief einfach
  in den Rückfallweg.  Erst die dritte — die mit dem Zeichengerät — scheiterte wirklich, weil
  `cp -a` ein Gerät nicht neu anlegen kann; sichtbar war nur die Meldung über `/dev/null`, die
  schon zweimal folgenlos dagestanden hatte.  Lehre: eine Fehlermeldung, die zweimal ohne Folgen
  auftritt, ist beim dritten Mal nicht harmlos, sondern verdeckt den eigentlichen Fehler.  Der
  Wandler mountet `/dev` jetzt vom Wirt.

### Abnahme des Stapels (22.10.2026, `run-1792693046693`)

Drei Stufen, eine Lane, `pipelines/stapel_probe.yaml`; die dritte löscht, was die erste angelegt
hat.  Gemessen, nicht geschlossen:

| Schritt | Ergebnis |
|---|---|
| Schichten auf Platte | `layers/0,1,2` — je 1 / 1 / 0 Dateien, die dritte mit dem Zeichengerät 0:0 |
| Meldung des Agenten | `layer_bytes`/`layer_files` je Stufe im `report_step` |
| Ablage des Controllers | KV `run_layers`, drei Zeilen zum Lauf |
| Schnappschuss | `get_cluster` → `Schichten=3` |
| `push:` | `--layers` statt `--cut`: 178 B / 162 B / 160 B, drei `diff_ids`, Manifest `sha256:13a3edb4…` |
| Rückimport | `/etc/stufe-zwei` da, `/etc/stufe-eins` **weg** — der Whiteout trägt |

Was dabei zuerst fehlschlug und warum, steht in F110-100 (`/dev/null`) und F103-24 (der Agent im
Abbild war älter als sein Modell).

## §110.33 Abnahme: vom nackten Ubuntu zum laufenden Compiler im Abbild

Gemessen in der Nacht zum 22.10.2026, `run-1792618220567`, neun Stufen, eine Lane.

| Stufe | was sie tat | Ergebnis |
|---|---|---|
| `basis_zeigen` | Wurzel, Dateisystem, Pakete | 91 Pakete, eigene Wurzel, uid 0 |
| `apt_installieren` | 40 Pakete + Abhängigkeiten | **332** Pakete, gcc 13, llvm 18.1.3 |
| `venv_bauen` | Python-Umgebung | 3.12.3, pip 26.2.2 |
| `exodus_klonen` / `_installieren` | Werkzeug aus `/src` | `exodus ca3b3ea` |
| `aiml_klonen` | Compiler-Quellen | `aiml d216077`, 125 MB |
| `abhaengigkeiten_verknuepfen` | Systempakete → `__exodus_cache` | 40 Verknüpfungen |
| `aiml_bauen` (`requires:`) | `exodus build --all` | `aiml` 80 MB, `libaiml.so` 81 MB, + `aiml-tests`, `aiml-asan`; 3 Konfigurationen nicht baubar **mit Grund** |
| `nachweis` | frisch Gebautes starten | „hallo aus dem frisch gebauten aiml" |
| `push:` | Wurzel → OCI | Schicht 1 546 128 470 B, Manifest `sha256:639417c3…` |

Und die Gegenrichtung: Import → 4,3 GB rootfs mit `/ws/aiml/out/aiml/aiml` (83 335 472 B) und
`libaiml.so` (84 617 392 B); in `cosmos-rt` gestartet, sagt der Compiler **„aus dem OCI-Abbild
heraus gebaut und gelaufen"**.  Damit ist die Kette geschlossen: Pipeline → Container → Abbild →
Container → laufendes Programm.

Was die Abnahme gekostet hat, steht in §110.32 und darunter: fünf Fehler, die alle dieselbe
Form hatten — **etwas galt als entbehrlich, während es noch gebraucht wurde** (F110-84 bis
F110-90).  Der Push selbst brauchte 30 Minuten `tar`+`gzip`; in dieser Zeit versuchte der
Controller **null** Mal, den Container abzuräumen.

## §110.32 Zwei Fragen an denselben Zustand driften auseinander

Gemessen am 21.10.2026 an einem Lauf, der nach Stufe 6 von neun stehenblieb und danach 35
Container in 36 Minuten verbrauchte — jeder gestartet, nach 60 s als untätig abgeräumt, der
nächste gestartet.

- **F110-84: Die Kapazitätsfrage ist die Zuteilungsfrage.**  Die Zuteilung fragte „pending **und**
  Etikett **und** Umgebung **und** Vorgänger fertig **und** Abbild schon da?"; die
  Kapazitätsschleife fragte „pending und Etikett?".  Dieselbe Lage, zwei Antworten: der
  Controller startete Container für Arbeit, die niemand nehmen *durfte*, und räumte sie als
  untätig wieder ab.  Jetzt gibt es **eine** Vorhersage — `StepScheduler.takeable(run, idx, who)`
  — und `claim`, `pending_for` und `first_pending_want` benutzen sie (`ready_here` ist dieselbe
  Frage ohne die Umgebung, weil die Kapazität die Umgebung ja gerade *sucht*).  Zwei
  Formulierungen derselben Frage driften; eine nicht.  Geprüft in
  `test/test_step_dispatch.aiml`.
- **F110-85: Solange der Stand im Container liegt, gehört der Container dem Lauf.**  Stufe 2
  installiert, was Stufe 7 braucht; Stufe 6 klont, was Stufe 7 übersetzt.  Wird der Container
  abgeräumt, ist der Lauf verloren — der nächste Container trägt dasselbe *Abbild*, aber ein
  Abbild ist der **Anfang**, nicht der Stand.  Darum bleibt ein Container stehen, solange er
  eine Stufe eines noch offenen Laufs ausgeführt hat (`cluster.serves_open_run`), auch während
  er wartet, etwa auf ein Abbild, das eine andere Stufe erst schreibt.  Das ist die ehrliche
  Zwischenstufe zu einem Container **je Lauf** (F110-68): erst der macht die Frage gegenstandslos.
- **F110-86: „Untätig" ist kein Beweis.**  Der Container wurde **eine Sekunde** nach dem
  Zuteilen abgeräumt.  Wer eine Ressource wegen Untätigkeit wegnimmt, muss ausschließen, dass
  gerade Arbeit auf dem Weg ist — hier über dieselbe Vorhersage (F110-84) plus den Stand
  (F110-85), nicht über eine Zeitschwelle.  Eine Schonfrist ersetzt die Frage nicht, sie
  verschiebt sie nur.

- **F110-90: Ein Schreibzugriff, der ein Abbild entwertet, gehört abgewiesen.**  Ein vertippter
  Aufruf (`--cut` statt `--bundle`, also Richtung verwechselt) exportierte ein **leeres**
  Verzeichnis in ein vorhandenes Layout und ersetzte dessen `index.json` durch ein Manifest mit
  96-Byte-Schicht.  Die 125 MB des echten Pushes lagen noch als Blöcke da, waren über den Index
  aber nicht mehr erreichbar — und der nachfolgende Import meldete „1 Schicht(en), startklar"
  für ein 16-KB-Ergebnis.  `export_cut` weist einen leeren Schnitt jetzt ab und nennt die
  Gegenrichtung beim Namen.  Beweis danach vollständig: Stufe → Wurzel → `push:` →
  Layout (Schicht 125 474 736 B, Manifest `sha256:7822a9f1…`) → Import → 386 MB rootfs mit
  `marke.txt` („hier war die pipeline"), also der Spur, die die Pipeline selbst gelegt hat.
- **F110-89: Der Lauf ist nicht zu Ende, wenn die letzte Stufe zu Ende ist.**  Ein `push:` liest
  das Dateisystem, das **im Container** liegt — er gehört zum Lauf wie eine Stufe.  Gemessen am
  21.10.2026 am ersten vollständigen Bau: Stufe 8 meldete fertig, der Lauf galt als erledigt,
  der Container wurde abgeräumt, und 19 Sekunden nach dem Start des Pushes las `tar` eine Wurzel,
  die unter ihm verschwand (`File removed before we read it` für halb `/usr`).  Das Abbild wäre
  halb geworden; dass `tar` dabei einen Fehler liefert, war Glück — ein leiser Fall hätte ein
  unvollständiges Abbild mit gültiger Digest erzeugt.  Darum hält `serves_open_run` den
  Container auch, solange ein Push-Ziel dieses Laufs weder `done` noch `failed` ist; WER das
  Dateisystem gebaut hat, steht an der Stufe (`stage_agent_if_done`), nicht im Push-Eintrag.
  Derselbe früher „sporadisch fehlgeschlagene" Push von 20:34 war dasselbe Rennen — es gewann
  nur meistens der Push.
- **F110-88: Ein Schutz, der nicht endet, ist eine Fessel.**  F110-85 hält den Container,
  solange der Lauf offen ist — und „offen" hieß „irgendeine Stufe ist `pending` oder `running`".
  Der Nachfolger einer **gescheiterten** Stufe bleibt aber für immer `pending` stehen (F101-10:
  übersprungen heißt nie zugeteilt), also wäre ein einziger Fehlschlag genug gewesen, den
  einen Container-Platz dauerhaft zu belegen — und `run_outcome` hätte den Lauf nie `failed`
  genannt.  Darum zählt eine übersprungene Stufe als Fehlschlag, nicht als offene Arbeit
  (`StepScheduler.lane_dead`): der Lauf endet, der Platz wird frei.  Gefunden beim Nachdenken
  über F110-85, nicht im Betrieb — geprüft in `test/test_step_dispatch.aiml` („der Nachfolger
  ist niemandem zuteilbar", „und der Lauf gilt nicht mehr als offen").
- **F110-87: Ein Container-Name darf keinen Vorgänger haben.**  Die Zählung begann nach jedem
  Controller-Neustart wieder bei `rt-auto-1` — und das Bündel `logs/rt_runs/rt-auto-1` gehörte
  noch einem Container des VORIGEN Starts, der den Neustart überlebt hatte.  Zwei Container auf
  einem Bündel (dieselbe Wurzel, dasselbe Token): der neue bekam seinen ersten Schritt und starb
  mit dem alten (gemessen 21.10.2026 an Stufe 0 von `run-1792614467716`; der Lauf lief weiter,
  weil `sweep_dead` den Platz freigab und die nächste Stufe einen frischen Container bekam —
  ein Glücksfall, kein Entwurf).  Darum trägt der Name jetzt eine **Marke je
  Controller-Start** (`rt-<startmarke>-<nummer>`).  Ein Name, der sich wiederholt, ist kein
  Name.

### Offen, mit Grund

- **Ein Modellwechsel macht gespeicherte Läufe unlesbar, und das Hochfahren sagt es
  schlecht.**  Nach einer Änderung an den Lauf-Modellen passt der Schema-Fingerprint der
  Blobs nicht mehr; die Laufzeit schreibt **je Blob** eine `[ser-FATAL]`-Zeile, und was
  übrigbleibt, ist ein leerer Lauf im Zustand `queued`.  Für die Zuteilung ist er harmlos
  (keine Stufen → nie nehmbar, hält also auch keinen Container nach F110-85), aber die Ausgabe
  ist eine Wand aus Fehlern statt **eines** Satzes: „N Läufe stammen aus einer älteren
  Modellfassung und werden übersprungen — `COSMOS_DROP_UNREADABLE=1 ./purge_demo` entfernt
  sie."  Das Aufräumen gibt es (gemessen 21.10.2026: 39 Läufe), die ruhige Meldung nicht.
- **Logik-Tests und Betrieb teilen sich einen Speicher, wenn man sie bar startet.**
  `run_tests.sh` setzt je Test ein `AIONDB_PATH` (Zeile 49) — ein direkt im Projektverzeichnis
  gestartetes Test-Binary aber nicht: es schreibt Testläufe (`r-1…`) und Demo-Daten
  (`pipeline-api-main`) in den Speicher des laufenden Controllers.  Die Reste belegten den
  einen Container-Platz und ließen denselben Test beim zweiten Lauf fehlschlagen
  (`nickname already taken`) — was von außen wie eine Regression aussieht.  Ein Riegel im
  Code (z. B. `{persist: true}` nur mit gesetztem `AIONDB_PATH`) wäre besser als eine Regel,
  die man kennen muss.

## §110.31 Bedienung — was man wissen muss, um es zu benutzen

Eine Oberfläche, die man nur mit dem Quelltext daneben bedienen kann, ist keine.  Darum
hier in einem Stück, was ein Betreiber setzt und was ein Autor schreibt.

**Der Wirt (Umgebung des Controllers):**

| Variable | Bedeutung | Beispiel |
|---|---|---|
| `COSMOS_RT_AUTOSCALE` | Container bei Bedarf starten | `1` |
| `COSMOS_RT_MAX` | höchstens so viele gleichzeitig | `2` |
| `COSMOS_RT_LIMIT_MB` | Speichergrenze je Container | `12288` |
| `COSMOS_RT_IMAGES` | **Name → Ort** der Abbilder (F110-72) | `ubuntu-base=/…/deploy/rt_image` |
| `COSMOS_RT_IMAGE` | Vorgabe-Abbild, wenn eine Pipeline keines nennt | `/…/deploy/rt_image` |
| `COSMOS_RT_LABELS` | Etiketten der gestarteten Container — **wo**, nicht worin | `x86_64,linux` |
| `COSMOS_RT_SRC` | lokale Spiegel nach `/src` (klonen ohne Zugang) | `/…/projects/python` |
| `COSMOS_RT_GIT_CRED` | eine Zugangsdatei nach `/gitcred` → `/ws/git-credentials` | `/…/git-credentials` |
| `COSMOS_RT_SHARES` | **Name → Ort** der Freigaben (§110.35); `:ro` nagelt sie lesend fest | `quellen=/srv/nfs/quellen:ro,ablage=/srv/out` |

**Der Autor (in der Pipeline):**

```yaml
- pipeline:
    name:  aiml_vom_base
    image: ubuntu-base                                  # WORIN (Schlüsselmaterial)
    push:  [{ from: aiml_bauen, to: "oci:deploy/oci/aiml-builder" }]
    steps:
      - stage:
          name: aiml_bauen
          requires: [git, "gcc>=13", python3]           # was die Umgebung mitbringen muss
          runs_on: x86_64                               # WO (Etikett, optional)
          resources: { cpu: 8, mem: "12G" }             # WIEVIEL Maschine (§110.34)
          shares: [{ name: ablage, to: /mnt/out, mode: rw }]   # WOMIT arbeiten (§110.35)
          run: "…"
```

- **F110-81: Fünf Fragen, fünf Wörter.**  `image:` = worin, `runs_on:` = wo, `requires:` =
  was mitgebracht werden muss, `resources:` = wieviel Maschine, `shares:` = womit gearbeitet
  wird.  Sie sind verschieden, und keines vertritt ein anderes: die
  Umgebung ist Schlüsselmaterial (aiml F62-67), das Etikett nie (F62-49), die Vorbedingung
  ist eine Prüfung und kein Merkmal (F62-127).  Wer sie vermischt, bekommt einen Cache, der
  Ergebnisse aus der falschen Welt ausliefert — still und mit voller Überzeugung.
- **F110-82: Ein Abbild altert mit der Laufzeit.**  Ändert sich `libaiml.so`, muss das
  Abbild neu: `deploy/collect_runtime.sh` → `tools/make_agent_image.sh`.  Sonst startet der
  Container und stirbt mit `undefined symbol` (F110-80).  Das gehört in jeden Bau, der die
  Laufzeit anfasst — nicht in die Erinnerung des Betreibers.
- **F110-83: Ein Agent, der älter ist als der Server, meldet sich im Takt vergeblich an.**
  Nach jeder Änderung an `AgentRegister` (hier: das Feld `image`) kann ein alter Agent sich
  nicht mehr anmelden; der Server sagt das („Agent zu alt"), aber der alte Agent versucht es
  weiter.  Der auf diesem Rechner installierte Knoten-Agent (`/opt/cosmos/agent`, root)
  gehört neu ausgerollt — bis dahin ist jede 30 s eine Zeile im Protokoll die Folge.

## §110.35 Freigaben: der Wirt ordnet zu, die Pipeline nennt (22.10.2026)

Dritter Teil der Frage des Nutzers (*„kerne, ram, netzlaufwerk"*).  Kerne und RAM stehen in
§110.34; hier das Netzlaufwerk.

Die Pipeline schreibt `shares: [{ name: quellen, to: /mnt/quellen, mode: ro }]` (aiml `spec/62`
§18.1b).  Sie nennt einen **Namen**; den Pfad kennt nur der Wirt:

```sh
COSMOS_RT_SHARES="quellen=/srv/nfs/quellen,artefakte=/srv/ablage,ccache=/var/cache/ccache"
```

- **F110-101: Ein Name, kein Pfad — aus demselben Grund wie bei `image:` (F110-72).**  Eine
  eingereichte Pipeline ist Nutzereingabe.  Dürfte sie den Pfad schreiben, wäre
  `shares: [{ name: "/", to: /wirt, mode: rw }]` eine gültige Pipeline, und der Container hätte
  den Wirt.  Die Zuordnung gehört darum dorthin, wo auch die Abbilder zugeordnet werden: in die
  Umgebung des Wirts, die nur der Betreiber setzt.
- **F110-102: Ein unbekannter Name ist ein Fehler VOR dem Start, kein leerer Ordner.**  Ein
  Container, der mit einem leeren `/mnt/quellen` startet, läuft minutenlang und scheitert dann
  mit „Datei nicht gefunden" — und niemand sieht den Grund.  Die Einreichung lehnt deshalb ab und
  nennt die Namen, die der Wirt kennt.
- **F110-103: `ro` ist die Vorgabe, `rw` muss dastehen** (aiml F62-137).  Der Wirt darf eine
  Freigabe zusätzlich als `:ro` festnageln (`name=/pfad:ro`); dann bleibt sie lesend, auch wenn
  die Pipeline `rw` sagt.  Ein Betreiber, der eine Ablage nur zum Lesen anbietet, soll sich auf
  seine Zusage verlassen können, ohne jede Pipeline zu prüfen.
- **F110-104: Die Freigabe wird in den Container EINGEHÄNGT, nicht in die Schicht gelegt.**  Was
  ein Schritt nach `/mnt/out` schreibt, gehört dem Wirt und darf nicht im Abbild landen; ein
  `rbind` ist kein Teil des overlayfs-`upper` und erscheint im Schnitt darum auch nicht.  Genau
  das ist der Unterschied zwischen „Ablage" und „Ergebnis".

- **F110-105: Die Freigaben reisen mit dem LAUF, nicht mit der Stufe.**  Einhängen kann der Wirt
  nur **beim Start** des Containers; eine Freigabe, die erst die dritte Stufe nennt, bliebe sonst
  draußen.  `first_pending_want` vereinigt darum die Freigaben aller noch offenen Stufen
  desselben Abbilds (`run_shares`).  Fertige Stufen zählen nicht mehr mit: ihre Freigabe
  einzuhängen wäre Zugriff ohne Anlass.  Gleiches Ziel zweimal heißt: der erste bleibt — zwei
  Einhängungen auf denselben Punkt verdecken einander, und welche gewinnt, hinge an der
  Reihenfolge.
- **F110-106: Das Ziel muss es im Abbild geben.**  Ein Bind auf einen Punkt, den die Wurzel nicht
  hat, scheitert mit „No such file or directory" — und zwar beim START des Containers: er kam gar
  nicht hoch, der Platz wurde frei, der nächste startete, und das im Fünf-Sekunden-Takt.  Der
  Launcher legt den Punkt jetzt vorher an.  (Die Endlosschleife selbst bleibt offen: ein
  Container, der beim Start stirbt, wird ohne Zähler neu gestartet.  Das gehört gezählt und nach
  drei Fehlversuchen dem Lauf gemeldet.)
- **F110-107: Die Schicht einer Stufe liegt ÜBER der Freigabe — bis man sie durchreicht.**  Der
  overlayfs einer Stufe (F110-93) legt sich über die ganze Wurzel, also auch über `/mnt/ablage`.
  Gemessen am 22.10.2026: die erste Stufe schrieb `/mnt/ablage/spur.txt`, die zweite las es
  wieder — und trotzdem stand auf dem Wirt **nichts**; die Datei lag in `layers/0/upper/mnt/ablage`.
  Das Schicht-Skript bindet die Ziele der Freigaben darum in die zusammengesetzte Wurzel zurück,
  wie es `proc`, `work` und `src` schon tat.  Der Agent erfährt sie beim Start (`--shares`): er
  hängt sie nicht selbst ein, aber nur er weiß, wo seine Schicht liegt.

### Abnahme der Freigaben (22.10.2026, `run-1792694051008`)

`pipelines/freigabe_probe.yaml`, zwei Stufen, Wirt mit
`COSMOS_RT_SHARES="ablage=<…>/logs/night/ablage"`:

| Was | Ergebnis |
|---|---|
| Stufe 1 schreibt `/mnt/ablage/spur.txt` | liegt auf dem **Wirt**: `logs/night/ablage/spur.txt` = „aus dem Lauf" |
| Stufe 2 liest dieselbe Datei | gelesen, obwohl ein anderer overlay darüber liegt |
| Stufe 2 schreibt `/etc/nur-in-der-schicht` | liegt in `layers/1/upper/etc/` — **nicht** auf dem Wirt |
| Schicht der Stufe 1 | **leer**: was auf die Freigabe ging, gehört nicht ins Abbild (F110-104) |

Zwei Anläufe waren nötig, und beide stehen oben: das Bind-Ziel gab es im Abbild nicht
(F110-106), und der overlay der Stufe verdeckte die Freigabe (F110-107).
- **F110-108: Nach `pivot_root` ist `/tmp` nicht mehr das `/tmp` des Containers.**  Der Container
  hängt ein `tmpfs` mit `mode=1777` auf `/tmp` — das liegt aber in der ALTEN Wurzel.  Die Schicht
  einer Stufe (F110-93) wechselt die Wurzel, und `/tmp` ist dann das Verzeichnis **aus dem
  Abbild**, mit dessen Rechten (`drwxr-xr-x root`).  `apt` lädt als Nutzer `_apt` herunter und
  kann dort nicht schreiben — und meldet das nicht als Rechtefehler, sondern als
  **„The repository … is not signed"**: `apt-key` scheitert am temporären File, die Signatur wird
  nie geprüft, `apt-get update` endet mit 100.  Gemessen am 22.10.2026 an
  `aiml-vom-Base-Image-3`, Stufe `apt_installieren`; der Fehler zeigte auf GPG und lag am
  Dateisystem.  Das Schicht-Skript legt jetzt ein eigenes `tmpfs` (mode 1777) auf `$MG/tmp`,
  mit `rbind /tmp` und `chmod 1777` als Rückfallwegen.  Nachgewiesen mit
  `pipelines/tmp_probe.yaml`: `/tmp` ist `drwxrwxrwt`, `_apt` kann schreiben, `apt-get update`
  holt 35,2 MB und endet mit 0.
- **F110-109: Mit Schichten sieht der Agent die BASIS, nicht den Stand der Stufe.**  `requires:`
  (aiml spec/62 §18.2) prüfte der Agent in seinem eigenen Blick — das war richtig, solange jede
  Stufe in dieselbe Wurzel schrieb.  Seit F110-93 liegt, was eine frühere Stufe installiert hat,
  in DEREN Schicht; der Agent sieht davon nichts.  Folge, gemessen am 22.10.2026 an
  `aiml-vom-Base-Image-5`: `apt_installieren` lief durch, und die nächste Stufe mit
  `requires: [git, "gcc>=13", python3, llvm-config-18]` wurde mit „Umgebung unvollständig"
  abgewiesen — gegen ein Abbild, in dem alles längst lag.
  Die Prüfung läuft jetzt **in der Wurzel der Stufe**: das Schicht-Skript ruft nach `pivot_root`
  denselben Agenten im Prüfmodus auf (`/opt/cosmos/agent --require-check '<spec>'`).  Damit
  bleibt es EINE Implementierung (`sys.require_tools`, aiml spec/23 §5.6) — eine Shell-Fassung
  daneben wäre die Kopie, die auseinanderläuft.  Ausserhalb des Containers (nackter Knoten)
  prüft weiterhin der Agent selbst, denn dort ist sein Blick der richtige.
- **F110-110: Der Arbeitsbereich gehört dem WIRT, nicht dem Container.**  Er lag unter
  `<bündel>/work` — also im Container.  Wird der abgeräumt (schon 60 s ohne Arbeit), startet der
  nächste mit einem neuen Bündel und findet die Schichten der früheren Stufen nicht; „ab Stufe X
  nochmal" liefe gegen das nackte Abbild.  Das widersprach F110-94, das genau dies versprach.
  Jetzt: `<wirt-arbeitsbereich>/lauf/<lauf>/…`, in jeden Container als `/work` gehängt.
- **F110-111: `/ws` war der Arbeitsplatz des CONTAINERS, nicht des Laufs.**  Der Bind des
  Lauf-Arbeitsplatzes nach `/ws` stand nur im bwrap-Pfad (Knoten ohne Container).  Im Container
  schrieb eine Stufe nach `/ws` in die **Wurzel des Containers** — und `reap` löscht die Wurzel.
  Gemessen am 22.10.2026: nach „ab `aiml_bauen` nochmal" endete der Schritt nach einer Sekunde
  mit `cd: can't cd to /ws/aiml`; der Klon aus `aiml_klonen` war mit dem Container gestorben,
  während die apt-Schicht noch lag.  Das Schicht-Skript hängt `/ws` jetzt aus `/work/<lauf>/ws`
  ein — derselbe Ort, der auch die Schichten trägt, und damit genauso haltbar.
- **F110-112: Was im Abbild landen soll, muss in die WURZEL.**  `/ws` ist eine Einhängung
  (F110-111) und gehört dem Lauf, nicht dem Dateisystem — der Schnitt sieht sie zu Recht nicht.
  Eine Pipeline, die etwas baut und weitergeben will, legt das Ergebnis darum in die Wurzel
  (`aiml_vom_base` → Stufe `aiml_ablegen`: Compiler und Laufzeitbibliothek nach `/opt/aiml`,
  dazu der Pfad, den fremde Projekte fest eintragen, als Symlink).  Der `push:` schneidet dann
  nach DIESER Stufe, nicht nach dem Bau.  Seit aiml spec/69 legt `aiml_ablegen` eine **venv** an
  (`aiml venv /opt/aiml`: `bin/aiml`, `lib/libaiml.so`, `lib/aiml/`, `env`); die Schicht braucht
  damit weder `ld.so.conf.d` noch den Symlink — den Wirtspfad verdrahtet die Pipeline, die ihn
  verlangt (`9rooms_vom_stapel`: `compiler_verdrahten`).
- **F110-113: Ein Layout auf Platte IST ein bekanntes Abbild.**  Die Einreichung prüfte
  `image:` nur gegen `COSMOS_RT_IMAGES` und gegen die `push:`-Ziele DERSELBEN Pipeline.  Eine
  zweite Pipeline, die auf dem Ergebnis einer ersten aufbaut (`image: "oci:deploy/oci/…"`),
  liess sich damit nicht einmal speichern — obwohl die Laufzeit genau diesen Fall kann
  (`rt_launcher.bundle_for` legt ein Layout als Wurzel aus).  Jetzt gilt ein `oci:`-Pfad mit
  `index.json` als bekannt; fehlt er noch, sagt die Meldung, dass erst die andere Pipeline laufen
  muss — statt „der Wirt kennt es nicht", was an der falschen Stelle suchen lässt.
- **F110-114: Ein zweiter Lauf kann auf den SCHICHTEN eines ersten stehen — ohne Abbild.**
  `base: "run:<lauf>"` am Kopf einer Pipeline (aiml `spec/62` §18.4) legt den Schichtstapel
  jenes Laufs als `lower` unter diesen, rechts von den eigenen Schichten: gelesen wird aus
  ihnen, geschrieben immer in die eigene.  Das spart den Umweg über ein OCI-Abbild vollständig
  — kein `tar`+`gzip` über 2,7 GB, kein Auslegen auf der anderen Seite; die Schichten liegen
  schon fertig im Arbeitsbereich des Wirts (F110-110).  Der Preis ist Ehrlichkeit über die
  Voraussetzungen: **derselbe Wirt** und **dasselbe Grundabbild**.  Ein Abbild ist der Weg nach
  draußen, der Stapel der Weg nebenan.  Gemessen am 22.10.2026 mit `pipelines/stapel_test.yaml`:
  `gcc 13.3.0` und `llvm-config-18 18.1.3` aus der apt-Schicht eines fremden Laufs, die eigene
  Schicht daneben unberührt.
- **F110-115: Ein editierbarer Einbau (`pip install -e`) überlebt den Stapel nicht.**  Er legt
  nur einen Verweis auf `/ws/<paket>` in die venv — und `/ws` gehört dem LAUF, nicht dem Stapel
  (F110-111).  Wer den Stapel erbt, bekommt eine venv mit einem Verweis ins Leere
  (`ModuleNotFoundError: No module named 'exodus'`, gemessen 22.10.2026).  Was weitergegeben
  werden soll, wird **fest** eingebaut (`pip install .`), dann liegt es in der Schicht.
- **F110-116: `base: "job:<kennung>"` zeigt auf den jüngsten FERTIGEN Lauf.**  Ein fester
  `run:`-Verweis veraltet mit dem nächsten Bau — wer `aiml` neu baut, müsste jede abhängige
  Pipeline nachziehen.  Der Controller löst `job:` darum bei der **Anlage** des Laufs auf
  (`last_good_of`: jüngstes `started_ms` unter den Läufen dieses Jobs mit Zustand `done`) und
  schreibt das Ergebnis als `run:<lauf>` fest.  Gibt es keinen fertigen Lauf, startet der Lauf
  **ohne** Unterbau und das Protokoll sagt es — statt still auf dem nackten Abbild zu bauen und
  erst in der fünften Minute an einem fehlenden Werkzeug zu scheitern.  Gemessen 22.10.2026:
  `'job:aiml-vom-Base-Image' → run:aiml-vom-Base-Image-5`, danach `gcc 13.3.0` und `/opt/venv`
  im Schritt.
- **F110-117: Zwei Wege zum Lauf — und nur einer kannte den Unterbau.**  `base:` wurde beim
  Einreichen (`run_pipeline`) gesetzt, beim Starten **aus einem Job** (`run_job`, der Knopf in
  der Oberfläche) nicht.  Dieselbe Pipeline lief damit eingereicht durch und gestartet sofort auf
  Grund: `/bin/sh: 1: git: not found` in der ersten Stufe, weil die Schichten fehlten (gemeldet
  22.10.2026 an `9rooms_vom_stapel-1`).  Lehre, die älter ist als dieser Fehler: wo zwei Wege
  denselben Zustand anlegen, muss jede Eigenschaft des Zustands auf BEIDEN stehen — sonst ist der
  seltener benutzte Weg der kaputte, und gerade der ist der, den der Nutzer nimmt.

## §110.36 Container auf einem FREMDEN Wirt (25.10.2026)

Frage des Nutzers: *„die agenten die wir spawnen mit eigenem CAS etc sind ja immer auch auf dem
host, ist das auch auf einem zuvor verbundenen agenten möglich?"*

Heute nein: `RtLauncher` lebt **im** Controller-Prozess und ruft lokal `./cosmos-rt`.  Ein über
SSH eingerichteter Knoten (doc/spec/94) trägt `agent` + Ladekette und sperrt seine Schritte mit
**bwrap** ein — er startet keine Container, hat keinen CAS und keine Schichten.  Das Zielbild
steht seit M3 in der Tabelle oben („beide melden sich bei **einem** cosmos"); hier sind die
Regeln, nach denen es gebaut wird.

- **F110-118: Der Starter gehört zum WIRT, das Token zum CONTROLLER.**  Container startet der
  Agent, der auf dem Knoten läuft — nur er kennt dessen Platte, seine cgroup und seinen
  Arbeitsbereich.  Das **Agent-Token** des neuen Containers prägt weiterhin der Controller und
  schickt es im Auftrag mit: wer Zugänge vergibt, bleibt eine Stelle.  Ein Knoten, der sich
  selbst Token ausstellen dürfte, wäre ein zweiter Ausweis-Aussteller im selben Cluster
  (spec/65 F65-6, Selbstbeglaubigung).
- **F110-119: Eine Fähigkeit, kein neues Feld.**  `AgentInfo.caps` trägt schon „steps"; ein
  Knoten, der Container starten kann, meldet zusätzlich **`rt`**.  Die Kapazitätsschleife fragt
  danach — und der Controller-eigene Starter ist nur der Sonderfall „Wirt = hier".  Ein Agent
  ohne `rt` wird nie gefragt; das ist der Unterschied zwischen „kann nicht" und „antwortet nicht".
- **F110-120: Ein Wirt kann nur Abbilder starten, die er HAT.**  Die Einreichung prüft `image:`
  heute gegen den Controller (F110-113).  Sobald mehrere Wirte in Frage kommen, ist die Frage
  nicht mehr „gibt es das Abbild", sondern „gibt es einen Wirt, der es hat" — und die Antwort
  gehört **vor** den Start, nicht in die fünfte Minute.  Ohne Registry (die fehlt, §110.30) ist
  das Abbild bis dahin über SFTP auszubringen, wie die Laufzeit in doc/spec/94 Schritt 5.
- **F110-121: Ein fremder Cache-Treffer ist eine Behauptung über Arbeit, die niemand gesehen
  hat.**  CAS und ActionCache bleiben **je Wirt**.  Ein Treffer von Wirt B darf auf Wirt A nicht
  gelten, solange niemand ihn signiert: der Schlüssel deckt Befehl, Umgebung und Eingaben ab
  (doc/spec/92 §92.2) — aber nicht, ob der fremde Wirt ehrlich gerechnet hat.  Wer das später
  will, braucht eine Signatur über (Schlüssel → Ergebnisbaum) und eine Liste, wessen Signatur
  zählt.  Bis dahin gilt: **gleicher Wirt, gleicher Cache**; über Wirte hinweg wird neu gerechnet.
  Das ist langsamer und ehrlich, und die schnelle Variante wäre ein Vertrauensbeweis, den wir
  nicht haben.
- **F110-122: `base:` ist wirtsgebunden und sagt das.**  Ein Schichtstapel (F110-114) liegt auf
  genau einer Platte.  Kommt ein Lauf auf einem anderen Wirt zustande, ist `run:<lauf>` dort
  nicht auflösbar — dann darf die Zuteilung diesen Wirt nicht wählen, statt ohne Unterbau zu
  starten.  Der Weg über Wirte hinweg bleibt das **Abbild** (F62-142).

### Reihenfolge des Baus

1. Fähigkeit `rt` melden und sichtbar machen (Agentenliste, Dashboard).
2. Spawn-Auftrag im Protokoll: Controller → Agent, mit Token, Abbild, Grenzen, Freigaben.
3. `RtLauncher` im Agenten-Prozess, eigener Arbeitsbereich, eigenes `logs/rt_runs`.
4. Zuteilung: wartet Arbeit, deren Abbild ein `rt`-Wirt hat, geht der Auftrag dorthin;
   sonst bleibt es beim lokalen Starter.
5. Abräumen und Buchführung über Wirte hinweg (F110-43 gilt dann je Wirt).

- **F110-123: Der Agent ZIEHT auch den Spawn-Auftrag.**  Die naheliegende Form wäre ein Ruf vom
  Controller zum Agenten — aber der Agent hat keinen RPC-Empfang; sein ganzer Rhythmus ist
  Fragen (`claim_step`, F103-2).  Der Container-Auftrag kommt deshalb auf demselben Weg:
  `claim_spawn` neben `claim_step`.  Das spart eine zweite Richtung im Protokoll (und damit eine
  zweite Stelle, an der Authentifizierung, Zeitgrenzen und Wiederholung geregelt werden müssten),
  und die Entscheidung bleibt trotzdem beim Controller — er antwortet nur dem, den er gewählt hat.

### §110.36a Die Namen (25.10.2026)

Vorgabe des Nutzers: *„man muss es immer in der Pipeline festlegen können, welcher Agent genutzt
wird — ob normal oder CAS/Basis-Abbild."*  Also **kein Automatismus**: die vorige Fassung gab
einen Container-Auftrag heraus, sobald der eigene Wirt voll war.  Das ist eine Entscheidung, die
die Pipeline trifft, nicht der Controller.

Damit darüber geredet werden kann, ohne jedes Mal zu erklären, was gemeint ist:

| Wort | Was es bezeichnet | Woran man es erkennt |
|---|---|---|
| **Knoten-Agent** | ein Agent, der auf einer Maschine installiert ist und dort bleibt (doc/spec/94).  Er führt Schritte **auf dem Dateisystem des Knotens** aus, eingesperrt mit bwrap. | `caps: steps`, `image` leer |
| **Container-Agent** | ein Agent **im** Container, aus einem Basis-Abbild gestartet, mit eigener Wurzel, eigenen Schichten und eigenem Arbeitsbereich.  Er stirbt mit seinem Lauf. | `caps: steps`, `image` gesetzt |
| **Wirt** | die Maschine, auf der ein Container entsteht.  Jeder Wirt hat einen Knoten-Agenten; ob er Container starten darf, sagt seine Fähigkeit. | `caps: spawn` |

Und in der Pipeline, drei Wörter für drei Fragen (F110-81 bekommt ein viertes):

| Schlüssel | Frage | Werte |
|---|---|---|
| `agent:` | **WER** nimmt den Schritt | Etikett (`x86_64`) oder Agenten-Kennung |
| `steplayer:` | **OB** je Stufe eine Schicht entsteht | `own` \| `none` |
| `image:` | **WORIN** — welche Wurzel | Abbild-Name oder `oci:<pfad>` |
| `base:` | **WORAUF** — welcher Schichtstapel | `run:<lauf>` \| `job:<kennung>` |

- **F110-127: `agent:` statt `node:`.**  Der Schlüssel wählt den **Ausführenden**, und das ist
  ein Agent — ein Container-Agent ist kein Knoten, er wohnt auf einem.  `node:` hätte für die
  Hälfte der Fälle gelogen.  Alte Namen (`runs_on:`, `label:`, `runs_in:`) werden **abgewiesen**
  und nennen den neuen; zwei Schreibweisen nebeneinander sind die Redundanz, die später niemand
  mehr auflöst (doc/spec/106 §106.3a).

- **F110-124: `steplayer:` ist die Entscheidung der PIPELINE, nicht die des Controllers.**  Kein
  Ausweichen bei Überlast, kein stilles Umschalten.  Wer `none` schreibt, bekommt den
  Knoten-Agenten — auch wenn der gerade beschäftigt ist; wer `own` schreibt, wartet auf einen
  Container-Agenten, auch wenn ein Knoten frei wäre.  Ein Zuteiler, der die Art der Ausführung
  selbst wählt, macht aus zwei verschiedenen Umgebungen eine Lotterie — und der Cache (`doc/spec/92`)
  hinge an einem Zufall.
- **F110-125: Die Vorgabe ergibt sich aus `image:` und wird nicht geraten.**  Steht ein `image:`
  da, ist `steplayer: own` gemeint; steht keines da, `none`.  Beides lässt sich hinschreiben, und
  widersprüchliche Angaben (`steplayer: none` **mit** `image:`) weist die Einreichung ab — statt
  eines davon gewinnen zu lassen.
- **F110-126: Die Fähigkeit heißt `spawn`, nicht `rt`.**  `rt` ist der Name eines Binaries, keine
  Eigenschaft: was den Wirt auszeichnet, ist nicht welches Programm er hat, sondern was er kann.
  (Umbenannt am selben Tag, an dem es entstand — ein Name, der eine Woche steht, steht ewig.)
