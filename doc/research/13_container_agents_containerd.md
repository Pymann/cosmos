# 13 — Pod als Agent: containerd, und ob der Docker-Client nötig ist

**Frage (User, 2026-10-18):** Wie schwierig ist es, einen Pod zu schedulen und als Agent zu
verbinden — so wie Kubernetes und Jenkins es im Zusammenspiel tun?  Engine soll **containerd**
sein.  Kann man auf den **Docker-Client** ganz verzichten?

**Kurz:** Auf den Docker-Client ja, vollständig und ohne Ersatz-Schmerz.  Für den ersten
Schritt braucht man sogar containerd nicht.  Der schwierige Teil ist weder Docker noch
containerd — es ist, dass **aiml mit containerd nicht sprechen kann** (unten §2), und dass
der Container allein **keine Vertrauensgrenze** ist (04).  Das eigentliche „Pod schedulen und
andocken" ist in cosmos erstaunlich klein, weil der Agent **zieht** statt zugeteilt zu werden.

---

## 1. Die Schichten, und wo Docker wirklich sitzt

```
docker CLI ──REST/unix──> dockerd ──gRPC──> containerd ──shim──> runc/crun ──> Namespaces+cgroups
nerdctl    ─────────────────────────gRPC──> containerd ──shim──> runc/crun
kubelet    ──────────CRI (gRPC)────────────> containerd
cosmos?    ─────────────────────────────────────────────────────> crun (OCI-Bundle, kein Daemon)
```

- **Docker ist eine Schicht ÜBER containerd**, kein Unterbau.  `dockerd` liefert Ergonomie
  (build, compose, Netzwerk-Komfort, Registry-Logins) und spricht selbst containerd.
- **containerd** ist der Daemon: Image-Store (content + snapshotter/overlayfs), Container-
  Lebenszyklus, Shims.  Seine Schnittstelle ist **gRPC über `/run/containerd/containerd.sock`**.
- **runc/crun** sind die OCI-Runtimes: sie bekommen ein **Bundle** (ein Verzeichnis mit
  `config.json` + `rootfs/`) und erzeugen daraus Namespaces, cgroups, seccomp.  Kein Daemon,
  keine Registry, kein Netzwerk-Plugin.

**Antwort auf die Docker-Frage:** Der Docker-Client wird nirgends gebraucht — weder zum
Starten, noch zum Bauen (BuildKit/buildah/kaniko), noch für Registries (OCI-Distribution ist
ein offener HTTP-Standard, den aiml mit seinem HTTP/TLS-Stack selbst sprechen kann).  Wer
Docker-Ergonomie will, nimmt **nerdctl** (gehört zur containerd-Familie, gleiche
Kommandos, rootless-fähig).  `ctr` liegt containerd bei, ist aber ausdrücklich ein
**Debug-Werkzeug mit instabiler Oberfläche** — für Skripte nur hinter einem Adapter und mit
gepinnter Version.

## 2. Der harte Befund: aiml kann containerd nicht ansprechen

Am Repo geprüft, nicht geraten:

| gebraucht für containerd | aiml-Stand |
|---|---|
| HTTP/2 | **fehlt** — `spec/32_2 §` nennt es „long-term extension" |
| protobuf | **fehlt** (es gibt `sys.serialize`/JSON, kein protobuf) |
| Unix-Domain-Sockets | **nicht in der Netz-Spec** (32_1…32_6 sind TCP/TLS/WS/SSH) |
| gRPC | folgt aus den ersten beiden: **fehlt** |

Daraus folgen genau drei Wege — und die Wahl zwischen ihnen ist die eigentliche
Architekturentscheidung, nicht „Docker ja/nein":

| Weg | Wie | Kosten | Risiko |
|---|---|---|---|
| **A — OCI-Runtime direkt** | `crun` mit selbst geschriebenem `config.json` via `sys.exe` | klein; kein Daemon, kein Image, keine Registry | Image-Verteilung und Layer-Cache muss cosmos selbst (hat es mit CAS ohnehin vor, 02/03) |
| **B — containerd über CLI** | `nerdctl`/`ctr` via `sys.exe`, Ausgabe als JSON parsen | mittel | **CLI-Ausgabe ist ein Vertrag, der driftet** (`ctr` gibt ihn nicht einmal) |
| **C — gRPC erreichen** | HTTP/2+protobuf in aiml, oder ein Go/C-Helfer neben dem Agenten | groß | widerspricht „Agent bleibt minimal" (04); Fremdsprache im Ausführungspfad |

