# cosmos auf dem kontor-Server einrichten — Schritt für Schritt

Ziel (doc/spec/112): auf dem Server, auf dem kontor und 9rooms schon laufen, kommen **genau
drei Dienste** dazu — `cosmosd`, `cosmos-api` und **ein** Agent.  Nichts davon ist von außen
erreichbar.  Pipelines auf dem Agenten legen ihre Ergebnisse in kontor ab.  aiml selbst liefert
sein Bündel schon aus der eigenen CI nach kontor; die GitHub-Runner von cosmos, kontor und ufo
laden es von dort (Schritt 8).

Alles unten läuft **auf dem Server**.  Dauer: etwa 20 Minuten, davon das meiste Bauen.

---

## 0. Was du brauchst

- Ubuntu 22.04 oder 24.04, x86-64, mit systemd, sudo-Rechte.
- Etwa 500 MB freier Platz (Programme, Bibliotheken).
- Eine **aiml-venv** — z. B. die, mit der kontor gebaut wurde.  Woran man sie erkennt:
  sie hat eine Datei `env` und `lib/libaiml.so`.  Keine zur Hand?  Dann in Schritt 2 neu holen.
- Ein **kontor-Token mit der Rolle `writer`** (Schritt 4).

Prüfen, dass die Ports frei sind (cosmos nimmt 8770 und 8771, beide nur auf 127.0.0.1):

```bash
sudo ss -ltnp | grep -E ':877[01] ' || echo "frei"
```

Belegt?  Nach Schritt 6 in `/etc/cosmos/cosmos.env` andere Ports eintragen (die Datei erklärt
sich selbst) und `sudo systemctl restart cosmosd cosmos-api cosmos-agent`.

## 1. cosmos holen

```bash
cd ~
git clone https://github.com/Pymann/cosmos.git      # privat: mit deinem Zugang
cd cosmos
git checkout main                                    # bzw. der Zweig mit deploy/server
```

## 2. aiml-venv aktivieren

Vorhandene venv:

```bash
. /pfad/zur/venv/env
echo "$AIML_VENV"; aiml --version
```

Keine da?  Neu holen (braucht `gh` und ein GitHub-Token, weil es noch kein öffentliches
aiml-Release gibt):

```bash
GH_TOKEN=<dein-token> bash .github/ci/setup-aiml.sh ~/aimlvenv
. ~/aimlvenv/env
```

Oder ohne GitHub aus kontor, wo aiml sein Bündel selbst ablegt (Token mit Leserecht):

```bash
AIML_KONTOR_URL=https://127.0.0.1:8443 AIML_KONTOR_TOKEN="$(cat ~/kontor-read.token)" \
    bash .github/ci/setup-aiml.sh ~/aimlvenv
```

## 3. Bauen (als du selbst, nicht als root)

```bash
sudo apt-get install -y --no-install-recommends g++ libssl-dev
aiml build -c exodus-cosmosd.json
aiml build -c exodus-api.json
aiml build -c exodus-agent.json
ls -l cosmosd cosmos-api agent          # alle drei müssen da sein
```

Auf 2–4 Kernen dauert das einige Minuten.  Wer kontor und 9rooms dabei nicht ausbremsen will:
`nice -n 10 aiml build …`.

## 4. kontor-Token für den Agenten anlegen

Pipelines auf dem Agenten laden mit diesem Token nach kontor hoch.  Jeder Schritt auf dem Agenten kann es lesen —
darum ein **eigenes** Token, nur mit `writer`, nicht dein Admin-Token.  Mit deinem
kontor-Admin-Token:

```bash
read -rs KADMIN; echo                   # kontor-Admin-Token einfügen, Enter
curl -sS -X POST -H "Authorization: Bearer $KADMIN" \
     --data '{"label":"cosmos-agent","roles":["writer"]}' \
     https://127.0.0.1:8443/api/v1/tokens
unset KADMIN
```

Aus der Antwort das Feld `token` in eine Datei legen (nicht in die Shell-History):

```bash
install -m 600 /dev/null ~/kontor-writer.token
nano ~/kontor-writer.token               # Token einfügen, speichern
```

**Selbstsigniertes Zertifikat?**  Dann scheitert `curl` oben mit einem Zertifikatsfehler.  Das
Zertifikat von kontor (die `.crt`/`.pem`-Datei, mit der kontor startet) brauchst du dann in
Schritt 6 als `--kontor-ca`; für den `curl` oben `--cacert <datei>` anhängen.

## 5. Eigene Pipelines (optional, auch später)

Jede `*.yaml` in `/etc/cosmos/pipelines/` ist ein Job `cat-<dateiname>`; anfangs ist das
Verzeichnis leer.  Eine Pipeline hinzufügen:

```bash
sudo install -m 0644 meine_pipeline.yaml /etc/cosmos/pipelines/
sudo systemctl restart cosmosd
sudo cosmosctl jobs
```

Ein Schritt legt eine Datei so in kontor ab: `/usr/local/libexec/cosmos/kontor-blob put <datei>
<pfad>` (landet unter `/generic/<pfad>`).  Soll ein Job nach Zeitplan laufen, gehört er
stattdessen als `job:` mit `interval_s` in `/etc/cosmos/cosmos.yaml` (die Datei zeigt, wie).

## 6. Einrichten

```bash
sudo deploy/server/install.sh \
     --venv "$AIML_VENV" \
     --kontor-url https://127.0.0.1:8443 \
     --kontor-token-file ~/kontor-writer.token
#    --kontor-ca /pfad/zu/kontor.crt        ← nur bei selbstsigniertem Zertifikat
```

