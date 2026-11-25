#!/bin/bash
# cosmos vom kontor-Server entfernen (doc/spec/112 §112.4).
#
#   sudo deploy/server/uninstall.sh            Dienste, Programme, Werkzeuge, Profil weg
#   sudo deploy/server/uninstall.sh --purge    zusaetzlich Daten, Zugaenge und Dienstnutzer
#
# kontor und 9rooms werden nicht angefasst.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "als root ausfuehren (sudo)" >&2; exit 1; }
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

systemctl disable --now cosmos-agent cosmos-api cosmosd 2>/dev/null || true
rm -f /etc/systemd/system/cosmosd.service /etc/systemd/system/cosmos-api.service /etc/systemd/system/cosmos-agent.service
systemctl daemon-reload
if [ -f /etc/apparmor.d/cosmos-server ]; then
    apparmor_parser -R /etc/apparmor.d/cosmos-server 2>/dev/null || true
    rm -f /etc/apparmor.d/cosmos-server
fi
rm -rf /opt/cosmos /usr/local/libexec/cosmos
rm -f /usr/local/sbin/cosmosctl /etc/tmpfiles.d/cosmos-agent.conf
echo "Dienste, Programme und Werkzeuge entfernt."
if [ "$PURGE" -eq 1 ]; then
    rm -rf /var/lib/cosmos /var/lib/cosmos-agent /etc/cosmos /etc/cosmos-agent
    userdel cosmos-agent 2>/dev/null || true
    userdel cosmos 2>/dev/null || true
    echo "Daten, Zugaenge und Dienstnutzer entfernt."
else
    echo "Stehen geblieben: /var/lib/cosmos*, /etc/cosmos* (Tokens!), Nutzer cosmos/cosmos-agent — --purge entfernt sie."
fi
