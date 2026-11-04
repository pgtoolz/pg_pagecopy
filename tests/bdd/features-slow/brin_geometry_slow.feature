@brin @slow
Feature: BRIN index geometry spanning WAL batch boundaries

  Slow-tier geometry: one BRIN main fork large enough that its page-image
  WAL logging (batches of XLR_MAX_BLOCK_ID, 32 on PG13-15 and 35 on PG16+)
  must cross several full batches plus a remainder, then survive crash
  recovery with the index file deleted so replay must reconstruct every
  batch from full-page images. Run explicitly:

    PG_VERSION=17 PG_PAGECOPY_FEATURES=/opt/pg-pagecopy-bdd/features-slow \
      ./tests/bdd/run.sh

  Block numbers near the 2^31-1 relfilenode limit would need a multi-terabyte
  heap and are not faked here; this tier covers the batch-boundary geometry
  that is technically feasible.

  Scenario: An index spanning several WAL batches recovers exactly
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.huge (id bigint, pad integer) WITH (fillfactor = 10);
      DO $do$
      DECLARE n bigint := 0;
      BEGIN
        WHILE (SELECT pg_relation_size('public.huge')) < 25990 * 8192 LOOP
          INSERT INTO public.huge SELECT n + i, (n + i) % 97 FROM generate_series(1, 100) AS i;
          n := n + 100;
        END LOOP;
        WHILE (SELECT pg_relation_size('public.huge')) < 26005 * 8192 LOOP
          INSERT INTO public.huge SELECT n + i, (n + i) % 97 FROM generate_series(1, 20) AS i;
          n := n + 20;
        END LOOP;
        WHILE (SELECT pg_relation_size('public.huge')) < 26006 * 8192 LOOP
          INSERT INTO public.huge VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
      END
      $do$;
      CREATE INDEX huge_brin ON public.huge USING brin (id) WITH (pages_per_range = 1);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CHECKPOINT;
      """
    Then the following SQL on "source" returns "26006|111|3|6":
      """
      WITH size AS (SELECT pg_relation_size('public.huge_brin'::regclass) / 8192 AS blocks)
      SELECT pg_relation_size('public.huge') / 8192,
             blocks,
             blocks / (CASE WHEN current_setting('server_version_num')::integer >= 160000
                            THEN 35 ELSE 32 END),
             blocks % (CASE WHEN current_setting('server_version_num')::integer >= 160000
                            THEN 35 ELSE 32 END)
      FROM size;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.huge', 'public.huge', true
      );
      """
    Then the following SQL on "target" returns "26006|111|3|6|t|t":
      """
      WITH size AS (SELECT pg_relation_size('public.huge_brin'::regclass) / 8192 AS blocks)
      SELECT pg_relation_size('public.huge') / 8192,
             blocks,
             blocks / (CASE WHEN current_setting('server_version_num')::integer >= 160000
                            THEN 35 ELSE 32 END),
             blocks % (CASE WHEN current_setting('server_version_num')::integer >= 160000
                            THEN 35 ELSE 32 END),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.huge_brin'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.huge_brin'::regclass)
      FROM size;
      """
    When target relation "public.huge_brin" block 1 is recorded as a brin "revmap" page
    And target relation "public.huge_brin" block 40 is recorded as a brin "summary" page
    And target relation "public.huge_brin" block 110 is recorded as a brin "summary" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery
    And target data checksums verify after a clean shutdown
    And the following SQL on "target" returns "t|26006|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.huge_brin'::regclass),
             pg_relation_size('public.huge') / 8192,
             count(*) FROM public.huge WHERE id < 3;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.huge WHERE id < 3;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.huge WHERE id < 3;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
