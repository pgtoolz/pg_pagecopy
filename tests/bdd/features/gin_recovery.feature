@gin @recovery
Feature: GIN transfers survive WAL, checksum and restart combinations

  GIN pages are logged as whole-page full images (a binary-upgraded
  pre-9.4 posting page may carry a stale pd_lower, so core itself refuses
  standard-page logging for those), so replay must restore metapage,
  entry-tree, posting-tree and pending-list pages byte for byte outside
  the stamped header.

  Scenario: WAL full-page images restore gin metapage and entry pages

    A pull always VACUUMs the source first, and VACUUM merges a GIN pending
    list into the main tree (ginvacuum.c), so a remote transfer ships a
    merged index; the pending-list page images are covered by the local
    clone crash scenario in gin_local.feature.
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 13] FROM generate_series(1, 3000) AS i;
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
    And target relation "public.t_items" block 0 is recorded as a gin "meta" page
    And target relation "public.t_items" block 1 is recorded as a gin "entry" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery
    And the following SQL on "target" returns "t|3000|231":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE items @> ARRAY[5])
      FROM pg_index WHERE indexrelid = 'public.t_items'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t VALUES (9999, ARRAY[5]);
      SELECT gin_clean_pending_list('public.t_items');
      """
    Then the following SQL on "target" returns "232":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.t WHERE items @> ARRAY[5];
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario: WAL full-page images restore a build-time posting-tree index
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.dup (id integer PRIMARY KEY, items integer[]);
      INSERT INTO public.dup SELECT i, ARRAY[5] FROM generate_series(1, 20000) AS i;
      CREATE INDEX dup_items ON public.dup USING gin (items);
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
        'public.dup', 'public.dup', true
      );
      """
    And target relation "public.dup_items" block 0 is recorded as a gin "meta" page
    And target relation "public.dup_items" block 1 is recorded as a gin "entry" page
    And target relation "public.dup_items" block 3 is recorded as a gin "data" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery
    And the following SQL on "target" returns "t|20000|20000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.dup),
             (SELECT count(*) FROM public.dup WHERE items @> ARRAY[5])
      FROM pg_index WHERE indexrelid = 'public.dup_items'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.dup VALUES (99999, ARRAY[5]);
      SELECT gin_clean_pending_list('public.dup_items');
      """
    Then the following SQL on "target" returns "20001":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.dup WHERE items @> ARRAY[5];
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario: A no-WAL gin import survives an intact restart and keeps growing
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 13] FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', false
      );
      """
    And target postmaster is crashed and restarted
    Then the following SQL on "target" returns "t|3000|231":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.t_items'::regclass),
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE items @> ARRAY[5]);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_items":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE items @> ARRAY[5];
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t VALUES (9999, ARRAY[5]);
      """
    Then the following SQL on "target" returns "232":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.t WHERE items @> ARRAY[5];
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario Outline: WAL <wal> with checksums <checksums> transfers and accepts writes
    Given a fresh PostgreSQL pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 9, i % 4] FROM generate_series(1, 1200) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', <wal>
      );
      """
    Then the following SQL on "target" returns "t|1200|400":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE items @> ARRAY[3])
      FROM pg_index WHERE indexrelid = 'public.t_items'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 9000 + i, ARRAY[i % 9, i % 4] FROM generate_series(1, 300) AS i;
      """
    Then the following SQL on "target" returns "1500":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.t;
      ROLLBACK;
      """

    Examples:
      | wal  | checksums |
      | true | enabled   |
      | true | disabled  |
      | false | enabled  |
      | false | disabled |

  Scenario: Mismatched source and target checksums fail a gin transfer closed
    Given a fresh PostgreSQL pair with source checksums "enabled" and target checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t SELECT i, ARRAY[i] FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "target" fails with "data checksums":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
