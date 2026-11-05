#!/bin/sh
set -eu

PG_VERSION=${PG_VERSION:-17}
SOURCE_PG_VERSION=${SOURCE_PG_VERSION:-$PG_VERSION}
TARGET_PG_VERSION=${TARGET_PG_VERSION:-$PG_VERSION}
# Private image-tag suffix (e.g. -spgist): several worktrees of this repo
# share one docker daemon, so parallel BDD runs must never build or run the
# same tags. Empty keeps the historical public tags.
tag_suffix=${PG_PAGECOPY_TAG_SUFFIX:-}
root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)

# Prebuilt toolchain cache (see Dockerfile, toolchain stage). The tag is
# derived from the same inputs as .github/workflows/images.yml computes
# (Dockerfile + images.yml; Cargo.lock is excluded on purpose), so CI
# hits the registry image and a local run without BUILDER_REGISTRY just
# builds from source as before.
hash_files() {
  cat "$root/Dockerfile" "$root/.github/workflows/images.yml" \
    | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
}
BUILDER_TAG=$(hash_files)

build_extension() {
  major=$1
  target=${2:-test}
  tag=${3:-dev}
  cache_args=""
  if [ -n "${BUILDER_REGISTRY:-}" ]; then
    cache_args="--cache-from ${BUILDER_REGISTRY}/builder-pg${major}:${BUILDER_TAG}"
  fi
  # shellcheck disable=SC2086
  docker build $cache_args --build-arg PG_VERSION="$major" \
    --target "$target" -t "pg-pagecopy-pg${major}:${tag}${tag_suffix}" "$root"
}

if [ "$SOURCE_PG_VERSION" != "$TARGET_PG_VERSION" ]; then
  build_extension "$SOURCE_PG_VERSION"
  build_extension "$TARGET_PG_VERSION"
  docker build -f "$root/tests/bdd/Dockerfile.cross" \
    --build-arg SOURCE_PG_VERSION="$SOURCE_PG_VERSION" \
    --build-arg TARGET_PG_VERSION="$TARGET_PG_VERSION" \
    --build-arg EXTENSION_TAG="dev${tag_suffix}" \
    -t "pg-pagecopy-bdd-pg${SOURCE_PG_VERSION}-pg${TARGET_PG_VERSION}:dev${tag_suffix}" "$root"
  image="pg-pagecopy-bdd-pg${SOURCE_PG_VERSION}-pg${TARGET_PG_VERSION}:dev${tag_suffix}"
  matrix="$SOURCE_PG_VERSION-$TARGET_PG_VERSION${tag_suffix}"
  features=/opt/pg-pagecopy-bdd/cross-features
else
  target=test
  image_tag=dev
  matrix="$PG_VERSION${tag_suffix}"
  if [ "${PG_PAGECOPY_RELEASE:-0}" = 1 ]; then
    target=release
    image_tag=release
    matrix="$PG_VERSION-release${tag_suffix}"
  fi
  build_extension "$PG_VERSION" "$target" "$image_tag"
  docker build -f "$root/tests/bdd/Dockerfile" \
    --build-arg PG_VERSION="$PG_VERSION" \
    --build-arg EXTENSION_TAG="${image_tag}${tag_suffix}" \
    -t "pg-pagecopy-bdd-pg${PG_VERSION}:${image_tag}${tag_suffix}" "$root"
  image="pg-pagecopy-bdd-pg${PG_VERSION}:${image_tag}${tag_suffix}"
  features=/opt/pg-pagecopy-bdd/features
fi

log_dir="$root/target/bdd-logs/$matrix"
mkdir -p "$log_dir"
output=$(mktemp)
trap 'rm -f "$output"' EXIT HUP INT TERM
if docker run --rm -e PG_PAGECOPY_LOG_DIR=/logs \
  -e "PG_PAGECOPY_FEATURES=${PG_PAGECOPY_FEATURES:-$features}" \
  -e "PG_PAGECOPY_TAGS=${PG_PAGECOPY_TAGS:-}" \
  -v "$log_dir:/logs" "$image" >"$output" 2>&1; then
  status=0
else
  status=$?
fi
cat "$output"
[ "$status" -eq 0 ] || exit "$status"
if [ -n "${PG_PAGECOPY_TAGS:-}" ]; then
  echo "tag selection '${PG_PAGECOPY_TAGS}' active; ignoring skipped scenarios" >&2
  exit 0
fi
if grep -Eq '[1-9][0-9]* skipped' "$output"; then
  echo 'BDD scenarios were skipped; treat the run as failed' >&2
  exit 1
fi
