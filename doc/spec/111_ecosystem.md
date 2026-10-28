# 111 — cosmos im Ökosystem: Config as Code, Katalog, REST, museum

**Auftrag (User, 2026-10-27):** *„mit cosmos kann man pro stage layer im container erzeugen,
schau mal ob museum sowas bereits kann und das cosmos sie auch wieder von da beziehen kann.
auch die images soll man dort hochladen können. wir brauchen auch LDAP anbindung und SAML SSO
dann brauchen wir ein pendant in cosmos zum jcasc (jenkins config as code) eine script console
gibs glaub ich schon, und auch eine art jobdsl, museum soll auch webhooks versenden können, die
cosmos annehmen kann insgesamt brauchen wir für beides REST-API."*

Der Vertrag zwischen beiden Seiten steht in **museum `doc/ecosystem.md`** (Abbilder, Stufen-
Schichten, Webhooks, Kampagnen, Identität, REST).  Hier steht, wie cosmos seine Hälfte erfüllt
und welche Entscheidungen dabei gefallen sind.

---

## 111.0 Befunde, bevor gebaut wurde

**F111-1: cosmos hatte keine Registry.**  `push:` kannte nur `oci:<pfad>` (aiml F62-122),
Stufen-Schichten liegen auf dem Wirt des Agenten (F110-94/F110-110).  → museum übernimmt die
Rolle der Registry; cosmos bleibt beim Layout-Verzeichnis als seiner Form und bekommt einen
**Übersetzer** (`cosmos-museum`, §111.9), keinen eigenen Netzcode im Lauf-Pfad.

**F111-2: Die Konsole gibt es (doc/spec/108).**  Sie bekommt nur einen REST-Zugang (§111.8).

**F111-3: Die Rechte waren Stufen, keine Rollen.**  Freigabe 1 (Admin) gegen alles andere.
Eine Rolle „darf `run_job`, aber nicht `save_job`" gab es nicht.  → Rollen sind **Listen von
RPC-Namen** (F100-11) und werden an EINER Stelle geprüft (§111.3), nicht in 40 Handlern.

**F111-4: Jobs gab es schon (`JobDef`, doc/spec/106).**  Ein Katalog darf darum kein zweiter
Job-Begriff werden — er erzeugt `JobDef`s (§111.4).  Persistierte Modelle bekommen keine neuen
Felder (F108-2); was der Katalog zusätzlich weiß, liegt in einem eigenen KV.

**F111-5: spec/100 schreibt `from_code` vor — ein Generator in aiml.**  Den auszuführen braucht
`ctx.new` aus der aiml-Fassung des Nutzers; hier ist er nicht umsetzbar.  → Umgesetzt sind
`jobs:` und `from_dir:`; `from_code:` ist der nächste Schritt (§111.10).

---

## 111.1 Die Erklärung (das Gegenstück zu JCasC)

Eine YAML-Datei, aiml-Daten in derselben Form wie `- pipeline:` (F100-1):

```yaml
- config:
    roles:
      - role: { name: operator, may: [run_job, pause_run, resume_run] }
      - role: { name: viewer,   may: [get_cluster, read_run_output] }
    grants:
      - grant: { user: alice@example.org, role: operator }
      - grant: { group: devs, role: viewer }          # Gruppe aus LDAP/SAML
    secrets:
      - secret: { name: hook, file: secrets/hook.secret }   # relativ zur Erklärung
      - secret: { name: mtok, env: COSMOS_MUSEUM_TOKEN }
    museum: { url: "http://museum:8081", webhook_secret: hook, token: mtok }
    ldap:   { url: "ldap://dir:389", user_dn: "uid={user},ou=people,dc=example,dc=org" }
    saml:   { idp_sso_url: …, idp_cert_file: …, sp_entity_id: …, acs_url: … }
- catalog:
    jobs:
      - job: { name: net, source: ci/net.aiml, project: net, triggers: [museum] }
    from_dir:
      - { path: ci, triggers: [museum] }               # jede *.aiml/*.yaml ein Job
```

Die vier Verben aus spec/100:

| Verb | Wie | Wirkung |
|---|---|---|
| declare | die Datei | — |
| plan | RPC `config_plan`, `POST /api/v1/config/plan` | Liste von Änderungen; **berührt nichts** (F100-3) |
| apply | RPC `config_apply`, `POST /api/v1/config/apply`, oder `COSMOS_CASC=<datei>` beim Start | speichert; idempotent — ein zweiter Plan ist leer (F100-4) |
| read | RPC `config_read`, `GET /api/v1/config` | Ist-Stand samt Katalog |

