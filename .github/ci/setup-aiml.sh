#!/usr/bin/env bash
# Fetch a prebuilt aiml (compiler + runtime) from Pymann/aiml and make a venv
# of it (aiml spec/68), so that every exodus.json here finds $AIML and
# $AIML_VENV/lib (F68-23).
#
# Source of the binary, first that works:
#   0. kontor, when AIML_KONTOR_URL is set (cosmos doc/spec/112 §112.6): the
#      tarball cosmos mirrored there -- aiml/<AIML_RELEASE>/... when a release
#      is pinned, else the one aiml/latest.env names.  Needs curl only.
#        AIML_KONTOR_CA      PEM text of kontor's certificate (self-signed)
#        AIML_KONTOR_TOKEN   only if kontor refuses anonymous reads
#        AIML_KONTOR_STRICT  1 = fail instead of falling back to GitHub
#   1. the release named by AIML_RELEASE (e.g. v1.0.2.4), else the newest
#      published release, prereleases included (drafts are not visible here);
#   2. the aiml-linux-x86_64 artifact of the newest green CI run on master.
# The tarball comes with its .sha256 and is checked against it.
#
# Usage: setup-aiml.sh <venv-dir>      (1. and 2. need GH_TOKEN for the gh CLI)
set -euo pipefail

VENV="${1:?venv dir}"
REPO="${AIML_REPO:-Pymann/aiml}"
DL="$(mktemp -d)"

# kontor: read, never sourced (F112-15) -- latest.env comes from the network.
from_kontor() {
    local url="${AIML_KONTOR_URL%/}" curl_args=(-fsS --retry 3 --connect-timeout 15) ver tarball hdr
    if [ -n "${AIML_KONTOR_CA:-}" ]; then
        printf '%s\n' "$AIML_KONTOR_CA" > "$DL/kontor-ca.pem"
        curl_args+=(--cacert "$DL/kontor-ca.pem")
    fi
    if [ -n "${AIML_KONTOR_TOKEN:-}" ]; then
        hdr="$DL/kontor.hdr"; (umask 077; printf 'Authorization: Bearer %s\n' "$AIML_KONTOR_TOKEN" > "$hdr")
        curl_args+=(-H @"$hdr")
    fi
    if [ -n "${AIML_RELEASE:-}" ]; then
        ver="$AIML_RELEASE"; tarball="aiml/$ver/aiml-$ver-linux-x86_64.tar.gz"
    else
        curl "${curl_args[@]}" -o "$DL/latest.env" "$url/generic/aiml/latest.env" || return 1
        ver="$(sed -n 's/^version=//p' "$DL/latest.env" | head -1)"
        tarball="$(sed -n 's/^tarball=//p' "$DL/latest.env" | head -1)"
        rm -f "$DL/latest.env"
    fi
    [[ "$ver" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$tarball" =~ ^aiml/[A-Za-z0-9._-]+/aiml-[A-Za-z0-9._-]+-linux-x86_64\.tar\.gz$ ]] \
        || { echo "kontor: unexpected latest.env (version='$ver' tarball='$tarball')"; return 1; }
    curl "${curl_args[@]}" -o "$DL/${tarball##*/}" "$url/generic/$tarball" || return 1
    curl "${curl_args[@]}" -o "$DL/${tarball##*/}.sha256" "$url/generic/$tarball.sha256" || return 1
    rm -f "$DL/kontor-ca.pem" "$DL/kontor.hdr"
    echo "aiml: kontor $url ($ver)"
}

got=""
if [ -n "${AIML_KONTOR_URL:-}" ]; then
    if from_kontor; then
        got=kontor
    elif [ "${AIML_KONTOR_STRICT:-0}" = "1" ]; then
        echo "::error::aiml not available from kontor $AIML_KONTOR_URL"; exit 1
    else
        echo "::warning::aiml not available from kontor $AIML_KONTOR_URL -- falling back to GitHub"
        rm -f "$DL"/*
    fi
fi

tag="${AIML_RELEASE:-}"
if [ -n "$got" ]; then
    :
elif [ -z "$tag" ]; then
    tag="$(gh release list -R "$REPO" --exclude-drafts -L 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)"
fi
if [ -n "$got" ]; then
    :
elif [ -n "$tag" ] && gh release download "$tag" -R "$REPO" -p 'aiml-*-linux-x86_64.tar.gz*' -D "$DL"; then
    echo "aiml: release $tag"
elif [ -n "${AIML_RELEASE:-}" ]; then
    echo "::error::aiml release $AIML_RELEASE has no linux-x86_64 tarball"; exit 1
else
    run="$(gh run list -R "$REPO" -w CI -b master -s success -L 1 --json databaseId -q '.[0].databaseId')"
    [ -n "$run" ] || { echo "::error::no release and no green CI run in $REPO"; exit 1; }
    gh run download "$run" -R "$REPO" -n aiml-linux-x86_64 -D "$DL"
    echo "aiml: CI run https://github.com/$REPO/actions/runs/$run"
fi

(cd "$DL" && sha256sum -c ./*.tar.gz.sha256)
tar -xzf "$DL"/aiml-*-linux-x86_64.tar.gz -C "$DL"
PKG="$(echo "$DL"/aiml-*-linux-x86_64/)"

# `aiml venv` copies the compiler and the runtime only (F68-10); the pinned
# libraries the tarball bundles next to them have to come along, or bin/aiml
# (RUNPATH $ORIGIN/../lib) no longer finds them.
"$PKG/bin/aiml" venv "$VENV"
cp --update=none "$PKG"/lib/*.so* "$VENV/lib/"

# A venv made from this one by `aiml venv <dir>` (ufo's venv_layer.sh does
# that) gets compiler and runtime only, without the bundled libraries, and
# then needs them from the system -- as on a developer machine, where they are
# installed with apt.  On the runner the tarball's copies play that part.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    sudo mkdir -p /usr/local/lib/aiml-bundle
    # `install`, not `cp`: it replaces a file instead of writing into it, so a
    # second run does not overwrite libraries that running processes (sudo
    # itself) have mapped -- that segfaulted (cosmos doc/spec/112 §112.7).
    sudo find "$PKG/lib" -maxdepth 1 -name 'lib*.so*' ! -name 'libaiml.so' -exec install -m 0644 {} /usr/local/lib/aiml-bundle/ \;
    echo /usr/local/lib/aiml-bundle | sudo tee /etc/ld.so.conf.d/aiml-bundle.conf > /dev/null
    sudo ldconfig
fi

# shellcheck disable=SC1091
. "$VENV/env"
missing="$(ldd "$AIML" "$AIML_VENV/lib/libaiml.so" | grep 'not found' || true)"
[ -z "$missing" ] || { echo "unresolved libraries:"; echo "$missing"; exit 1; }

# Smoke test, away from any checkout: a program whose exit code is its own.
probe="$(mktemp -d)"
printf -- '- call: [sys.exit, 42]\n' > "$probe/smoke.aiml"
set +e; (cd "$probe" && "$AIML" smoke.aiml); rc=$?; set -e
[ "$rc" -eq 42 ] || { echo "::error::aiml smoke test exited $rc, expected 42"; exit 1; }

if [ -n "${GITHUB_ENV:-}" ]; then
    { echo "AIML_VENV=$AIML_VENV"; echo "AIML=$AIML"; echo "AIML_BIN=$AIML"; } >> "$GITHUB_ENV"
    echo "$AIML_VENV/bin" >> "$GITHUB_PATH"
fi
echo "aiml venv ready at $AIML_VENV"
