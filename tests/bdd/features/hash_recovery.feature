@hash @recovery
Feature: HASH transfers survive WAL, checksum and restart combinations

  HASH pages are standard pages (data outside the [pd_lower, pd_upper)
  hole), so they use the ordinary whole-page WAL path; legitimate all-zero
  sparse blocks from bucket allocation must survive preparation, import and
  crash recovery byte for byte.

  Scenario: A naturally sparse hash index transfers its all-zero reserved blocks
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.sparse (id integer PRIMARY KEY, k integer);
      CREATE INDEX sparse_k ON public.sparse USING hash (k) WITH (fillfactor = 10);
      INSERT INTO public.sparse SELECT i, i * 3 FROM generate_series(1, 3000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size('public.sparse_k'::regclass) >= 111 * 8192;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.sparse', 'public.sparse', true
      );
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size('public.sparse_k'::regclass) >= 111 * 8192
      FROM pg_index WHERE indexrelid = 'public.sparse_k'::regclass;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.sparse SELECT 9000 + i, i * 3 FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "5000|2|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*),
             count(*) FILTER (WHERE k = 300),
             count(*) FILTER (WHERE k = 3)
      FROM public.sparse;
      ROLLBACK;
      """

  Scenario: WAL full-page images restore hash metapage, bucket and sparse pages
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.sparse (id integer PRIMARY KEY, k integer);
      CREATE INDEX sparse_k ON public.sparse USING hash (k) WITH (fillfactor = 10);
      INSERT INTO public.sparse SELECT i, i * 3 FROM generate_series(1, 3000) AS i;
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
        'public.sparse', 'public.sparse', true
      );
      """
    And target relation "public.sparse_k" block 0 is recorded as a hash "meta" page
    And target relation "public.sparse_k" block 1 is recorded as a hash "bucket" page
    And target relation "public.sparse_k" block 110 is recorded as a hash "all-zero" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery except the WAL hole
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.sparse', 'public.sparse_after_recovery', true);
      """
    Then the following SQL on "target" returns "t|3000":
      """
      SELECT i.indisvalid AND i.indisready,
             (SELECT count(*) FROM public.sparse_after_recovery)
      FROM pg_index AS i
      WHERE i.indrelid = 'public.sparse_after_recovery'::regclass
        AND i.indexprs IS NULL AND i.indpred IS NULL
        AND pg_get_indexdef(i.indexrelid) LIKE '%USING hash%';
      """
    And the following SQL on "target" returns "t|3000|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.sparse),
             (SELECT count(*) FROM public.sparse WHERE k = 3)
      FROM pg_index WHERE indexrelid = 'public.sparse_k'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.sparse VALUES (9999, 300);
      """
    Then the following SQL on "target" returns "2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.sparse WHERE k = 300;
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario: A no-WAL hash import survives an intact restart and keeps growing
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.sparse (id integer PRIMARY KEY, k integer);
      CREATE INDEX sparse_k ON public.sparse USING hash (k) WITH (fillfactor = 10);
      INSERT INTO public.sparse SELECT i, i * 3 FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.sparse', 'public.sparse', false
      );
      """
    And target relation "public.sparse_k" block 110 is recorded as a hash "all-zero" page
    And target postmaster is crashed and restarted
    Then the recorded target block is unchanged after crash recovery
    And the following SQL on "target" returns "t|3000|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.sparse_k'::regclass),
             (SELECT count(*) FROM public.sparse),
             (SELECT count(*) FROM public.sparse WHERE k = 3);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using sparse_k":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.sparse WHERE k = 3;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.sparse VALUES (9999, 3);
      """
    Then the following SQL on "target" returns "2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.sparse WHERE k = 3;
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario: WAL full-page images restore hash overflow and bitmap pages
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.dup (id integer PRIMARY KEY, k integer);
      CREATE INDEX dup_k ON public.dup USING hash (k) WITH (fillfactor = 10);
      INSERT INTO public.dup SELECT i, 42 FROM generate_series(1, 2500) AS i;
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
    And target relation "public.dup_k" block 0 is recorded as a hash "meta" page
    And target relation "public.dup_k" block 65 is recorded as a hash "bitmap" page
    And target relation "public.dup_k" block 66 is recorded as a hash "overflow" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery except the WAL hole
    And the following SQL on "target" returns "t|2500|2500":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.dup),
             (SELECT count(*) FROM public.dup WHERE k = 42)
      FROM pg_index WHERE indexrelid = 'public.dup_k'::regclass;
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario Outline: WAL <wal> with checksums <checksums> transfers and accepts writes
    Given a fresh PostgreSQL pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 1200) AS i;
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
    Then the following SQL on "target" returns "t|1200|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE k = 3)
      FROM pg_index WHERE indexrelid = 'public.t_k'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 9000 + i, i * 3 FROM generate_series(1, 300) AS i;
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
      | wal  | checksums |
      | true | enabled   |
      | true | disabled  |
      | false | enabled  |
      | false | disabled |

  Scenario: Mismatched source and target checksums fail a hash transfer closed
    Given a fresh PostgreSQL pair with source checksums "enabled" and target checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i FROM generate_series(1, 100) AS i;
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
