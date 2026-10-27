#!/usr/bin/env bash
# PROBE: Trägt dieser Host die Isolationsschicht aus doc/spec/91 §AP2.A (Weg 2)?
#
# Geprüft wird die Kette, die das Schritt-Modell (§AP2.D) braucht:
#   1. ID-Bereiche   (/etc/subuid, /etc/subgid)
#   2. Namespace-Politik (sysctl + AppArmor)
#   3. User-Namespace erzeugen  → drinnen uid 0
#   4. overlayfs IM Namespace mounten (lower=ro, upper=Δ)
#   5. writeset = Diff der upper-Schicht  ← das ist der Snapshot-Mechanismus
#
# Exit 0 = die ganze Kette trägt.  Sonst sagt die Probe, welches Glied fehlt
# und was dagegen zu tun ist.  Keine Systemänderung, nur Prüfungen.
#
# Später wird genau diese Kette der Agent beim Start prüfen (Abnahme A5).
set -uo pipefail
cd "$(dirname "$0")"

WORK="${TMPDIR:-/tmp}/cosmos_isolation_probe.$$"
FAILED=0
step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '  ok   — %s\n' "$1"; }
bad()  { printf '  FEHLT — %s\n' "$1"; FAILED=$((FAILED + 1)); }
note() { printf '         %s\n' "$1"; }

