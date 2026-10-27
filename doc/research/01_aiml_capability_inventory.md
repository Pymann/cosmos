# 01 — aiml-Laufzeit: Fähigkeiten & Lücken für cosmos

Am Repo verifiziert (`test/aiml`, Spec + `src/`).  Legende: ⭑ stark · ~ vorhanden/begrenzt · ✗ fehlt.

## Was da ist (nutzbar als Fundament)

| Bereich | Stand | Konkret (Builtins / Quelle) |
|---|---|---|
| **Prozesse** | ⭑ | `sys.exe(argv,{cwd,env,shell,timeout,capture})`→`process`; Methoden `wait,kill,pid,returncode,running,read_line,read_err_line,stdout/stderr_buffer,eof,detach,merge`; `sys.process_attach`. `process_runtime.cpp` (fork+execvp, Capture-Pipes, Timeout SIGTERM→SIGKILL, Orphan-Reaper). Spec 23 §5. |
| **Code-Objekte** | ~ | `sys.bundle/exec/clone`, `Code`-Typ. `sys.exec` shared-context **nur JIT** (AOT → -2). Spec 29_*. |
| **IO/FS** | ~ | `io.open/open_binary/read/read_all/read_file/write/write_file/read_at/seek/skip/tell/eof/exists/is_file/is_dir/file_size/list_dir/mkdir/mkdir_all/remove/remove_all/rename/read_asset`; binäre Reader; `path`-Typ (`cwd,home,temp_dir,config_dir,current_exe`). |
| **Netz/Transport** | ⭑ | `net` (TCP **+UDP**), `tls` (Client+Server, min TLS1.2, verify), `ws/wss` (Client+Server, `send_binary,send_kv_blob,peer_ip,poll`), `http` (Client + Server/`server_tls`, Ranges, client_ip), `mirror` (sync/RPC, `listen/listen_tls`, `register/register_id`, peers). Spec 32_*, 44_5. |
| **Persistenz** | ⭑ | `db`: `open_kv/open_timeseries/open_vec/query/checkpoint/kv_evict/reload_kv/get_path/set_path`; Typen `Kv/Store/TimeSeries/VecStore`, WAL. **TimeSeries für Metriken: JA** — `aiml_db_ts_append` + `aiml_db_ts_range(from,to)`. Indexierte Felder (`db_indexed`). Heap-Serialisierung. Spec 31/45/23_2. |
| **Digests/HMAC** | ⭑ | `hash`: `sha256,sha512,sha3_256,keccak256,ripemd160,blake2b,blake2s,md5` (+`_raw`), `hmac_sha256/512`, `pbkdf2,const_time_eq,crc32`. CSPRNG `math.random_hex/random_int`. OpenSSL gelinkt. |
| **Serialisierung** | ⭑ | `sys.serialize/deserialize` (JSON/yyjson), binärer Heap-Serializer (`ser_runtime.cpp`, delta-tx, deep_copy), `yaml`. Spec 29/45/60. |
| **FFI** | ⭑ | `extern: "C"`, Libs in `exodus.json linker.libraries`, `sys.load_lib/load_sym` (dlopen), libffi gelinkt. **Schon gelinkt: zstd, lz4, brotli, zip, zlib.** Beispiele `tests/test_ffi.aiml`. Spec 34/35. |
| **Nebenläufigkeit** | ⭑ | Threads (`spawn`→`thread_handle.join/detach`), `chan<T>` (gepuffert), `lock`. Spec 26/27/47. |
| **Grafik/Engine** | ⭑ | `gl,ui,engine,input,prefabs,gltf,mirror` — native GLFW/OpenGL (Shader, Texturen, FBOs, instanced draw, Widgets, Charts, Hit-Test). Spec 43_*/44_*. |
| **Build** | ⭑ | `exodus.json`, LLVM 18, **JIT + AOT + wasm32 (emcc)** + Hot-Reload (fptable/trampoline). Spec 30_*/36/37. |
| **Kompression/Archive** | ⭑ | `compress`: `gzip,zstd,lz4,brotli,zlib,deflate`, `tar_gz/untar_gz,zip/unzip`, `zip_entries/tar_entries`. Spec 33_2. |

## Was fehlt (muss gebaut/angebunden werden)

| Lücke | Relevanz für cosmos | Weg |
|---|---|---|
| **OS-Isolation** ✗ | Least-Privilege/rootless, Multi-Tenant-Sandbox (03/04) | **komplett abwesend** (kein `unshare/seccomp/cgroup/setns/mount/pivot_root/chroot`). Spec 40/41 = Vision. → `extern "C"` zu libc **oder** crun/youki via `sys.exe`. |
| **User-Code-Sandboxing** ✗ | fremden Build-Code sicher ausführen | `sys.exec` shared = **in-process, voller Host-Zugriff**. Nur **wasm32** bietet heute echte Isolation. → Container/VM (04). |
| **Content-Addressing** ~ | CAS/Versionierung (02) | nur **FNV-1a 32-bit** (Code.id); sha256 da, aber nicht auf Strukturen angewandt; **kein Merkle/CAS**, **kein blake3** (nur blake2). → CAS nativ auf KV + Tree-Hashing bauen. |
| **Rekursiver FS-Walk/Copy** ✗ | Tree-Materialisierung aus CAS, Checkout | nur flaches `list_dir`; kein `walk/copy_tree`; **Globber (Spec 42_1) nicht implementiert**. → nativ bauen (rekursiv über `list_dir`+`is_dir`). |
| **FS-Metadaten/overlay/symlink/chmod/stat** ✗ | overlayfs-Snapshots, Rechte | fehlen. → via libc-FFI oder Runtime-Delegation. |
| **Asymmetrische Krypto / Signaturen** ✗ | Artefakt-/Snapshot-Provenienz, Cert-Gen (11) | **gar keine** (RSA/ECDSA/Ed25519/X509 fehlen). → OpenSSL-API/FFI. |
| **Post-Quanten-Krypto** ✗ | quantensichere Security (11) | **liboqs nicht gelinkt**; System-OpenSSL **3.0.13** (kein ML-KEM). → OpenSSL 3.5+ relinken bzw. liboqs-FFI. |
| **Clustering/Replikation** ✗ | Skalierung/HA (07/12) | AionDB ist **single-node embedded**. → mehrere Control-Plane-Instanzen über geteilten Store / Replikationsschicht. |
| **Metrik-Ingest (OTLP/Prometheus)** ✗ | Observability (08) | TimeSeries-Store da, aber kein Exposition-/OTLP-Decoder. → http-Endpoint + Decoder bauen. |
| **QUIC/HTTP2** ✗ | moderner Transport | fehlt; ws/mirror reichen vorerst. |

## Folgerung
cosmos steht auf einem **ungewöhnlich breiten Fundament**: Prozesse, Netz/TLS/WS/HTTP/mirror,
eingebettete WAL-DB **inkl. TimeSeries für Metriken**, Digests/HMAC/PBKDF2, JSON/YAML/Binär-Ser,
**FFI zu beliebigen C-Libs** (zstd/lz4/zip schon da), Threads/chan/locks, **native OpenGL-Engine**,
JIT/AOT/wasm/Hot-Reload, zstd/zip-Kompression.  Die großen **Neu-Baustellen** sind exakt die
Zukunftsthemen: **OS-Isolation/Container**, **CAS/Content-Addressing + FS-Walk**, **asym./PQ-Krypto**,
**Metrik-Ingest** und **Clustering** — und für fast alle ist der Weg dank **starkem FFI** „reife
C-Bibliothek anbinden" statt „from scratch".
