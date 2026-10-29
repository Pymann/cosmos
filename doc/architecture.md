# Cosmos – Architektur (Stand 2026-10-08)

Cosmos besteht derzeit aus drei eigenständigen AIML-Programmen. Sie teilen sich
Model-Definitionen aus `sources/shared/`, aber keinen Zustand: Jedes Programm hat
seine eigenen persistenten KV-Stores im Unterverzeichnis `aiondb/` seines
Arbeitsverzeichnisses.

| Programm | Build-Config | Einstieg | Klasse | Zweck |
|---|---|---|---|---|
| `server` | `exodus-server.json` | `sources/server/server_main.aiml` | `ClusterBootstrap` | Demo-Cluster anlegen, Workloads auf Nodes verteilen (einmaliger Lauf) |
| `controller` | `exodus-controller.json` | `sources/server/controller_main.aiml` | `JobController` | Job an einen Agent vergeben, Job-Zustand persistent führen |
| `agent` | `exodus-agent.json` | `sources/agent/agent_main.aiml` | `AgentRunner` | Job dauerhaft ausführen, Log streamen, nach Abbrüchen wieder anhängen |

`server` und `controller`/`agent` sind noch nicht verbunden: Der Server plant
Workloads, der Controller verwaltet Jobs. Beides läuft getrennt.

```
                ┌────────────────────┐
                │ server             │  einmaliger Lauf, keine Netzwerk-Schnittstelle
                │ ClusterBootstrap   │  aiondb/{nodes,workloads,pipelines}.kvwal
                └────────────────────┘

 ┌────────────────────┐   mirror tcp://127.0.0.1:<port>   ┌────────────────────┐
 │ controller         │ ◄──────── hello / job_update ──── │ agent              │
 │ JobController      │ ───────── AgentWelcome / JobAck ─►│ AgentRunner        │
 │ aiondb/jobs.kvwal  │                                    │ aiondb/agent_jobs  │
 └────────────────────┘                                    │ ws/<job>/job.log   │
                                                           │ ws/<job>/job.status│
                                                           └─────────┬──────────┘
                                                                     │ sys.exe detach
                                                           ┌─────────▼──────────┐
                                                           │ Monitor (Session)  │
                                                           │  └─ Job-Prozess    │
                                                           └────────────────────┘
```

---

## 1. Server (`ClusterBootstrap`)

Datei: `sources/server/cluster_bootstrap.aiml`. Aufruf: `./server` (keine Flags).

**Daten** (`sources/shared/`):

- `Node`: Rechenknoten bzw. Build-Agent mit `labels`, `agent_tags`, CPU/Speicher (`total_*`, `used_*`), `status`, `endpoint`.
- `Workload`: deploybarer Service/Job mit `required_label`, `cpu_request`, `memory_request`, Replikas und `assigned_node_ids`.
- `PipelineRun` mit einer Liste `PipelineStage`: CI/CD-Lauf (Repo, Branch, Stages mit `required_label` und `script_ref`).

**Stores:** `nodes`, `workloads`, `pipelines` (persistent, `aiondb/<name>.kvwal`).

**Ablauf von `run`:**

1. `seed_demo_cluster`: schreibt drei Nodes (`node-control-1`, `node-build-1`, `node-general-1`), zwei Workloads (`workload-build` mit Label `build`, `workload-api` mit Label `general`) und die Pipeline `pipeline-api-main` mit drei Stages. Ein erneuter Lauf überschreibt diese Einträge.
2. `promote_pipeline`: setzt die Pipeline auf `deploying`.
3. `reconcile_workload` je Workload: probiert die Nodes in fester Reihenfolge (`node-build-1`, `node-general-1`, `node-control-1`). `place_on_node` platziert, wenn der Node `ready` ist, das Label passt und CPU und Speicher reichen. Dann werden Node-Auslastung und Workload-Status (`running`, `assigned_node_ids`) geändert und per `kv.set` zurückgeschrieben. Passt kein Node, wird der Workload `waiting_for_capacity`.
4. Report aller Nodes, Workloads und der Pipeline per `log.info`.

Änderungen erfolgen über `ref<T>`-Borrows aus `kv.get` und werden mit `kv.set` auf denselben Key persistiert (Self-Write, aiml spec/31 §6.7).

**Ergebnis mit den Demo-Daten:** `workload-build` → `node-build-1` (CPU 4/16), `workload-api` → `node-general-1` (CPU 2/12).

---

## 2. Controller (`JobController`)

Datei: `sources/server/job_controller.aiml`.

