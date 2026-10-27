# AP1 — Agenten verbinden, Live-Übersicht, Remote-`sys.exe`

**Status:** Server-, Agenten- und Protokollseite **implementiert und gemessen** (§AP1.8);
WASM-Oberfläche offen.  Design-Weichen festgelegt (§AP1.7).

## AP1.1 Zielbild (User Story)
> Ich starte einen Agenten; er verbindet sich mit cosmosd.  Im Browser (WASM) sehe ich **live** eine
> Übersicht **aller verbundenen Agenten** — ohne „Aktualisieren".  Ich wähle einen Agenten, tippe in
> ein Eingabefeld ein Shell-Kommando (mit festlegbarem **Arbeitsverzeichnis `cwd`**), sende es ab; es
> läuft per `sys.exe` **auf diesem Agenten**.  **stdout und stderr werden live zum Server gestreamt**
> und im Browser getrennt erkennbar angezeigt, am Ende der **Exit-Code**.  Verbindet/trennt sich ein
> Agent, ändert sich die Liste sofort.

Das ist die kleinste nützliche Realisierung der Live-Observability (Leitprinzip 6) und des
Runner-Modells — die Keimzelle, auf der Pipelines/Jobs/CAS später aufbauen.

## AP1.2 In Scope
1. **Agent↔cosmosd-Verbindung:** der Agent verbindet sich per **ws/wss** (`mirror.connect` auf die
   cosmosd-URL) und **registriert sich** als `Agent`-Entität (agent_id, Labels, Host-Info).
   Heartbeat/last_seen.
2. **Agenten-Entität live** (spec/01 §1.7 wird real): `agent_id`, `status` (connected/disconnected),
   `last_seen_ms`, `current_command` (leer=idle), optional `host`/`os`.  In `ClusterView.agents`
   bzw. eigener Agent-Push.
3. **Live-Übersicht im WASM-Client:** Liste aller verbundenen Agenten, live gepusht (auth. Server-
   Push §7.4) — connect/disconnect ohne Poll sichtbar.
4. **Remote-Kommando:** Eingabefeld (Kommando) + Feld fürs **Arbeitsverzeichnis `cwd`** + „Ausführen"
   → der eingeloggte Nutzer wählt einen Agenten und schickt Kommando+cwd; cosmosd leitet es **gezielt**
   an genau diesen Agenten; der Agent führt es via `sys.exe({shell:true, capture:true, cwd})` aus.
   **stdout und stderr werden fortlaufend zum Server gestreamt** (getrennt gekennzeichnet) und von dort
   an **genau diesen** Nutzer gepusht; am Ende der **Exit-Code**.  `cwd` leer = Arbeitsverzeichnis des
   Agenten.
5. **Security-Minimum (verbindlich):** nur **authentifizierte** Nutzer dürfen Kommandos senden
   (Token-gesichert); der **Agent authentifiziert sich** bei der Registrierung (Agent-Token), damit
   nicht jeder sich als Runner anmeldet; Ausgabe nur an den anfragenden Nutzer (kein Broadcast);
   keine Secrets/Token in Logs.

## AP1.3 Explizit NICHT in Scope (kommt später, Research 02–04)
- **Sandbox/Isolation/rootless** der Kommandoausführung → AP1 führt **direkt** per `sys.exe` aus
  (⚠️ **RCE-by-design**, siehe §AP1.6).  Container/rootless/userns/Kata später.
- CAS/StepSnapshots, Scheduling/Load-Balancing, Pipelines, Job-Queue, mehrere Kommandos parallel pro
  Agent, Datei-Upload/-Download, Artefakte, Dashboards/Metriken-Visualisierung.
- Der bestehende durable-Job/Controller-Pfad bleibt unberührt (AP1 ist davon unabhängig).

## AP1.4 Protokoll (Entwurf, baut auf Vorhandenem auf)
Wiederverwendet: `mirror` targeted `send_rpc` (peer_id-Routing), Auth/Token, `ConnRegistry`,
auth. Server-Push (§7.4), das `AgentHello`-Muster des durable-Job-Protokolls.