**Entscheidungen:**

- **Unbekannte Schlüssel sind Fehler.**  Ein Tippfehler in `grnats:` wäre sonst eine
  Rechtevergabe, die nie stattfindet.
- **Fehlerhaft heißt: nichts wird angewandt** (fail closed).  Beim Start mit `COSMOS_CASC`
  **startet cosmosd nicht** — ein Dienst mit halb gelesener Rechtevergabe wäre schlimmer als
  keiner.  Das entspricht JCasC.
- **Quellen werden beim LESEN geladen**, damit plan und apply dieselben Bytes sehen.
- **Geheimnisse nur per Verweis** (F100-10): die Datei nennt Quelle und Namen, nie den Wert.
  Werte stehen in keinem Log, keiner Antwort und keinem Modell.
- plan/apply/read verlangen Freigabe 1.

Belegt: `test_casc` (Leser), `run_e2e_api.sh` Phase 3 + 4 (plan berührt nichts, kaputte Datei
→ 422 bzw. kein Start, apply idempotent).

---

## 111.2 config

`roles`, `grants`, `secrets`, `museum`, `ldap`, `saml` — Modelle in
`sources/models/casc_basics.aiml` / `casc_idp.aiml` / `casc_config.aiml`.  Gespeichert unter
`casc_config["current"]`.  Fehlt `roles:` ganz, bleibt die Rollenprüfung **aus**
(`roles_on = 0`) — eine bestehende Installation ändert ihr Verhalten nicht, bloß weil sie eine
Erklärung für den Katalog bekommt.

---

## 111.3 Das Rollen-Gate

Geprüft wird in `AuthService.email_for_token` (server_state.aiml) — der Stelle, durch die
**jeder** Handler das Token auflöst.  Der Dispatcher setzt vorher `g_current_method`.  Damit
gilt die Prüfung für alle RPCs, ohne einen Handler anzufassen.

Erlaubt ist ein Aufruf, wenn eines gilt:

1. Rollen sind aus (`roles_on = 0`).
2. Das Konto hat Freigabe 1.
3. Die RPC ist Selbstbedienung (`validate_token`, `logout`, Profil, `my_clearance`, eigene
   API-Tokens, `may_call`).
4. Eine Rolle des Kontos (direkt oder über eine Gruppe) nennt die RPC oder `*`.

Eine Ablehnung steht im Log (`[rollen] … abgelehnt`) und wirkt für den Handler wie ein
ungültiges Token.  Für Leser, die das als **leere Sicht** beantworten (`get_cluster`), gibt es
`may_call(method)`: dieselbe Rechnung als Frage, damit das REST-Gateway 403 statt 200 melden
kann.

---

## 111.4 Der Katalog (das Gegenstück zur JobDSL)

Ein Katalog-Eintrag wird ein ganz gewöhnlicher `JobDef` mit der Kennung `cat-<name>`.
Zusätzlich (KV `catalog_meta`): `project` (welches exodus-Projekt der Job baut),
`triggers` (`museum` = startet in Kampagnen, §111.6), `source_file`, `origin: catalog`.

- `from_dir:` nimmt jede `*.aiml`/`*.yaml` darin, sortiert, Name = Dateiname ohne Endung,
  `project` aus einer Kopfzeile `# project: <name>`.
- **Entfernen schaltet ab, löscht nicht** (F100-15): ein Job, der nicht mehr im Katalog steht,
  wird `enabled: 0`; seine Läufe und Nummern bleiben.
- Jobs, die von Hand angelegt wurden (`origin` ≠ catalog), fasst der Katalog nicht an.

**Warum keine eigene DSL:** spec/100 F100-13 — Jobs werden aus Dateien oder aus aiml-Code
erzeugt, nicht aus einer zweiten Sprache.  Die Pipeline-Quelle IST schon aiml.

---

## 111.5 Identität: LDAP und SAML

Der Vertrag (museum `doc/ecosystem.md` §6) gilt für beide Seiten gleich.  Die Mechanik
(LDAP-Client, XML-Signaturprüfung, base64) steckt in aiml selbst (spec/67, Zweig
`feature/identity-builtins-memv3`); cosmos trägt nur die Politik
(`sources/auth/identity_login.aiml`).

**LDAP** — `config.ldap`.  Die Anmeldemaske und `POST /api/v1/login` bleiben dieselben:
scheitert die lokale Anmeldung mit „unknown user" oder „wrong password", fragt cosmosd das
Verzeichnis.  **Lokale Konten gehen vor** (Notfall-Admin ohne Verzeichnis).