Das Skript erzählt, was es tut (Schritte 0–10).  Am Ende steht `Fertig.`  Bricht es ab, nennt
es den Schritt, und es läuft kein Agent.  Es darf beliebig oft wiederholt werden; Tokens und
deine Einstellungen bleiben stehen.

Danach die Token-Kopien in deinem Home löschen — sie liegen jetzt unter `/etc/cosmos-agent/`:

```bash
shred -u ~/kontor-writer.token
```

## 7. Prüfen

```bash
sudo cosmosctl status
```

Erwartet: drei Dienste `active (running)` und der Agent mit `registered at ws://127.0.0.1:8770`.
`sudo cosmosctl jobs` zeigt die Pipelines aus Schritt 5 (anfangs keine).

**Update von einer früheren Fassung:** die Spiegel-Pipeline `aiml_to_kontor` gibt es nicht
mehr.  `install.sh` entfernt sie samt `aiml-mirror` und `aiml.env`, cosmos schaltet den Job ab
(seine alten Läufe bleiben sichtbar).  Ein altes `/etc/cosmos-agent/github.token` wird nicht
mehr gebraucht: `sudo shred -u /etc/cosmos-agent/github.token`.

## 8. Die GitHub-Runner auf kontor umstellen

aiml legt sein Bündel samt Bibliotheken bei jedem Lauf selbst in kontor ab
(`/generic/aiml/latest/aiml-x86_64-linux.tar.gz`).  Damit die Runner von cosmos, kontor und ufo
es von dort nehmen, brauchen diese Repositories dieselben **Secrets** wie `Pymann/aiml`
(Settings → Secrets and variables → Actions → *New repository secret*):

| Name | Wert |
|---|---|
| `KONTOR_URL` | `https://151.80.143.81:8443` |
| `KONTOR_CA` | der **Inhalt** der CA-Datei von kontor (`-----BEGIN CERTIFICATE-----` …) |

Im nächsten
CI-Lauf steht im Schritt *Download aiml*: `aiml: kontor https://151.80.143.81:8443 (latest,
sha256 …)`.  Ist kontor nicht erreichbar, lädt der Runner wie bisher von GitHub und warnt.

kontor verlangt fürs Lesen ein Token (anonymes Lesen ist abgeschaltet).  Die Workflows nehmen
das Secret `AIML_KONTOR_TOKEN` (am besten ein Token nur mit der Rolle `reader`), und wenn es
fehlt, `KONTOR_TOKEN`.

## 9. Bedienen

| Was | Wie |
|---|---|
| Zustand | `sudo cosmosctl status` |
| Jobs | `sudo cosmosctl jobs` |
| Lauf starten | `sudo cosmosctl run cat-<name>` |
| Protokoll eines Laufs | `sudo cosmosctl log <run-id>` |
| Dienst-Protokolle | `journalctl -u cosmosd -u cosmos-api -u cosmos-agent -f` |
| Mehr Speicher für den Agenten (Vorgabe 2 GB) | `sudo systemctl edit cosmos-agent` → `[Service]` `MemoryMax=4G` |
| Von deinem Rechner aus an die REST-API | `ssh -L 8771:127.0.0.1:8771 <server>`, dann `http://127.0.0.1:8771/api/v1/health` |
| Admin-Konto | `/etc/cosmos/admin.password` (E-Mail, Passwort) |
| Neue Fassung von cosmos | `git pull`, Schritt 3, dann `sudo deploy/server/install.sh --venv "$AIML_VENV"` |

Der Agent bekommt bewusst wenig Vorrang (`CPUWeight=20`, `IOWeight=20`, `Nice=10`): rechnen
kontor oder 9rooms, gehen sie vor; ist der Rechner leer, nimmt der Agent alles.

## 10. Wieder entfernen

```bash
sudo deploy/server/uninstall.sh            # Dienste, Programme, Werkzeuge
sudo deploy/server/uninstall.sh --purge    # zusätzlich Daten, Tokens, Dienstnutzer
```

kontor und 9rooms werden dabei nicht angefasst.  Was schon in kontor liegt, bleibt dort.

---

## Wenn etwas nicht geht

| Meldung | Ursache, Abhilfe |
|---|---|
| `install.sh`: `…/cosmosd fehlt — erst bauen` | Schritt 3 im selben Checkout ausführen, oder `--from <checkout>` |
| `keine aiml-venv` | `sudo` vergisst die Umgebung: `--venv "$AIML_VENV"` mitgeben |
| `Bibliotheken fehlen` | die venv ist unvollständig — neu holen (Schritt 2) |
| `Isolation traegt nicht` | AppArmor: `sudo aa-status \| grep cosmos` muss `cosmos-bwrap` zeigen; `sudo dmesg \| grep DENIED` nennt, was fehlt |
| `kontor-blob: PUT … → HTTP 401/403` | kontor-Token falsch oder ohne `writer`: `/etc/cosmos-agent/kontor.token` ersetzen |
| `kontor-blob`: `SSL certificate problem` | `--kontor-ca` fehlt: `sudo deploy/server/install.sh --venv "$AIML_VENV" --kontor-ca <crt>` |
| cosmosd startet nicht | `journalctl -u cosmosd -n 50` — meist ein Fehler in `/etc/cosmos/cosmos.yaml` (cosmosd startet absichtlich nicht mit kaputter Erklärung) |
