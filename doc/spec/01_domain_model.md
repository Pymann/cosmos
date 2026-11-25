# Cosmos — Kapitel 01: Domänenmodell

Definiert die Entitäten der Control-Plane, ihre Felder, Identität und Beziehungen.  Zustände und
Übergänge stehen in [02_lifecycles.md](02_lifecycles.md).  Felder sind in aiml-Typen angegeben;
`enum`-Felder, die heute als String implementiert sind, sind unter „Implementierungsstand" vermerkt.

## 1.1 Gemeinsame Konventionen

- **Identität.**  Jede Entität hat eine opake, stabile Primär-ID (String), die zugleich ihr
  KV-Schlüssel ist.  IDs sind nicht wiederverwendbar und werden nie aus Anzeigenamen abgeleitet.
- **Eigentümer (Zielbild Mandanten).**  Jede Entität SOLL künftig ein Feld `owner` (= `player_id`
  der Auth-Schicht, architecture §7) tragen; Lese-/Schreibzugriff ist dann auf den Tenant
  beschränkt.  In dieser Fassung noch nicht modelliert (Abweichung unten) — die Spec hält den
  Platz dafür frei.
- **Zeitstempel.**  `*_ms`/`*_at`-Felder sind `i64` = `time.now`-Millisekunden.
- **Labels.**  `list<string>`; die Zuordnungsmechanik (Workload/Stage → Node/Agent) ist in
  [03](03_scheduling_and_reconcile.md) definiert.

## 1.2 Node — Ausführungsknoten / Runner-Host

Ein `Node` ist ein Rechenknoten, auf dem Workloads platziert und Agenten/Jobs ausgeführt werden.

| Feld | Typ | Bedeutung |
|---|---|---|
| `node_id` | `string` | Primär-ID (KV-Schlüssel) |
| `name` | `string` | Anzeigename |
| `role` | `enum NodeRole` | `control_plane` \| `build_agent` \| `worker` |
| `status` | `enum NodeStatus` | `ready` \| `not_ready` \| `draining` \| `offline` (§02) |
| `labels` | `list<string>` | Platzierungs-/Stage-Zuordnung (z. B. `build`, `amd64`, `linux`) |
| `agent_tags` | `list<string>` | Runner-Fähigkeiten (z. B. `jenkins`, `runtime`, `orchestrator`) |
| `total_cpu` / `used_cpu` | `i32` | CPU-Kapazität bzw. belegt (abstrakte Einheiten) |
| `total_memory` / `used_memory` | `i32` | Speicher-Kapazität bzw. belegt (MB) |
| `endpoint` | `string` | Erreichbarkeit (z. B. `wss://…`, `ssh://…`) |

- **Kapazität.**  `used_* ≤ total_*` ist eine Invariante; der Reconciler erhöht `used_*` bei
  Platzierung und senkt es bei Entfernung (§03).
- **Observability (Zielbild).**  Ein Node trägt künftig Live-Metriken (Last, freie Kapazität,
  verbundene Agenten) als automatisch visualisierte Zeitreihen (Kapitel 10).

## 1.3 Workload — deploybares Ziel

Ein `Workload` beschreibt einen Soll-Zustand (Service/Deployment/Job), den der Reconciler auf
passende Nodes bringt.

| Feld | Typ | Bedeutung |
|---|---|---|
| `workload_id` | `string` | Primär-ID |
| `name` | `string` | Anzeigename |
| `namespace` | `string` | logische Gruppierung (später Tenant-scoped) |
| `kind` | `enum WorkloadKind` | `deployment` \| `job` \| `service` |
| `status` | `enum WorkloadStatus` | `pending` \| `running` \| `waiting_for_capacity` \| `failed` (§02) |
| `required_label` | `string` | Platzierungs-Anforderung (leer = beliebig) |
| `desired_replicas` / `ready_replicas` | `i32` | Soll-/Ist-Replikate |
| `cpu_request` / `memory_request` | `i32` | Ressourcenbedarf pro Platzierung |
| `assigned_node_ids` | `list<string>` | Nodes, auf die platziert wurde |
| `image_ref` | `string` | Container-Image (Anknüpfung Container-Laufzeit, Kapitel 13) |

