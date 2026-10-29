# Cosmos

`Cosmos` ist ein AIML-basiertes Kontrollsystem, das Ideen aus Kubernetes,
Jenkins und klassischen Build-Node-Farmen zusammenführt.

Die Produktentscheidung ist bewusst:

- keine klassische HTML-/CSS-/Formular-UI als Hauptoberflaeche
- keine DOM-zentrierte App-Architektur
- stattdessen reine AIML-/OpenGL-ES-/WebGL-Szene
- Synchronisation und Live-Zustand ueber Mirror

Der erste Stand ist bewusst als Backend-/Control-Plane aufgebaut, aus drei Programmen
(Details: [doc/architecture.md](doc/architecture.md)):

- `server`: legt einen Demo-Cluster an (`Node`, `Workload`, `PipelineRun`) und verteilt
  Workloads nach Label und Kapazität auf Nodes, persistent im KV.
- `controller`: vergibt einen Job an einen Agent und führt dessen Zustand (Log, PID,
  Exit-Code, Disconnects) persistent, sodass Agent- und Controller-Abstürze überstanden werden.
- `agent`: führt den Job als dauerhaften Prozess aus (aiml `sys.exe` mit `detach`),
  streamt das Log zum Controller und hängt sich nach Abbrüchen wieder an.

## Browser-Client (WASM) + Login

Zweites Tier (aus 9rooms übernommen, ohne Kartenspiel): ein WASM-Browser-Client mit echten
Accounts gegen `cosmosd` (ws/wss). Nach dem Login gibt es eine Read-only-Cluster-Ansicht (live per authentifiziertem Server-Push aktualisiert) und
Account-Einstellungen. Security 1:1 aus 9rooms (PBKDF2, Zufalls-Tokens, Login-Throttle/IP-Bann,
TLS) plus geschlossene Lücken (Token-Ablauf, serverseitiges Logout, Passwort-Policy,
Register-Ratelimit). Details: [doc/architecture.md](doc/architecture.md#7-browser-tier--login-account-cluster-view-ported-from-9rooms).

```bash
./run_web.sh --build      # cosmosd + static + WASM-Client bauen, dann starten
# Browser: http://127.0.0.1:8080/    (--tls für https:8443 + wss:8765)
```

## Zielbild

Später kann daraus werden:

- Scheduler für Workloads ähnlich Kubernetes
- Build-/Deploy-Pipelines ähnlich Jenkins
- Persistente Cluster-State-Datenbank
- grafische OpenGL-Observability fuer Cluster, Agenten und Pipeline-Laeufe
- Policies, Health-Checks, Rollouts und Queue-Management
- Mirror-synchronisierte verteilte Agenten und Steuerknoten

## Start

```bash
source ../../exvenv/bin/activate
exodus build -c exodus-server.json && ./server          # oder: ./run.sh --build
exodus build -c exodus-controller.json
exodus build -c exodus-agent.json
./controller --port 19870 --job-id job-1 --command "echo hi; sleep 2" --exit-when-done &
./agent --port 19870 --agent-id agent-1
```

## Probe: Agent-Disconnect (durable Job)

```bash
probe/agent_disconnect.sh --build
```

Startet Controller und Agent und beendet dann Agent und Controller per SIGKILL und startet sie neu.
Geprüft wird: Der Job läuft weiter, der Controller hält den Zustand persistent im KV
(`agent_lost`, Log-Offset), der Agent hängt sich nach dem Neustart wieder an, und Log und
Exit-Code kommen vollständig an. Die Logs liegen unter `out/probe/agent_disconnect/`,
der Ablauf ist in [doc/architecture.md](doc/architecture.md#5-probe-probeagent_disconnectsh) beschrieben.