**04 hat diesen Weg schon einmal gewählt** (crun/youki via `sys.exe`, „kein FFI nötig") — die
containerd-Frage führt also zurück auf eine bereits getroffene Entscheidung.  Was containerd
*zusätzlich* brächte, ist klar benennbar: **Images aus Registries, Snapshotter/Layer-Cache,
Aufsicht über viele Container, CRI-Kompatibilität**.  Keines davon wird für „einen Agenten in
einer Sandbox starten" gebraucht; alle werden interessant, sobald **Job-Images** das Thema
sind (06) — und dann konkurriert containerd mit der CAS-Materialisierung aus 02/03, die
cosmos ohnehin baut.

## 3. Was „Pod schedulen und als Agent verbinden" in cosmos heißt

Das Vorbild (Jenkins + Kubernetes) besteht aus vier Teilen.  Drei davon hat cosmos schon:

| Teil | Jenkins/K8s | cosmos heute | fehlt |
|---|---|---|---|
| Agent dockt **ausgehend** an | JNLP-Inbound-Agent mit Secret | `./agent --exec-url ws://… --agent-token-file …` (`agent_main.aiml`) | — |
| Registrierung + Anwesenheit | Pod-Status + Agent-Registry | `agent_registry`, `online` vom Server entschieden (F104-3), Heartbeat + Last (109) | — |
| Arbeit zuteilen | Scheduler platziert Pod, Jenkins gibt Build | **Agent ZIEHT** (`claim_step`, doc/spec/103 F103-2) | — |
| Pod **erzeugen** | kube-scheduler + kubelet | SSH-Provisionierung eines **dauerhaften** systemd-Dienstes (15 Schritte) | **das ist die Lücke** |

Der Pull-Betrieb ist hier ein Vorteil: ein frisch gestarteter Agent braucht **keine**
Zuteilung, er meldet sich und greift zu.  Es fehlt nur die Entscheidung *„es liegt Arbeit an,
für die kein freier Agent da ist → starte einen"* — bei Jenkins genau die Aufgabe des
kubernetes-Plugins.  Ein Scheduler im K8s-Sinn (Filter→Score über Knoten, 07) ist dafür
**nicht** nötig; er wird erst gebraucht, wenn mehrere Hosts im Spiel sind.

> **Abweichung zum Notieren:** 07 plant Zuteilung per Filter→Score (Push), doc/spec/103 hat
> sich für Pull entschieden und die Implementierung folgt 103.  Für Pod-Agenten ist Pull
> günstiger; 07 sollte das aufnehmen, statt dass beide Dokumente nebeneinander gelten.

### Was der Container ERSETZT

Die heutige Provisionierung baut von Hand nach, was eine OCI-Runtime liefert: eigener
Dienst-Nutzer, `subuid`-Bereich, AppArmor-Profil für `userns`, bubblewrap-Sandkasten,
Isolations-Selbsttest.  Mit Container-Agenten entfallen `service_user`, `subuid_range`,
`install_profile`, `apparmor_reload`, `install_unit`, und die Schritt-Isolation (`bwrap`,
`agent_isolation.aiml`) wird zur Container-Grenze.  **Die Einrichtung wird kleiner, nicht
größer** — vorausgesetzt, auf dem Host liegt eine Runtime.

## 4. Was neu zu bauen ist (Größenordnung)

| Baustein | Inhalt | Schätzung |
|---|---|---|
| `ContainerLauncher` (aiml) | OCI-`config.json` erzeugen (`sys.serialize`), rootfs-Bundle legen, `crun run --detach`, PID/Exit einsammeln, `crun delete` | ~250–350 Zeilen + Tests |
| Ephemeres Token | `AgentToken` um **TTL + one-shot** erweitern, Widerruf beim Pod-Ende | klein — aber **neues Feld = KV-Fingerprint** (F108-2): Migration mitplanen |
| Kapazitäts-Schleife | „offene Schritte ohne freien Agenten" → starten; Leerlauf-Agent → beenden; Obergrenze je Host | ~150 Zeilen, rein rechnerisch (ohne Fenster testbar) |
| Einsammeln | Exit-Code, Logs (stdout/stderr des Containers), Waisen beim Daemon-Neustart | ~150 Zeilen; hängt am durable Job (05) |
| Host-Vorbereitung | crun (oder containerd+nerdctl) installieren, cgroup-v2-Delegation, rootless-Netz | **nicht Code, aber der zeitfressende Teil** |

**Auf diesem Rechner ist nichts davon installiert** (`containerd`, `ctr`, `nerdctl`, `crun`,
`runc`, `podman`, `docker`, `rootlesskit`, `slirp4netns` — alle nicht vorhanden).  Der erste
Meilenstein ist deshalb nicht Code, sondern: *einen Container von Hand starten, der den
cosmos-Agenten ausführt und sich beim Controller meldet.*

## 5. Was wirklich schwierig ist (nach Risiko sortiert)

1. **Rootless-Betrieb.**  Rootless *crun* ist überschaubar; **rootless containerd** verlangt
   `containerd-rootless-setuptool.sh`, eine systemd-User-Instanz, `slirp4netns` und
   cgroup-v2-Delegation.  Das ist der Punkt, an dem containerd deutlich teurer ist als die
   nackte Runtime.
2. **Netzwerk.**  Der Agent braucht nur **ausgehend** zum Controller.  Damit entfällt CNI
   komplett: `--net host` (oder rootless slirp) genügt.  Wer später eingehende Dienste in
   Containern will, holt sich die ganze K8s-Netzwerkfrage ins Haus.
3. **Aufräumen.**  Ein Pod, der nach dem Job nicht verschwindet, ist ein Leck mit Rechten.
   Es braucht einen Reaper beim Daemon-Start (Container mit cosmos-Label ohne lebenden Job →
   weg) und Token-Widerruf als Teil des Abbaus — genau wie `deprovision` es heute macht.
4. **Vertrauensgrenze.**  04 ist hier unmissverständlich: ein Container ohne Sandbox ist
   keine Grenze.  Für fremden Code bleibt Kata/gVisor die Auflage; für eigene,
   vertrauenswürdige Nutzer ist rootless+userns vertretbar — dieselbe Linie, die heute schon
   gilt.
5. **CLI-Vertrag.**  Jede Variante über `sys.exe` bindet sich an Ausgabeformate.  Deshalb
   gehört genau **eine** Adapterklasse zwischen cosmos und das Werkzeug, mit einem Test, der
   gegen die echte Binärdatei läuft — sonst wandert der Bruch unbemerkt in die Laufzeit.

## 6. Empfehlung

**Stufe 1 — Agent im Container, ohne containerd.**  `crun` + selbst erzeugtes OCI-Bundle,
rootfs = Verzeichnis mit Agent-Binary und `libaiml` (die Provisionierung legt beides heute
schon ab).  Kein Daemon, kein Image, kein gRPC, kein Docker.  Damit ist „Pod schedulen und
andocken" erreichbar, weil Token, Anmeldung, Registry und Pull-Dispatch bereits stehen.
*Abnahme:* Ein Lauf, der keinen freien Agenten findet, startet einen Container-Agenten, der
Schritt läuft darin, der Container ist danach weg und das Token ungültig.

**Stufe 2 — containerd, wenn Images das Thema werden.**  Sobald Jobs in benannten Images mit
Werkzeugketten laufen sollen (06), zieht containerd ein: Pull, Snapshotter, Layer-Cache,
gesteuert über **nerdctl** hinter dem Adapter aus Stufe 1.  Dann ist auch die Frage zu
entscheiden, ob Images oder die CAS-Materialisierung (02/03) der kanonische Weg sind —
**beides nebeneinander wäre die zweite Wahrheit**, die dieses Projekt schon zweimal teuer
bezahlt hat.

**Stufe 3 — Isolationsstufen.**  Kata/gVisor als wählbare Stufe je Mandant (04), erst wenn
fremde Nutzer zugelassen werden.

Der Docker-Client taucht in keiner der drei Stufen auf.