## 1.4 PipelineRun — CI/CD-Lauf

Ein `PipelineRun` ist ein Durchlauf einer Integrationspipeline über geordnete Stages.

| Feld | Typ | Bedeutung |
|---|---|---|
| `run_id` | `string` | Primär-ID |
| `pipeline_name` | `string` | Name der Pipeline-Definition |
| `repo_url` / `branch` | `string` | Git-Quelle (Kapitel 14) |
| `status` | `enum PipelineStatus` | `queued` \| `running` \| `deploying` \| `succeeded` \| `failed` (§02) |
| `target_namespace` | `string` | Ziel-Namespace des Deploys |
| `queue_label` | `string` | Label, über das Stages Agenten/Nodes wählen |
| `produced_workload_id` | `string` | vom Lauf erzeugter/aktualisierter Workload |
| `produced_job_id` | `string` | verknüpfter durable Job des Deploys (Kapitel 04/05) |
| `stages` | `list<PipelineStage>` | geordnete Stufen |

## 1.5 PipelineStage — eine Stufe eines Laufs

| Feld | Typ | Bedeutung |
|---|---|---|
| `stage_id` | `string` | ID innerhalb des Laufs |
| `name` | `string` | Anzeigename |
| `stage_kind` | `enum StageKind` | `git` \| `build` \| `test` \| `deploy` (erweiterbar) |
| `state` | `enum StageState` | `pending` \| `running` \| `paused` \| `done` — Lebenszyklus (§96.10) |
| `status` | `enum StepStatus` | Ergebnis, gültig ab `done` — sechs Werte (§96.10); ersetzt `StageStatus` |
| ~~`script_ref`~~ | `string` | **abgelöst** von `steps`: der Rumpf ist aiml-Code im Schritt, kein Skript-Verweis (aiml `spec/62` §5.1) |
| `required_label` | `string` | **WER** den Schritt nimmt: ein Etikett oder eine Agenten-Kennung, aus `agent:` der Stufe bzw. der Pipeline (aiml `spec/62` F62-146, bis 2026-10-25 `runs_on:`); darf Parameter interpolieren |
| `per` | `enum StagePer` | `lane` \| `once` — einmal je Lane oder einmal für den ganzen Lauf (F62-58) |
| `on_fail` | `enum FailReach` | `lane` \| `pipeline` \| `continue` (F62-39) |
| `timeout_ms` | `i64` | Grenze für die ganze Stufe (F62-40); 0 = keine |
| `pause_before` | `i32` | 1 = Freigabe-Tor vor dieser Stufe (F62-54) |
| `steps` | `list<PipelineStep>` | geordnete Schritte dieser Stufe (§1.5a) |

Die Stufe ist die **Einheit der Lokalität**: ein Workspace je (Lane, Stufe), ein Knoten je Stufe
(aiml F62-60).  Deshalb sitzt `agent:` hier und nicht am Schritt, und deshalb ist eine
`needs`-Kante **über** eine Stufengrenze die Stelle, an der ein `output_tree` übertragen werden
muss (§96.11, F96-15).

## 1.5a PipelineStep — ein Schritt einer Stufe

Der Schritt trägt den Cache — nicht die Stufe.  Ein Schlüssel gilt je (Schritt, Lane)
(aiml `spec/62` §8).