| Richtung | Methode | Payload → Antwort | Zweck |
|---|---|---|---|
| Agent→cosmosd | `agent_register` | `AgentRegister{agent_id, agent_token, labels, host, os_name}` → `AgentAck{accepted, reason}` | Registrierung + Agent-Auth |
| Agent→cosmosd | `agent_heartbeat` | `AgentBeat{agent_id}` → `AgentAck` | last_seen aktualisieren (nur für den Agenten DIESER Verbindung) |
| Browser→cosmosd | `subscribe_agents` | `TokenReq` → `AgentList` | Live-Liste abonnieren (initial + Push) |
| Browser→cosmosd | `run_on_agent` | `RunReq{token, agent_id, command, cwd}` → `RunAck{accepted, run_ref, reason}` | Kommando+cwd an Agent beauftragen |
| cosmosd→Agent (targeted) | `run_command` | `RunCommand{run_ref, command, cwd}` | Ausführung anstoßen |
| Agent→cosmosd | `command_output` | `OutChunk{run_ref, stream, chunk, offset}` — `stream`: `OutStream.out`\|`.err` | stdout **und** stderr getrennt streamen |
| Agent→cosmosd | `command_result` | `RunResult{run_ref, exit_code}` | Abschluss |
| cosmosd→Browser (targeted) | `agents_update` / `command_output` / `command_result` | Push an den Abonnenten/Anfrager | live |
| Browser→cosmosd | `read_run_output` | `RunWindowReq{token, run_ref, stream, offset:i64, len:i32}` → `RunWindow{data, offset, next_offset, total:i64, done}` | **Scrollback/Paging** — nur das angefragte Fenster (§AP1.5a) |
| Browser→cosmosd | `get_run_info` | `{token, run_ref}` → `RunInfo` | Zustand/Größen/Exit-Code ohne Ausgabe |

cosmosd hält **nur beschränkten** Zustand: Agenten-Registry (peer_id↔agent_id, status, last_seen),
Zuordnung `run_ref` → anfragender Nutzer-peer_id (damit Ausgabe nur dorthin geht), je laufendem Run
einen offenen Schreib-fd + `RunInfo`.  **Nicht** die Ausgabe selbst (§AP1.5a).

## AP1.5 Abnahmekriterien (testbar)
1. cosmosd+static+client laufen; Agent starten → er erscheint **binnen ≤2 s** im Browser als
   „connected", **ohne** Aktualisieren.
2. Agent beenden → wird **live** „disconnected"/entfernt.
3. Browser: Agent wählen, `echo hello; uname -a` senden → Ausgabe + Exit-Code 0 erscheinen im Browser.
4. Ohne gültiges Nutzer-Token → Kommando **abgelehnt**.  Ohne gültiges Agent-Token → Registrierung
   abgelehnt.
5. Zwei Agenten verbunden → Kommando trifft **genau den gewählten**; Ausgabe geht **nur** an den
   anfragenden Nutzer.
6. Langläufer (`sleep 3; echo done`) → Ausgabe kommt an, **UI friert nicht** (net_pump/async; kein
   blockierendes send_and_await über die Laufzeit).
7. Exit-Code ≠ 0 (`exit 7`) → 7 wird angezeigt.
8. **cwd wirkt:** mit `cwd=/tmp` liefert `pwd` → `/tmp`; leeres `cwd` = Agent-Arbeitsverzeichnis.
9. **stderr getrennt:** `echo out; echo err 1>&2` → beide Zeilen erscheinen, als stdout bzw. stderr
   gekennzeichnet; Reihenfolge je Strom erhalten.
10. **Große Ausgabe ohne RAM-Wachstum:** `seq 1 200000` (≈1,3 MB) → (a) die Ausgabe liegt
    **vollständig** in `run_logs/<run_ref>.out`, `RunInfo.out_bytes` stimmt mit der Dateigröße
    überein; (b) cosmosd akkumuliert sie **nicht** — kein Feld/Container hält die Gesamtausgabe,
    Speicherzuwachs des Daemons bleibt beschränkt (mem_diff/valgrind-Messung, nicht proportional zur
    Ausgabelänge); (c) `read_run_output{offset, len}` liefert genau das angefragte Fenster
    (Byte-exakt, `next_offset`/`total` korrekt), auch **während** der Lauf noch läuft; (d) der Browser
    zeigt den Live-Tail und hält selbst nur ein begrenztes Fenster.

