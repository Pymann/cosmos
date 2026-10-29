# 07 — Scheduling & Load-Balancing

**Ziel (spec 21, Jenkins-Abgrenzung):** Jobs/Stages **lastverteilt** auf freie, geeignete Runner
(least-loaded, nicht „erster passender"); horizontal skalierbar; Control-Plane mehrfach instanziierbar.

## Vorbilder
- **Kubernetes-Scheduler:** zweistufig **Filter** (Prädikate: Label/Taints/Ressourcen passen) →
  **Score** (Prioritäten: least-allocated / most-allocated / spread / affinity) → höchstes Score gewinnt.
- **Nomad:** ähnliche filter+rank-Pipeline, bin-packing/spread wählbar.
- **HTCondor/Slurm (HPC):** Matchmaking über ClassAds, faire Queues.
- **Jenkins:** faktisch **kein** echtes Scheduling — Label-Match + „erster freier Executor", kein
  Balancing, Master-zentriert.  Genau die Schwäche, die cosmos vermeiden will.

## cosmos-Modell (aus spec 03/21)
1. **Filter:** `Node.status==ready` ∧ Label-Match (`required_label` ⊂ `labels`) ∧ Kapazität
   (`used_cpu+req ≤ total_cpu`, analog memory).  (Heute: erster passender in fester Reihenfolge → Ist-
   Abweichung.)
2. **Score:** **least-loaded** = max. freie Kapazität (oder relative Auslastung minimieren); optional
   spread (mehrere Agenten eines Tenants streuen) / Cache-Affinität (Node, der den Input-Tree schon
   materialisiert hat → weniger Transfer, verzahnt mit 02).
3. **Zuweisung** + `used_*`-Erhöhung; bei Jobende Freigabe.

## Reuse vs. Build
- **Reuse:** die **Konzepte** (filter→score, bin-packing/spread); ggf. ein externer LB **vor** den
  Control-Plane-Instanzen (nginx/envoy) für HTTP/ws.
- **Neu in cosmos (reine aiml-Logik, klein):** der Scheduler als Funktion über den **Live-Zustand**
  (Nodes/Agents/Jobs) — filter+score, deterministisch, testbar.  **Cache-affines Scoring** (02) ist
  der cosmos-Mehrwert.
- **Clustering (größer):** mehrere Control-Plane-Instanzen **zustandslos über geteiltem AionDB**;
  Scheduler-Entscheidungen müssen dann konfliktfrei sein (optimistisches Locking/Lease auf Job-
  Zuweisung im KV), weil AionDB single-node ist (→ 12).

## aiml-Eignung
- filter/score ist triviale aiml-Logik über die (per Push live gehaltenen) Entitäten.
- **Lücke:** Agenten-Live-Zustand als eigene Entität (spec 01 Abweichung 4) + Lease/atomare
  Zuweisung im KV; AionDB-Replikation für echte HA (fehlt).

## Empfehlung
Scheduler **nativ** als filter→score mit **least-loaded + Cache-Affinität** bauen (klein, testbar,
klarer Jenkins-Vorsprung).  Horizontale Skalierung zuerst als **mehrere zustandslose Daemons über
einem AionDB** + Lease-basierte Job-Zuweisung; echte Store-Replikation ist ein späterer, größerer
Schritt (12).

## Quellen
- k8s-Scheduler (filter/score), Nomad, HTCondor/Slurm; Jenkins-Executor-Modell (Allgemeinwissen, Cutoff 2026).
