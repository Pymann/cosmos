# 04 — Container, Isolation, rootless Ausführung

**Ziel (Leitprinzip 7):** fremder Build-Code läuft nie als root/mit Host-Privilegien; rootless +
userns pro Tenant, caps gedroppt, seccomp/MAC; für Nicht-Vertrauenswürdiges stärkere Isolation.
Der Agent bleibt minimal (Container-Laufzeit + aiml), Werkzeuge kommen aus Images/CAS.

## Runtimes & Isolationsstufen

| Schicht | Vertreter | Isolation | Kosten | cosmos-Einsatz |
|---|---|---|---|---|
| **OCI-Runtime** | **runc** (Referenz), **crun** (C, schnell/klein), **youki** (Rust, CNCF-Sandbox) | Namespaces+cgroups+seccomp | gering | Standard-Ausführung; rootless unterstützt |
| **User-space-Kernel** | **gVisor** (Sentry fängt Syscalls ab) | stärker, shared-kernel-Grenze bleibt | Syscall-/I-O-Overhead | mittleres Risiko, I/O-leicht |
| **microVM** | **Kata** (eigener Gast-Kernel via KVM; VMM Cloud-Hypervisor/FC/QEMU), **Firecracker** (minimal, <125 ms Boot) | je Workload eigener Kernel | VM-Overhead/Orchestrierung | **Default für fremden/Fork-Code** (Kata); FC für Eigenbau |

**Belegte Kernaussagen:** runc = Default/Referenz; rootless von runc/crun/youki unterstützt
(userns-Remapping).  gVisor teilt die Host-Kernel-Grenze (Risiko-Rest), kostet I/O.  Kata gibt
jedem Workload einen eigenen Gast-Kernel, aus k8s-Sicht wie ein Container → am leichtesten für CI.
Firecracker bootet <125 ms, aber DIY-Orchestrierung.  **Ein reiner Container ohne Sandbox ist keine
Vertrauensgrenze** (dokumentierter Fall: bösartiges Build-Skript las ein gemountetes Admin-Token und
erreichte Host-Netz).

## Rootless-Mechanik (die Pflicht)
- **User-Namespaces**: Container-root → unprivilegierte Host-UID (100000+); **pro Tenant eigener
  UID-Bereich** → Isolation + Mandantenbindung (Account=Tenant).
- **caps drop ALL**, nur Nötiges zurück; **seccomp**-Profil; **AppArmor/SELinux**; `no-new-privileges`;
  read-only rootfs + tmpfs.
- **idmapped mounts** lösen das UID-Mapping gemounteter CAS-Bäume (03).
- **Build-in-Build** ohne privileged: **rootless BuildKit / kaniko / buildah**.

## „Repo/Target = Container" (Design-Entscheidung, spec 13)
Der Container ist die **materialisierte, gecachte Umgebung** eines Targets (aus dem CAS-Tree +
Toolchain-Layer), zugleich die **Sandbox** (03) und optional das Deploy-Artefakt.  Kanonisch bleibt
der CAS-Stand; das Image ist Projektion.  **Build ≠ Packaging:** Layering nach Referenzhäufigkeit
(Nix `dockerTools`-Muster), nicht nach Build-Reihenfolge → kein Docker-Kaskaden-Rebuild.

## Reuse vs. Build
- **Reuse (nicht nachbauen):** crun **oder** youki als OCI-Runtime (Namespaces/cgroups/seccomp/
  rootless erledigt die Runtime); gVisor/Kata als wählbare Isolationsstufe; buildkit/kaniko fürs
  Image-Bauen; OCI/ORAS fürs Registry.
- **Neu in cosmos bauen:**
  1. **Runner/Launcher-Adapter** in aiml: `config.json` (OCI-Spec) generieren, Runtime via `sys.exe`
     starten, Lebenszyklus/Exit/Log einsammeln (der durable Job, Kapitel 05, wird so erweitert).
  2. **Image-/Tree-Materialisierung** aus dem CAS (overlay lower = CAS-Tree) — hängt an 02/03.
  3. **Isolationsstufen-Policy**: eigener Tenant→rootless crun; fremder/öffentlicher Code→Kata/gVisor.
  4. **Per-Tenant-UID-Bereiche** + idmapped mounts.

## aiml-Lücken
- aiml hat **keine** Container-/Namespace-Builtins (spec 40 „containerization" ist vermutlich Doku/
  Platzhalter — 01 bestätigt).  Aber: **`sys.exe` genügt**, um crun/youki als Subprozess zu fahren
  (OCI-Spec als JSON schreiben, `sys.serialize` vorhanden).  Kein FFI nötig für den Start — nur die
  Runtime muss auf dem Agent liegen (das **eine** erlaubte „Werkzeug auf dem Agent", weil es der
  Isolations-Kern ist; alternativ statisch mitgeliefert).

## Empfehlung
**crun** (klein/schnell, C) als Default-Runtime via `sys.exe`; **Kata** als Isolationsstufe für
fremden Code; rootless + userns pro Tenant; Image-Materialisierung aus CAS mit overlayfs.  cosmos
baut **nur den Adapter + die Policy**, nicht die Runtime.  Das hält den Agent minimal und die
Sicherheitsgrenze real.

## Quellen
- Northflank/Edera-Vergleiche (Vendor — mit Vorsicht): Kata vs Firecracker vs gVisor.
- youki (CNCF-Sandbox, rootless), crun (C), runc (Referenz) — rust-digger/docs.rs/pistack-Guide.
- DevSecOps-Sandboxing-Guide (securityalliance): ephemere Runner, keine Secrets in untrusted Jobs, deny-egress; „Container ohne Sandbox ≠ Trust-Boundary".
- Red Hat OpenShift sandboxed containers (VM-Ansatz fürs Image-Bauen).