## AP1.5a Ausgabe-Persistenz — KEIN unbegrenzter RAM (verbindlich)
**Regel:** Die Kommando-Ausgabe (stdout+stderr) darf **nicht** im Arbeitsspeicher von cosmosd (oder
Controller) akkumuliert werden.  Sie wird **beim Eintreffen sofort persistiert**; der Server hält nur
den aktuellen Chunk (transient) + kleine Metadaten (Byte-Zähler, Zustand, Exit-Code).  Der Browser
lädt **Fenster auf Anfrage** (Tail/Scrollback), nie zwangsläufig alles.

**Fluss (bounded RAM):**
1. Agent streamt `command_output{run_ref, stream, chunk}`.
2. cosmosd **hängt jeden Chunk sofort an die Ablage an** (ein offener Schreib-fd je laufendem Run;
   sequentielles Schreiben — kein Zwischenpuffer) und aktualisiert `RunInfo` (out_bytes/err_bytes/
   state/exit).  **Keine** Gesamt-Ausgabe im RAM.
3. **Live-Tail:** cosmosd leitet den eintreffenden Chunk **transient** an den gerade zuschauenden
   Anfrager weiter (Push); der Browser hält nur ein **begrenztes** Tail-Fenster (Ring, z. B. letzte
   N KB).
4. **Scrollback/Paging:** Browser ruft `read_run_output{run_ref, stream, offset, len}` → cosmosd liest
   den Byte-Bereich via `io.read_at` (zweiter, lesender fd) → gibt nur dieses Fenster zurück.

**Ablage-Layout A — Datei je Run (MVP, empfohlen; keine aiml-Erweiterung):**
- `run_logs/<run_ref>.out` und `run_logs/<run_ref>.err` — append-only (Schreib-fd bleibt für die
  Laufzeit offen; getrennte Dateien → reiner Strom + eigene Byte-Offsets je Strom).
- `RunInfo` (klein, in KV `runs`): `{run_ref, agent_id, command, cwd, state(running/finished),
  exit_code, out_bytes:i64, err_bytes:i64, started_ms, updated_ms}`.
- **Schreiben** (je Chunk, flusht sofort): `buf.write_string(chunk)` + `buf.write_to(logfd)`;
  `logfd` = `io.open(path, "a")`, bleibt für die Laufzeit des Laufs offen (`RunStore.cur_out`/
  `cur_err`; Lauf-Wechsel = reopen, also höchstens zwei offene Schreib-fds).
- **Lesen** (je Fensteranfrage, kurzlebiger fd): `io.open(path, "r")` + `io.seek(offset)` +
  `io.read(len)` → **string**, dann `io.close`.  Nicht `io.read_at`: das liefert `buffer<u8>`, und
  es gibt keine Bytes→string-Brücke für die RPC-Nutzlast.  Beide Wege sind positionssicher,
  weil der Lese-fd pro Anfrage frisch geöffnet wird.
  **Grenze (MVP):** `io.read` NUL-terminiert, und ein `string`-Feld endet am ersten `0x00` —
  die Ausgabe ist damit **textorientiert**; ein `0x00` in der Ausgabe schneidet den Chunk ab.
  Binärsichere Ausgabe bräuchte ein `buffer`-Feld im Protokoll (nicht in AP1).

**Ablage-Layout B — AionDB TimeSeries (DB-Ausbau, später):**
- Pro Run+Strom ein TimeSeries; `ts_append(seq_or_ts, chunk)`; Fenster via `ts_range(from, to)`.
  Vorteil: Retention/mehrere Leser/strukturiert.  Paging per seq-Bereich statt Byte-Offset.
  Ebenfalls **ohne** aiml-Erweiterung (`db.open_timeseries/ts_append/ts_range` vorhanden).
- **Nicht**: an einen KV-Wert anhängen (überschreibt den ganzen Wert → Rewrites) — das wäre die
  einzige echte Lücke und wird vermieden.

**Festgelegt (D5):** **A (Datei je Run) im AP1-MVP**, B als DB-Ausbaustufe.  Die Schnittstelle
(`read_run_output` + `RunInfo` + ein schmales Store-Modul `run_store`) ist für beide identisch →
Backend-Wechsel ist ein Implementierungstausch ohne Protokolländerung.

**Konsequenz für den durable-Job-Pfad (Abweichung, dokumentiert):** `JobRecord.log: string` hält heute
das **gesamte** Log im RAM/KV — genau das hier verbotene Muster.  AP1 lässt diesen Pfad unberührt
(§AP1.3), aber er ist damit als **Altlast** markiert und soll später auf `run_store` umgestellt werden.

