# 05 — Git-Ingestion-Adapter

**Ziel (Diskussion 2026-10-08):** git **nicht** auf jedem Agent, sondern als **Adapter an einer
Ingestion-Grenze** → `repo@ref` wird **einmal** in einen inhaltsadressierten Tree (02) aufgelöst;
Agenten konsumieren Trees, brauchen kein git.  Credentials nur an dieser Grenze (Secret-Vorteil).

## Optionen

| Option | reads/clone/fetch | write-ops | Einbindung | Risiko |
|---|---|---|---|---|
| **git-CLI via `sys.exe`** | alles (CLI komplett) | alles | trivial (Subprozess, capture) | git muss am Adapter installiert sein; Textparsing (`--porcelain`/`-z`/`--format`) |
| **libgit2 (FFI)** | mature | mature (push/merge/status) | aiml-FFI (spec 35) + Link | C-API-Bindings schreiben; LFS/Submodule teils fummelig |
| **gitoxide / `gix` (FFI/Rust)** | **solide** (clone, fetch, checkout, object/ref r/w, index, pathspec, gitignore/attrs) | **teilweise** (status in Arbeit; push/merge/rebase offen) | C-ABI-Wrapper um die Rust-Crate | Binaries „forever unstable"; Lib-Pfad (`gix`) gemeint; **1 Hauptmaintainer** (Reife-Risiko) |

**Belegte Einschätzung:** gitoxide ist **lese-/klon-/fetch-stark**, write-seitig noch keine
libgit2-Ablösung; libgit2 ist für Schreiboperationen die sichere Wahl.  Für **Ingestion** (clone/
fetch/checkout/read → CAS) genügt das done-Set von gitoxide; write-ops braucht der Adapter kaum.

## Reuse vs. Build
- **Reuse:** eine der drei Git-Implementierungen — **an genau einer Stelle** (dem Ingestion-Dienst),
  nicht n-fach.  Dort lohnt sich auch libgit2/gitoxide via FFI (ein gepflegter Einstiegspunkt).
- **Neu in cosmos bauen:**
  1. **Ingestion-Dienst/Stage** `repo@ref → CAS-Tree`: fetch (inkrementell, nicht full-clone),
     Working-Tree in den CAS schreiben (02), Commit-SHA ↔ Tree-Hash mappen (ActionCache-artig →
     derselbe Commit = derselbe Tree, kein zweiter Checkout).
  2. **Credential-Handling** nur hier (Tokens/Keys), nie auf Agenten.
  3. **LFS/Submodule/Shallow** sauber abbilden (Adapter-intern).
  4. Perspektivisch **Git-Trigger/Historie** (Kapitel 14) über `ls-remote`/Webhooks.

## aiml-Weg
- **Sofort machbar, null neue Abhängigkeit:** git-CLI via `sys.exe` (vorhanden, mit capture/cwd/
  timeout).  Das ist der pragmatische Start — die „git-überall"-Sorge entfällt, weil git nur am
  **einen** Adapter liegt (nicht auf Agenten).
- **Später, prozessfrei/strukturiert:** libgit2 **oder** gitoxide via aiml-FFI (spec 35) — hinter
  **derselben** aiml-Schnittstelle (`Git.clone/fetch/head_sha/…`), sodass der Wechsel CLI→Lib ein
  reiner Implementierungstausch ist.

## Empfehlung
**CLI-Adapter zuerst** (einfach, sofort, git nur am Rand), gekapselt hinter einer stabilen
`Git`-Schnittstelle; **libgit2** als erste Lib-Option für Prozessfreiheit (reifer als gitoxide bei
write-ops, obwohl der Adapter kaum write braucht); **gitoxide** beobachten.  Kernaussage: **git ist
ein Ingestion-Detail an einer Grenze, keine Agent-Abhängigkeit.**

## Quellen
- gitoxide: GitoxideLabs/gitoxide README + `crate-status.md`, rust-digger/gix-status (1 Maintainer, Reife-Subscore niedrig), lwn.net.
- libgit2: Allgemeinwissen (Suche lieferte wenig), reife C-Lib mit `git2`-Bindings.