```
./controller --port 19870 --job-id job-1 --command "<Shell-Kommando>" [--exit-when-done]
```

| Flag | Default | Bedeutung |
|---|---|---|
| `--port` | `19870` | TCP-Port, gebunden an `127.0.0.1` |
| `--job-id` | `job-1` | Der eine Job, den dieser Controller verwaltet |
| `--command` | `echo hello` | Shell-Kommando des Jobs (beim Agent über `sh -c` ausgeführt) |
| `--exit-when-done` | aus | Nach Jobende Log schreiben und beenden |

**Persistenter Zustand:** Store `jobs` (`aiondb/jobs.kvwal`), ein `JobRecord` pro Job:
`job_id`, `command`, `state`, `agent_id`, `pid`, `exit_code`, `log` (das bisher empfangene Log),
`disconnects`, `updated_ms`.

**Job-Zustände** (`JobState` in `sources/shared/job_state.aiml`):

```
queued ──hello──► running ──Disconnect──► agent_lost ──hello (reattach)──► running ──Job-Ende──► finished
```

**Start:** Existiert der Job schon im Store, wird er wiederhergestellt (`restored … state=… log_len=…`), sonst als `queued` angelegt. Dadurch übersteht der Job-Zustand einen Absturz des Controllers.

**Hauptschleife** (alle 20 ms): `session.update`, dann alle Mirror-Events, dann alle RPCs abarbeiten.

- `peer_disconnected`: Gehörte dem Peer ein laufender Job, geht er auf `agent_lost`, `disconnects` wird erhöht und der Zustand gespeichert.
- `hello` (`AgentHello` → `AgentWelcome`):
  - Ein Agent, der den Job bereits besitzt (`current_job_id`), wird wieder angehängt (Reattach).
  - Ein neuer Agent bekommt einen `queued` Job zugeteilt.
  - Die Antwort enthält Job-ID, Kommando und die Log-Länge, die der Controller schon hat.
- `job_update` (`JobUpdate` → `JobAck`):
  - Ein Log-Chunk wird nur übernommen, wenn sein `offset` genau der gespeicherten Log-Länge entspricht. Chunks sind damit idempotent, und doppelte oder veraltete Sendungen schaden nicht.
  - Die Antwort enthält immer die maßgebliche Log-Länge. Der Agent setzt dort fort.
  - Updates von Peers, die nicht (mehr) an den Job gebunden sind, werden ignoriert. Ein RPC, den ein Agent kurz vor seinem Abbruch gesendet hat, kann nach dem Disconnect-Event ankommen (aiml spec/44_5 §8).

**Ende** (mit `--exit-when-done`): Bei `finished` schreibt der Controller `<job_id>.controller.log`, bedient noch etwa 1 s weiter (damit der letzte `JobAck` ankommt) und beendet sich.

Zustandsänderungen werden als `STATE <grund> job=… state=… pid=… exit=… log_len=… disconnects=…` geloggt; der Probe wertet diese Zeilen aus.

---

## 3. Agent (`AgentRunner`)

Datei: `sources/agent/agent_runner.aiml`.

```
./agent --port 19870 --agent-id agent-1
```

**Persistenter Zustand:** Store `agent_jobs` (`aiondb/agent_jobs.kvwal`), Key `current` → `LocalJob` (`job_id`, `command`, `pid`). Damit weiß ein neu gestarteter Agent, welchen Job er besitzt.

**Job-Start** (`launch`), angestoßen durch das `AgentWelcome`:

```yaml
- call: [sys.exe, ["sh", "-c", command],
    {detach: true, stdout: ws/<job>/job.log, stderr: ws/<job>/job.log, status_file: ws/<job>/job.status}]
```

aiml startet dafür einen Monitor-Prozess in eigener Session (spec/23 §5.4). Der Monitor startet den Job, wartet auf ihn und schreibt den Exit-Code atomar nach `job.status`. Der Job hängt nicht am Agent:

- Er erbt weder den Socket noch die KV-Datei des Agents (aiml schließt im Kind alle fds ab 3).
- Er läuft weiter, wenn der Agent abstürzt oder neu startet.

**Hauptschleife** (alle 200 ms):

- *Nicht verbunden:* `mirror.connect_timeout` (500 ms), dann `hello` mit `agent_id` und `current_job_id`. Gelingt das, übernimmt der Agent die Log-Länge des Controllers als Offset.
- *Verbunden:* `session.update`. Bei `is_connected() == 0` die Session schließen und in den Reconnect-Zweig gehen. Sonst `push_update`:
  1. `sys.process_attach(pid, job.status)` und `running()`. Ist der Job beendet, gehen `finished` und `returncode` in das Update. Vorher wird der Status geprüft, denn nach Jobende ist das Log vollständig.
  2. `job.log` lesen und alles ab dem bestätigten Offset als Chunk senden (`send_and_await`, 2 s).
  3. Aus dem `JobAck` den neuen Offset übernehmen.
