@spgist @recovery
Feature: SP-GiST transfers survive WAL, checksum and restart combinations

  SP-GiST main-fork pages are standard pages (upstream WAL-logs them with
  REGBUF_STANDARD and sets the metapage's pd_lower past its metadata), so
  they use the ordinary hole-compressing WAL path; the fixed metapage,
  root and nulls pages must survive import and crash recovery byte for
  byte outside the [pd_lower, pd_upper) hole.

  Scenario: A grown spgist tree transfers its root, inner, leaf and nulls pages
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.tree (id integer PRIMARY KEY, p point);
      CREATE INDEX tree_q ON public.tree USING spgist (p);
      INSERT INTO public.tree
      SELECT i, CASE WHEN i % 13 = 0 THEN NULL
                     ELSE point((i * 17) % 401 - 200, (i * 23) % 409 - 204) END
      FROM generate_series(1, 5000) AS i;
      """
    Then the following SQL on "source" returns "t|t":
      """
      SELECT pg_relation_size('public.tree_q'::regclass) > 3 * 8192,
             (SELECT count(*) > 0 FROM public.tree WHERE p IS NULL)
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.tree', 'public.tree', true
      );
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size('public.tree_q'::regclass) > 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.tree_q'::regclass;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.tree SELECT 9000 + i, point(i, -i) FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "7000|384|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*),
             count(*) FILTER (WHERE p IS NULL),
             count(*) FILTER (WHERE p <@ box(point(0, 0), point(0, 0)))
      FROM public.tree;
      ROLLBACK;
      """

  Scenario: WAL full-page images restore spgist metapage, root, inner and nulls pages
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.tree (id integer PRIMARY KEY, p point);
      CREATE INDEX tree_q ON public.tree USING spgist (p);
      INSERT INTO public.tree
      SELECT i, CASE WHEN i % 13 = 0 THEN NULL
                     ELSE point((i * 17) % 401 - 200, (i * 23) % 409 - 204) END
      FROM generate_series(1, 5000) AS i;
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
        'public.tree', 'public.tree', true
      );
      """
    And target relation "public.tree_q" block 0 is recorded as a spgist "meta" page
    And target relation "public.tree_q" block 1 is recorded as a spgist "inner" page
    And target relation "public.tree_q" block 2 is recorded as a spgist "nulls" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery except the WAL hole
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.tree', 'public.tree_after_recovery', true);
      """
    Then the following SQL on "target" returns "t|5000":
      """
      SELECT i.indisvalid AND i.indisready,
             (SELECT count(*) FROM public.tree_after_recovery)
      FROM pg_index AS i
      WHERE i.indrelid = 'public.tree_after_recovery'::regclass
        AND i.indexprs IS NULL AND i.indpred IS NULL
        AND pg_get_indexdef(i.indexrelid) LIKE '%USING spgist%';
      """
    And the following SQL on "target" returns "t|5000|384":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.tree),
             (SELECT count(*) FROM public.tree WHERE p IS NULL)
      FROM pg_index WHERE indexrelid = 'public.tree_q'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.tree VALUES (9999, NULL);
      """
    Then the following SQL on "target" returns "385":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.tree WHERE p IS NULL;
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario: A no-WAL spgist import survives an intact restart and keeps growing
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.tree (id integer PRIMARY KEY, p point);
      CREATE INDEX tree_q ON public.tree USING spgist (p);
      INSERT INTO public.tree
      SELECT i, CASE WHEN i % 13 = 0 THEN NULL
                     ELSE point((i * 17) % 401 - 200, (i * 23) % 409 - 204) END
      FROM generate_series(1, 5000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.tree', 'public.tree', false
      );
      """
    And target relation "public.tree_q" block 1 is recorded as a spgist "inner" page
    And target postmaster is crashed and restarted
    Then the recorded target block is unchanged after crash recovery
    And the following SQL on "target" returns "t|5000|384":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.tree_q'::regclass),
             (SELECT count(*) FROM public.tree),
             (SELECT count(*) FROM public.tree WHERE p IS NULL);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using tree_q":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.tree WHERE p IS NULL;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.tree VALUES (9999, point(-200, -204));
      """
    Then the following SQL on "target" returns "1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.tree WHERE p <@ box(point(-201, -205), point(-199, -203));
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario Outline: WAL <wal> with checksums <checksums> transfers and accepts writes
    Given a fresh PostgreSQL pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 1200) AS i;
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
    Then the following SQL on "target" returns "t|1200|6":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(3, 3)))
      FROM pg_index WHERE indexrelid = 'public.t_q'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 9000 + i, point(i % 83, i % 79) FROM generate_series(1, 300) AS i;
      """
    Then the following SQL on "target" returns "1500":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.t;
      ROLLBACK;
      """

    Examples:
      | wal   | checksums |
      | true  | enabled   |
      | true  | disabled  |
      | false | enabled   |
      | false | disabled  |

  Scenario: Mismatched source and target checksums fail a spgist transfer closed
    Given a fresh PostgreSQL pair with source checksums "enabled" and target checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i, i) FROM generate_series(1, 100) AS i;
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
