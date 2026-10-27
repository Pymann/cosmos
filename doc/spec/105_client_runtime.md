# 105 — Der Client als Gruppe: Globals abschaffen

Der Server wurde 2026 auf eine Classgroup umgestellt (doc/spec/93) und hat seitdem **zwei**
Globals: `g_runtime` (die Gruppe selbst) und `g_current_peer_id` (Zustand der laufenden
Anfrage, F93-7). Der **Client wurde nie umgestellt** und hat **29**. Der Agent hat **null**.

Das ist keine Stilfrage. Die Frage des Users — *„warum nutzt cosmos globale Variablen, wir
haben doch extra zu classgroups umgestellt?"* — hat die Ursache von zwei Abstürzen benannt.

## 105.0 Was die Globals angerichtet haben (gemessen)

Vier der 29 Client-Globals sind **besitzende** Zeiger: `g_live_cluster`, `g_live_agents`,
`g_token_list`, `g_cosmos_app`. Drei Aufrufstellen reichten so ein Global an einen
`ptr<T>`-Parameter weiter. Das **verschiebt den Besitz** (spec/61 §6.2/§10): beim Rücksprung
verwirft der Parameter die Kiste, und das Global zeigt ins Leere.

| Stelle | Folge |
|---|---|
| `ClusterScreen.apply(g_live_cluster)` | Absturz in `RunsScreen_draw_grid` (2026-10-13) |
| `AgentsScreen.apply_agents(g_live_agents)` | Absturz in `LiveTable_agents` (2026-10-14) |
| `AgentsScreen.apply_tokens(g_token_list)` | **noch nicht** aufgetreten — vom Compiler gefunden |

Alle drei übersetzten **grün**. Der Server, der dieselben Daten hält, konnte diesen Fehler
nicht machen: dort ist jeder Zustand eine Instanz mit Eigentümer.

**F105-1: Zustand mit Besitz gehört in eine Instanz.** Ein Global hat keinen Eigentümer —
niemand gibt es frei, und jeder darf es weiterreichen. Ein *besitzendes* Global vereint
beides zum schlechtest möglichen Fall.

## 105.1 Zielbild — die Kompositionswurzel, nicht die Gruppe

**Entscheid 2026-10-14 (User):** der Client wird wie der **9rooms-Client** aufgebaut, nicht wie
der cosmos-Server. Gemessen am 2026-10-14:

| | Mechanismus | Globals | davon besitzend |
|---|---|---|---|
| 9rooms Client | Kompositionswurzel (`MainMenuApp` hält alles als Member) | **2** | 1 (`g_app`) |
| cosmos Server | classgroup | 2 | 0 |
| cosmos Client | keines von beidem | **27** | 3 |

Der 9rooms-Client ist **keine** classgroup und erreicht das Ziel trotzdem: `MainMenuApp` hält
Anmeldung, Menü, Lobby, Editor und Brett-Zustand als Member. Das ist das billigere Mittel —
keine `sees:`-Kanten, keine Phasen, keine Reihenfolge-Fallen — und es ist in einem gewachsenen
Client belegt. `CosmosApp` übernimmt diese Rolle; die Instanzen unten sind **Member**, keine
Gruppen-Instanzen.

| Member von `CosmosApp` | Ersetzt | Zuständig für |
|---|---|---|
| `session` | `g_session`, `g_server_url`, `g_server_pinned`, `g_token`, `g_email`, `g_nick`, `g_pid`, `g_connected` | Verbindung und Anmeldung |
| `live` | `g_live_cluster`, `g_live_cluster_seq` | der Cluster-Schnappschuss (doc/spec/104 F104-1) |
| `agents` | `g_live_agents`, `g_live_agents_seq` | die Agenten-Sicht |
| `run_output` | `g_run_ref`, `g_run_live`, `g_run_exit`, `g_run_seq`, `g_run_tail`, `g_run_tail_cap` | der mitlaufende Ausgabestrom |
| `tokens` | `g_token_list`, `g_token_list_seq`, `g_new_secret`, `g_new_token_id` | Enrollment-Token |
| `provisioning` | `g_prov_fp`, `g_prov_status`, `g_prov_running`, `g_prov_done` | die Einrichtung |
| `pipelines` | `g_pipe_run_id`, `g_pipe_status` | Einreichen und Starten |

**Was bleibt:** `g_cosmos_app` — und zwar **erzwungen**, nicht aus Bequemlichkeit.
`engine.run(win, update, render)` nimmt nackte Funktionszeiger ohne Kontext, der
Update-Rückruf hat also keinen Platz für seinen Empfänger. 9rooms landet aus demselben Grund
bei demselben einen Global (`g_app`).

**F105-2:** Genau **ein** Global je Binary ist erlaubt — die Rückruf-Brücke. Alles andere ist
ein Member. Dass es überhaupt eines braucht, ist als TODO in aiml `spec/44_1` festgehalten
(Kontext-Parameter für `engine.run`); danach fällt es in **beiden** Projekten ersatzlos weg.

