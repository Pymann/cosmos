# 112 — cosmos auf dem kontor-Server: ein Dienst, ein Agent, ein Blob für alle

**Auftrag (User, 2026-11-25):** *„ich habe jetzt das zielbild, dass wir cosmos auf dem selben
server wie kontor laufen lassen und pipelines laufen lassen, die z.b. die pipeline schritte
hochladen, z.b. für aiml, dann brauchen die anderen runner nur noch diesen blob downloaden"* —
*„nein nur cosmos soll auf dem server laufen und einen agenten verbinden"*.

Der Server ist der, auf dem schon kontor (`https://151.80.143.81:8443`) und 9rooms laufen: 2–4
Kerne, kein Platz für einen zweiten Stapel.  Von hier aus ist er nicht erreichbar; darum liegt
alles, was der Betreiber dort ausführt, in diesem Repository (`deploy/server/`), samt einer
Anleitung in einem Stück (`deploy/server/ANLEITUNG.md`), und wird in GitHub Actions auf einem
frischen Ubuntu 24.04 einmal ganz durchgespielt (§112.7).

---

## 112.0 Befunde, bevor gebaut wurde

**F112-1: Es gibt kein öffentliches aiml-Release.**  `v1.0.2.4` ist ein *Entwurf*; ohne Zugang
sieht ihn niemand.  Jeder Runner holt aiml heute über `gh run download` aus dem neuesten grünen
CI-Lauf von `Pymann/aiml` — 129 MB je Lauf und Repository, mit einem GitHub-Token.  Genau das
ersetzt dieses Kapitel: **einmal** holen (cosmos), **einmal** ablegen (kontor), überall von dort
lesen.

**F112-2: Ein Knoten-Agent sieht vom Wirt nur `/usr` und `/etc`.**  Der Sandkasten
(`AgentStep.sandbox_argv`) bindet `/usr` und `/etc` lesend, das Schrittverzeichnis und `/ws`
schreibend, sonst nichts; die Umgebung ist eine Erlaubnisliste (`PATH`, `HOME`, `TMPDIR`, `LANG`,
`TZ`, F103-14).  Freigaben (`shares:`, §110.35) gibt es nur im Container.  Folge:

- Werkzeuge, die Schritte aufrufen, liegen unter **`/usr/local/libexec/cosmos/`** (in `/usr`).
- Zugänge, die Schritte brauchen, liegen unter **`/etc/cosmos-agent/`**, lesbar für die Gruppe
  `cosmos-agent` — der Sandkasten bildet den Dienstnutzer ab, also liest der Schritt sie.
- Was Schritte **nicht** sehen dürfen (Agent-Token, Datenbank von cosmosd, Admin-Zugang), liegt
  **außerhalb** von `/usr` und `/etc` oder ist für `cosmos-agent` nicht lesbar.

**F112-3: Die Browser-Oberfläche lässt sich mit `aiml build` nicht bauen.**  Der WASM-Client
(`exodus-client.json`) braucht emscripten und den alten Bauweg.  Bedient wird der Server darum
über die REST-Schnittstelle (`cosmos-api`, §111.8) und ein kleines Werkzeug (`cosmosctl`), nicht
über den Browser.  Das ist für einen Bau-Server auch die ehrlichere Oberfläche.

**F112-4: `cosmos-api` horchte fest auf `0.0.0.0`**, ohne TLS.  Auf einem Server mit öffentlicher
Adresse wäre das ein offenes Login über Klartext.  → neue Variable **`COSMOS_API_HOST`**
(Vorgabe `0.0.0.0`, damit bestehende Aufrufe gleich bleiben); der Server setzt `127.0.0.1`.

**F112-5: Jobs haben einen Zeitplan** (`interval_s`, doc/spec/106 G2), und der Katalog setzt
ihn (`job: { …, interval_s: n }`, §111.4).  Es braucht keinen systemd-Timer und keinen Cron.

---

## 112.1 Zielbild