- DN-Vorlage (`user_dn: "uid={user},ou=people,dc=…"`, Eingabe durch `ldap.escape_dn`) oder
  suchen-dann-binden (`search_base` + `search_filter`, Vorgabe `(uid={user})`, Eingabe durch
  `ldap.escape_filter`, gesucht mit `bind_dn`/`bind_secret`; genau EIN Treffer).
- E-Mail aus `mail_attr` (Vorgabe `mail`), Gruppen aus `group_attr` (Vorgabe `memberOf`).
  Zu jedem DN-Wert wird auch sein erstes RDN gemerkt: `cn=devs,ou=groups,…` erfüllt
  `grant: { group: devs }`.
- Fehlt das Konto, wird es angelegt — mit einem Zufalls-Passwort, das niemand kennt.

**SAML 2.0** — `config.saml`, SP-initiiert:

| Schritt | REST | RPC |
|---|---|---|
| Anmeldung beginnen | `GET /api/v1/sso/saml/login?relay=/pfad` → 302 zum IdP | `saml_begin` |
| Antwort annehmen | `POST /api/v1/sso/saml/acs` (POST-Bindung) | `saml_finish` |

- Die Antwort muss mit `idp_cert_file` signiert sein; Audience = `sp_entity_id`,
  Destination/Recipient = `acs_url`, Zeitfenster, keine Signatur-Umhüllung — das prüft der
  Baustein (spec/67 §4.3).  `idp_entity_id` (optional) prüft zusätzlich den Aussteller.
- **Nur Antworten auf eine offene Anfrage** zählen, jede Anfrage-Kennung **einmal** und
  höchstens 10 Minuten (im Speicher von cosmosd).  Damit gibt es weder IdP-initiierte
  Anmeldungen noch Wiederholungen.
- Erfolg: mit einem `RelayState`, der ein **Pfad** dieses Dienstes ist (`/…`, nicht `//…`),
  302 dorthin mit `#token=<sitzung>` (das Fragment erreicht keinen Server); sonst die
  Sitzung als JSON.  Fremde Ziele werden nie angesprungen.
- E-Mail aus `email_attr` oder `NameID`, Gruppen aus `group_attr`.

Beide Wege enden in `AuthService.login_external` und melden die Gruppen an
`ApiTokenStore.set_groups` — von dort liest das Rollen-Gate (§111.3).

Belegt: `run_e2e_identity.sh` — Wegwerf-slapd und ein gespielter IdP (Schlüssel per openssl,
Signatur per xmlsec1): LDAP-Anmeldung, Gruppe → Rolle, falsches/leeres Passwort, `*` als
Login; SAML-Hin- und Rückweg, Gruppe → Rolle, Wiederholung, fremdes Zertifikat,
unangefragte Antwort, offener Umleiter — 19 Prüfungen.

---

## 111.6 Rebuild-Kampagnen aus museum-Webhooks

museum schickt `package.published` mit seinem Plan (`rebuild_waves`, `needs`).  cosmos:

1. prüft die Signatur `X-Museum-Signature-256` (HMAC-SHA256 über die rohen Bytes, Geheimnis
   aus `config.museum.webhook_secret`, zeitkonstant verglichen).  **Das Gateway prüft nicht**
   — es kennt das Geheimnis nicht und reicht Bytes und Kopf durch;
2. verarbeitet jede `X-Museum-Delivery` **einmal** (museum stellt mindestens einmal zu);
3. **führt eine offene Kampagne das Projekt**, wird dessen Posten erledigt (`published`, bei
   `unchanged: true` → `unchanged`) und alles Startbare gestartet — es entsteht keine zweite
   Kampagne, die dieselben Projekte noch einmal baute;
4. **sonst** öffnet es eine Kampagne: ein Posten je Projekt aus den Wellen, Job über
   `project:` + `triggers: [museum]` aus dem Katalog;
5. startet einen Posten, sobald alle `needs` fertig sind (der Auslöser zählt als fertig);
6. **überspringt** einen Posten, dessen `needs` alle byte-gleich geblieben sind;
7. **fail closed**: scheitert ein Lauf, werden seine Abhängigen `blocked`.

Zustände eines Postens: `waiting → running → built | published | unchanged | failed`, dazu
`skipped`, `blocked` und `no_job` (kein Katalog-Job — wartet auf eine fremde
Veröffentlichung).  Der Daemon-Takt (5 s) sieht laufende Posten über `run_status` nach.