cleanup() { rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT
mkdir -p "$WORK"

ME="$(id -un)"
printf 'Host: %s, Kernel %s, Nutzer %s (uid %s)\n' \
    "$(uname -n)" "$(uname -r)" "$ME" "$(id -u)"

# ── 1. ID-Bereiche ───────────────────────────────────────────────────────────
step 1 "Untergeordnete ID-Bereiche"
SUB_U="$(grep "^${ME}:" /etc/subuid 2>/dev/null | head -1)"
SUB_G="$(grep "^${ME}:" /etc/subgid 2>/dev/null | head -1)"
if [ -n "$SUB_U" ] && [ -n "$SUB_G" ]; then
    ok "subuid=${SUB_U#*:}  subgid=${SUB_G#*:}"
else
    bad "kein Eintrag für '$ME' in /etc/subuid bzw. /etc/subgid"
    note "nötig erst für das Abbilden MEHRERER IDs; eine einzelne geht ohne"
fi
if command -v newuidmap >/dev/null 2>&1; then
    ok "newuidmap/newgidmap vorhanden ($(command -v newuidmap))"
else
    note "newuidmap fehlt (Paket uidmap) — nur für Mehrfach-Abbildung nötig;"
    note "die erste Ausbaustufe bildet NUR die eigene uid auf 0 ab."
fi

# ── 2. Politik ───────────────────────────────────────────────────────────────
step 2 "Namespace-Politik"
UCLONE="$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "-")"
MAXNS="$(sysctl -n user.max_user_namespaces 2>/dev/null || echo "-")"
AA_NS="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo "-")"
[ "$UCLONE" = "0" ] && bad "kernel.unprivileged_userns_clone=0" || ok "unprivileged_userns_clone=$UCLONE"
[ "$MAXNS" = "0" ] && bad "user.max_user_namespaces=0" || ok "max_user_namespaces=$MAXNS"
if [ "$AA_NS" = "1" ]; then
    note "kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu-Riegel)"
    note "→ unconfined Prozesse werden beim Erzeugen in das Profil"
    note "  'unprivileged_userns' überführt, das 'audit deny capability' setzt:"
    note "  Namespace ja, MOUNTEN darin nein.  cosmos braucht daher ein eigenes"
    note "  AppArmor-Profil (wie podman eines hat) — siehe Schritt 4."
else
    ok "apparmor_restrict_unprivileged_userns=$AA_NS"
fi

# ── 3. Namespace erzeugen ────────────────────────────────────────────────────
step 3 "User-Namespace erzeugen (uid 0 innen)"
NS_OUT="$(unshare -r id -u 2>&1)"
if [ "$NS_OUT" = "0" ]; then
    ok "drinnen uid 0"
    NS_OK=1
else
    bad "unshare -r schlug fehl: $NS_OUT"
    # Nicht raten lassen: AppArmor protokolliert die Verweigerung.  Damit ist
    # unterscheidbar, ob der Riegel greift oder etwas anderes im Weg ist.
    DENIAL=""
    for LOGF in /var/log/kern.log /var/log/syslog /var/log/audit/audit.log; do
        [ -r "$LOGF" ] || continue
        DENIAL="$(grep 'apparmor="DENIED"' "$LOGF" 2>/dev/null                   | grep -E 'uid_map|userns|profile="unprivileged_userns"'                   | tail -1)"
        [ -n "$DENIAL" ] && break
    done
    if [ -n "$DENIAL" ]; then
        note "BELEGT per Audit-Log — es ist AppArmor, nicht die Umgebung:"
        note "$(printf '%s' "$DENIAL" | sed 's/.*apparmor=/apparmor=/' | cut -c1-150)"
        note "Abhilfe: deploy/apparmor/cosmos-agent einspielen (Anleitung im Kopf"
        note "der Datei).  NICHT den sysctl systemweit auf 0 setzen."
    else
        note "kein Audit-Eintrag lesbar — dann entweder kein AppArmor-Riegel,"
        note "oder dieser Prozess läuft in einer Sandbox, die Namespaces sperrt."
    fi
    NS_OK=0
fi

# ── 4./5. overlayfs im Namespace + writeset ──────────────────────────────────
step 4 "overlayfs im Namespace + writeset aus der upper-Schicht"
if [ "$NS_OK" != "1" ]; then
    bad "übersprungen (Schritt 3 fehlgeschlagen)"
else
    mkdir -p "$WORK"/{low,up,work,merged}
    echo "input-aus-dem-CAS-Tree" > "$WORK/low/vorhanden.txt"
    OVL_OUT="$(unshare -rm --propagation private sh -c '
        set -e
        cd "$1"
        mount -t overlay cosmos_probe \
            -o lowerdir=low,upperdir=up,workdir=work merged
        cat merged/vorhanden.txt >/dev/null
        echo "neu geschrieben" > merged/erzeugt.txt
        printf "geaendert\n" >> merged/vorhanden.txt
        printf "UPPER:"; (cd up && ls -1 | tr "\n" " ")
        printf "\n"
    ' _ "$WORK" 2>&1)"
    if printf '%s' "$OVL_OUT" | grep -q "^UPPER:"; then
        ok "gemountet, gelesen, geschrieben"
        ok "writeset (upper-Diff) = $(printf '%s' "$OVL_OUT" | sed -n 's/^UPPER://p')"
        note "genau das ist der Snapshot-Mechanismus aus §AP2.D: die upper-Schicht"
        note "IST das writeset, ohne zusätzliche Beobachtung."
    else
        bad "overlayfs-Mount im Namespace nicht möglich"
        note "Ausgabe: $(printf '%s' "$OVL_OUT" | head -3 | tr '\n' ' ')"
        if [ "$AA_NS" = "1" ]; then
            note "erwartbar bei apparmor_restrict_unprivileged_userns=1 —"
            note "das Profil 'unprivileged_userns' verbietet Capabilities."
            note "Abhilfe: eigenes AppArmor-Profil für den Agenten mit"
            note "'userns' UND behaltenen Capabilities (NICHT den sysctl auf 0)."
        fi
    fi
fi

printf '\n========================================================\n'
if [ "$FAILED" -eq 0 ]; then
    echo "TRÄGT — Weg 2 ist auf diesem Host ohne Systemänderung möglich."
    exit 0
fi
echo "$FAILED Glied(er) fehlen — Details oben."
echo "Solange das so ist, laufen Jobs unter der Identität des Agenten"
echo "(doc/spec/90 §AP1.6: Agent nicht als root starten)."
exit 1
