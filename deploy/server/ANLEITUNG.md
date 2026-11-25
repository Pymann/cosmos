# cosmos auf dem kontor-Server einrichten — Schritt für Schritt

Ziel (doc/spec/112): auf dem Server, auf dem kontor und 9rooms schon laufen, kommen **genau
drei Dienste** dazu — `cosmosd`, `cosmos-api` und **ein** Agent.  Nichts davon ist von außen
erreichbar.  Die Pipeline `aiml_nach_kontor` legt stündlich den neuesten geprüften aiml-Bau in
kontor ab; die GitHub-Runner von cosmos, kontor und ufo laden aiml dann nur noch von dort.

Alles unten läuft **auf dem Server**.  Dauer: etwa 20 Minuten, davon das meiste Bauen.

---

## 0. Was du brauchst

- Ubuntu 22.04 oder 24.04, x86-64, mit systemd, sudo-Rechte.
- Etwa 1 GB freier Platz (Programme, Bibliotheken, ein aiml-Tarball zum Spiegeln).
- Eine **aiml-venv** — z. B. die, mit der kontor gebaut wurde.  Woran man sie erkennt:
  sie hat eine Datei `env` und `lib/libaiml.so`.  Keine zur Hand?  Dann in Schritt 2 neu holen.
- Ein **kontor-Token mit der Rolle `writer`** (Schritt 4).
- Ein **GitHub-Token, nur lesend** (Schritt 5).

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

Sobald cosmos einmal gelaufen ist, geht das auch ohne GitHub, aus kontor:

```bash
AIML_KONTOR_URL=https://127.0.0.1:8443 bash .github/ci/setup-aiml.sh ~/aimlvenv
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

Der Agent lädt mit diesem Token nach kontor hoch.  Jeder Schritt auf dem Agenten kann es lesen —
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

## 5. GitHub-Token (nur lesend)

aiml wird aus dem neuesten grünen CI-Lauf von `Pymann/aiml` gespiegelt; Artefakte lädt GitHub
nur mit Token aus.  Auf github.com → Settings → Developer settings → **Fine-grained tokens** →
*Generate new token*: Repository access **„Public repositories (read-only)"**, keine weiteren
Rechte.  Das Token in eine Datei:

```bash
install -m 600 /dev/null ~/github-read.token
nano ~/github-read.token
```

## 6. Einrichten

```bash
sudo deploy/server/install.sh \
     --venv "$AIML_VENV" \
     --kontor-url https://127.0.0.1:8443 \
     --kontor-token-file ~/kontor-writer.token \
     --github-token-file ~/github-read.token
#    --kontor-ca /pfad/zu/kontor.crt        ← nur bei selbstsigniertem Zertifikat
```

Das Skript erzählt, was es tut (Schritte 0–10).  Am Ende steht `Fertig.`  Bricht es ab, nennt
es den Schritt, und es läuft kein Agent.  Es darf beliebig oft wiederholt werden; Tokens und
deine Einstellungen bleiben stehen.

Danach die Token-Kopien in deinem Home löschen — sie liegen jetzt unter `/etc/cosmos-agent/`:

```bash
shred -u ~/kontor-writer.token ~/github-read.token
```

## 7. Prüfen

```bash
sudo cosmosctl status
```

Erwartet: drei Dienste `active (running)`, der Agent mit `registered at ws://127.0.0.1:8770`, und
schon ein Lauf von `aiml_nach_kontor` — der Zeitplan startet ihn sofort nach der Einrichtung.

```bash
sudo cosmosctl runs | jq -r '.runs[] | "\(.run_id) \(.status)"'
sudo cosmosctl wait <run-id>            # bis er fertig ist (ein paar Minuten: 130 MB laden)
sudo cosmosctl log <run-id>             # was jede Stufe gesagt hat
curl -s https://127.0.0.1:8443/generic/aiml/latest.env     # (--cacert … bei eigenem Zertifikat)
```