## AP1.6 Security-Vorbehalt (verbindlich dokumentiert)
Remote-Shell auf Agenten ist **per Definition Remote-Code-Execution**.  AP1-MVP führt **ohne
Sandbox** aus → nur auf **vertrauenswürdigen, eigenen** Agenten betreiben, idealerweise bereits
**nicht als root** (Agent-Prozess unprivilegiert starten).  Echte Isolation (rootless/userns/Kata/
gVisor, Research 03/04) ist **Voraussetzung**, bevor fremde Nutzer/Agenten zugelassen werden.  Das
steht so in AP1, damit der MVP nicht versehentlich offen gehostet wird.

### AP1.6a Zwei Regeln, die nicht aus „angemeldet" folgen (Befund 2 und 3, 2026-10-11)

Beide Lücken hatten dieselbe Ursache: der Handler prüfte **Authentifizierung** und hielt das für
**Autorisierung**. „Wer bist du" sagt nichts darüber, worauf du zugreifen darfst.

- **AP1.6a-1 — ein `run_ref` ist ein Bezeichner, kein Pfadbestandteil.** Er wird in Dateipfade
  eingesetzt (`<root>/<run_ref>.out`). Ungeprüft führte `../…` aus dem Log-Verzeichnis heraus,
  und ein angemeldeter Nutzer konnte beliebige Dateien lesen.
  **Vorgabe:** Form erzwingen, und zwar **dort, wo der Pfad entsteht** (`RunStore`), nicht nur
  im Handler — sonst schützt die Prüfung nur den einen Aufrufer, der sie hat. Gültig ist ein
  Bezeichner aus **Buchstaben, Ziffern, `-` und `_`**, 3–120 Zeichen, nicht mit `-` beginnend;
  alles andere wird abgelehnt, bevor ein Pfad gebildet wird.

  **Geändert am 15.10.2026:** vorher war zusätzlich das Präfix `run-` und *nur Ziffern* danach
  verlangt. Das koppelte den Store an die Kennungen des AP1-Einzelbefehls: eine
  **Stufen**-Kennung (`<job>-<nummer>-<lane>-<idx>`, doc/spec/103 F103-19) fiel durch, und das
  Protokoll eines Pipeline-Schritts landete nirgends. Das Präfix schützte nichts — es
  beschrieb nur, wer damals Protokolle anlegte. Die Schutzwirkung steckt im Zeichensatz, und
  der ist unverändert streng. Damit die Kennungen diesen Zeichensatz auch einhalten, wird
  `job_id` beim Speichern aus dem Namen **abgeleitet** statt wörtlich übernommen
  (doc/spec/106 F106-9).

  Eine **Positivliste**, keine Suche nach `../`: letztere übersieht Schreibweisen (Kodierung,
  Symlinks, `a/../../b`), eine Formprüfung nicht.

  Bewusst **nicht** die engere Form `run-<ziffern>-<ziffern>`, die `run_on_agent` heute
  erzeugt. Sicherheitsrelevant ist der **Zeichensatz** — `/`, `.` und `..` sind damit schon
  ausgeschlossen. Die engere Regel würde den Store an das heutige Format koppeln und brechen,
  sobald dort ein Feld hinzukommt; sie liess ausserdem `run-1` durchfallen, das
  `test_agent_exec` seit je verwendet (ein Konflikt, der die Regel, nicht den Test betraf).

- **AP1.6a-2 — ein Agent darf nur über SEINEN Lauf berichten.** `command_output` und
  `command_result` prüften nur, dass der Absender *irgendein* registrierter Agent ist. Damit
  konnte ein übernommener Agent Ausgabe und Ergebnis **fremder** Läufe schreiben.
  **Vorgabe:** der gemeldete `run_ref` muss der Lauf sein, der diesem Agenten gerade zugewiesen
  ist (`AgentRegistry.current_run_of`). Die Angaben dafür lagen schon vor — sie wurden nur nicht
  geprüft.

Beides ist Autorisierung **am Server**; eine Prüfung im Agenten oder in der Oberfläche zählt
nicht (§AP2.C: UI-Verbergen ist Bequemlichkeit, keine Sicherheit).

