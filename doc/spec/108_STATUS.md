# Stand der Nacht 17.10.2026 — was gebaut und was gemessen ist

Kurzfassung für den Einstieg.  Die Begründungen stehen in doc/spec/108 (Konsole und
Rechtevergabe) und doc/spec/109 (Last-Überwachung); hier steht nur, was davon **läuft**
und **wie es belegt ist**.

## Was läuft

| Bereich | Gebaut | Belegt durch |
|---|---|---|
| Freigabe je Konto (`levels`-KV) | ✅ | `test_auth_cluster` (17 Prüfungen) |
| `cosmosd --grant-email/--grant-level` | ✅ | `run_e2e_console.sh` Phase-Wechsel |
| RPCs `my_clearance`/`list_users`/`set_user_level` | ✅ | `e2e_rpc_surface` + `run_e2e_console.sh` |
| Konten-Bereich im Client (§107.6) | ✅ | `doc/spec/ui/shots/UsersScene.png` |
| Skript-Konsole (Prozess je Lauf, Freigabe am Lauf) | ✅ | `test_console` (11 Prüfungen) |
| Admin-Tor der Konsole | ✅ | beide e2e-Läufe, mit Grund im Klartext |
| Konsolen-Oberfläche + markierte Fundstelle | ✅ | `doc/spec/ui/shots/ConsoleScene.png` |
| Job-Ordner | ✅ (war schon da) | `client/shell_screen.aiml` `sync_folders` |
| CPU/Speicher Server + Agenten | ✅ | `t_res`, `run_e2e.sh` (echter Agent meldet 48 MB) + `doc/spec/ui/shots/AgentsScene.png` |

## Wie man es startet

```bash
./run_web.sh --build          # baut auch die Angebots-Bibliothek der Konsole
./cosmosd --grant-email du@example.com --grant-level 1    # bei GESTOPPTEM Dienst
```

Die Konsole erscheint danach als Reiter „Konsole", die Rechtevergabe als „Konten" —
beide nur für Konten mit Freigabe 1.

## Was NICHT läuft, und warum das hier steht

- **Die Konsole ist nicht für fremde Nutzer freigegeben** (F108-13).  Die Zulassung aus
  spec/65 wirkt zur Übersetzungszeit; sie ersetzt keine Sandbox.  Voraussetzung ist der
  User-Namespace aus §AP2.A, und der hängt am AppArmor-Profil.
- **Das Angebot ist winzig**: `cosmos_whoami` und `cosmos_cluster_summary`, beide nur
  lesend und aus einem Schnappschuss.  Jede weitere Zeile ist eine Rechteentscheidung
  (doc/spec/108 §11), keine Bauaufgabe.
- **Zwei gleichzeitige Konsolenläufe sind nicht erzwungen worden** (C7).  Je Lauf
  entstehen eine eigene Datei und ein eigener Prozess; geprüft ist es nicht.
- **Maschinenlesbare Compiler-Diagnostik fehlt** — die Fundstelle wird aus dem Logtext
  gelesen (F108-16b).  Das ist der letzte offene Punkt aus doc/spec/98 §98.1.
- **Die Last ist die des PROZESSES, nicht der Maschine** (F109-1).  Für „ist der Knoten
  voll?" braucht es eine andere Messung.

## Was als Nächstes dran wäre

1. **Maschinenlesbare Compiler-Diagnostik** (doc/spec/98 §98.1, letzter offener Punkt).
   Die Fundstelle wird heute aus dem Logtext gelesen (F108-16b).  Wer das baut, ersetzt
   die Näherung — nicht ergänzen, sonst gibt es zwei Wahrheiten über dieselbe Meldung.
2. **Das Angebot erweitern** (§11).  Scheibe 1 ist nur lesend über einen Schnappschuss;
   wirkende Funktionen gehen über eine RPC zurück an den Server, damit er der einzige
   Schreiber bleibt.  Vor jeder neuen Zeile: spec/23 und spec/61 lesen (F108-9d).
3. **Die Konsole für Nicht-Admins öffnen** — erst nach der Isolation aus §AP2.A.  Die
   Tabellenzeile von `|1` auf `|7` zu ändern ist eine Zeile; die Voraussetzung dafür ist
   es nicht.
4. **`RunInfo.started_by`** (§AP2.E) fehlt weiterhin: es gibt keine Spur, wer einen LAUF
   gestartet hat.  Die Konsole hat ihre Spur (F108-10), die Läufe nicht.

## Hinterlassenschaften dieser Nacht

- In der Entwicklungs-DB (`aiondb/`) stehen aus einem manuellen Testlauf die Konten
  `alice@example.com` und `carl@example.com` sowie ein neues `levels`-KV.  Ich habe dort
  **nichts gelöscht** — `users.kvwal` kann echte Konten enthalten.
- `.e2e_console/` und `.test_run/` sind Arbeitsverzeichnisse der Abnahmen (jetzt in
  `.gitignore`).
