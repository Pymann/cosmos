#!/bin/bash
# Ein exodus-Projekt in kontors exodus-Repository veroeffentlichen (aiml
# spec/68 §6.1, doc/spec/111 §111.9):
#
#   KONTOR_TOKEN=… tools/kontor_publish.sh <repo-dir> <kontor-url>
#     PUT <url>/exodus/<name>/<version>/exodus.json
#     PUT <url>/exodus/<name>/<version>/package
#
# Mitgeht, was unter Versionskontrolle steht — Baureste, Caches und Laufdaten
# gehoeren nicht in ein Quellpaket, und `git ls-files` weiss das besser als
# jede Ausschlussliste.  Das Archiv ist reproduzierbar (sortiert, mtime 0,
# owner 0:0, gzip -n): gleiche Quellen, gleiche Bytes, und kontor meldet eine
# Wiederveroeffentlichung als `unchanged`.
#
# Das Token geht ueber eine Header-Datei, nie auf die Kommandozeile (Argumente
# sind in /proc fuer jeden auf der Maschine lesbar).
set -eu
REPO="${1:?Repo-Verzeichnis}"
URL="${2:?kontor-URL}"
: "${KONTOR_TOKEN:?KONTOR_TOKEN setzen (ein kontor-Token mit der Rolle writer)}"

cd "$REPO"
# Welche Datei das Projekt benennt: `exodus.json`, wo es eine gibt (ufo,
# kontor), sonst `aiml.tool.json` — cosmos hat nur `exodus-<ding>.json`, und
# der Name eines Projekts steht nicht in dreizehn Dateien.  Genau diese Datei
# legt kontor als Manifest ab; sie muss name und version nennen, weil kontor
# sie gegen die URL prueft.
MANIFEST=exodus.json
[ -f "$MANIFEST" ] || MANIFEST=aiml.tool.json
[ -f "$MANIFEST" ] || { echo "$REPO hat weder exodus.json noch aiml.tool.json" >&2; exit 1; }
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$MANIFEST" | head -1; }
NAME="$(field name)"
VERSION="$(field version)"
[ -n "$NAME" ] && [ -n "$VERSION" ] || {
    echo "$MANIFEST in $REPO nennt nicht beides: name und version" >&2; exit 1; }

STAGE="$(mktemp -d)"
HDR="$(mktemp)"
trap 'rm -rf "$STAGE" "$HDR"' EXIT
chmod 600 "$HDR"
printf 'Authorization: Bearer %s\n' "$KONTOR_TOKEN" > "$HDR"

DIR="$NAME-$VERSION"
mkdir "$STAGE/$DIR"
git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$STAGE/$DIR"
# Was nicht unter Versionskontrolle steht, ist nicht im Archiv — und ein
# Werkzeug ohne aiml.tool.json wird von `aiml venv install` uebersprungen, ohne
# dass jemand merkt, warum (hier passiert, cosmos, 2026-10-31).
for need in "$MANIFEST" aiml.tool.json; do
    [ -f "$need" ] || continue
    [ -f "$STAGE/$DIR/$need" ] || {
        echo "$need liegt in $REPO, aber nicht in git — 'git add $need'" >&2; exit 1; }
done
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go+rX,go-w' -C "$STAGE" -cf - "$DIR" \
    | gzip -n -9 > "$STAGE/package.tar.gz"

BASE="${URL%/}/exodus/$NAME/$VERSION"
put() {
    code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$HDR" -X PUT --data-binary @"$1" "$2")
    case "$code" in 200|201) ;; *) echo "$2: HTTP $code" >&2; exit 1 ;; esac
}
put "$MANIFEST" "$BASE/exodus.json"
put "$STAGE/package.tar.gz" "$BASE/package"
echo "veroeffentlicht: $NAME $VERSION ($(stat -c%s "$STAGE/package.tar.gz") Bytes) → $BASE"
