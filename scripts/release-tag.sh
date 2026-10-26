#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?usage: scripts/release-tag.sh vX.Y.Z}"
[[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo 'Release tags must use vX.Y.Z with numeric components.' >&2
    exit 1
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SOURCE_VERSION="$(sed -n 's/.*version: "\([^"]*\)".*/\1/p' Sources/anyrec/AnyRec.swift | head -1)"
[[ "${TAG#v}" == "$SOURCE_VERSION" ]] || {
    echo "Tag $TAG does not match source version $SOURCE_VERSION." >&2
    exit 1
}
[[ "$(git rev-parse "refs/tags/$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || {
    echo 'Release tag does not point to the checked-out commit.' >&2
    exit 1
}