```
                       ┌──────────────── kontor-Server (2–4 Kerne) ─────────────────┐
GitHub (Pymann/aiml)   │                                                             │
  grüner CI-Lauf ──────┼─▶ cosmos-agent ──(Schritte, bwrap)── aiml-mirror ──PUT──▶ kontor :8443
  oder Release         │      ▲ ws://127.0.0.1:8770                            /generic/aiml/…
                       │   cosmosd ◀── cosmos-api 127.0.0.1:8771 ◀── cosmosctl    │
                       └──────────────────────────────────────────────────────┼─────┘
                                                                              │ GET (anonym)
                     GitHub-Actions-Runner von cosmos, kontor, ufo ◀──────────┘
                       .github/ci/setup-aiml.sh  (AIML_KONTOR_URL)
```

- **Genau drei Dienste**: `cosmosd`, `cosmos-api`, `cosmos-agent` — kein `static`, kein Client,
  keine Container-Laufzeit (`cosmos-rt`), kein zweiter Agent.
- **Nichts horcht nach außen.**  cosmosd auf `ws://127.0.0.1:8770`, das Gateway auf
  `127.0.0.1:8771`.  Von außen erreichbar bleibt nur kontor, wie bisher.  Wer cosmos von außen
  bedienen will, nimmt einen SSH-Tunnel (Anleitung, Schritt 9).
- **Ports** neben 9rooms (8765/8766/8080) und kontor (8443): 8770 und 8771, beide in
  `/etc/cosmos/cosmos.env` änderbar.

## 112.2 Ablage auf dem Server

| Ort | Eigentümer, Modus | Inhalt | Sieht ein Schritt es? |
|---|---|---|---|
| `/opt/cosmos/bin/` | root, 0755 | `cosmosd`, `cosmos-api`, `agent`, `bwrap` (eigene Kopie) | nein |
| `/opt/cosmos/lib/` | root, 0755 | `libaiml.so` + Ladekette (aus der aiml-venv) | nein |
| `/etc/cosmos/pipelines/` | root, 0755 | die Pipelines des Katalogs | ja (harmlos) |
| `/etc/cosmos/cosmos.env` | root, 0644 | Ports, Adressen — **kein** Geheimnis | ja (harmlos) |
| `/etc/cosmos/cosmos.yaml` | root, 0644 | Erklärung (Katalog, §111.1) | ja (harmlos) |
| `/etc/cosmos/admin.password`, `api.token` | root, 0600 | Admin-Konto, API-Token für `cosmosctl` | **nein** (0600 root) |
| `/etc/cosmos-agent/kontor.env` | root:cosmos-agent, 0640 | `KONTOR_URL`, `KONTOR_CA` | ja — gewollt |
| `/etc/cosmos-agent/kontor.token` | root:cosmos-agent, 0640 | kontor-Token (Rolle `writer`) | ja — gewollt |
| `/etc/cosmos-agent/github.token` | root:cosmos-agent, 0640 | GitHub-Token, nur lesend | ja — gewollt |
| `/var/lib/cosmos/` | cosmos, 0750 | KV von cosmosd, Lauf-Protokolle | nein |
| `/var/lib/cosmos-agent/` | cosmos-agent, 0750 | `agent.token` (0600), `steps/` | nur das eigene Schrittverzeichnis |
| `/usr/local/libexec/cosmos/` | root, 0755 | `kontor-blob`, `aiml-mirror` | ja — gewollt |
| `/usr/local/sbin/cosmosctl` | root, 0755 | Bedienung über REST | ja (ohne Token wertlos) |

- **F112-6: Zwei Dienstnutzer.**  `cosmos` (cosmosd, Gateway) und `cosmos-agent` (Agent).
  Schritte laufen als `cosmos-agent` und können darum weder den KV von cosmosd noch das
  Admin-Token lesen.  Ein Nutzer für beides hätte jedem Schritt die Freigabe 1 geschenkt.
- **F112-7: Was ein Schritt liest, ist eine Zusage an alle Pipelines dieses Agenten.**  Das
  kontor-Token unter `/etc/cosmos-agent/` sieht **jeder** Schritt.  Darum: ein eigenes Token nur
  mit der Rolle `writer` (nicht `admin`), und nur eigene Pipelines im Katalog.  Das steht in der
  Anleitung, nicht nur hier.