**Entscheidung:** Ein fertiger Lauf ohne Veröffentlichung gilt als `built` und damit als
**geändert** — sicherer als ein übersprungener Neubau.  Kommt die Veröffentlichung vor dem
Laufende (der Normalfall: der Push ist eine Stufe des Laufs), zählt sie.

Belegt: `run_e2e_api.sh` (Signatur, falsche Signatur, Doppelzustellung, Welle 1 läuft, Welle 2
wartet, byte-gleiche Abhängigkeit → übersprungen, Kampagne fertig).

---

## 111.7 API-Tokens

Für Werkzeuge und CI: `cosmos_` + 64 Hex (256 Bit).  Gespeichert ist nur `sha256(Token)`;
das Geheimnis gibt es genau einmal, in der Antwort auf das Anlegen.  Jedes Token gehört
einem Konto und hat **dessen** Rechte (Freigabe und Rollen) — keine eigene Rechtevergabe.
Widerruf per Kennung (`at-…`), ohne das Geheimnis.  Admins sehen alle Tokens.

RPCs `create_api_token`, `list_api_tokens`, `revoke_api_token`; REST `POST/GET/DELETE
/api/v1/tokens`.  Das Rollen-Gate kennt beide Token-Arten: `AuthService.identity_for_token`
fragt erst die Sitzung, dann den Token-Speicher.

---

## 111.8 REST: `cosmos-api`

Ein eigenes Programm (`exodus-api.json`), das als **Client** von cosmosd dieselben RPCs ruft
wie der Browser.  Darum gilt jede Prüfung von cosmosd unverändert, und cosmosd bleibt der
einzige Schreiber.  `COSMOS_API_PORT` (8090), `COSMOS_API_UPSTREAM` (`ws://127.0.0.1:9100`).
Token per `Authorization: Bearer <token>` (Sitzung oder API-Token).

| Methode | Pfad | RPC |
|---|---|---|
| GET | `/api/v1/health` | — |
| POST | `/api/v1/register`, `/login`, `/logout` | `submit_register`, `submit_login`, `logout` |
| GET | `/api/v1/whoami` | `my_clearance` |
| GET | `/api/v1/cluster`, `/jobs`, `/runs` | `get_cluster` (Ausschnitte) |
| PUT | `/api/v1/jobs/:id` | `save_job` |
| POST | `/api/v1/jobs/:id/run` | `run_job` |
| POST | `/api/v1/pipelines/run` (Körper = Quelltext) | `run_pipeline` |
| POST | `/api/v1/runs/:id/pause`, `/resume`, `/step`, `/rewind` | `pause_run` … |
| POST | `/api/v1/console?wait=<s>` (Körper = Skript) | `console_exec` + Nachfragen |
| GET/POST | `/api/v1/config`, `/config/plan`, `/config/apply` (`?path=` oder Körper) | `config_*` |
| POST/GET/DELETE | `/api/v1/tokens`, `/tokens/:id` | `*_api_token` |
| GET | `/api/v1/campaigns` | `list_campaigns` |
| POST | `/api/v1/hooks/museum` | `museum_event` |

Status: 401 ohne/ungültiges Token (Probe über `my_clearance`), 403 Token gilt, Aufruf
abgewiesen, 400 ungültig, 422 Erklärung mit Befunden, 502/504 cosmosd nicht erreichbar bzw.
stumm.  Fehler sind `{"error": "...", "code": "..."}` wie bei museum.

Belegt: `run_e2e_api.sh` — 45 Prüfungen über echte Prozesse.

---

## 111.9 museum als Registry

`cosmos-museum` (`exodus-museum-client.json`) bewegt OCI-Layouts:

```bash
cosmos-museum --mode push --layout <dir> --url <museum> --ref <repo>:<tag> [--token-file f | --token-env VAR] [--artifact-type t]
cosmos-museum --mode pull --layout <dir> --url <museum> --ref <repo>:<tag>|<repo>@sha256:<hex>
```

- **Pipelines** schreiben `image: museum:<repo>:<tag>`; `rt_launcher.pull_museum` holt es in
  `<arbeitsbereich>/museum_cache/` und legt es aus wie `oci:` (vorhandene Blobs werden nicht
  neu geladen).  `pipeline_submit.known_image` nimmt `museum:` an, ohne ins Netz zu gehen.
- **`push: to: "museum:<repo>:<tag>"`**: erst schneidet cosmos-oci wie bisher (in ein Layout
  neben dem Protokoll), dann lädt cosmos-museum hoch; die Digest im Lauf ist die, die museum
  meldet.
