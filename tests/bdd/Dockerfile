ARG PG_VERSION=17

FROM rust:1.99-bookworm AS build
RUN rustup component add clippy
WORKDIR /work
COPY tests/bdd/Cargo.toml tests/bdd/Cargo.lock ./
# Stub binary: prebuild dependencies in the release profile (plain and clippy
# fingerprints) so later harness changes recompile only this crate; real
# sources overwrite the stub.
RUN echo 'fn main() {}' > main.rs \
    && cargo build --release --locked \
    && cargo clippy --release --locked -- -D warnings -D clippy::pedantic
COPY tests/bdd/main.rs tests/bdd/postgres.rs tests/bdd/steps.rs tests/bdd/world.rs ./
RUN touch main.rs postgres.rs steps.rs world.rs \
    && cargo clippy --release --all-targets --locked -- -D warnings -D clippy::pedantic \
    && cargo test --release --locked \
    && cargo build --release --locked

FROM postgres:${PG_VERSION}-bookworm AS fixtures
ARG PG_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc postgresql-server-dev-${PG_VERSION} \
    && rm -rf /var/lib/apt/lists/*
COPY tests/bdd/fixtures.c /tmp/fixtures.c
RUN cc -shared -fPIC -Wall -Werror \
    -I"$(/usr/lib/postgresql/${PG_VERSION}/bin/pg_config --includedir-server)" \
    /tmp/fixtures.c -o /tmp/pc_bdd_fixtures.so

FROM pg-pagecopy-pg${PG_VERSION}:dev
ARG PG_VERSION
COPY --from=fixtures /tmp/pc_bdd_fixtures.so /usr/lib/postgresql/${PG_VERSION}/lib/
ENV PATH="/usr/lib/postgresql/${PG_VERSION}/bin:${PATH}" \
    PG_PAGECOPY_FEATURES=/opt/pg-pagecopy-bdd/features
COPY --from=build /work/target/release/pg-pagecopy-bdd /usr/local/bin/pg-pagecopy-bdd
COPY tests/bdd/features /opt/pg-pagecopy-bdd/features
COPY tests/bdd/features-slow /opt/pg-pagecopy-bdd/features-slow
COPY tests/bdd/features-release /opt/pg-pagecopy-bdd/features-release
# Column-level COMPRESSION and LZ4 are unavailable before PostgreSQL 14, and
# bloom/minmax-multi BRIN opclasses do not exist there either.
RUN [ "$PG_VERSION" -ge 14 ] \
      || rm /opt/pg-pagecopy-bdd/features/safety_lz4.feature \
              /opt/pg-pagecopy-bdd/features/brin_modern_opclasses.feature
CMD ["pg-pagecopy-bdd"]