Die Schnittlinien sind nicht erfunden: jede `client/net/*.aiml` hält heute schon genau einen
dieser Sätze. Die Migration folgt den Dateien, nicht einem Reißbrett.

## 105.2 Reihenfolge — und warum diese

Nach Risiko, nicht nach Größe. Zuerst die drei, die Besitz halten (dort ist der Schaden
belegt), danach die reinen Wertzustände (dort ist es Hygiene).

1. **`live`** — ein Datensatz, zwei Leser (Cluster- und Läufe-Ansicht). Kleinster Schnitt mit
   dem größten belegten Nutzen.
2. **`agents`** und **`tokens`** — dieselbe Form, derselbe Absturz.
3. **`run_output`** — sechs Felder, aber nur ein Leser; der Umbau ist mechanisch.
4. **`session`** — acht Felder und *jeder* Bildschirm liest `g_token`. Zuletzt, weil ein
   Fehler hier alles lahmlegt.
5. **`provisioning`**, **`pipelines`** — reine Statusfelder, zum Schluss.

Je Schritt: Instanz anlegen, Push-Handler zur Methode machen, Leser umstellen, bauen,
betroffene Tests laufen lassen. **F105-3: Kein Schritt lässt ein Global und seine Instanz
nebeneinander bestehen** — zwei Quellen für denselben Zustand sind genau der Fehler aus
doc/spec/104 §104.0.

## 105.3 Was dabei auffallen wird

Die Push-Handler (`cluster_apply_push`, …) sind heute **freie Funktionen**, die der
Push-Router aufruft. Als Methoden brauchen sie die Gruppe — der Router bekommt also eine
`sees:`-Kante, und die Reihenfolge der Instanzen muss stimmen (eine gesehene Instanz muss
vorher deklariert sein; das kostete beim Server-Umbau eine Stunde Suche).

**Und ein Nebenbefund, der die Migration leichter macht:** `sees:`-Kanten sind nur in
`groupmethods:` sichtbar (doc/spec/93 §1.1). Klassenmethoden sehen sie nicht. Beim
Cluster-Schnappschuss hiess das: der netzlos prüfbare Kern bleibt Klassenmethode
(`snapshot`), nur das Verweben kommt in die Gruppe (`snapshot_live`). Dasselbe Muster trägt
hier — **F105-4: Rechnen bleibt in der Klasse, Zusammenführen kommt in die Gruppe.** Sonst
verliert man mit jedem Umbau einen netzlosen Test.

## 105.4 Der Lint, der das offen hält

aiml meldet ein modulweites Global ab sofort als **Warnung** (spec/21 §6.2 Regel 5),
abschaltbar mit `AIML_LINT_GLOBALS=0`. Sie ist bewusst keine Fehlermeldung: ein Global ist
legal, und wenige sind richtig (`g_current_peer_id`, `g_cosmos_app`). Die Warnung sorgt
dafür, dass eine Ausnahme eine **Entscheidung** ist und keine Gewohnheit — und sie macht den
Fortschritt dieser Migration messbar: 29 → 1 je Binary.

## 105.5 Ergebnis (2026-10-14)

**29 → 1.** Übrig ist genau `g_cosmos_app`, die Engine-Rückruf-Brücke (F105-2); sie fällt mit
dem Kontext-Parameter aus aiml `spec/44_1` ersatzlos weg.

Die Gruppe `CosmosClient` hält elf Instanzen: `session`, `live`, `agents_state`,
`tokens_state`, `provisioning`, `pipelines`, `push_router` sowie die Bildschirme `login`,
`menu`, `agents`, `pipes`.

**Der Umbau war billiger als geplant** (User-Hinweis 2026-10-14): statt `ref<SessionState>`
durch 132 Vorkommen in 9 Dateien zu fädeln, deklariert jede Klasse ihren Kollaborateur als
**eigenes Member** und die Gruppe verdrahtet es über `sees:` (aiml spec/58 §5.1, „sees onto a
base member"). Damit bleiben es **gewöhnliche** Klassenmethoden — nichts musste in
`groupmethods:`, und jede Klasse ist weiter ohne Gruppe prüfbar. Eine sees-Instanz ist
vollwertig: auch ihre **Attribute** sind lesbar und schreibbar (belegt in aiml
`tests/test_classgroup_sees_base_member.aiml`).

Aus freien Funktionen wurden Instanzen: `auth_rpc` + `session` → `SessionState` (17 Methoden),
`provision_rpc` → `ProvisionState`, `pipeline_rpc` → `PipelineState`, `cluster_rpc` ging in
`LiveState` auf, `push_router` → `PushRouter` mit drei Kollaborateuren.

Stolperstellen, die wiederkommen werden: aus freien Funktionen übernommene Methoden haben
**kein** `access: public` (30 Stück nachzuziehen), und maschinelles Umformen zerlegt die
YAML-Einrückung — der Verteiler wurde von Hand neu geschrieben statt am Generat geflickt.
