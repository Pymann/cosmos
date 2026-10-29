# 03 — Build-Sandbox & read/writeset-Tracing

**Ziel (spec 16):** pro Schritt die **tatsächlichen** gelesenen/geschriebenen Pfade erfassen →
Input-Hash-Schlüssel + Bernstein-Vertauschbarkeit + minimale Invalidierung; zugleich die Sandbox,
die fremden Build-Code **isoliert** (Leitprinzip 7).  **Eine Schicht, zwei Zwecke.**

## Wie andere Systeme Inputs bestimmen

| Ansatz | Vertreter | read/writeset | Preis |
|---|---|---|---|
| **Deklariert** | Bazel, Buck2 | exakt, vom Nutzer angegeben | Boilerplate/Disziplin („jahrelang konfigurieren") |
| **Getract (Syscall)** | BuildXL, rattle/Fabricate, Nix-Sandbox | automatisch beobachtet | braucht Trace-/Sandbox-Schicht |
| **FS-Snapshot-Diff** | Docker-Layer | nur writeset, kein readset | zu grob, Positionsschlüssel (Docker-Schwäche) |

cosmos will **getract** (automatisch, „ohne Ballast") → Sandbox nötig.

## Trace-/Sandbox-Primitive (Linux)

| Primitive | Zweck | Reife / Hinweis |
|---|---|---|
| **overlayfs** (lower=CAS-Tree ro, upper=Δ) | writeset = upper-Diff, Materialisierung | Standard; Kern der Snapshot-Erzeugung |
| **Landlock LSM** | unprivilegierte Selbst-Beschränkung auf Datei-Hierarchien | seit 5.13; Netz-Controls ABI v4+ (5.19+); 2025 systemd-Integration in Arbeit |
| **seccomp (+ notify)** | Syscall-Filter / -Vermittlung; kann Zugriffe beobachten/gaten | reif; `seccomp_unotify` erlaubt Supervisor |
| **fanotify / inotify** | Dateizugriffe mitschneiden (reads!) | fanotify kann permission-events (reads sichtbar) |
| **ptrace / strace** | Syscalls tracen | langsam, fragil — nur Fallback |
| **FUSE** (tracing-FS) | reads+writes exakt abgreifen | flexibel, I/O-Overhead |
| **idmapped mounts** | UID-Remap von gemounteten CAS-Bäumen (rootless) | ~5.12; löst das „Volume-Ownership"-Problem |

**Beste Kombination (Stand der Technik):** Build-Schritt läuft in einem **rootless Container**
(04) mit **overlayfs** (lower = materialisierter CAS-Input-Tree read-only, upper = Schreibschicht).
Danach ist **writeset = Diff der upper-Schicht** (gratis), und **readset** = beobachtete Reads via
**fanotify** oder einem **FUSE-Overlay** über dem lower-Tree.  Landlock + seccomp kapseln zusätzlich
(deny-by-default).  Das ist exakt, wie BuildXL (Detours/sandbox) und Nix (bind-mount + Namespaces)
es tun — nur auf Linux-Bordmitteln.

## Reuse vs. Build

- **Reuse (OS-Primitive, kein Nachbau):** overlayfs, Landlock, seccomp, fanotify, idmapped mounts —
  alles im Kernel vorhanden.  Werden über Syscalls/FFI angesprochen.
- **Neu in cosmos bauen:**
  1. **Sandbox-Launcher**: Namespaces + overlayfs + Landlock/seccomp aufsetzen, Schritt starten
     (hängt an 04; teilt sich den Launcher mit der Container-Ausführung).
  2. **readset-Erfassung**: fanotify-Listener ODER FUSE-Tracing-Mount → Pfadliste.
  3. **writeset**: overlay-upper-Diff → geänderte/gelöschte Pfade (Deletes = whiteouts).
  4. **Normalisierung + Hashing** der Mengen → Input-Hash (02).
  5. **Bernstein-Prüfung** (Mengen-Schnitte) → Unabhängigkeit/Reorder (reine aiml-Logik, trivial).

## aiml-Lücken

- aiml hat **keine** Namespace-/seccomp-/Landlock-/mount-Builtins (01 bestätigt voraussichtlich
  „keine").  Der Sandbox-Launcher ist entweder (a) ein kleiner **C-Helfer via FFI** (clone+unshare+
  mount+landlock+seccomp) oder (b) wird an eine bestehende **rootless-Runtime delegiert** (04:
  crun/youki übernehmen Namespaces/seccomp; cosmos reicht die FS-Config rein).  **(b) ist weniger
  Neubau.**
- readset: fanotify/FUSE braucht ebenfalls C-Anbindung; FUSE ließe sich perspektivisch in aiml
  schreiben, ist aber Aufwand.

## Empfehlung

**Delegieren statt selbst bauen, wo möglich:** Ausführung in **crun/youki** (04), overlayfs für
den Tree, writeset aus der upper-Schicht.  Für readset zunächst der **pragmatische Weg**: Build im
Container ohne Netz, lower-Tree read-only; readset grob = „alle Dateien des Input-Trees" (konservativ
korrekt, nur weniger fein) — fein später via fanotify/FUSE.  So ist Vertauschbarkeit/Cache sofort
nutzbar (konservativ), die Präzision kommt als Ausbaustufe.  **Nicht** mit ptrace anfangen.

## Quellen
- Landlock: phoronix/Landlock, dev.to Landlock-Guide, All-Systems-Go 2025 (M. Salaün, systemd-Integration).
- BuildXL/rattle/Fabricate, Nix-Sandbox, overlayfs/fanotify/seccomp/idmapped mounts (Allgemeinwissen, Cutoff 2026).