## 112.3 Die Dienste (systemd)

`deploy/server/systemd/` — feste Pfade, keine Vorlagen; was sich ändert, steht in
`/etc/cosmos/cosmos.env` (`EnvironmentFile=`).

| Einheit | Nutzer | Startet | Schutz |
|---|---|---|---|
| `cosmosd.service` | cosmos | `cosmosd`, `COSMOS_CASC=/etc/cosmos/cosmos.yaml` | `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, schreibt nur `/var/lib/cosmos` |
| `cosmos-api.service` | cosmos | `cosmos-api`, `COSMOS_API_HOST=127.0.0.1` | wie oben |
| `cosmos-agent.service` | cosmos-agent | `agent --exec-url … --agent-token-file … --bwrap-path /opt/cosmos/bin/bwrap` | wie oben, schreibt nur `/var/lib/cosmos-agent`; **`Nice=10`, `CPUWeight=20`, `IOWeight=20`, `MemoryMax=2G`** |

- **F112-8: Der Agent weicht.**  `CPUWeight`/`IOWeight` 20 (Vorgabe 100) heißt: solange kontor
  oder 9rooms rechnen, bekommen sie den Vorrang; ist der Rechner leer, nimmt der Agent alles.  Eine
  harte Obergrenze (`CPUQuota`) hätte auch den leeren Rechner gebremst.  `MemoryMax=2G` begrenzt
  den Schaden eines entgleisten Schritts; wer mehr braucht, setzt es mit `systemctl edit`.
- **F112-9: Fail closed beim Start.**  Eine kaputte Erklärung hält cosmosd an (§111.1) — so
  soll es bleiben.  Der Agent startet erst, nachdem `agent --verify-isolation` mit genau dem
  `bwrap` gelaufen ist, das die Schritte einsperrt (doc/spec/94 Schritt 9, `ExecStartPre=`).
- Ein AppArmor-Profil (`deploy/server/apparmor/cosmos-server`) erlaubt **nur**
  `/opt/cosmos/bin/bwrap` und `/opt/cosmos/bin/agent` das Anlegen von User-Namespaces; das
  systemweite `/usr/bin/bwrap` bleibt unberechtigt (doc/spec/94 Schritt 6).  Kein `sysctl`.

## 112.4 Die Einrichtung (`deploy/server/install.sh`)

Läuft als root, **idempotent** (zweimal ausführen ändert nichts kaputt), **fail closed** (bricht
ein Schritt ab, wird kein Dienst gestartet).  Gebaut wird **nicht** als root: die Binaries baut
der Betreiber vorher als sein Nutzer mit `aiml build` (Anleitung, Schritt 3); das Skript nimmt
sie aus dem Checkout und die Bibliotheken aus der aiml-venv.

1. Pakete: `bubblewrap uidmap apparmor curl ca-certificates jq unzip git`.
2. Nutzer `cosmos`, `cosmos-agent` (System, ohne Shell).  Kein `subuid`-Bereich: ein Knoten-Schritt bildet mit bwrap genau eine Kennung ab.
3. Binaries und Ladekette nach `/opt/cosmos` (root-eigen; der Agent kann sein Programm nicht
   überschreiben).  `ldd` prüft vorher, dass nichts fehlt.
4. AppArmor-Profil laden.
5. Werkzeuge nach `/usr/local/libexec/cosmos/`, `cosmosctl` nach `/usr/local/sbin/`.
6. `/etc/cosmos/*` und `/etc/cosmos-agent/*` anlegen — **vorhandene Dateien bleiben stehen**
   (Ports, Tokens des Betreibers werden nie überschrieben).  Zugänge kommen aus Dateien
   (`--kontor-token-file`, `--github-token-file`), nie aus Argumenten (Prozessliste).
7. Dienste anhalten; beim ersten Lauf: Admin-Konto anlegen (`cosmosd --add-user`, Zufallspasswort
   nach `/etc/cosmos/admin.password`), Freigabe 1 setzen, Agent-Token prägen
   (`cosmosd --mint-token`) — Betriebshandlungen bei gestopptem Dienst (F108-3).
8. Einheiten ablegen, `daemon-reload`, cosmosd und Gateway starten, auf `health` warten.
9. Beim ersten Lauf: anmelden, ein API-Token anlegen (`POST /api/v1/tokens`) →
   `/etc/cosmos/api.token`.
10. Agent starten (mit dem Nachweis davor, F112-9) und warten, bis er in `/api/v1/cluster` steht.

`deploy/server/uninstall.sh` nimmt alles zurück; Daten (`/var/lib/cosmos*`) und Zugänge
(`/etc/cosmos*`) nur mit `--purge`.

## 112.5 Die Pipeline `aiml_nach_kontor`

Katalog-Job `cat-aiml_nach_kontor`, **stündlich** (`interval_s: 3600`), auf dem Knoten-Agenten
(kein `image:`, `steplayer: none`, F110-125).  Die Arbeit tut `aiml-mirror <stufe>`; die Pipeline
nennt nur die Stufen, damit sie lesbar bleibt und das Werkzeug für sich prüfbar ist.

| Stufe | Tut | Ergebnis in `/ws` |
|---|---|---|
| `quelle` | neuestes **nicht-Entwurfs**-Release mit Linux-Tarball, sonst neuester grüner CI-Lauf auf `master` (wie `setup-aiml.sh`); fragt kontor, ob es diese Fassung schon hat | `quelle.env`, ggf. `unveraendert` |
| `holen` | Tarball + `.sha256` laden (Release-Asset oder CI-Artefakt), `sha256sum -c` | `dl/` |
| `pruefen` | auspacken, `ldd` ohne „not found", Rauchtest `sys.exit 42` | — |
| `hochladen` | `PUT` Tarball, `.sha256`, **zuletzt** `latest.env` | — |
| `aufraeumen` | `dl/` weg | — |

Ablage in kontor (generisches Repository):

```
/generic/aiml/<fassung>/aiml-<fassung>-linux-x86_64.tar.gz
/generic/aiml/<fassung>/aiml-<fassung>-linux-x86_64.tar.gz.sha256   („<hex>  <name>", wie bei GitHub)
/generic/aiml/latest.env                                            (version=…, tarball=…, sha256=…, source=…)
```

`<fassung>` ist der Release-Tag (`v1.0.2.4`) oder `git-<sha7>` — derselbe Name, den
`tools/ci/package_release.sh` in aiml vergibt.

- **F112-10: Der Zeiger kommt zuletzt.**  `latest.env` wird erst geschrieben, wenn Tarball und
  Prüfsumme liegen.  Wer liest, findet nie einen Zeiger auf etwas, das noch fehlt.
- **F112-11: Unverändert heißt: nichts tun.**  Hat kontor die Fassung schon und zeigt
  `latest.env` darauf, enden alle folgenden Stufen sofort mit 0 — ein stündlicher Lauf kostet
  dann zwei kleine Anfragen, keinen Download.
- **F112-12: Geprüft wird vor dem Ablegen.**  Ein Tarball, dessen Prüfsumme nicht stimmt oder
  der auf diesem Rechner nicht startet, kommt nicht nach kontor.
- **F112-13: Gebaut wird hier noch nicht.**  Den Compiler aus den Quellen zu bauen braucht
  exodus, 171 festgelegte apt-Pakete und LLVM — auf 2–4 Kernen eine Stunde, und `apt-get
  download` findet im Sandkasten keine Paketlisten.  Die Pipeline **spiegelt** darum den
  geprüften CI-Bau von aiml; ein Quellbau ist der nächste Schritt (§112.9) und eine eigene
  Entscheidung.

## 112.6 Die Runner: `setup-aiml.sh` liest kontor

Neue Quelle **vor** den beiden bisherigen, nur wenn `AIML_KONTOR_URL` gesetzt ist:

1. **kontor**: mit `AIML_RELEASE` die Fassung `aiml/<tag>/…`, sonst `aiml/latest.env`; Tarball
   und `.sha256` laden, prüfen.  Braucht nur `curl` (kein `gh`, kein GitHub-Token).
   `AIML_KONTOR_CA` (PEM-**Inhalt**, für ein selbstsigniertes Zertifikat) und
   `AIML_KONTOR_TOKEN` (nur nötig, wenn kontor anonymes Lesen abschaltet) sind optional.
2. Release, 3. CI-Lauf — unverändert.

- **F112-14: Fällt kontor aus, fällt der Runner zurück** (`::warning::`), statt rot zu werden:
  kontor ist eine Abkürzung, keine neue Abhängigkeit jedes Builds.  Mit `AIML_KONTOR_STRICT=1`
  scheitert er stattdessen (für die Abnahme, §112.7).
- **F112-15: `latest.env` wird gelesen, nicht ausgeführt.**  Die Datei kommt aus dem Netz; das
  Skript nimmt nur `version=` und `tarball=`, prüft sie gegen `^[A-Za-z0-9._-]+$` und
  `source`t nie.
- In GitHub: Repository-Variable `AIML_KONTOR_URL` (z. B. `https://151.80.143.81:8443`), bei
  selbstsigniertem Zertifikat `AIML_KONTOR_CA`.  Ohne Variable bleibt alles wie bisher.

## 112.7 Abnahme (`deploy/server/test_install.sh`, CI-Job `server-setup`)

Ein frischer GitHub-Runner (Ubuntu 24.04, mit systemd und AppArmor) spielt den Server:

1. baut `cosmosd`, `cosmos-api`, `agent`; startet einen **kontor-Ersatz**
   (`test/kontor_stub.py`, das generische Repository mit Bearer-Prüfung — das echte kontor ist
   ein privates Repository und für diesen Job nicht ladbar);
2. `install.sh` mit Zugängen aus Dateien;
3. prüft: drei Dienste aktiv; cosmosd und Gateway horchen **nur** auf 127.0.0.1; der Agent steht
   in `/api/v1/cluster`; der Job `cat-aiml_nach_kontor` steht im Katalog mit `interval_s 3600`;
4. startet den Job, wartet auf `done`; kontor hat Tarball, `.sha256` und `latest.env`, die
   Prüfsumme stimmt;
5. ein zweiter Lauf lädt **nichts** (F112-11: kontor sieht keinen zweiten `PUT` des Tarballs);
6. `setup-aiml.sh` mit `AIML_KONTOR_URL` (und `AIML_KONTOR_STRICT=1`) baut eine venv **aus
   kontor**, Rauchtest grün;
7. das Agent-Token steht in keiner Schritt-Ausgabe; ein Schritt kann `/etc/cosmos/api.token`
   und `/var/lib/cosmos` **nicht** lesen;
8. `install.sh` ein zweites Mal: Tokens unverändert, Dienste wieder aktiv (idempotent).

**Grenze, nicht verschwiegen:** der Runner ist hier Prüfstand eines Installers, kein
Bau-Agent.  Die Pipeline lädt im Test einmal den aiml-Tarball (das tut jeder CI-Lauf ohnehin);
gebaut wird auf dem Runner nichts mit cosmos.

## 112.8 Was der Betreiber tun muss (und warum nicht wir)

- auf dem Server: Checkout, `aiml build`, `sudo deploy/server/install.sh` — der Server ist von
  hier nicht erreichbar;
- in kontor: ein Token mit Rolle `writer` für den Agenten anlegen;
- bei GitHub: ein nur lesendes Token für den Agenten (öffentliche Repositories genügen) und in
  den Repositories die Variable `AIML_KONTOR_URL`.

## 112.9 Offen

- **Quellbau von aiml in cosmos** (F112-13): braucht einen eigenen Bau-Weg für apt im Sandkasten
  oder ein Basis-Abbild mit Container-Agent — auf diesem Server mit `MemoryMax` und Zeit
  abzuwägen.
- **Weitere Blobs**: dieselbe Form (`kontor-blob put`) trägt auch Bauergebnisse von kontor, ufo
  und cosmos; dafür braucht es nur weitere Pipelines im Katalog.
- `setup-aiml.sh` liegt in kontor und ufo als eigene Kopie; die kontor-Quelle muss dort
  nachgezogen werden, damit auch deren Runner aus kontor lesen.
