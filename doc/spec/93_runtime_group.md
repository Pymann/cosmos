# Kapitel 93 — Die Server-Dienste als Classgroup (`CosmosRuntime`)

Dieses Kapitel ist normativ für den **Aufbau** des Controllers: wie Dienste entstehen, wie sie
einander erreichen und was ein RPC-Handler sehen darf.  Was die Handler fachlich tun, steht in
[90_ap1_agent_exec.md](90_ap1_agent_exec.md) (Agenten-Ausführung), [92_cas.md](92_cas.md) (CAS)
und den Auth-Kapiteln.

Sprachgrundlage ist `spec/58` der aiml-Spec (Classgroups); §-Verweise ohne Kapitelangabe
beziehen sich darauf.

## 93.1 Warum

Der Controller hielt seine Dienste in `g_*`-Globals: `g_auth`, `g_conn`, `g_cluster`, `g_agents`,
`g_runs`, `g_tokens` und weitere — dreizehn Dateien griffen direkt darauf zu.  Das hat zwei
Eigenschaften, die mit wachsendem Umfang teuer werden:

1. **Jeder Handler sah alles.**  Ein Handler, der nur das Ausgabe-Archiv lesen soll, konnte
   ebenso Tokens widerrufen — nichts in der Sprache hielt ihn davon ab.  Die tatsächliche
   Abhängigkeit eines Handlers war nur durch Lesen seines Körpers feststellbar.
2. **Jeder neue Dienst war ein neues Global.**  CAS allein hätte zwei weitere gebraucht.

`spec/58 §11.3` nennt das die „`g_*` bridge" und beschreibt ihre Ablösung.  Das Ergebnis ist
**genau ein** Dienst-Global.

## 93.2 Festlegungen

- **F93-1.** Alle Dienste des Controllers MÜSSEN Instanzen der Classgroup `CosmosRuntime` sein.
  Ein neuer Dienst wird eine Instanz, **kein** weiteres Global.