`latest.env` nennt `version=`, `tarball=`, `sha256=`.  Ab jetzt prüft cosmos stündlich; ist
nichts Neues da, endet der Lauf nach zwei kleinen Anfragen.  Von Hand anstoßen:

```bash
sudo cosmosctl run cat-aiml_nach_kontor
```

## 8. Die GitHub-Runner auf kontor umstellen

aiml legt sein Bündel samt Bibliotheken bei jedem Lauf selbst in kontor ab
(`/generic/aiml/latest/aiml-x86_64-linux.tar.gz`).  Damit die Runner von cosmos, kontor und ufo
es von dort nehmen, brauchen diese Repositories dieselben **Secrets** wie `Pymann/aiml`
(Settings → Secrets and variables → Actions → *New repository secret*):

| Name | Wert |
|---|---|
| `KONTOR_URL` | `https://151.80.143.81:8443` |
| `KONTOR_CA` | der **Inhalt** der CA-Datei von kontor (`-----BEGIN CERTIFICATE-----` …) |

Das Schreib-Token `KONTOR_TOKEN` gehört **nicht** dazu — die Runner lesen nur.  Im nächsten
CI-Lauf steht im Schritt *Download aiml*: `aiml: kontor https://151.80.143.81:8443 (latest,
sha256 …)`.  Ist kontor nicht erreichbar, lädt der Runner wie bisher von GitHub und warnt.

Hat kontor anonymes Lesen abgeschaltet (`auth.anonymous: none`), zusätzlich ein Token mit der
Rolle `reader` als Secret `AIML_KONTOR_TOKEN`.

## 9. Bedienen

| Was | Wie |
|---|---|
| Zustand | `sudo cosmosctl status` |
| Jobs | `sudo cosmosctl jobs` |
| Lauf starten | `sudo cosmosctl run cat-aiml_nach_kontor` |
| Protokoll eines Laufs | `sudo cosmosctl log <run-id>` |
| Dienst-Protokolle | `journalctl -u cosmosd -u cosmos-api -u cosmos-agent -f` |
| Feste aiml-Fassung statt der neuesten | `AIML_RELEASE=v…` in `/etc/cosmos-agent/aiml.env` |
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

kontor und 9rooms werden dabei nicht angefasst.  Was schon in kontor liegt (`/generic/aiml/…`),
bleibt dort.

---

## Wenn etwas nicht geht

| Meldung | Ursache, Abhilfe |
|---|---|
| `install.sh`: `…/cosmosd fehlt — erst bauen` | Schritt 3 im selben Checkout ausführen, oder `--from <checkout>` |
| `keine aiml-venv` | `sudo` vergisst die Umgebung: `--venv "$AIML_VENV"` mitgeben |
| `Bibliotheken fehlen` | die venv ist unvollständig — neu holen (Schritt 2) |
| `Isolation traegt nicht` | AppArmor: `sudo aa-status \| grep cosmos` muss `cosmos-bwrap` zeigen; `sudo dmesg \| grep DENIED` nennt, was fehlt |
| Stufe `quelle`: `CI-Laeufe … nicht lesbar` | GitHub-Token fehlt oder ist abgelaufen: neues nach `/etc/cosmos-agent/github.token` (Gruppe `cosmos-agent`, Modus 0640) |
| Stufe `hochladen`: `HTTP 401/403` | kontor-Token falsch oder ohne `writer`: `/etc/cosmos-agent/kontor.token` ersetzen |
| Stufe `hochladen`: `SSL certificate problem` | `--kontor-ca` fehlt: `sudo deploy/server/install.sh --venv "$AIML_VENV" --kontor-ca <crt>` |
| Stufe `pruefen`: `fehlen Bibliotheken` | auf dem Server fehlt eine Systembibliothek (z. B. `libgl1`) — `sudo apt-get install` des genannten Pakets |
| cosmosd startet nicht | `journalctl -u cosmosd -n 50` — meist ein Fehler in `/etc/cosmos/cosmos.yaml` (cosmosd startet absichtlich nicht mit kaputter Erklärung) |
