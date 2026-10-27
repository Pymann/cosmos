# 12 — Transport & Skalierung der Control-Plane

**Ziel (spec 21):** horizontal skalierbar, keine Single-Point-of-Contention wie der Jenkins-Master;
Live-Push an authentifizierte Abonnenten.

## Ist-Stand (01)
- **Transport vorhanden & stark:** `mirror` (Objekt-Sync/RPC, `listen/listen_tls`, targeted
  `send_rpc`, peers), ws/wss, http(s), net TCP+UDP.  Der cosmos-Daemon nutzt schon **auth. Server-
  Push** (architecture §7.4): Abonnenten per `peer_id`, Push nur an sie (kein Broadcast-Leak).
- **Engpass:** **AionDB ist single-node embedded** (keine Replikation/Clustering).  TLS heute
  klassisch (OpenSSL 3.0.13, kein Hybrid-PQC — 11).  Kein QUIC/HTTP2.

## Skalierungsstufen
1. **Mehrere zustandslose Daemons über einem geteilten AionDB** (ein Host/Volume).  LB davor
   (nginx/envoy, ws-fähig).  Konfliktfreiheit über **Lease/optimistisches Locking** auf Job-
   Zuweisung (07).  → erste echte Horizontalität, begrenzt durch den einen Store.
2. **Store-Replikation/Partitionierung** (der große Schritt): AionDB fehlt das; Optionen —
   (a) AionDB um Replikation erweitern (WAL-Shipping/Raft), (b) Blob/CAS-Daten in einen externen
   inhaltsadressierten Store (S3-artig/OCI) auslagern und nur Metadaten lokal, (c) pro Region eine
   Control-Plane + globale Föderation.  **Honest:** das ist Forschung/Großbaustelle.
3. **Transport-Härtung:** OpenSSL 3.5+ → Hybrid-PQC (11); optional QUIC später.

## Reuse vs. Build
- **Reuse:** externer LB (nginx/envoy) vor den Daemons; S3/OCI als externer Blob-Store (Stufe 2b);
  Raft-Bibliothek (falls 2a) via FFI.
- **Neu in cosmos:** Daemon **zustandslos** machen (Subscriber-Registry + Scheduler-Leases im
  geteilten Store statt im Prozess), idempotente RPCs; später die Replikationsschicht.

## aiml-Eignung
- `mirror`/ws/http + auth. Push sind **sehr gut** für das Live-/RPC-Fundament.
- **Lücken:** geteilter Subscriber-/Lease-Zustand (heute prozesslokal `g_cluster_subs`), Store-
  Replikation, Hybrid-PQC-Transport (Relink), QUIC.

## Empfehlung
Kurzfristig: Daemon **zustandslos** über AionDB (Subscriber/Leases in den Store), ein LB davor →
mehrere Instanzen auf einem Host.  Mittelfristig: Blob/CAS in externen Objektspeicher auslagern
(entkoppelt Rechen- von Speicher-Skalierung), OpenSSL-3.5-Relink für PQC-Transport.  Langfristig:
Store-Replikation/Föderation (eigenes großes Thema).

## Quellen
- aiml `mirror`/ws/http (Inventur 01); architecture §7.4 (auth. Push).  Raft/WAL-Shipping, envoy/nginx, S3/OCI (Allgemeinwissen).
