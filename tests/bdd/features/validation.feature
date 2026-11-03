@validation
Feature: Transfer validation and failure isolation

  Background:
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """

  Scenario: Server info exposes physical and extension compatibility
    Then the following SQL on "target" returns "t|t|t|t|t|t|t|t|t|t|t|t":
      """
      SELECT server_version_num = current_setting('server_version_num')::integer,
             catversion > 0,
             block_size = current_setting('block_size')::integer,
             max_align > 0,
             endianness IN ('little', 'big'),
             server_encoding = current_setting('server_encoding'),
             data_checksums = current_setting('data_checksums')::boolean,
             extension_version = (SELECT extversion FROM pg_extension WHERE extname = 'pg_pagecopy'),
             max_toast_chunk_size > 0,
             max_identifier_length = current_setting('max_identifier_length')::integer,
             checksum_algorithm_version > 0,
             lz4_supported IN (true, false)
      FROM pagecopy.server_info();
      """
    And the following SQL on "target" returns "t":
      """
      WITH server_info AS MATERIALIZED (
        SELECT server_version_num, catversion, block_size, max_align,
               endianness, server_encoding, data_checksums, extension_version,
               max_toast_chunk_size, max_identifier_length, checksum_algorithm_version, lz4_supported
        FROM pagecopy.server_info()
      )
      SELECT txid_current_if_assigned() IS NULL FROM server_info;
      """

  Scenario: Missing source server info leaves destination unchanged
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'source', 'new');
      DROP EXTENSION pg_pagecopy;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id bigint PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "source compatibility check failed":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """
    And the following SQL on "source" returns "0|0":
      """
      SELECT vacuum_count, autovacuum_count FROM pg_stat_user_tables
      WHERE relid = 'public.events'::regclass;
      """

  Scenario Outline: Source <check> mismatch leaves destination unchanged
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'source', 'new');
      ALTER FUNCTION pagecopy.server_info() RENAME TO server_info_original;
      CREATE FUNCTION pagecopy.server_info()
      RETURNS TABLE (
        server_version_num integer,
        catversion integer,
        block_size integer,
        max_align integer,
        endianness text,
        server_encoding text,
        data_checksums boolean,
        extension_version text,
        max_toast_chunk_size integer,
        max_identifier_length integer,
        checksum_algorithm_version integer,
        lz4_supported boolean
      ) LANGUAGE SQL AS $$
        SELECT <source_version>, info.catversion, info.block_size, info.max_align,
               info.endianness, info.server_encoding, info.data_checksums, <source_extension>,
               info.max_toast_chunk_size, info.max_identifier_length,
               info.checksum_algorithm_version, info.lz4_supported
        FROM pagecopy.server_info_original() AS info;
      $$;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id bigint PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "<error>":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """
    And the following SQL on "source" returns "0|0":
      """
      SELECT vacuum_count, autovacuum_count FROM pg_stat_user_tables
      WHERE relid = 'public.events'::regclass;
      """

    Examples:
      | check             | source_version                  | source_extension       | error             |
      | PostgreSQL major  | info.server_version_num + 10000 | info.extension_version | PostgreSQL major  |
      | extension version | info.server_version_num         | '0.0.0'::text          | extension version |

  Scenario: Empty source server info leaves destination unchanged
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'source', 'new');
      ALTER FUNCTION pagecopy.server_info() RENAME TO server_info_original;
      CREATE FUNCTION pagecopy.server_info()
      RETURNS TABLE (
        server_version_num integer,
        catversion integer,
        block_size integer,
        max_align integer,
        endianness text,
        server_encoding text,
        data_checksums boolean,
        extension_version text,
        max_toast_chunk_size integer,
        max_identifier_length integer,
        checksum_algorithm_version integer,
        lz4_supported boolean
      ) LANGUAGE SQL AS $$
        SELECT info.server_version_num, info.catversion, info.block_size, info.max_align,
               info.endianness, info.server_encoding, info.data_checksums, info.extension_version,
               info.max_toast_chunk_size, info.max_identifier_length,
               info.checksum_algorithm_version, info.lz4_supported
        FROM pagecopy.server_info_original() AS info
        WHERE false;
      $$;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id bigint PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "source compatibility check failed: source server info must return one row with eleven columns":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """
    And the following SQL on "source" returns "0|0":
      """
      SELECT vacuum_count, autovacuum_count FROM pg_stat_user_tables
      WHERE relid = 'public.events'::regclass;
      """

  Scenario: NULL source server info field leaves destination unchanged
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'source', 'new');
      ALTER FUNCTION pagecopy.server_info() RENAME TO server_info_original;
      CREATE FUNCTION pagecopy.server_info()
      RETURNS TABLE (
        server_version_num integer,
        catversion integer,
        block_size integer,
        max_align integer,
        endianness text,
        server_encoding text,
        data_checksums boolean,
        extension_version text,
        max_toast_chunk_size integer,
        max_identifier_length integer,
        checksum_algorithm_version integer,
        lz4_supported boolean
      ) LANGUAGE SQL AS $$
        SELECT info.server_version_num, info.catversion, info.block_size, info.max_align,
               info.endianness, info.server_encoding, info.data_checksums, NULL::text,
               info.max_toast_chunk_size, info.max_identifier_length,
               info.checksum_algorithm_version, info.lz4_supported
        FROM pagecopy.server_info_original() AS info;
      $$;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id bigint PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "source compatibility check failed: source server info column 6 is NULL":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """
    And the following SQL on "source" returns "0|0":
      """
      SELECT vacuum_count, autovacuum_count FROM pg_stat_user_tables
      WHERE relid = 'public.events'::regclass;
      """

  Scenario: Incompatible table layout leaves destination unchanged
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'source', 'new');
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id bigint PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (99, 'stale', 'old');
      """
    Then the following SQL on "target" fails with "source and target table attributes differ":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|99|stale":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

  Scenario: Missing source relation leaves destination unchanged
    When the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "does not exist":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.missing', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

  Scenario: Invalid source schema name leaves destination unchanged
    When the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "invalid name syntax":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public..events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

  Scenario: Invalid target schema name leaves destination unchanged
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'source', 'new');
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "string is not a valid identifier":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public..events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

  Scenario: Non-default tablespace is readable through an authorized source connection
    Given a non-default tablespace is available on "source"
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'from tablespace', 'owner');
      ALTER TABLE public.events SET TABLESPACE attach_space;
      CREATE ROLE attach_owner LOGIN;
      GRANT pg_checkpoint TO attach_owner;
      ALTER TABLE public.events OWNER TO attach_owner;
      """
    And the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events_copy', true
      );
      """
    Then the following SQL on "target" returns "1|from tablespace|owner":
      """
      SELECT count(*), min(payload), min(note) FROM public.events_copy;
      """

  Scenario: Import freezes unfrozen source tuples automatically
    When the following SQL is executed on "source":
      """
      INSERT INTO public.events VALUES (1, 'frozen by import', 'new');
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    And the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pagecopy_internal.pagecopy_source_is_frozen('public.events');
      """
    Then the following SQL on "target" returns "1|1|frozen by import":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

  Scenario: Unsupported unlogged relation leaves destination unchanged
    When the following SQL is executed on "source":
      """
      ALTER TABLE public.events SET UNLOGGED;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Then the following SQL on "target" fails with "source must be a plain logged table":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

  Scenario: Unsupported existing target index is disabled and can be rebuilt
    When the following SQL is executed on "source":
      """
      CREATE INDEX events_id_hash ON public.events USING hash (id);
      INSERT INTO public.events VALUES (1, 'new', 'one'), (2, 'new', 'two');
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      CREATE INDEX events_id_hash ON public.events USING hash (id);
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "2|1|new|f|f":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT min(id) FROM public.events),
             (SELECT min(payload) FROM public.events),
             i.indisvalid, i.indisready
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = 'events_id_hash';
      """
    And the following SQL on "source" returns "t|t":
      """
      SELECT i.indisvalid, i.indisready
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = 'events_id_hash';
      """
    When the following SQL is executed on "target":
      """
      REINDEX INDEX public.events_id_hash;
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT i.indisvalid, i.indisready
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = 'events_id_hash';
      """

  Scenario: Unsupported unique index cannot be degraded
    When the following SQL is executed on "source":
      """
      CREATE UNIQUE INDEX events_note_key ON public.events (note) WHERE note IS NOT NULL;
      """
    Then the following SQL on "target" fails with "cannot be degraded":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('public.events');
      """

  Scenario: Exclusion index cannot be degraded
    When the following SQL is executed on "source":
      """
      ALTER TABLE public.events
        ADD CONSTRAINT events_note_excl EXCLUDE USING btree (note WITH =);
      """
    Then the following SQL on "target" fails with "foreign/exclusion constraints":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('public.events');
      """

  Scenario: Offline source leaves destination unchanged
    When the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      INSERT INTO public.events VALUES (42, 'keep', 'old');
      """
    Given source PostgreSQL is stopped
    Then the following SQL on "target" fails with "Connection refused":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|42|keep":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """
