# 06 — Abhängigkeiten & Packaging

**Ziel:** Conan/Git sind nur zwei Punkte einer fragmentierten Landschaft (siehe cosmos-vision).
cosmos soll die Ökosysteme **nicht ersetzen**, sondern **einheitlich inhaltsadressiert darüberlegen**
(CAS, 02) — Paketmanager als **Adapter**, die CAS-Artefakte produzieren/konsumieren.

## Landschaft
- **C/C++:** Conan, vcpkg, Hunter, Spack (HPC).  **Sprachen:** Cargo, npm/pnpm, pip/uv/Poetry,
  Maven/Gradle, Go-Modules, NuGet.  **OS:** apt/rpm, Nix/Guix.
- **Artefakt-Registries:** Artifactory, Nexus, **OCI-Registries** (Harbor/GHCR/Quay), Sprach-Registries.
- **OCI + ORAS:** beliebige Artefakte inhaltsadressiert in OCI-Registries ablegen → generisches
  Artefakt-Transportformat, passt direkt zum CAS-Gedanken.

## Reuse vs. Build
- **Reuse:** die Paketmanager selbst (laufen als Schritt **im Build-Container**, via `sys.exe`); ihre
  Lockfiles als **deklarierte, gehashte Inputs** (fließen in den Input-Hash, 02/03).  **OCI/ORAS** als
  Artefakt-Registry/Transport.
- **Neu in cosmos:**
  1. **Artefakt-Entität** im CAS (Name+Version+Hash+Herkunft); Paketmanager-Output wird in den CAS
     geschrieben → Dedup + Cross-Pipeline-Reuse.
  2. **Dependency-Resolver-Adapter** pro Ökosystem (dünn: ruft `conan install`/`uv pip install`/… im
     Container, erfasst die aufgelöste Closure als CAS-Tree).
  3. **OCI-Push/Pull**: minimaler OCI-Client (http + zstd/gzip **sind vorhanden** → Image-Layer als
     tar+zstd pushen) **oder** ORAS/buildkit via `sys.exe`.

## aiml-Eignung
- `sys.exe` + Container (04) → jeder Paketmanager nutzbar, ohne ihn auf dem Agent-Host zu haben.
- http-Client + zstd/gzip/tar/zip **vorhanden** → OCI-Transport ist **nativ baubar** (kein neuer Lib-
  Zwang).  Registry-Auth (Bearer/OAuth) müsste ergänzt werden.

## Empfehlung
Ökosysteme als **Adapter im Container** behandeln, Output in den CAS, **OCI/ORAS** als universelle
Senke.  Nichts von Conan/npm/… nachbauen — nur ihre Ergebnisse inhaltsadressiert einfangen.  Das
macht „Conan **und** Git **und** npm …" zu einer einheitlichen, gecachten Schicht statt vieler Silos.