## AP1.7 Design-Entscheidungen (festgelegt, User 2026-10-09)
- **D1 Transport:** **ws/wss zu cosmosd** — der Agent nutzt `mirror.connect` auf die cosmosd-URL
  (wie der Browser; ein Server, internetfähig, TLS-/PQC-Pfad).  Der tcp/Controller-Pfad bleibt separat.
- **D2 Ausgabe:** **Live-Stream** — stdout **und** stderr fortlaufend als `command_output`-Chunks
  (getrennt via `stream`-Feld) zum Server, von dort Push an den anfragenden Nutzer.
- **D3 Agent-Auth:** ~~gemeinsames Registrierungs-Geheimnis in `COSMOS_AGENT_TOKEN` auf beiden
  Seiten~~ → **ersetzt durch §AP1.9**: im Web-UI erzeugte, einzeln widerrufbare Enrollment-Tokens.
  cosmosd lehnt falsche/leere/widerrufene Tokens ab (fail closed).
- **D4 Agent-Basis:** **bestehenden Agenten erweitern** — ws-Verbindung zu cosmosd + `run_command`-
  Handler + Streaming; der durable-Job-Pfad bleibt erhalten.
- **Zusatz (User):** Arbeitsverzeichnis `cwd` pro Kommando festlegbar (RunReq/`run_command`-Feld,
  an `sys.exe({cwd})`).  stdout+stderr beide zum Server gestreamt.
- **D5 Ausgabe-Ablage (User 2026-10-09):** Die Ausgabe darf **nicht** im Server-RAM gehalten werden →
  sofortige Persistenz + Fenster-Lesen auf Anfrage (§AP1.5a).  MVP = **Datei je Run** (Layout A),
  Datenbank (TimeSeries, Layout B) als Ausbaustufe hinter derselben Schnittstelle.