| Feld | Typ | Bedeutung |
|---|---|---|
| `step_id` | `string` | ID innerhalb der Stufe |
| `name` | `string` | Anzeigename, eindeutig in der Pipeline |
| `cache_class` | `enum CacheClass` | `pure` \| `resolved` \| `opaque` — Vorgabe `opaque` (aiml `spec/62` §7) |
| `arg_names` | `list<string>` | Parameter, die dieser Schritt **deklariert** — nur diese gehen in den Schlüssel (F62-59) |
| `host_names` | `list<string>` | berücksichtigte Host-Werte, **nur Namen** (F62-17) |
| `step_key` | `string` | Schlüssel (§8); "" = noch nicht gebildet |
| `output_tree` | `string` | Adresse des erzeugten Baums; "" = nicht erzeugt |
| `reused` | `i32` | 1 = aus dem Cache übernommen, Rumpf **nicht** ausgeführt (§96.6) |
| `state` | `enum StageState` | `pending` \| `running` \| `paused` \| `done` (Lebenszyklus, §96.10) |
| `status` | `enum StepStatus` | Ergebnis, gültig ab `done` — sechs Werte (§96.10) |

## 1.6 Job (durable) — dauerhafte Build-/Deploy-Ausführung

Der `JobRecord` ist der persistente, Controller-seitige Zustand einer dauerhaften Ausführung
(Jenkins-artig).  Er überlebt Agent-/Controller-Absturz (Kapitel 05).

| Feld | Typ | Bedeutung |
|---|---|---|
| `job_id` | `string` | Primär-ID |
| `command` | `string` | auszuführendes Kommando (aus `script_ref` der deploy-Stage) |
| `state` | `enum JobState` | `queued` \| `running` \| `agent_lost` \| `finished` (§02) |
| `agent_id` | `string` | ausführender Agent |
| `pid` | `i64` | Prozess-ID des Jobs auf dem Agenten |
| `exit_code` | `i32` | Exit-Code (gültig ab `finished`; `-1` = unbekannt) |
| `log` | `string` | **vollständiges** Build-Log (Keimzelle des Logging-Pfeilers, Kapitel 11) |
| `disconnects` | `i32` | Zahl der Agent-Verbindungsabbrüche während des Laufs |
| `updated_ms` | `i64` | letzter Zustandswechsel |

## 1.7 Agent / Runner — ausführender Prozess (live beobachtet)

Ein Agent ist ein Runner-Prozess, der durable Jobs ausführt.  Heute ist er **implizit** (über
`JobRecord.agent_id` und die Verbindungs-Registry `ConnRegistry`, die `peer_id → player_id`,
`last_seen`, `disconnected_at` führt).  Die Spec hebt ihn zur **beobachtbaren Entität**:

| Feld | Typ | Bedeutung |
|---|---|---|
| `agent_id` | `string` | Primär-ID des Runners |
| `status` | `enum AgentStatus` | `connected` \| `disconnected` (§02) |
| `last_seen_ms` | `i64` | letzte Lebendmeldung |
| `current_job_id` | `string` | aktuell ausgeführter Job (leer = idle) |
| `labels` | `list<string>` | Fähigkeiten (deckt sich mit `Node.agent_tags`) |

- **Live.**  Verbinden/Trennen eines Agenten ist ein Ereignis, das sofort an Abonnenten gepusht
  wird (Leitprinzip 6, §02 Agent-Lebenszyklus).  Dafür darf die Überwachung **nicht** auf eine
  Job-Zustandsänderung warten (aktuelle Abweichung, siehe unten).

## 1.8 Beziehungen

```
PipelineRun ──produced_workload_id──▶ Workload ──assigned_node_ids──▶ Node
     │                                                                  ▲
     └──produced_job_id──▶ Job ──agent_id──▶ Agent ──(läuft auf)────────┘
PipelineStage.required_label ─┐
Workload.required_label ──────┴─(Label-Match + Kapazität, §03)─▶ Node.labels
```

- Eine `PipelineRun` erzeugt genau einen `produced_workload_id` und (für ihr Deploy) höchstens
  einen `produced_job_id`.
