@brin @wal
Feature: BRIN transfer durability, atomicity and crash recovery

  Checksum and WAL combinations, checksum mismatch rejection, cancellation
  and failure after index pages have arrived, existing-target preservation
  down to relfilenodes, rollback of successful pulls, and crash recovery
  comparing both revmap and summary pages with checksum-aware comparisons.

  Scenario Outline: Checksums <checksums> with WAL <wal> survive a crash without file deletion
    Given a fresh PostgreSQL pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint, payload text);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t
      SELECT i, i * 37, repeat(md5(i::text), 40)
      FROM generate_series(1, 6000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CHECKPOINT;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', <wal>
      );
      """
    And target relation "public.t_brin" block 1 is recorded as a brin "revmap" page
    And target relation "public.t_brin" block 2 is recorded as a brin "summary" page
    And target postmaster is crashed and restarted
    Then the recorded target block is unchanged after crash recovery
    And the following SQL on "target" returns "t|6000|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass),
             count(*),
             count(*) FILTER (WHERE k = 3700)
FROM public.t;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k < 300;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k < 300;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """

    Examples:
      | checksums | wal   |
      | enabled   | true  |
      | enabled   | false |
      | disabled  | true  |
      | disabled  | false |

  Scenario Outline: A checksum mismatch between source <source_checksums> and target <target_checksums> is rejected
    Given a fresh PostgreSQL pair with source checksums "<source_checksums>" and target checksums "<target_checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "data checksums":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|999999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(k) FROM public.t),
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """

    Examples:
      | source_checksums | target_checksums |
      | enabled          | disabled         |
      | disabled         | enabled          |

  Scenario: Cancelling after heap and index pages have arrived rolls everything back
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION pgcrypto;
      CREATE TABLE public.t (id integer, k bigint, payload text);
      CREATE INDEX t_a ON public.t USING brin (k) WITH (pages_per_range = 4);
      CREATE INDEX t_b ON public.t USING brin (id) WITH (pages_per_range = 4);
      INSERT INTO public.t
      SELECT i, i * 37, encode(gen_random_bytes(1024), 'hex') || encode(gen_random_bytes(1024), 'hex') || encode(gen_random_bytes(1024), 'hex') || encode(gen_random_bytes(1024), 'hex')
      FROM generate_series(1, 150000) AS i;
      """
    And the following SQL is executed on "source":
      """
      INSERT INTO public.t
      SELECT i, i * 37, encode(gen_random_bytes(1024), 'hex') || encode(gen_random_bytes(1024), 'hex') || encode(gen_random_bytes(1024), 'hex') || encode(gen_random_bytes(1024), 'hex')
      FROM generate_series(150001, 300000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint, payload text);
      CREATE INDEX t_a ON public.t USING brin (k) WITH (pages_per_range = 4);
      CREATE INDEX t_b ON public.t USING brin (id) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999, 'sentinel');
      """
    When the following SQL on "target" is cancelled after the BRIN page milestone:
      """
      SET pagecopy.debug_hold_brin_page_block = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "1|999999|t|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(k) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_b'::regclass),
             (SELECT count(*) = 0 FROM pg_locks
              WHERE relation = 'public.t'::regclass AND NOT granted)
      """
    And the following SQL on "target" returns "t":
      """
      DO $do$
      DECLARE remaining integer;
      BEGIN
        FOR attempt IN 1..50 LOOP
          SELECT count(*) INTO remaining FROM pg_locks
          WHERE relation = 'public.t'::regclass;
          EXIT WHEN remaining = 0;
          PERFORM pg_sleep(0.1);
        END LOOP;
      END
      $do$;
      SELECT count(*) = 0 FROM pg_locks WHERE relation = 'public.t'::regclass;
      """
    And the following SQL on "source" returns "300000|0":
      """
      DO $do$
      DECLARE remaining integer;
      BEGIN
        FOR attempt IN 1..50 LOOP
          SELECT count(*) INTO remaining FROM pg_stat_activity
          WHERE query LIKE 'COPY (SELECT pagecopy_internal.pagecopy_export_stream(%'
            AND state = 'active';
          EXIT WHEN remaining = 0;
          PERFORM pg_sleep(0.1);
        END LOOP;
      END
      $do$;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM pg_stat_activity
              WHERE query LIKE 'COPY (SELECT pagecopy_internal.pagecopy_export_stream(%'
                AND state = 'active');
      """

  Scenario: A failure on a later physical index after an earlier one was written rolls back
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_a ON public.t USING brin (k) WITH (pages_per_range = 4);
      CREATE INDEX t_b ON public.t USING brin (id) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 4000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_a ON public.t USING brin (k) WITH (pages_per_range = 4);
      CREATE INDEX t_b ON public.t USING brin (id) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 32;
      SET pagecopy.debug_corrupt_index_ordinal = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|999999|t|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(k) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_b'::regclass),
             (SELECT count(*) = 0 FROM pg_locks
              WHERE relation = 'public.t'::regclass AND NOT granted)
      """
    And the following SQL on "target" returns "t":
      """
      DO $do$
      DECLARE remaining integer;
      BEGIN
        FOR attempt IN 1..50 LOOP
          SELECT count(*) INTO remaining FROM pg_locks
          WHERE relation = 'public.t'::regclass;
          EXIT WHEN remaining = 0;
          PERFORM pg_sleep(0.1);
        END LOOP;
      END
      $do$;
      SELECT count(*) = 0 FROM pg_locks WHERE relation = 'public.t'::regclass;
      """

  Scenario: A failed transfer over an existing target preserves rows, relfilenodes and plans
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 4000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999);
      CREATE TABLE public.expected AS
      SELECT pg_relation_filepath('public.t') AS heap,
             pg_relation_filepath('public.t_brin'::regclass) AS index;
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 24;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "t|t|t":
      """
      SELECT pg_relation_filepath('public.t') = (SELECT heap FROM public.expected),
             pg_relation_filepath('public.t_brin'::regclass) = (SELECT index FROM public.expected),
             (SELECT count(*) = 1 AND max(k) = 999999 FROM public.t);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k = 999999;
      ROLLBACK;
      """

  Scenario: A failed auto-created target leaves no table, index or TOAST leftovers
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint, payload text);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t
      SELECT i, i * 37, (SELECT string_agg(md5(i::text || g::text), '') FROM generate_series(1, 64) AS g)
      FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.expected AS
      SELECT count(*) AS classes FROM pg_class;
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 24;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "0|t|t":
      """
      SELECT (SELECT count(*) FROM pg_class
              WHERE oid IN (to_regclass('public.t'), to_regclass('public.t_brin'))),
             -- The snapshot table counts itself out by exactly one row; the
             -- failed auto-creation must leave the catalog otherwise intact.
             (SELECT classes FROM public.expected) + 1 = (SELECT count(*) FROM pg_class),
             (SELECT count(*) = 0 FROM pg_class c
              WHERE c.relkind = 't'
                AND NOT EXISTS (SELECT 1 FROM pg_class h
                                WHERE h.oid = split_part(c.relname, '_', 3)::oid));
      """

  Scenario: Rolling back a successful pull removes an auto-created target and restores an existing one
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.keep (id integer, k bigint);
      CREATE INDEX keep_brin ON public.keep USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.keep VALUES (1, 1);
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.keep', true
      );
      ROLLBACK;
      """
    Then the following SQL on "target" returns "0|1|1":
      """
      SELECT (SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.t')),
             (SELECT count(*) FROM public.keep),
             (SELECT max(k) FROM public.keep);
      """

  Scenario: A truncated stream with missing index pages is rejected and rolls back
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 4000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "stream ended early":
      """
      SET pagecopy.debug_drop_index_page_relation = 3;
      SET pagecopy.debug_drop_index_page_block = 2;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|999999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(k) FROM public.t),
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
