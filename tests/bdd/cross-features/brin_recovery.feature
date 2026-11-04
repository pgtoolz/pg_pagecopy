@cross-major @brin @wal
Feature: BRIN crash recovery across major upgrades

  Cross-major crash recovery with checksum-aware comparison of both the
  revmap and a summary page: a WAL-logged pull is crashed and the file is
  deleted so replay must reconstruct the index from full-page images, and a
  no-WAL pull is crashed without deleting anything so the synced files must
  carry the index alone.

  Scenario Outline: PostgreSQL <source_major> to <target_major> WAL recovery rebuilds revmap and summary pages with checksums <checksums>
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "<checksums>"
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
        'public.t', 'public.t', true
      );
      """
    And target relation "public.t_brin" block 1 is recorded as a brin "revmap" page
    And target relation "public.t_brin" block 2 is recorded as a brin "summary" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
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
      | source_major | target_major | checksums |
      | 13           | 18           | enabled   |
      | 16           | 17           | enabled   |
      | 15           | 16           | disabled  |

  Scenario: PostgreSQL 17 to 18 no-WAL durability survives a crash without file deletion
    Given a fresh PostgreSQL 17 to 18 pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
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
        'public.t', 'public.t', false
      );
      """
    And target relation "public.t_brin" block 1 is recorded as a brin "revmap" page
    And target relation "public.t_brin" block 2 is recorded as a brin "summary" page
    And target postmaster is crashed and restarted
    Then the recorded target block is unchanged after crash recovery
    And target data checksums verify after a clean shutdown
    And the following SQL on "target" returns "t|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass),
             count(*) FILTER (WHERE k = 3700)
FROM public.t;
      ROLLBACK;
      """