- **F93-2.** Es gibt genau einen Dienst-Global: `g_runtime: ptr<CosmosRuntime>` (die
  „runtime-root", §11.3).  `init_server_state(db_dir)` erzeugt ihn.
- **F93-3.** Jeder RPC-Handler MUSS eine Instanz von `RpcHandlerBase` mit instance-level
  `implements: [mirror.RpcHandler]` sein.  Sein `run` steht als `groupmethods:` in der
  fachlichen Handler-Datei.
- **F93-4.** Die `sees:`-Liste eines Handlers ist seine **Zugriffsliste**: er erreicht genau die
  dort genannten Dienste und keinen weiteren.  Sie MUSS minimal sein — nur was `run` benutzt.
- **F93-5.** Der Instanzname eines Handlers MUSS gleich seinem RPC-Namen sein
  (`subscribe_cluster` ↔ `"subscribe_cluster"`).  Damit ist die Registrierung im Daemon
  mechanisch prüfbar.
- **F93-6.** Handler-Dateien DÜRFEN NICHT aus dem Server importieren (kein `server_state`).
  Die Gruppen-Datei importiert die Handler-Dateien — siehe 93.4.
- **F93-7.** `g_current_peer_id` bleibt ein Global.  Es ist Zustand der **laufenden Anfrage**,
  den der Dispatcher vor jedem `run` setzt, kein Dienst.
- **F93-8.** Die Zugriffsliste ist eine **Struktur**-Aussage, keine Sicherheitsgrenze gegen
  einen Angreifer: sie begrenzt, was der Code erreichen kann, nicht wer den RPC auslösen darf.
  Jeder Handler, der Nutzerdaten anfasst, MUSS weiterhin selbst das Token prüfen
  (§AP1.6 gilt unverändert).

## 93.3 Aufbau in drei Phasen

`spec/58 §3`.  Für den Controller heißt das:

| Phase | Was läuft | Sichtbarkeit |
|---|---|---|
| 0 | `constructor:` je Instanz (z. B. `[init, db_dir]`) | **sees-blind** — daher reihenfolgefrei |
| 1 | `sees:`-Kanten werden verdrahtet (nur Adressen) | — |
| 2 | `on_wired` | Kollaborateure sind da |

Init, die einen anderen Dienst braucht, gehört nach Phase 2.  Beispiel `cas_trees`: es braucht
den `cas`-Store, ein Phase-0-Konstruktor könnte ihn nicht sehen —

```yaml
- class: CasTrees
  instance: cas_trees
  sees: [cas]
  methods:
    - def: { name: on_wired, body: [{ call: [<.init, <.cas] }] }
```

**Wurzelpfade als `params:`**, nicht als Literale im `constructor:` — damit Betrieb und Tests
eigene Pfade setzen können, statt sie im Gruppen-Aufbau festzuschreiben.

## 93.4 Import-Richtung (die nicht naheliegende Regel)

Der Compiler faltet `groupmethods:` **vor** der Validierung in die Gruppe (§1.1), und validiert
wird beim Übersetzen der Datei, die die Gruppe definiert.  Daraus folgt zwingend:

> Die Gruppen-Datei (`server_state.aiml`) importiert die Handler-Dateien.

Importierte eine Handler-Datei umgekehrt `server_state`, wäre `run` zum Validierungszeitpunkt
noch nicht gefaltet und das instance-level `implements: [mirror.RpcHandler]` schlüge fehl mit
`missing method 'run' required by interface 'mirror.RpcHandler'`.

Daraus folgt F93-6: Handler-Dateien importieren nur ihre **Modelle**.  Alles, was sie vom Server
brauchen, erreichen sie über `<.<dienst>`.

**Konsequenz für gemeinsame Hilfsfunktionen.**  Eine freie Funktion, die selbst einen Dienst
braucht, kann es unter dieser Richtung nicht geben — sie müsste `server_state` importieren.
Solche Hilfen werden **Gruppen-Methoden** auf dem Dienst, den sie benutzen.  Die Token-Auflösung
ist der Fall: aus den freien `resolve_token`/`resolve_token_pid` wurden

```yaml
- class: AuthService
  instance: auth
  constructor: [init, db_dir]
  sees: [conn]
  methods:
    - def: { name: pid_for_token,   args: [[token, string]], … }   # → player_id, "" = ungültig
    - def: { name: email_for_token, args: [[token, string]], … }   # → email
```

Beide stempeln die Verbindung als lebend (`<.conn.touch`) — deshalb die Kante `sees: [conn]`.
`sources/auth/token_resolver.aiml` ist damit entfallen.

**Welche Variante.**  `pid_for_token` ist die Vorgabe; die email verlässt den Auth-Layer nicht.
`email_for_token` nutzen nur die Profil-Handler, weil das `users`-KV email-keyed ist.

## 93.5 Ein Handler im Vorher/Nachher

Vorher — Klasse, Dienst über Global, volle Reichweite:

```yaml
- import: "sources/server/server_state.aiml"
- class:
    name: ClusterReadHandler
    implements: [mirror.RpcHandler]
    methods:
      - def:
          name: run
          body:
            - decl: [pid, string, { call: [resolve_token_pid, req.token] }]
            - decl: [view, ClusterView, { call: [g_runtime.cluster.snapshot] }]
```

Nachher — Instanz, Zugriffsliste in der Gruppe, Körper als Gruppen-Methode:

```yaml
# server_state.aiml
- { class: RpcHandlerBase, instance: get_cluster, sees: [auth, cluster], implements: [mirror.RpcHandler] }

# cluster_read_handlers.aiml  (importiert nur Modelle)
- groupmethods:
    group: CosmosRuntime
    instances:
      - instance: get_cluster
        methods:
          - def:
              name: run
              body:
                - decl: [req_pid, string, { call: [<.auth.pid_for_token, req.token] }]
                - decl: [view, ClusterView, { call: [<.cluster.snapshot] }]
```

Der Dispatcher nimmt die Instanz als Borrow:

```yaml
- call: [disp.register, "get_cluster", g_runtime.get_cluster]
```

`ref<mirror.RpcHandler>`, nicht `ptr<>`: die Gruppe **besitzt** ihre Instanzen, der Dispatcher
borgt sie nur (`spec/61 §8` — `ptr<T>` als Parameter übernähme die Box).  Die Zuordnung ist
`map<string:ref<mirror.RpcHandler>>`; die vtable trägt die synthetisierte Unterklasse (§M3).

## 93.6 Stand

**20 von 20 RPC-Handlern** sind Instanzen; Dienst-Globals von 13 auf 1 reduziert.

| Dienst-Instanzen | |
|---|---|
| `auth`, `conn` | Konten, Sessions, Verbindungs-Liveness |
| `cluster` | Cluster-Schnappschuss |
| `agents`, `runs`, `router` | AP1: Agenten, Ausgabe-Archiv, run_ref → Anfrager |
| `tokens` | AP1.9: Enrollment-Tokens |
| `cas`, `cas_trees` | Kapitel 92 |
| `cluster_subs`, `agent_subs` | Push-Abonnenten (zwei Instanzen **derselben** Klasse) |
| `push` | Live-Push an Abonnenten, hält die Signaturen je Strom |
| `reaper` | Aufräumen bei Verbindungsverlust |

Zugriffslisten der Handler:

| `sees:` | Handler |
|---|---|
| `[auth]` | `submit_login`, `submit_register`, `validate_token`, `logout`, `set_nickname`, `change_password`, `change_email` |
| `[auth, cluster]` (+`cluster_subs`) | `get_cluster`, `subscribe_cluster` |
| `[agents, tokens]` | `agent_register` — prüft den Enrollment-Token, **nicht** `auth`: Agent-Token und Nutzer-Session sind getrennte Vertrauensketten |
| `[agents]` | `agent_heartbeat` |
| `[auth, agents, agent_subs]` | `subscribe_agents` |
| `[auth, agents, runs, router]` | `run_on_agent` |
| `[agents, runs, router]` | `command_output`, `command_result` — kommen **vom Agenten**, daher kein `auth` |
| `[runs, auth]` | `read_run_output`, `get_run_info` |

### Stufe 3 — der Daemon trägt keine Dienst-Logik mehr

`drop_sub`, `drop_agent_sub`, `peer_gone`, `push_agents`, `push_cluster` (83 Zeilen) sind aus
`CosmosDaemon` in zwei Instanzen gewandert:

- **`push` (`LivePush`)**, `sees: [cluster, agents, cluster_subs, agent_subs]` — die Schleife
  ruft nur noch `g_runtime.push.tick(sess)`.
- **`reaper` (`PeerReaper`)**, `sees: [conn, agents, runs, cluster_subs, agent_subs]` — eine
  weggefallene Verbindung war vorher drei Methodenaufrufe in Folge, fachlich ist es ein
  Vorgang: `g_runtime.reaper.peer_gone(peer_id, now)`.

Ausschlaggebend war nicht die Zeilenzahl, sondern der **Zustand**: die Push-Signaturen
(`cluster_sig`, `agent_sig`) lagen als Daemon-Member neben einer Logik, die vier fremde Dienste
anfasste.  Jetzt liegen Zustand und Logik in derselben Instanz.

Mit den sees-Kanten entfielen auch die `pneq: [g_runtime.X, null]`-Wachen: nach Phase 1 ist eine
Instanz verdrahtet und kann nicht null sein (§3).

**Was im Daemon bleibt** — und dort hingehört: `bind_url`, TLS, Takte (`last_sweep_ms`,
`last_push_ms`), die Ereignisschleife und `install_*_handlers`.  Die Registrierung ist
Komposition, nicht Dienst-Logik; sie DARF `g_runtime` benutzen (F93-2).  Eine Gruppen-Methode
daraus zu machen hieße, 20 `sees`-Kanten zu deklarieren, nur um eine Liste abzuschreiben.

**Nachweis, dass die verschobene Logik läuft** (eine grüne E2E allein zeigt das nicht — sie
wäre auch grün, wenn Push und Reaper nie feuerten): im `run_e2e.sh`-Lauf erscheinen
`[live_push] pushed cluster_update`, 3× `[live_push] pushed agents_update`,
`[reaper] peer_disconnected` und `[reaper] agent agent-e2e disconnected`, und **keine** der
alten `[cosmos_daemon] pushed/peer_disconnected`-Zeilen mehr.

### Offen

**Log-Herkunft bei Gruppen-Methoden.**  `log.*` aus einer Gruppen-Methode schreibt als Quelle
die **Gruppen**-Datei (`sources/server/server_state.aiml:?`), nicht die Datei, in der der Körper
steht — die `groupmethods:` werden vor der Emission dorthin gefaltet.  Für alle 22
Gruppen-Methoden zeigt die Herkunft also auf dieselbe Datei; Methoden gewöhnlicher Klassen
zeigen weiter korrekt auf ihre eigene (`[run_store] … (sources/server/run_store.aiml:?)`).
Das ist eine Diagnose-Verschlechterung durch die Umstellung und eine aiml-Sache, kein
cosmos-Fehler.  (Die fehlende Zeilennummer `:?` ist davon unabhängig und betrifft alle
`log.*`-Aufrufe.)

## 93.7 Abnahme

- **A93-1.** Jede Handler-Instanz hat genau einen `run`-Körper, ist genau einmal registriert,
  und Instanzname = RPC-Name (F93-5).  Mechanisch prüfbar durch Abgleich von `server_state.aiml`
  gegen `cosmos_daemon.aiml`.
- **A93-2.** Keine Handler-Datei enthält `g_runtime` oder importiert `server_state` (F93-6).
  Prüfbar mit `grai --needle g_runtime --file sources/server/cosmos_daemon.aiml` — grai folgt
  `import:` durch den ganzen Graphen; Treffer DÜRFEN nur in `server_state.aiml` und
  `cosmos_daemon.aiml` stehen.
- **A93-3.** Die Agenten-Handler sind durch `./run_e2e.sh` (`e2e_agent_exec`, `e2e_enroll`)
  abgedeckt, die übrigen durch `e2e_rpc_surface` im selben Lauf: Registrierung, Anmeldung,
  `validate_token` (gültig **und** abgelehnt), beide Cluster-Leser (mit und ohne gültigem
  Token), die drei Profil-Aktionen (inkl. abgelehntem falschen Alt-Passwort) und `logout` mit
  anschließendem Nachweis, dass das Token tot ist.  **Ein** Test für alle — pro Handler ein
  eigener Test hieße pro Handler ein Server-Build.

### Befund aus A93-3

`e2e_rpc_surface` hat beim ersten Lauf einen Fehler aufgedeckt, der **vor** der Umstellung
bestand und ihr nicht zuzuschreiben ist: `set_nickname` übergab die `player_id` an
`AuthService.set_nickname`, das den Nutzer im email-keyed `users`-KV nachschlägt.  Der Handler
antwortete daher ausnahmslos `success=0, "unknown user"` — das Setzen des Anzeigenamens hat im
UI nie funktioniert.  Behoben durch `email_for_token` (wie bei `change_password`/`change_email`
daneben).  Dass der Fehler so lange überlebte, ist genau die Lücke, die A93-3 schließt: die
Profil-Handler hatten keine automatische Abnahme.