- **Stufen-Schichten eines Laufs** als Artefakt: Repository `cosmos-layers/<pipeline>`, Tag
  `<run_id>`, `--artifact-type application/vnd.cosmos.run-layers.v1+json` (Vertrag §3).
- Der Zugang kommt aus `config.museum` und wird jede Runde neu gelesen — ein `config apply`
  gilt ohne Neustart.  Das Token reist nur als **Verweis** (`--token-file`/`--token-env`).
- **Fremde Schichten sind nicht vertrauenswürdig** (F110-121): ein Lauf nimmt Schichten aus
  museum nur als Abbild, nicht als Wiederverwendung einer Stufe, solange keine Signaturen
  geprüft werden (`config.museum.layer_trust` bleibt vorerst `none`).

Braucht die aiml-Erweiterung `client.body_file` / `resp.save_to` / `resp.body_len` (Zweig
`feature/http-client-files-memv3`): der HTTP-Client war nur textsicher und brach an der ersten
NUL ab — eine Schicht ist Binärdaten.

Belegt: `run_e2e_museum.sh` gegen ein echtes museum — Webhook-ping mit Signatur,
`package.published` öffnet die Kampagne (Welle 1 läuft), die nächste Veröffentlichung setzt
**dieselbe** Kampagne fort (Welle 2 startet, Projekt ohne Job → `no_job`), push/pull per Tag
und Digest byte-gleich, push ohne Token abgewiesen, `image.pushed` kommt bei cosmos an —
18 Prüfungen.

---

## 111.10 Bauen

cosmosd braucht ab hier die aiml-Bausteine aus drei Zweigen (alle von `mem-v3-compiler`):
`feature/identity-builtins-memv3` (LDAP/SAML/base64 — `libaiml.so` hängt dann an libldap,
libxmlsec1, libxml2, libxslt), `feature/http-client-files-memv3` (binäre HTTP-Körper für
cosmos-museum) und — für museum — `feature/http-registry-support-memv3`.
Seit 2026-10-28 sind alle drei (und die übrigen Ökosystem-Zweige) direkt in `mem-v3-compiler`
gemergt (34c3340); ein eigener Integrationszweig ist nicht mehr nötig.  Darauf laufen
museum `tests/run_all.sh` und `run_e2e_api.sh`, `run_e2e_identity.sh`, `run_e2e_museum.sh`.

Neue Programme: `cosmos-api` (`exodus-api.json`), `cosmos-museum` (`exodus-museum-client.json`).

## 111.11 Was NICHT läuft, und warum das hier steht

- **`from_code:`** (spec/100 §100.6) fehlt, siehe F111-5.
- **LDAP/SAML** brauchen den aiml-Zweig `feature/identity-builtins-memv3` (libldap,
  xmlsec1).  `memberOf` als Gruppen-Attribut setzt das memberof-Overlay im Verzeichnis voraus.
- **Schicht-Annotationen** (`cosmos.stage`, `cosmos.bindings`, …) setzt cosmos-oci noch nicht;
  das Artefakt trägt bisher nur den `artifactType`.
- Beim Holen und Hochladen wird eine Schicht einmal ganz gelesen (Hash-Prüfung) — für
  mehrere GB große Schichten wäre ein Strom-Hash besser.

### 111.11.1 Erledigt (2026-10-28, aiml `mem-v3-compiler` 9810134)

- **`pipeline_submit.aiml` übersetzt** mit der aiml-Fassung, die die Pipeline-Merkmale trägt;
  `run_e2e_api.sh`, `run_e2e_identity.sh` und `run_e2e_museum.sh` laufen damit ohne Platzhalter.
- **`push: to: "museum:<repo>"`** nimmt die aiml-Pipeline-Prüfung an und reicht das Ziel
  unverändert durch (`pipe.push_to`); `push_worker` setzt `museum:` um.
- **Gateway-Absturz unter gleichzeitigen Anfragen behoben.**  Der aiml-HTTP-Server hat einen
  Faden je Verbindung (aiml spec/32_2 §3.12), nicht einen für alle — die Annahme in
  `api_link.aiml` war falsch.  Zwei Fäden lasen dieselbe Mirror-Sitzung (SIGSEGV in
  `SSL_read`, zwei von vier `run_e2e_museum.sh`-Läufen); `ApiGateway.serial` (ein `lock`)
  nimmt jetzt jede Route ganz.  Danach fünf von fünf Läufen grün.
