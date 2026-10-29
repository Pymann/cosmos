# Ökosystem-Karte: cosmos · ufo · kontor (· aiml/exodus)

Stand 2026-10-29.  Diese Datei **zeigt** das Zusammenspiel; die Verträge stehen woanders und
gehen vor: kontor `doc/ecosystem.md` (Wire-Formate), [spec/111](spec/111_ecosystem.md) (cosmos'
Hälfte), [spec/96](spec/96_layer_cache.md) und [spec/110](spec/110_runtime.md) (Schichten,
Laufzeit), ufo `README.md` / `doc/kit.md` (Schichten als Git-Commits, Layer-Kit), aiml
`spec/62` (Pipelines) und `spec/68` (venv).

**Legende** (gilt für alle Flussdiagramme): durchgezogene Kante = gebaut und getestet,
gestrichelte Kante `-.->` = geplant oder nur teilweise da; `⟨…⟩` an einer Kante nennt das
Protokoll bzw. den Befehl.

| Diagramm | Frage |
|---|---|
| [1 Gesamtbild](#1-gesamtbild) | Wer ist was, und wer redet mit wem? |
| [2 Use-Case-Karte](#2-use-case-karte) | Was kann wer tun — und in welchem System passiert es? |
| [3 Lebenslauf einer Schicht](#3-lebenslauf-einer-schicht) | Wo reist ein Stufen-Ergebnis überall hin? |
| [4 Pipeline-Lauf](#4-pipeline-lauf-end-to-end) | Was passiert zwischen „einreichen" und „Abbild in kontor"? |
| [5 Schritt-Entscheidung](#5-ein-schritt-ausführen-oder-wiederverwenden) | Wann läuft ein Schritt, wann wird er wiederverwendet? |
| [6 Rebuild-Kampagne](#6-rebuild-kampagne) | Eine Bibliothek ändert sich — was wird neu gebaut? |
| [7 Kampagnen-Posten](#7-zustände-eines-kampagnen-postens) | Zustände eines Postens |
| [8 Identität](#8-identität-und-zugriff) | Wie meldet man sich an, und wie reden Maschinen miteinander? |
| [9 Config as Code](#9-config-as-code-und-katalog) | Wie wird cosmos aus Dateien konfiguriert? |
| [10 aiml-venv-Kette](#10-vom-nackten-ubuntu-zur-aiml-venv-und-weiter) | Wie entsteht die Werkzeug-Schicht, auf der alles baut? |
| [11 Vertrauen](#11-vertrauensgrenzen) | Was wird wo geprüft? |

---

## 1. Gesamtbild

```mermaid
flowchart LR
    %% ── Akteure ─────────────────────────────────────────────
    subgraph ACT["Akteure"]
        dev(["Entwickler:in"])
        ops(["Operator / Admin"])
        rel(["Release-Verantwortliche"])
        ci(["CI / Werkzeug<br/>(API-Token)"])
        ociuser(["OCI-Client<br/>docker · podman · skopeo · oras"])
    end

    %% ── Fremdsysteme ────────────────────────────────────────
    subgraph EXT["Fremdsysteme"]
        ldap[("LDAP-Verzeichnis")]
        idp[("SAML-IdP")]
        gitremote[("Git-Server<br/>(smart HTTP)")]
        ubuntu[("ubuntu-base<br/>Grundabbild")]
    end

    %% ── cosmos ──────────────────────────────────────────────
    subgraph COS["cosmos — Control Plane"]
        direction TB
        web["Web-Client (WASM/WebGL)<br/>Cluster · Pipelines · Jobs · Konsole"]
        api["cosmos-api<br/>REST /api/v1 → RPC"]
        cosmosd["cosmosd<br/>RPC · Auth · Rollen-Gate · KV"]
        casc["CasC-Erklärung<br/>config + catalog"]
        catalog["Katalog → JobDef"]
        campaign["Kampagnen<br/>(aus kontor-Webhooks)"]
        sched["Lauf-Zuteilung<br/>Matrix → Lanes → Schritte<br/>pause · resume · step · rewind"]
        acache["ActionCache / CAS<br/>Schritt-Schlüssel → output_tree"]
        console["Skript-Konsole<br/>(eigener Prozess)"]
        prov["Agent-Einrichtung<br/>(SSH, libssh)"]
        subgraph NODE["Knoten / Wirt"]
            direction TB
            agent["agent<br/>sys.exec(Bundle)"]
            rt["cosmos-rt<br/>Container: userns · seccomp"]
            overlay["overlayfs<br/>lower = Schichten · upper = Stufe"]
            oci["cosmos-oci<br/>Schnitt → OCI-Layout"]
            ckontor["cosmos-kontor<br/>push · pull"]
        end
    end

    %% ── kontor ──────────────────────────────────────────────
    subgraph KON["kontor — Artefakt-Ablage + Abhängigkeitsgraph"]
        direction TB
        reg["/v2/ OCI-Registry<br/>Blobs · Manifeste · Tags"]
        exrepo["/exodus/&lt;name&gt;/&lt;version&gt;/<br/>exodus.json · package"]
        generic["/generic/&lt;pfad&gt;"]
        kgraph["Graph + /api/v1/impact<br/>rebuild_waves · needs · pins"]
        layersapi["/api/v1/layers/&lt;pipeline&gt;[/&lt;lauf&gt;]"]
        hooks["Webhook-Hub<br/>HMAC · Wiederholung · Zustell-Log"]
        kauth["Auth: lokal · LDAP · SAML<br/>Rollen · API-Tokens"]
        cas[("cas/&lt;sha256&gt;<br/>ein Speicher für alles")]
    end

    %% ── ufo ─────────────────────────────────────────────────
    subgraph UFO["ufo — Git-Client + Schichten"]
        direction TB
        ugit["Objekte · Packs · Refs<br/>clone · fetch · push"]
        ulayer["layer commit · apply · diff · log<br/>refs/layers/&lt;pipeline&gt;/&lt;stufe&gt;"]
        uimage["image export · import · push · pull · record"]
        ukit["Layer-Kit: LayerKit<br/>KontorKit · LayoutKit"]
    end

    %% ── aiml / exodus ───────────────────────────────────────
    subgraph TOOL["aiml / exodus — Werkzeuge"]
        direction TB
        aimlc["aiml-Compiler<br/>JIT · Objekte"]
        libaiml["libaiml.so<br/>Laufzeit + LLVM"]
        venv["aiml-venv /opt/aiml<br/>bin · lib · lib/aiml · env"]
        exodus["exodus build<br/>(Python; Ablösung durch aiml-exodus)"]
    end

    %% ── Kanten: Menschen und Werkzeuge ──────────────────────
    dev -->|"Pipeline schreiben, einreichen"| web
    dev -->|"⟨REST⟩ pipelines/run"| api
    ops -->|"config plan/apply"| api
    ops -->|"Agent einrichten"| prov
    ops -->|"Skript"| console
    ci -->|"⟨Bearer⟩"| api
    ci -->|"⟨PUT⟩ package · ⟨/v2/⟩"| KON
    rel -->|"publish.sh ⟨PUT /exodus/…⟩"| exrepo
    ociuser -->|"⟨docker login + Token⟩"| reg
    web -->|"⟨wss RPC⟩"| cosmosd
    api -->|"⟨ws RPC, derselbe Weg wie der Browser⟩"| cosmosd

    %% ── cosmos innen ────────────────────────────────────────
    casc --> cosmosd
    cosmosd --> catalog
    cosmosd --> sched
    cosmosd --> campaign
    campaign -->|"run_job"| sched
    catalog --> sched
    console -->|"Wirt-Angebote"| cosmosd
    prov -->|"agent + Ladekette nach /opt/cosmos"| agent
    sched -->|"⟨RPC⟩ Schritt-Bundle"| agent
    agent --> rt --> overlay
    agent -->|"Schlüssel, Bäume"| acache
    overlay -->|"upper je Stufe"| oci
    oci -->|"oci:&lt;layout&gt;"| ckontor

    %% ── cosmos ⇄ kontor ─────────────────────────────────────
    ckontor -->|"⟨/v2/ push⟩ push: kontor:&lt;repo&gt;:&lt;tag&gt;"| reg
    ckontor -->|"⟨/v2/ push⟩ cosmos-layers/&lt;pipeline&gt;:&lt;lauf&gt;"| reg
    reg -->|"⟨/v2/ pull⟩ image: kontor:…"| ckontor
    hooks -->|"⟨POST /hooks/kontor⟩ package.published · image.pushed"| api
    reg --> cas
    exrepo --> cas
    generic --> cas
    exrepo -->|"exodus.json"| kgraph
    kgraph -->|"Plan"| hooks
    reg -->|"image.pushed"| hooks
    layersapi -.->|"liest Artefakt-Manifeste"| reg

    %% ── ufo ─────────────────────────────────────────────────
    ulayer -->|"Schichten als Commits"| ugit
    ugit -->|"⟨smart HTTP⟩ push/fetch refs/layers/*"| gitremote
    uimage --> ukit
    ukit -->|"KontorKit ⟨/v2/, UFO_REGISTRY_TOKEN⟩"| reg
    ukit -->|"LayoutKit ⟨Verzeichnis⟩"| oci
    uimage -->|"record: eine Schicht je Stufe"| ulayer
    overlay -.->|"ufo layer commit &lt;upper&gt;"| ulayer
    ulayer -->|"layer apply / --upper / --oci"| overlay

    %% ── Werkzeuge ───────────────────────────────────────────
    exodus -->|"baut"| aimlc
    exodus -->|"baut"| libaiml
    aimlc -->|"aiml venv"| venv
    venv -->|"Schicht /opt/aiml"| overlay
    libaiml -->|"in agent · cosmosd · kontor · ufo"| agent
    rel -.->|"exodus deps install (geplant)"| exrepo

    %% ── Identität ───────────────────────────────────────────
    cosmosd -->|"⟨bind/search⟩"| ldap
    kauth -->|"⟨bind/search⟩"| ldap
    cosmosd -->|"⟨SAML POST⟩"| idp
    kauth -->|"⟨SAML POST⟩"| idp
    ubuntu -->|"image: ubuntu-base"| rt

    classDef actor fill:#fdf6e3,stroke:#b58900,color:#333
    classDef ext fill:#eee8d5,stroke:#93a1a1,color:#333
    class dev,ops,rel,ci,ociuser actor
    class ldap,idp,gitremote,ubuntu ext
```

**Lesart.**  cosmos **führt aus**, kontor **bewahrt auf und rechnet Abhängigkeiten**, ufo
**versioniert Dateisysteme** als Git.  Sie reden nur über HTTP miteinander (kontor-Vertrag
§1), und jedes läuft ohne die anderen.  Alle drei sind aiml-Programme auf `libaiml.so`.

---

## 2. Use-Case-Karte

Mermaid kennt kein UML-Use-Case-Diagramm; die Ovale (`([…])`) sind die Use Cases, gruppiert nach
dem System, in dem sie stattfinden.  Eine Kante zwischen Use Cases heißt „nutzt" (include).

```mermaid
flowchart LR
    dev(["👤 Entwickler:in"])
    ops(["👤 Operator / Admin"])
    rel(["👤 Release"])
    ci(["🤖 CI / Werkzeug"])
    kh(["🤖 kontor-Webhook"])
    ag(["🤖 Agent-Knoten"])

    subgraph UC_COS["cosmos"]
        direction TB
        c1(["Pipeline einreichen<br/>run_pipeline · REST"])
        c2(["Pipeline prüfen<br/>Befunde im Editor"])
        c3(["Matrix ausfalten<br/>params · exclude → Lanes"])
        c4(["Lauf steuern<br/>pause · resume · step · rewind · abort"])
        c5(["Lauf beobachten<br/>live, Stage-Graph, Log, 3D-Szene"])
        c6(["Job anlegen / starten<br/>save_job · run_job"])
        c7(["Auf Lauf aufsetzen<br/>base: run:&lt;lauf&gt; · job:&lt;kennung&gt;"])
        c8(["In Abbild bauen<br/>image: name · oci: · kontor:"])
        c9(["Ergebnis ablegen<br/>push: oci: · kontor:"])
        c10(["Schritt wiederverwenden<br/>pure · resolved · Schlüssel"])
        c11(["Konfiguration erklären<br/>config plan · apply · read"])
        c12(["Katalog pflegen<br/>jobs: · from_dir:"])
        c13(["Rollen & Gruppen vergeben"])
        c14(["API-Token anlegen / widerrufen"])
        c15(["Agent einrichten / rückbauen<br/>SSH, einmal sudo"])
        c16(["Skript in der Konsole"])
        c17(["Rebuild-Kampagne führen"])
        c18(["Schritt ausführen<br/>Container, Sandkasten"])
        c19(["Anmelden<br/>lokal · LDAP · SAML"])
    end

    subgraph UC_KON["kontor"]
        direction TB
        k1(["Paket veröffentlichen<br/>exodus.json + package"])
        k2(["Rebuild-Plan abfragen<br/>impact?project= · ?apt="])
        k3(["Abhängigkeitsgraph ansehen"])
        k4(["Abbild push / pull<br/>OCI /v2/"])
        k5(["Lauf-Schichten ablegen<br/>cosmos-layers/&lt;pipeline&gt;"])
        k6(["Stufen eines Laufs ansehen<br/>/api/v1/layers"])
        k7(["Datei ablegen / holen<br/>generic, Range"])
        k8(["Webhook abonnieren · testen<br/>· erneut zustellen"])
        k9(["Nutzer · Tokens · Rollen"])
        k10(["Anmelden<br/>lokal · LDAP · SAML · Basic"])
        k11(["Byte-gleich erkennen<br/>unchanged"])
    end

    subgraph UC_UFO["ufo"]
        direction TB
        u1(["Stufe als Schicht festhalten<br/>layer commit &lt;upper&gt;"])
        u2(["Schichten stapeln<br/>layer apply"])
        u3(["Schichten vergleichen<br/>layer diff · log"])
        u4(["Schichten teilen<br/>push · fetch refs/layers/*"])
        u5(["Abbild aus Schichten<br/>image export-layers · export-dir"])
        u6(["Abbild auspacken<br/>image import"])
        u7(["Abbild ⇄ Registry<br/>image push · pull"])
        u8(["Abbild-Geschichte<br/>image record"])
        u9(["Git-Arbeit<br/>clone · fetch · push · cat-file …"])
        u10(["Als Paket verteilen<br/>package.sh · publish.sh"])
    end

    subgraph UC_TOOL["aiml / exodus"]
        direction TB
        t1(["Compiler + Laufzeit bauen<br/>exodus build"])
        t2(["venv anlegen / aktualisieren<br/>aiml venv &lt;dir&gt;"])
        t3(["Paket importieren<br/>@name/… aus Tabelle"])
        t4(["Abhängigkeiten installieren<br/>exodus deps install (geplant)"])
    end

    dev --- c1 & c2 & c5 & c4 & c7 & c8 & c9 & u1 & u2 & u3 & u9 & t3
    ops --- c11 & c12 & c13 & c14 & c15 & c16 & k8 & k9
    rel --- k1 & k2 & u10 & t1 & t2
    ci --- c1 & c6 & k4 & k7 & u7 & c14
    kh --- c17
    ag --- c18

    c1 --> c2
    c1 --> c3
    c3 --> c18
    c18 --> c10
    c18 --> c8
    c9 --> k4
    c9 --> k5
    c8 --> k4
    c7 -.->|"anderer Wirt: über kontor"| k5
    c17 --> c6
    c17 -->|"needs, Wellen"| k2
    c12 --> c6
    c11 --> c12
    c11 --> c13
    c5 --> k6
    k1 --> k11
    k1 -->|"package.published"| c17
    k5 --> k6
    u5 --> u7
    u7 --> k4
    u8 --> u1
    u4 --> u9
    u10 --> k1
    t2 -->|"Schicht /opt/aiml"| c9
    t4 -.-> k1
    c19 -.-|"selber Vertrag"| k10
```

---

## 3. Lebenslauf einer Schicht

Ein Stufen-Ergebnis ist in jedem System **dasselbe Dateisystem**, nur in einer anderen Form:
overlay-upper (cosmos), Git-Baum mit OCI-Whiteouts (ufo), tar+gzip-Blob (OCI, kontor).

```mermaid
flowchart TB
    subgraph S_RUN["cosmos: Lauf auf einem Wirt"]
        direction TB
        lower["lower: Grundabbild + Schichten<br/>der Vorstufen (+ base:-Stapel)"]
        upper["upper der Stufe<br/>Dateien · Whiteouts c 0:0 · opaque-xattr"]
        key["Schritt-Schlüssel<br/>sha256(source · bindings · needs · host · resolve · image-Digest)"]
        ac[("ActionCache<br/>Schlüssel → output_tree + Rückgabewert")]
        cut["cosmos-oci Schnitt<br/>tar sortiert · mtime fest · uid/gid deklariert"]
        layout[["OCI-Layout auf Platte<br/>oci-layout · index.json · blobs/sha256"]]
        lower --> upper
        upper --> key --> ac
        upper --> cut --> layout
    end

    subgraph S_KON["kontor"]
        direction TB
        img[["Abbild<br/>&lt;repo&gt;:&lt;tag&gt;"]]
        art[["Lauf-Artefakt cosmos-layers/&lt;pipeline&gt;:&lt;lauf&gt;<br/>artifactType run-layers.v1<br/>1 Schicht je Stufe + Annotationen"]]
        kcas[("cas/ — dedupliziert<br/>auch gegen Pakete und Dateien")]
        img --> kcas
        art --> kcas
    end

    subgraph S_UFO["ufo"]
        direction TB
        commit["Layer-Commit<br/>Baum: .wh.&lt;name&gt; · .wh..wh..opq · .ufo-keep<br/>.ufo-attributes: Modi · Eigentümer · Geräte · xattrs"]
        refs["refs/layers/&lt;pipeline&gt;/&lt;stufe&gt;<br/>Eltern = voriger Lauf derselben Stufe"]
        trailers["Trailer: Ufo-Pipeline · Stage · Run · Step<br/>· Agent · Binding · Base"]
        commit --> refs
        commit --- trailers
    end

    subgraph S_USE["wieder verwenden"]
        direction TB
        rootfs["Wurzel-Dateisystem<br/>layer apply &lt;dir&gt; untere … obere"]
        up2["einzelne Schicht, mountbar<br/>layer apply --upper"]
        ocidir["Verzeichnis für tar<br/>layer apply --oci"]
        nextrun["nächster Lauf<br/>image: oci:… · image: kontor:…"]
        stack["Schicht-Stapel ohne Abbild<br/>base: run:&lt;lauf&gt; · job:&lt;kennung&gt;"]
    end

    gitsrv[("Git-Server")]

    layout -->|"push: kontor: ⟨cosmos-kontor⟩"| img
    layout -->|"Lauf-Schichten ⟨cosmos-kontor --artifact-type⟩"| art
    layout -->|"image: oci:&lt;pfad&gt;"| nextrun
    img -->|"pull ⟨rt_launcher.pull_kontor⟩<br/>nur fehlende Blobs"| nextrun
    ac -->|"Treffer: Schritt läuft nicht"| upper
    upper -->|"selber Wirt, selbes Grundabbild"| stack

    upper -.->|"ufo layer commit (in einer Stufe)"| commit
    layout -->|"ufo image record --pipeline"| commit
    refs -->|"ufo push … refs/layers/*"| gitsrv
    gitsrv -->|"ufo fetch / git fetch"| refs
    refs --> rootfs
    refs --> up2
    refs --> ocidir
    refs -->|"ufo image export-layers"| layout
    img -->|"ufo image pull ⟨KontorKit⟩"| layout
    layout -->|"ufo image push ⟨KontorKit⟩"| img
    layout -->|"ufo image import"| rootfs
    art -.->|"fremde Schicht nur als Abbild,<br/>nie als Cache-Treffer (F110-121)"| nextrun
```

---

## 4. Pipeline-Lauf, End-to-End

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Entwickler:in
    participant API as cosmos-api
    participant D as cosmosd
    participant AG as agent (Knoten)
    participant RT as cosmos-rt
    participant K as kontor
    participant H as kontor-Webhook-Hub

    Dev->>API: POST /api/v1/pipelines/run (Quelltext, Bearer)
    API->>D: run_pipeline (RPC, derselbe Weg wie der Browser)
    D->>D: Rollen-Gate (may run_pipeline?)
    D->>D: prüfen: Schlüssel, image:, push:, requires:, Befunde
    alt Befunde
        D-->>API: Fehler + Zeilen
        API-->>Dev: 422 {"error","code"}
    end
    D->>D: Matrix ausfalten (params × … − exclude) → Lanes
    D->>D: base: job:X → jüngster fertiger Lauf → run:N (festgeschrieben)
    D-->>Dev: run_id (live per Push sichtbar)

    loop jede Lane, jede Stufe (Zuteilung nach label/runs_on, wenig ausgelastet zuerst)
        D->>AG: nächster Schritt als Bundle
        alt image: kontor:<repo>:<tag>
            AG->>K: GET /v2/<repo>/manifests/<tag> + fehlende Blobs
            K-->>AG: Manifest + Blobs (Digest geprüft)
        end
        AG->>RT: Container (userns, seccomp, Grenzen je Stufe)
        RT->>RT: overlay: lower = Abbild + Vorstufen + base:-Stapel
        AG->>D: Schritt-Schlüssel (inkl. resolve-Probe, image-Digest)
        alt Treffer im ActionCache
            D-->>AG: output_tree + Rückgabewert (Erfolg ohne Ausführung)
        else kein Treffer / opaque
            RT->>RT: run: im Sandkasten → upper der Stufe
            AG->>D: output_tree, Status, Log-Strom
        end
        opt pause_run
            Dev->>API: POST /runs/:id/pause
            API->>D: pause_run → Zuteilung hält an (dauerhaft im Lauf)
        end
    end

    opt push: { from: <stufe>, to: kontor:<repo>:<tag> }
        AG->>AG: cosmos-oci: Schnitt nach <stufe> → OCI-Layout
        AG->>K: cosmos-kontor --mode push (Token per Datei/Env)
        K-->>AG: Digest
        K->>H: image.pushed
        H->>API: POST /api/v1/hooks/kontor (HMAC)
        API->>D: kontor_event (einmal je Delivery)
    end
    D-->>Dev: Lauf fertig (Status je Lane, Rangfolge)
```

---

## 5. Ein Schritt: ausführen oder wiederverwenden

```mermaid
flowchart TD
    start(["Schritt einer Lane ist dran"]) --> paused{"Lauf angehalten?"}
    paused -->|"ja"| wait["keine Zuteilung<br/>(laufende Schritte dürfen fertig werden)"] --> paused
    paused -->|"nein"| cls{"cache: ?"}
    cls -->|"opaque (Vorgabe)"| run
    cls -->|"resolved"| probe["resolve:-Probe läuft immer<br/>git ls-remote · apt-Version · Tag → Digest"]
    cls -->|"pure"| keyb
    probe --> keyb["Schlüssel bilden<br/>Quelle wie geschrieben · deklarierte Bindungen<br/>· needs-Schlüssel · host: · Probe · image-Digest"]
    keyb --> hit{"Schlüssel im ActionCache?"}
    hit -->|"ja"| reuse["output_tree + Rückgabewert übernehmen<br/>Status: Erfolg ohne Ausführung"]
    hit -->|"nein"| run["ausführen im Sandkasten<br/>(Container, eigener upper)"]
    run --> ok{"Ergebnis"}
    ok -->|"Erfolg"| store["output_tree speichern<br/>(nur pure/resolved)"]
    ok -->|"Fehlschlag"| onfail{"on_fail:"}
    onfail -->|"lane"| stoplane["nur diese Lane endet"]
    onfail -->|"pipeline"| stopall["Server hält alle Knoten an<br/>(F96-10)"]
    onfail -->|"continue"| next
    store --> next(["nächster Schritt / nächste Stufe"])
    reuse --> next
    trust{{"Treffer stammt von fremdem Wirt?"}}
    hit -.-> trust
    trust -.->|"layer_trust none: nur same_host"| run
```

---

## 6. Rebuild-Kampagne

kontor rechnet **was** von was abhängt, cosmos entscheidet **wann** es läuft.

```mermaid
sequenceDiagram
    autonumber
    actor R as Release / CI
    participant K as kontor
    participant G as Graph
    participant H as Webhook-Hub
    participant API as cosmos-api
    participant D as cosmosd
    participant C as Kampagne
    participant J as Katalog-Jobs

    R->>K: PUT /exodus/zlib-lite/1.1.0/exodus.json
    K->>H: manifest.published
    R->>K: PUT /exodus/zlib-lite/1.1.0/package
    K->>K: sha256 = vorige Version?
    alt byte-gleich
        K-->>R: unchanged: true, impact: null
    else geändert
        K->>G: impact(zlib-lite)
        G-->>K: rebuild_waves [[core],[legacy,net],[app]]<br/>needs, outdated_pins, cycles
        K-->>R: Plan
    end
    K->>H: package.published {…, unchanged, impact}
    H->>API: POST /api/v1/hooks/kontor<br/>X-Kontor-Signature-256, X-Kontor-Delivery
    API->>D: kontor_event (Bytes + Kopf unverändert)
    D->>D: HMAC prüfen (zeitkonstant), Delivery schon gesehen? → 200, nichts tun
    alt Kampagne führt das Projekt schon
        D->>C: Posten → published / unchanged
    else neue Kampagne
        D->>C: öffnen: ein Posten je Projekt der Wellen
    end
    C->>J: Projekt → Job (project: + triggers: [kontor])
    J->>D: run_job(core)
    Note over D,C: Daemon-Takt 5 s: run_status der laufenden Posten
    D->>K: core baut und veröffentlicht (Stufe des Laufs)
    K->>H: package.published(core)
    H->>API: Webhook
    API->>D: kontor_event
    D->>C: core → published (oder unchanged)
    C->>C: legacy, net: alle needs fertig → starten
    alt alle needs von app byte-gleich
        C->>C: app → skipped
    else ein needs-Lauf scheitert
        C->>C: Abhängige → blocked (fail closed)
    end
    Note over R,K: outdated_pins: Verbraucher mit festem anderem Pin<br/>werden NICHT gebaut — erst Pin anheben
```

## 7. Zustände eines Kampagnen-Postens

```mermaid
stateDiagram-v2
    [*] --> waiting: Kampagne geöffnet
    [*] --> no_job: kein Katalog-Job für das Projekt
    no_job --> published: fremde Veröffentlichung kommt an
    no_job --> unchanged: … byte-gleich
    waiting --> running: alle needs fertig (Auslöser zählt als fertig)
    waiting --> skipped: alle needs byte-gleich
    waiting --> blocked: ein needs ist failed/blocked
    running --> published: package.published
    running --> unchanged: package.published, unchanged
    running --> built: Lauf fertig ohne Veröffentlichung (zählt als geändert)
    built --> published: Veröffentlichung kommt nach
    running --> failed: Lauf scheitert
    published --> [*]
    unchanged --> [*]
    built --> [*]
    skipped --> [*]
    failed --> [*]
    blocked --> [*]
```

---

## 8. Identität und Zugriff

Beide Seiten erfüllen **denselben** Vertrag (kontor `doc/ecosystem.md` §6) mit denselben
aiml-Bausteinen (aiml `spec/67`): lokal zuerst, dann Verzeichnis; SAML nur auf eigene Anfrage.

```mermaid
sequenceDiagram
    autonumber
    actor U as Mensch (Browser)
    participant S as cosmos ODER kontor
    participant L as LDAP
    participant I as SAML-IdP
    actor M as Maschine (CI · cosmos · docker)

    rect rgb(240,245,255)
    Note over U,L: LDAP — dieselbe Anmeldemaske / HTTP Basic
    U->>S: Name + Passwort
    S->>S: lokales Konto? (Notfall-Admin)
    alt lokal unbekannt / falsch
        S->>L: bind (DN-Vorlage) oder suchen-dann-binden<br/>Eingabe durch ldap.escape_dn / escape_filter
        L-->>S: ok, mail, memberOf (cn=devs,… → auch "devs")
        S->>S: Konto anlegen falls neu, Gruppen → Rollen
    end
    S-->>U: Sitzung
    end

    rect rgb(245,255,240)
    Note over U,I: SAML 2.0 — SP-initiiert
    U->>S: GET /api/v1/sso/saml/login?relay=/pfad
    S->>S: Anfrage-Kennung merken (einmal, ≤ 10 min)
    S-->>U: 302 → IdP (Redirect-Bindung)
    U->>I: anmelden
    I-->>U: signierte Antwort (POST-Bindung)
    U->>S: POST /api/v1/sso/saml/acs
    S->>S: Signatur (idp_cert_file) · Audience · Destination · Zeitfenster<br/>· keine Umhüllung · eigene offene Anfrage
    S-->>U: 302 relay#35;token=… (nur lokaler Pfad) oder JSON
    end

    rect rgb(255,248,238)
    Note over M,S: Maschinen — API-Tokens
    M->>S: Authorization: Bearer <token> (kontor auch Basic user:token)
    S->>S: sha256(token) nachschlagen → Konto → Rollen
    S->>S: Rollen-Gate: Liste erlaubter Aktionen / RPC-Namen
    S-->>M: 2xx · 401 · 403
    end
```

---

## 9. Config as Code und Katalog

```mermaid
flowchart LR
    file[/"casc.yaml<br/>- config: roles · grants · secrets · kontor · ldap · saml<br/>- catalog: jobs · from_dir"/]
    secrets[/"secrets/*.secret · Env-Variablen<br/>(nur Verweise in der Datei)"/]
    dir[/"ci/*.aiml · ci/*.yaml<br/># project: &lt;name&gt;"/]

    file --> read["lesen (Quellen beim LESEN laden)<br/>unbekannter Schlüssel = Fehler"]
    secrets --> read
    dir --> read
    read --> plan{"config_plan<br/>POST /config/plan"}
    plan -->|"Befunde"| reject["422 — nichts angewandt<br/>(fail closed)"]
    plan -->|"Änderungsliste, berührt nichts"| apply["config_apply<br/>POST /config/apply · COSMOS_CASC beim Start"]
    apply --> kv[("KV casc_config['current']")]
    apply --> jobs["JobDef cat-&lt;name&gt;<br/>+ catalog_meta: project · triggers · source_file"]
    apply --> roles["Rollen = Listen von RPC-Namen<br/>Grants: Nutzer / LDAP-SAML-Gruppe"]
    apply --> kcfg["config.kontor: url · webhook_secret · token<br/>(jede Runde neu gelesen)"]
    jobs --> gone["aus dem Katalog entfernt → enabled: 0<br/>(Läufe bleiben)"]
    kcfg --> wh["Webhook-Prüfung"]
    kcfg --> push["cosmos-kontor push/pull"]
    jobs -->|"triggers: [kontor]"| camp["Kampagnen"]
    apply -->|"zweiter Plan ist leer"| idem(["idempotent"])
    fromcode["from_code: (Generator in aiml)"] -.->|"geplant, F111-5"| jobs
```

---

## 10. Vom nackten Ubuntu zur aiml-venv — und weiter

Die Werkzeug-Schicht entsteht selbst als cosmos-Lauf.  Seit aiml `spec/68` ist ihr Ergebnis eine
**venv** unter `/opt/aiml`, die ohne Wirtspfade, `ldconfig` oder Symlinks auskommt.

```mermaid
flowchart TB
    base[("ubuntu-base")] --> s1

    subgraph P1["Pipeline aiml_vom_base"]
        direction TB
        s1["apt_installieren<br/>gcc · llvm-18 · libssl · …"] --> s2["venv_bauen<br/>/opt/venv (Python)"]
        s2 --> s3["exodus_installieren<br/>pip install . (fest, nicht -e)"]
        s3 --> s4["aiml_klonen · abhaengigkeiten_verknuepfen"]
        s4 --> s5["aiml_bauen<br/>exodus build --all (Python-exodus, einmal)"]
        s5 --> s6["aiml_ablegen<br/>aiml venv /opt/aiml"]
        s6 --> s7["nachweis<br/>. /opt/aiml/env; aiml hallo.aiml"]
    end

    s6 --> venv[["/opt/aiml<br/>bin/aiml (RUNPATH $ORIGIN/../lib)<br/>lib/libaiml.so · lib/aiml/aiml.packages.json · env"]]
    s6 -->|"push: from aiml_ablegen"| ocib[["oci:deploy/oci/aiml-builder:nightly"]]
    ocib -.->|"push: kontor:aiml-builder:nightly"| kreg[("kontor /v2/")]

    venv -->|"base: job:aiml-vom-Base-Image<br/>(Stapel, selber Wirt)"| P2
    ocib -->|"image: oci:deploy/oci/aiml-builder"| P2
    kreg -.->|"image: kontor:aiml-builder:nightly<br/>(anderer Wirt)"| P2
    venv -->|"ufo layer commit → refs/layers/aiml/venv"| ufo1["ufo"]
    ufo1 -->|"layer apply &lt;dir&gt; → aiml venv &lt;dir&gt;/opt/aiml"| local["venv auf einem anderen Rechner<br/>. &lt;dir&gt;/opt/aiml/env"]

    subgraph P2["abhängige Pipelines (9rooms, cosmos, kontor, ufo …)"]
        direction TB
        w1["compiler_verdrahten<br/>(nur wer feste Pfade hat)"] --> w2["bauen mit aiml aus PATH"]
        w2 --> w3["veröffentlichen → kontor"]
    end
    w3 -->|"package.published"| camp(["Rebuild-Kampagne (Diagramm 6)"])

    future["aiml-exodus (in aiml)<br/>build · link · deps install"]
    venv -.->|"ersetzt Python-exodus ab dem zweiten Bau"| future
    future -.->|"Pakete nach lib/aiml/"| venv
```

---

## 11. Vertrauensgrenzen

```mermaid
flowchart LR
    subgraph T_USER["nicht vertrauenswürdig"]
        src["fremder Pipeline-Code<br/>run: · aiml-Rümpfe"]
        foreign["fremde Schicht aus kontor"]
        hookin["eingehender Webhook"]
        samlin["SAML-Antwort"]
    end

    subgraph T_COS["cosmos prüft"]
        sandbox["Sandkasten: rootless, userns-UID-Bereich,<br/>seccomp, no-new-privileges, Grenzen je Stufe"]
        gate["Rollen-Gate an EINER Stelle<br/>(email_for_token)"]
        hmac["HMAC-SHA256, zeitkonstant<br/>+ Delivery einmal"]
        ltrust["layer_trust: none → nur Abbild,<br/>nie Cache-Treffer / base:"]
        nopath["keine Wirtspfade / Adressen in Pipelines<br/>(kontor-URL aus config)"]
    end

    subgraph T_KON["kontor prüft"]
        digest["Digest jedes Blobs (sha256)<br/>X-Checksum-Sha256"]
        ktok["Tokens nur als sha256, Rollen,<br/>keine Rechte über die des Erstellers"]
        paths["Pfad-Prüfung (kein ..)"]
    end

    subgraph T_UFO["ufo prüft"]
        uhash["Objekt-Hashes (sha1, wie git)"]
        utok["UFO_REGISTRY_TOKEN nur per Env,<br/>nie in argv oder Log"]
    end

    src --> sandbox
    src --> nopath
    foreign --> digest --> ltrust
    hookin --> hmac --> gate
    samlin --> sig["Signatur · Audience · Zeitfenster<br/>· eigene Anfrage, einmal"] --> gate
    foreign -.->|"geplant: Signaturen statt Vertrauen"| sigs["Schicht-Signaturen<br/>(ML-DSA/SLH-DSA, spec 06)"]
```

---

## Offene Punkte, die in den Diagrammen gestrichelt sind

- `exodus deps install` (Pakete aus kontor in eine Tabelle) — heute ein Stub; kommt mit
  aiml-exodus.
- `from_code:` im Katalog (F111-5).
- Schicht-Annotationen (`cosmos.stage`, `cosmos.bindings`, …) setzt cosmos-oci noch nicht
  (spec/111 §111.11).
- `ufo layer commit` direkt als Stufe eines cosmos-Laufs: die Bausteine sind da (ufo
  `tests/venv_layer.sh` zeigt den Weg), cosmos verdrahtet ihn noch nicht selbst.
- Fremde Schichten als Cache-Treffer: erst mit Signaturen (F110-121).
- `image: kontor:aiml-builder` statt `oci:` für die venv über Wirtsgrenzen.