- **D7 Streaming-Peer muss DROSSELN (korrigiert 2026-10-09):** Ein Agent darf die Ausgabe **nicht
  in einem Rutsch** abfeuern.  Nachgewiesen mit 6,9 MB (105 × 64 KB): beim unbegrenzten Schwall
  meldete cosmosd die **noch lebende** Agenten-Verbindung als `peer_disconnected`, verwarf die
  restliche Ausgabe („output from unregistered peer") und der Lauf blieb unvollständig —
  während der Agent weiter sendete und selbst keinen Abbruch sah.  Hintergrund: die Mirror-Queue
  ist **pro Sender auf 4096 Events / 64 MiB begrenzt und ein Peer darüber wird getrennt**
  (spec/44_5 §Queue), und der relayende Konsument ist langsamer als der Produzent.
  **Regel:** je Tick höchstens N Chunks senden (`AgentExec.drain_streams(sess, 16)` ≈ 1 MB/Tick)
  und den Lauf erst abschliessen, wenn ein Tick keinen Fortschritt mehr bringt; zusätzlich nach
  jedem Chunk `session.update()`.
  *Zwei verworfene Hypothesen, damit sie niemand erneut verfolgt:* (a) „`session.update()` nach
  jedem Send genügt" — half, beseitigte es aber nicht (bestand einmal, fiel dann wieder um);
  (b) „der Disconnect eines ANDEREN Clients löst es aus" — mit
  `probe_spurious_disconnect.sh` **widerlegt**: ein idle Agent ohne Ausgabe-Last überlebt
  4/4 fremde Client-Disconnects sauber.  Der Schwall ist die notwendige Bedingung.
- **D6 aiml-Erweiterung — am Quelltext geprüft (nicht nur Inventur):**
  - **Lesen: vollständig vorhanden.**  `io.open_binary` + `io.read_at(f, offset:i64, n:i32) →
    buffer<u8>` (spec/23, implementiert in `binary_io_runtime.cpp`); `read_at` sichert/restauriert die
    Position selbst, stört also keinen sequentiellen Leser.  **Vorgabe:** den **Lese-fd pro
    Fensteranfrage** öffnen und schließen (kurzlebig) — ein langlebiger Lese-`FILE*` könnte durch
    stdio-Pufferung **veraltete** Bytes einer gerade wachsenden Datei liefern.
  - **Append-Modus: vorhanden, aber undokumentiert.** `aiml_io_open` reicht den Modus-String
    unverändert an `fopen` durch (+`e`), `io.open(path, "a")` funktioniert also — spec/23 §5.1 listet
    die erlaubten Modi aber nicht.  → **Spec-Lücke, nachzutragen.**
  - **Schreiben: hier ist die echte Lücke — Flush.**  `io.write` ist `strlen`-basiert (nicht
    binärsicher, bricht an einem `0x00` ab) und **flusht nicht**; ein `io.flush` existiert **nicht**.
    Ein Leser (oder ein Daemon-Absturz) verliert damit bis zu einen stdio-Puffer (~4 KB) am Ende —
    Abnahmekriterium 10(c) „Fenster lesen **während** der Lauf läuft" wäre nicht erfüllbar.
    `buffer.write_to(f)` dagegen ist binärsicher **und flusht** (spec/11 §Methods, `fflush` in
    `aiml_buffer_write_to`) — das ist der richtige Schreibweg.
  - **⚠️ Spec-vs-Impl-Widerspruch (gefunden 2026-10-09):** der dafür nötige String→Buffer-Schritt
    `buf.write_string(s)` ist in **spec/32 §1 und spec/32_4 §5.1 dokumentiert**, aber **nirgends
    implementiert** (kein Treffer in `src/`, kein Test).  Byteweises `buf.write(v, u8)` ist der
    einzige heute funktionierende Weg — für KB-große Chunks untragbar.
  - **Erledigt (2026-10-09):** `buffer.write_string` ist implementiert (aiml
    `binary_io_runtime.cpp` + `builtin_registry.cpp`), in spec/11 dokumentiert und von
    `tests/test_buffer_write_string.aiml` abgedeckt — inklusive des hier gebrauchten Falls
    „ein zweiter Handle liest, während der erste noch anhängt".  Das irreführende
    `write_string("\x00\x01\x02")`-Beispiel in spec/32_4 ist korrigiert, die `io.open`-Modi
    (inkl. `"a"`) stehen jetzt in spec/23.
  - Layout B (TimeSeries) braucht ebenfalls keine neue Oberfläche
    (`db.open_timeseries/ts_append/ts_range`).  **Einzige** echte Lücke bliebe „an einen KV-Wert
    anhängen" (KV überschreibt den ganzen Wert) — dieser Weg wird bewusst nicht genommen.

## AP1.8 Implementierungsstand (2026-10-09)

**Dateien.**  Protokoll: `sources/models/agent_proto|agent_list|run_reqs|run_output|run_window|
run_info|agent_token|agent_token_reqs.aiml` + Barrel `agent_exec.aiml` (Aufteilung erzwungen durch
den 3-Typen-Cap, spec/49 §14).
Server: `run_store.aiml` (Ablage §AP1.5a), `agent_registry.aiml` (Registry + Routing),
`agent_token_store.aiml` (Enrollment-Tokens, §AP1.9), `agent_reg_handlers.aiml`,
`run_exec_handlers.aiml`, `run_read_handlers.aiml`, `agent_token_handlers.aiml`, Verdrahtung +
Live-Push in `cosmos_daemon.aiml`, Globals in `server_state.aiml`.
Agent: `agent_exec.aiml` (ws-Modus), Einstieg über `agent_main.aiml` (`--exec-url`).
Client: `client/agents_screen.aiml` + `AgentsScene`/`AgentTokenOverlay` (prefabs),
`client/net/agent_rpc.aiml`, `client/net/agent_token_rpc.aiml`, `client/net/push_router.aiml`
(EINE Drain-Schleife für alle Pushes — poll_rpc konsumiert jedes Ereignis, eine typspezifische
Schleife verschluckte fremde Pushes).
Tests: `test/test_agent_exec.aiml` (Logik), `test/e2e_runner.aiml` + `test/e2e_agent_exec.aiml` +
`test/e2e_enroll.aiml` (Abnahme), `probe_spurious_disconnect.sh` (Probe zu D7);
Skripte `run_tests.sh`, `run_e2e.sh`, `run_mem_check.sh`.

**Abnahme (Stand).**
| # | Kriterium | Status |
|---|---|---|
| 1 | Agent erscheint live | ✅ E2E (`wait_agent`) + `agents_update`-Push |
| 2 | Disconnect live sichtbar | ✅ Server (`peer_gone` → status disconnected, Signatur-Push); UI offen |
| 3 | Kommando läuft auf dem Agenten | ✅ E2E |
| 4 | Ohne Token abgelehnt | ✅ Logik + E2E (falsches und widerrufenes Token, §AP1.9) |
| 5 | Ausgabe nur an den Anfrager | ✅ `g_run_owner`-Routing; Zwei-Agenten-E2E offen |
| 6 | Langläufer blockiert die UI nicht | ⬜ mit der UI zu prüfen |
| 7 | Exit-Code ≠ 0 | ✅ E2E (exit 7) |
| 8 | cwd wirkt | ✅ E2E (`pwd` → `/tmp`) |
| 9 | stderr getrennt | ✅ E2E (getrennte Dateien + `stream`-Feld) |
| 10 | Grosse Ausgabe ohne RAM-Wachstum | ✅ **gemessen**, siehe unten |
| 11 | Token im UI erzeugen → Agent verbindet sich damit | ✅ E2E (`e2e_enroll` nutzt denselben RPC wie das UI) |
| 12 | Falsches Token abgelehnt | ✅ E2E |
| 13 | Widerrufenes Token abgelehnt | ✅ E2E |
| 14 | Geheimnis nicht mehr abrufbar (nur sha256 im KV) | ✅ Logik (liest den KV-Record direkt) |

**Messung zu Kriterium 10 (`run_mem_check.sh`).**  Zwei Durchläufe gegen denselben cosmosd:
108.907 B und 6.888.909 B Ausgabe.  cosmosd-RSS **61.380 kB → 61.380 kB**, also **0 kB** Zuwachs
bei 6,6 MB zusätzlicher Ausgabe (Grundlast ~2,7 MB fällt unabhängig von der Ausgabelänge an).
Damit ist belegt, dass der Server die Ausgabe **nicht** hält.  Die Ausgabe liegt vollständig und
byte-exakt in `run_logs/<run_ref>.out` (108.907 B inkl. Endmarker), Fenster-Lesen liefert genau die
angefragten Bytes, auch während der Lauf läuft.

**Dabei gefundene und behobene Fehler.**
1. *Abschluss-Drain schnitt die Ausgabe ab* (eigener Agent-Bug): endete der Prozess schneller als
   das Tailing, wurde nur EIN weiterer Chunk je Strom nachgezogen → bei 6,9 MB blieben 131.072 B
   (2 × 64 KB).  Der E2E-Test hatte das durchgelassen (prüfte nur „> 100 KB") → jetzt prüft er
   einen **Endmarker am Dateiende**, der Trunkierung unmöglich übersieht.
2. *Unbegrenzter Sende-Schwall* trennte die lebende Agenten-Verbindung → §AP1.7-D7 (gedrosselt,
   danach 3 Durchläufe in Folge byte-exakt 6.888.909 B und 0 verworfene Chunks).
3. *Push-Drain verschluckte fremde Pushes* (Client): die cluster-spezifische Schleife warf alles
   weg, was nicht `cluster_update` war → zentraler `push_router`.

**Messwiederholung.**  Drei aufeinanderfolgende `run_mem_check.sh`-Läufe: je 6.888.909 B gespeichert,
RSS-Zuwachs 60 kB, 0 verworfene Chunks.  Zwei `run_e2e.sh`-Läufe in Folge grün.

**Offen.**  Zwei-Agenten-E2E für Kriterium 5 (Ausgabe nur an den Anfrager), Kriterium 6
(Langläufer friert die UI nicht ein) — beides am laufenden Browser-Client zu prüfen.
Die WASM-Oberfläche ist gebaut (native + wasm32 linken), aber noch nicht im Browser durchgeklickt.

## AP1.9 Enrollment-Tokens — im Web-UI erzeugt (ersetzt D3, User 2026-10-09)

**Änderung gegenüber D3.**  Nicht mehr ein geteiltes Env-Geheimnis auf beiden Seiten, sondern
**Enrollment-Tokens, die ein angemeldeter Nutzer im Web-UI erzeugt** und einzeln widerrufen kann.
`COSMOS_AGENT_TOKEN` bleibt nur noch der Weg, wie der **Agent** sein Token bekommt (Umgebung, nicht
argv — sonst stünde es in der Prozessliste).  Der **Server** liest diese Variable nicht mehr.

**Warum besser:** mehrere Agenten mit je eigenem Token; ein verlorenes Token lässt sich einzeln
widerrufen, ohne alle anderen Agenten auszusperren; es ist nachvollziehbar, wer welches Token wann
erzeugt und wann es zuletzt benutzt wurde; und der Server kennt das Geheimnis nach dem Erzeugen
nicht mehr.

**Wie der Agent sein Token bekommt (drei Quellen, Rangfolge in `agent_main`):**
1. `--agent-token <wert>` — bequem, aber **in der Prozessliste sichtbar** (`ps`,
   `/proc/<pid>/cmdline`); wird mit einer Warnung im Log akzeptiert.  Nachgemessen: `ps -o args=`
   zeigt das vollständige Token.
2. `--agent-token-file <pfad>` — Datei mit dem Token (Rest wird getrimmt, Zeilenumbruch egal);
   in der Prozessliste steht nur der Pfad.  **Empfohlen, wenn es von der Kommandozeile kommen soll.**
3. `COSMOS_AGENT_TOKEN` — Umgebung.

Alle Felder kommen über `sys.arg_dump` (spec/23: `--foo-bar` → `foo_bar`), sind also schlicht
Felder von `AgentCfg`.  Fehlt das Token ganz oder ist die Datei unlesbar, sagt der Agent das
deutlich und die Registrierung wird abgelehnt (fail closed).

**Token-Format:** `"<token_id>.<secret>"` — `token_id` = 16 Hex (`math.random_hex(8)`),
`secret` = 64 Hex = 256 bit CSPRNG (`math.random_hex(32)`, OpenSSL RAND_bytes).  Die `token_id`
erlaubt den Lookup in O(1); nur das `secret` ist geheim.

**Ablage (KV `agent_tokens`, token_id → AgentToken):**
`{token_id, label, created_by (opake player_id), created_ms, last_used_ms, use_count, revoked,
secret_hash}`.  **Gespeichert wird nur `hash.sha256(secret)`, niemals das Geheimnis selbst** —
wie bei Passwörtern.  Kein PBKDF2 nötig: das Token ist mit 256 bit Entropie nicht ratbar, es gibt
kein Wörterbuch dagegen.  Das Klartext-Token wird **genau einmal** in der Antwort auf das Erzeugen
ausgeliefert und danach nirgends mehr; wer es verliert, erzeugt ein neues.

**Prüfung bei `agent_register`:** Token an `.` zerlegen → `token_id` nachschlagen → fehlt/`revoked`
→ abgelehnt; sonst `hash.sha256(secret)` **constant-time** (`hash.const_time_eq`) gegen
`secret_hash` vergleichen.  Bei Erfolg `last_used_ms`/`use_count` fortschreiben.
Weiterhin **fail closed**: kein passendes Token → keine Registrierung.  Das Token wird NIE geloggt
(auch nicht gekürzt).

**Neue RPCs (alle nutzer-token-gesichert):**
| Richtung | Methode | Payload → Antwort | Zweck |
|---|---|---|---|
| Browser→cosmosd | `create_agent_token` | `AgentTokenReq{token, label}` → `AgentTokenNew{accepted, reason, token_id, secret}` | Token erzeugen; `secret` **nur hier** |
| Browser→cosmosd | `list_agent_tokens` | `TokenReq` → `AgentTokenList{tokens: list<AgentTokenInfo>}` | Übersicht **ohne** Geheimnisse/Hashes |
| Browser→cosmosd | `revoke_agent_token` | `AgentTokenRevoke{token, token_id}` → `AgentAck` | Token widerrufen |

`AgentTokenInfo` trägt bewusst **kein** `secret_hash` — das Wire-Format zum Browser enthält keinen
Hash, auch keinen unbrauchbaren.

**UI (Web).**  Im Agenten-Screen ein Token-Dialog: Bezeichnung eingeben → „Erzeugen" → das Token
erscheint **einmal** mit dem Hinweis, es jetzt zu kopieren, samt fertiger Startzeile für den Agenten.
Darunter die Liste bestehender Tokens (Bezeichnung, erzeugt, zuletzt benutzt, Anzahl Nutzungen) mit
„Widerrufen".

**Abnahme (Ergänzung zu §AP1.5):**
11. Token im UI erzeugen → Agent mit diesem Token startet und erscheint in der Liste.
12. Falsches/unbekanntes Token → Registrierung abgelehnt (Kriterium 4, jetzt konkret prüfbar).
13. Token widerrufen → eine **neue** Registrierung mit diesem Token wird abgelehnt.
14. Das Geheimnis ist nach dem Erzeugen nicht mehr abrufbar: `list_agent_tokens` liefert es nicht,
    und im KV liegt nur der sha256-Hash.