- Ist der Job beendet und hat der Controller das vollständige Log bestätigt, löscht der Agent `current` und beendet sich.

`returncode -1` bedeutet: Der Job-Prozess ist verschwunden, ohne einen Status zu schreiben (z. B. nach einem Reboot). Der Agent meldet dann `finished` mit `exit=-1`.

---

## 4. Protokoll (`sources/shared/`)

Alle RPCs gehen vom Agent aus (Mirror Request/Response, `send_and_await` → `reply_rpc`).

| Methode | Request | Response | Datei |
|---|---|---|---|
| `hello` | `AgentHello { agent_id, current_job_id }` | `AgentWelcome { job_id, command, log_len }` (`job_id ""` = kein Job) | `agent_hello.aiml` |
| `job_update` | `JobUpdate { agent_id, job_id, state, pid, exit_code, offset, chunk }` | `JobAck { job_id, log_len }` | `job_update.aiml` |

---

## 5. Probe `probe/agent_disconnect.sh`

```bash
probe/agent_disconnect.sh --build     # baut controller + agent, dann Probe
```

Ablauf (Arbeitsverzeichnisse und Logs unter `out/probe/agent_disconnect/`):

1. Controller und Agent starten. Der Job gibt 40 Zeilen `step N` im Abstand von 0,2 s aus und endet mit Exit-Code 3.
2. Nach 5 Log-Zeilen wird der Agent per `kill -9` beendet. Erwartet: Der Controller meldet innerhalb von 1,5 s `agent_lost`, und der Job läuft weiter.
3. Der Controller wird per `kill -9` beendet und neu gestartet. Erwartet: Der Job-Zustand wird aus dem KV wiederhergestellt, und der Job schreibt offline weiter.
4. Der Agent startet neu, hängt sich an (`reattach`) und sendet das restliche Log.

Geprüft wird: keine geerbten Socket-/KV-fds im Job, dieselbe PID von Anfang bis Ende, Exit-Code 3, genau ein Disconnect, Controller-Log byte-identisch mit `job.log`, alle 40 Zeilen in Reihenfolge.

---

## 6. Grenzen und offene Punkte

- **Browser-Tier vorhanden (§7), aber getrennt:** Login, Account und eine Read-only-Cluster-Ansicht laufen im WASM-Client gegen `cosmosd` (ws/wss). Controller-Jobs/Pipelines sind in die Cluster-Sicht verdrahtet (§7.3) und werden live an authentifizierte Clients gepusht (§7.4) — kein Poll mehr. Weiter offen: mehr Control-Plane-Aktionen (Jobs vom Browser aus starten/abbrechen).
- **Ein Job pro Controller:** Es gibt keine Queue und keine Zuteilung nach Labels. Der Agent führt ebenfalls nur einen Job aus.
- **Nur `127.0.0.1`:** Listen- und Connect-Adresse sind fest eingetragen. Es gibt kein TLS und keine Authentifizierung der Agents.
- **Server und Controller sind getrennt:** Pipelines/Workloads aus dem Server erzeugen noch keine Jobs im Controller.
- **Log-Handling:** Das Log liegt vollständig im `JobRecord` und wird vom Agent bei jedem Update komplett gelesen. Das reicht für kleine Logs, für große braucht es Chunk-Dateien und Offsets ab Dateiposition.
- **Kein Test für reinen Netzabbruch:** Der Probe beendet den Agent-Prozess. Der Fall „Agent lebt, nur die Verbindung bricht ab“ ist implementiert (Reconnect-Zweig), aber nicht getestet.
- **PID-Wiederverwendung:** Wird die PID zwischen zwei Agent-Starts neu vergeben, erkennt `sys.process_attach` das nicht (aiml spec/23 §5.4).
- **Alte Problemnotizen:** `doc/issues/2026-05-29_sys_exec_remote_agent_execution_gaps.md` ist teilweise überholt, weil Jobs über `sys.exe` laufen, nicht über `sys.exec`/Code-Bundles. Die beiden anderen Notizen sind weiter offen.

---

## 7. Browser tier — login, account, cluster view (ported from 9rooms)

A second, independent tier serves a WebSocket + WASM browser client with real accounts. It reuses
9rooms' proven auth/session infrastructure (not its card game).

