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

Die Projektkonfigurationen nehmen Compiler und Laufzeit aus einer **aiml-venv**
(`$AIML`, `$AIML_VENV/lib`; aiml spec/68 F68-23) — gebaut wird also mit dem
Compiler, neben dem das Programm liegen wird, nicht ueber einen Pfad in einen
fremden Baubaum.  Die `run_*.sh` aktivieren `../../aimlvenv` von selbst, wenn
keine venv aktiv ist; von Hand:

```bash
aiml venv ../../aimlvenv        # einmal, mit dem gebauten Compiler
. ../../aimlvenv/env
```

```bash
aiml build -c exodus-server.json && ./server            # oder: ./run.sh --build
aiml build -c exodus-controller.json                    # aiml spec/68 §7, ohne exodus
aiml build -c exodus-agent.json
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

## Lizenz

cosmos ist **kein Open Source**, sondern *source-available* unter der
[Pymann Commercial Source License 1.0](LICENSE)
(`LicenseRef-Pymann-Commercial-1.0`). Lesen, Evaluieren (bis 30 Tage) und
private, nicht kommerzielle Nutzung sind frei. Jeder produktive Einsatz braucht
eine kommerzielle Lizenz: **5.000 € pro Jahr** je Organisation (zzgl. USt.).
Kontakt über [github.com/Pymann](https://github.com/Pymann).

Abhängigkeiten wie aiml und exodus behalten ihre eigenen Lizenzen (MIT).