- Ein `Job` läuft auf genau einem `Agent`; ein `Agent` führt zu einem Zeitpunkt höchstens einen
  `Job` aus (Erweiterung auf mehrere Slots: späteres Kapitel).
- Platzierung verbindet `Workload`/`Stage` über Labels + Kapazität mit `Node` (§03).

## 1.9 Aggregat für die Live-Ansicht — `ClusterView`

Der Browser-Client liest den Cluster als `ClusterView` (token-gesichert, live gepusht —
architecture §7.4):

| Feld | Typ |
|---|---|
| `nodes` | `list<Node>` |
| `workloads` | `list<Workload>` |
| `pipelines` | `list<PipelineRun>` |
| `jobs` | `list<JobRecord>` |

`ClusterView` SOLL künftig `agents: list<Agent>` enthalten, damit die Agenten-Live-Sicht ohne
Umweg über Jobs funktioniert (Abweichung unten).

## Implementierungsstand (Abweichungen von dieser Spec)

Maßgeblich ist die Spec; die folgenden Punkte sind offen und werden nachgezogen (Spec → Tests → Code):

1. **Zustände als String statt `enum`.**  `Node.status`, `Workload.status`, `PipelineRun.status`,
   `PipelineStage.status` sind heute `string`.  Soll: die in §02 definierten Enums (nur `JobState`
   ist bereits ein Enum).  Migration: Enums einführen, Seeds/Reconcile anpassen, `str_cmp`-
   Vergleiche entfernen.
2. **`role`/`kind`/`stage_kind` als freie Strings.**  Sollen Enums (`NodeRole`, `WorkloadKind`,
   `StageKind`) werden.
3. **Kein `owner`/Tenant-Feld.**  Entitäten tragen noch keine Eigentümer-Identität; für den
   Cloud-/Mandanten-Nordstern (spec/00) nachzurüsten.
4. **`Agent` ist keine eigene Entität.**  Nur implizit über `JobRecord.agent_id` + `ConnRegistry`.
   Soll: eigenes `Agent`-Modell + `ClusterView.agents`, damit Agent-Connect/-Disconnect **ohne**
   Job-Änderung live sichtbar wird.
5. **Live-Push nur bei Cluster-/Job-Signaturänderung.**  Der Daemon pusht, wenn sich Node/Workload/
   Pipeline/Job-Signatur ändert (architecture §7.4).  Ein reiner Agent-Connect ohne Jobwechsel löst
   heute keinen Push aus → verletzt Leitprinzip 6.  Soll: Agent-Ereignisse in die Push-Signatur
   aufnehmen (Kapitel 02).
6. **Pipelines sind deklarativ, aber nicht ausführend.**  Stages werden noch nicht ausgeführt;
   nur der Link `produced_job_id` + die durable-Job-Welt existieren (Kapitel 04/05).
   Soll: Ausführung mit Layer-Cache nach §96; die dafür nötigen Stage-Felder (`cache_class`,
   `resolve`, `env_names`, `step_key`, `output_tree`, `reused`) stehen in §1.5 und fehlen im Code.
7. **`StageStatus`/`PipelineStatus` vermischen Lebenszyklus und Ergebnis.**  `pending | running |
   succeeded | failed | skipped` stellt Zustände verschiedener Art als Alternativen dar, weshalb
   sich für sie keine Aggregationsregel angeben lässt.  Soll: zwei Enums — `StageState`
   (`pending | running | done`) und `StepStatus` (sechs Werte, benannt nach den additiven
   Grundfarben und ihren Mischungen; Bedeutungen noch offen), siehe §96.10 und aiml `spec/62`
   §5.7.  Der Grund, warum drei Werte nicht genügen: Erfolg **mit** Ausführung und Erfolg **ohne**
   Ausführung (Cache-Treffer) müssen unterscheidbar sein.  Punkt 1 dieser Liste (Zustände als
   String statt `enum`) wird dabei mitgezogen.