| Binary | Config | Entry | Zweck |
|---|---|---|---|
| `cosmosd` | `exodus-cosmosd.json` | `sources/server/daemon_main.aiml` (`CosmosDaemon`) | ws/wss listener: auth + logout + token-gated cluster read |
| `static` | `exodus-static.json` | `client/web/static_main.aiml` | HTTP(S) host for `out/client/`, `/servers.json`, `/log` |
| `client` | `exodus-client.json` | `client/main.aiml` (`CosmosApp`) | WASM browser client: login → menu → cluster |

```
browser ── http(s) ─▶ static (:8080/:8443)  serves client.{html,js,wasm,data} + /servers.json
   │
   └──── ws(s) ──────▶ cosmosd (:8765)  submit_login/register, validate_token, logout,
                                        set_nickname/change_password/change_email, get_cluster
                                        └─ AuthService (users/tokens/token_meta/throttle/ip_bans KV)
                                        └─ ClusterBootstrap.snapshot() → ClusterView
```

- **Client flow:** `CosmosApp.init` connects (`net_connect`), tries auto-login with the stored token
  (`validate_token`), else shows `LoginScreen`. After login the menu offers **Cluster** (read-only nodes/workloads/pipelines/jobs, **live** via `subscribe_cluster` + server push, §7.4) and **Account** (change email/password); **Logout**
  invalidates the token server-side and returns to login.
- **Token storage:** `storage.*` → `localStorage` in the browser, `storage.json` natively (keys
  `cosmos_token`/`cosmos_email`).
- **Server discovery:** the client fetches `/servers.json`; the static host derives the game URL
  from the `Host` header (scheme follows TLS), so a phone on the LAN reaches the right server.
- **Native build:** `exodus-client-native.json` builds the same client as a desktop window (for
  compile-checks / local use); the browser build is the WASM one.

### 7.1 Security (ported 1:1 + gaps closed)

Carried over from 9rooms `doc/security_hardening.md`:
- **Passwords:** PBKDF2-HMAC-SHA256, 100k iterations, per-user random salt (`pbkdf2$salt$derived`);
  legacy sha256 hashes are rehashed on next login; constant-time compare.
- **Tokens:** 256-bit CSPRNG (`math.random_hex`), single session per account (new login invalidates
  older tokens).
- **Login throttle + IP ban:** 3–4 fails → 60 s, 5th → 1 h, 6th → permanent IP ban (keyed by the
  trusted `session.peer_ip`, not client-supplied data).
- **TLS:** `wss://`/`https://` via env cert/key (`--tls` dev cert, Let's Encrypt in prod), hardened
  TLS defaults (min TLS 1.2).
- **Transport:** fixed the unauthenticated WS-frame-overflow crash in the aiml runtime (a forged
  oversized frame length; `tests/test_ws_oversized_frame.aiml`) — the reader now caps frame size.

Gaps from that report, now closed in cosmos:
- **Token expiry:** server-side 24 h TTL (`SessionToken` in `token_meta` KV); `validate_token`
  rejects and deletes expired tokens.
- **Server-side logout:** `logout` RPC invalidates token + meta (client-only clearing was a gap).
- **Password policy:** registration requires ≥ 6 characters, server-side.
- **Register flood:** per-IP registration rate-limit (escalating cooldown), plus the IP-ban check.

### 7.2 Run

```bash
./run_web.sh --build        # build cosmosd + static + WASM client, then start cosmosd + static
./run_web.sh --tls          # same, self-signed dev cert → https:8443 + wss:8765
# open http://127.0.0.1:8080/
./run_prod.sh --build|--systemd|--run   # Let's Encrypt + systemd units (set DOMAIN in prod.env)
```

Tests (no display), gebündelt über `./run_tests.sh`:
- `test/test_auth_cluster.aiml` — register/login/validate/logout, token expiry, password policy,
  per-IP register throttle, cluster snapshot.
- `test/test_agent_exec.aiml` — AP1-Logik: Ausgabe-Ablage (getrennte Ströme, byte-exakte Fenster,
  Lesen während des Laufs, 200 KB ohne Akkumulation) + Agenten-Registry/Routing.

AP1-Abnahme end-to-end (cosmosd + Agent + Testclient, selbst-terminierend):
```bash
./run_e2e.sh                # Agent erscheint live, Kommando mit cwd, stdout/stderr getrennt, Exit-Code
./run_mem_check.sh          # Kriterium 10(b): Server-RSS skaliert NICHT mit der Ausgabelänge
```

### 7.2a AP1 — Agenten verbinden und Kommandos ausführen (doc/spec/90)

```bash
./run_web.sh --build               # cosmosd + static + WASM-Client
# Browser → Login → "Agenten" → "Agent-Tokens" → Bezeichnung + "Erzeugen"
#   → das Token erscheint EINMAL, samt fertiger Startzeile; jetzt kopieren.
COSMOS_AGENT_TOKEN=<kopiertes Token> ./agent --exec-url ws://127.0.0.1:8765 --agent-id builder-1
# oder:  ./agent --exec-url … --agent-id builder-1 --agent-token-file token.txt
# oder:  ./agent --exec-url … --agent-id builder-1 --agent-token <Token>   (per ps sichtbar)
# Browser → "Agenten": Live-Liste, Kommando + Arbeitsverzeichnis, Ausgabe live
```
Die Agent-Tokens werden **im Web-UI erzeugt** (doc/spec/90 §AP1.9) und sind einzeln widerrufbar;
cosmosd speichert davon nur `sha256(secret)` — das Geheimnis ist nach dem Erzeugen nicht mehr
abrufbar.  Der Agent nimmt es aus `--agent-token`, `--agent-token-file` oder `COSMOS_AGENT_TOKEN` (in dieser
Rangfolge).  `--agent-token` ist bequem, steht aber in der Prozessliste (`ps`) — der Agent warnt
dann; `--agent-token-file` zeigt dort nur den Pfad.
Ohne gültiges, nicht widerrufenes Token wird JEDE Registrierung abgelehnt (fail closed).
Ohne `--exec-url` läuft derselbe Agent weiter im durable-Job-Modus am tcp-Controller.
⚠️ Remote-Shell = RCE: nur eigene, vertrauenswürdige Agenten, nicht als root (doc/spec/90 §AP1.6).

### 7.3 Step 2 — pipelines ↔ durable jobs wired into the cluster view

The controller/agent durable-job world and the cluster view are now connected through the shared
`jobs` KV (one writer: the controller/agent; `cosmosd` reads only).

- `PipelineRun.produced_job_id` links a pipeline to the durable job that runs its deploy
  (`pipeline-api-main` → `job-deploy-api`, seeded by `ClusterBootstrap`).
- `ClusterView` carries `jobs: list<JobRecord>`; `ClusterBootstrap.snapshot` calls
  `db.reload_kv` on the shared `jobs` KV (cross-process visibility, spec/31 §6.5) and lists the
  controller's `JobRecord`s. `get_cluster` serves them, and the client shows a **Jobs** section
  (id, state, pid, exit, disconnects) next to workloads/pipelines.
- **Operate:** run the controller/agent on the pipeline's job id, sharing `AIONDB_PATH` with
  `cosmosd`:
  ```bash
  AIONDB_PATH=$PWD/aiondb ./controller --job-id job-deploy-api --command "…" --exit-when-done &
  AIONDB_PATH=$PWD/aiondb ./agent --agent-id deployer
  ```
  The browser cluster view then reflects that job live (queued → running → finished).
- Verified cross-process: controller+agent finish `job-deploy-api` (exit 0) in a shared AIONDB, a
  separate `snapshot` reader sees it (state finished). Same-process coverage in the logic test
  (`snapshot includes job`, `pipeline links to job`).

### 7.4 Live updates — authenticated server push (no polling)

Instead of the client polling, the server pushes `ClusterView` to **authenticated subscribers**
when the cluster/job state changes — security-correct (Mirror `sync:`/`register` would broadcast
to every connected peer, including unauthenticated ones; a token-gated push does not).

- **Subscribe:** after login the client sends `subscribe_cluster` (token-gated). The server checks
  the token, records the sender's `peer_id` in `g_cluster_subs`, and replies with the initial
  `ClusterView`. On `peer_disconnected` the daemon drops that `peer_id`.
- **Push:** the daemon loop (~every 400 ms) snapshots, builds a change signature (node/workload/
  pipeline counts + per-job state/exit/disconnects/updated_ms); on change it `send_rpc`s
  `cluster_update` (the `ClusterView` payload) to each subscriber — targeted, never broadcast.
- **Client:** each frame drains `poll_rpc` (`net_drain_cluster_pushes`); a `cluster_update`
  decodes into the global `g_live_cluster` and bumps `g_live_cluster_seq`. The cluster screen
  re-renders when the seq changes. The refresh button remains an explicit one-shot `get_cluster`.
- Verified end-to-end: login → subscribe (initial snapshot, nodes=3) → a job written to the shared
  KV by another process → daemon detects the change and pushes → client receives it (~400 ms,
  jobs 0→1) with no timer poll.
