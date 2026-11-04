@brin
Feature: BRIN pages_per_range geometry transfers exactly

  Every geometry is measured in actual heap and index blocks, never in row
  counts: a shared exact-fill loop builds heaps of a chosen block count, and
  each scenario asserts the same measured geometry on source and target plus
  indexed-versus-sequential equality.

  Scenario Outline: pages_per_range <ppr> transfers with identical measured geometry
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.g (id bigint, pad integer) WITH (fillfactor = 10);
      DO $do$
      DECLARE n bigint := 0;
      BEGIN
        WHILE (SELECT pg_relation_size('public.g')) < 12 * 8192 LOOP
          INSERT INTO public.g SELECT n + i, (n + i) % 97 FROM generate_series(1, 20) AS i;
          n := n + 20;
        END LOOP;
        WHILE (SELECT pg_relation_size('public.g')) < 13 * 8192 LOOP
          INSERT INTO public.g VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
      END
      $do$;
      CREATE INDEX g_brin ON public.g USING brin (id) WITH (pages_per_range = <ppr>);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "13|3":
      """
      SELECT pg_relation_size('public.g') / 8192,
             pg_relation_size('public.g_brin'::regclass) / 8192;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.g', 'public.g', true
      );
      """
    Then the following SQL on "target" returns "13|3|t|t":
      """
      SELECT pg_relation_size('public.g') / 8192,
             pg_relation_size('public.g_brin'::regclass) / 8192,
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.g_brin'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on g_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.g WHERE id < 3;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.g WHERE id < 3;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.g WHERE id < 3;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """

    Examples:
      | ppr |
      | 1   |
      | 2   |
      | 3   |
      | 4   |
      | 128 |

  Scenario: A pages_per_range larger than the heap still transfers one partial range
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.g (id bigint, pad integer) WITH (fillfactor = 10);
      DO $do$
      DECLARE n bigint := 0;
      BEGIN
        WHILE (SELECT pg_relation_size('public.g')) < 13 * 8192 LOOP
          INSERT INTO public.g VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
      END
      $do$;
      CREATE INDEX g_brin ON public.g USING brin (id) WITH (pages_per_range = 1024);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "13|3":
      """
      SELECT pg_relation_size('public.g') / 8192,
             pg_relation_size('public.g_brin'::regclass) / 8192;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.g', 'public.g', true
      );
      """
    Then the following SQL on "target" returns "13|3|t|t":
      """
      SELECT pg_relation_size('public.g') / 8192,
             pg_relation_size('public.g_brin'::regclass) / 8192,
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.g_brin'::regclass;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.g WHERE id = 5;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.g WHERE id = 5;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """

  Scenario: Heaps ending just before, exactly at and just after a range boundary
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.g7 (id bigint, pad integer) WITH (fillfactor = 10);
      CREATE TABLE public.g8 (id bigint, pad integer) WITH (fillfactor = 10);
      CREATE TABLE public.g9 (id bigint, pad integer) WITH (fillfactor = 10);
      DO $do$
      DECLARE n bigint := 0;
      BEGIN
        WHILE (SELECT pg_relation_size('public.g7')) < 7 * 8192 LOOP
          INSERT INTO public.g7 VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
        n := 0;
        WHILE (SELECT pg_relation_size('public.g8')) < 8 * 8192 LOOP
          INSERT INTO public.g8 VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
        n := 0;
        WHILE (SELECT pg_relation_size('public.g9')) < 9 * 8192 LOOP
          INSERT INTO public.g9 VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
      END
      $do$;
      CREATE INDEX g7_brin ON public.g7 USING brin (id) WITH (pages_per_range = 4);
      CREATE INDEX g8_brin ON public.g8 USING brin (id) WITH (pages_per_range = 4);
      CREATE INDEX g9_brin ON public.g9 USING brin (id) WITH (pages_per_range = 4);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "7|3|8|3|9|3":
      """
      SELECT pg_relation_size('public.g7') / 8192,
             pg_relation_size('public.g7_brin'::regclass) / 8192,
             pg_relation_size('public.g8') / 8192,
             pg_relation_size('public.g8_brin'::regclass) / 8192,
             pg_relation_size('public.g9') / 8192,
             pg_relation_size('public.g9_brin'::regclass) / 8192;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.g7', 'public.g7', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.g8', 'public.g8', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.g9', 'public.g9', true
      );
      """
    Then the following SQL on "target" returns "7|3|8|3|9|3":
      """
      SELECT pg_relation_size('public.g7') / 8192,
             pg_relation_size('public.g7_brin'::regclass) / 8192,
             pg_relation_size('public.g8') / 8192,
             pg_relation_size('public.g8_brin'::regclass) / 8192,
             pg_relation_size('public.g9') / 8192,
             pg_relation_size('public.g9_brin'::regclass) / 8192;
      """
    And the following SQL on "target" returns "0|0|0|0|0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE i7 AS SELECT id FROM public.g7 WHERE id = 3;
      CREATE TEMP TABLE i8 AS SELECT id FROM public.g8 WHERE id = 3;
      CREATE TEMP TABLE i9 AS SELECT id FROM public.g9 WHERE id = 3;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE s7 AS SELECT id FROM public.g7 WHERE id = 3;
      CREATE TEMP TABLE s8 AS SELECT id FROM public.g8 WHERE id = 3;
      CREATE TEMP TABLE s9 AS SELECT id FROM public.g9 WHERE id = 3;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM i7 EXCEPT ALL SELECT id FROM s7) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM s7 EXCEPT ALL SELECT id FROM i7) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM i8 EXCEPT ALL SELECT id FROM s8) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM s8 EXCEPT ALL SELECT id FROM i8) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM i9 EXCEPT ALL SELECT id FROM s9) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM s9 EXCEPT ALL SELECT id FROM i9) AS d);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on g7_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.g7
      WHERE id >= (SELECT max(id) FROM public.g7) - 1;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on g8_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.g8
      WHERE id >= (SELECT max(id) FROM public.g8) - 1;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on g9_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.g9
      WHERE id >= (SELECT max(id) FROM public.g9) - 1;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|t|0|0|t|0|0|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE f7 AS SELECT id FROM public.g7
      WHERE id >= (SELECT max(id) FROM public.g7) - 1;
      CREATE TEMP TABLE f8 AS SELECT id FROM public.g8
      WHERE id >= (SELECT max(id) FROM public.g8) - 1;
      CREATE TEMP TABLE f9 AS SELECT id FROM public.g9
      WHERE id >= (SELECT max(id) FROM public.g9) - 1;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE t7 AS SELECT id FROM public.g7
      WHERE id >= (SELECT max(id) FROM public.g7) - 1;
      CREATE TEMP TABLE t8 AS SELECT id FROM public.g8
      WHERE id >= (SELECT max(id) FROM public.g8) - 1;
      CREATE TEMP TABLE t9 AS SELECT id FROM public.g9
      WHERE id >= (SELECT max(id) FROM public.g9) - 1;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM f7 EXCEPT ALL SELECT id FROM t7) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM t7 EXCEPT ALL SELECT id FROM f7) AS d)
           || '|' || substr(((SELECT count(*) FROM f7) = (SELECT count(*) FROM t7)
                        AND (SELECT count(*) FROM t7) > 0)::text, 1, 1)
           || '|' || (SELECT count(*) FROM (SELECT id FROM f8 EXCEPT ALL SELECT id FROM t8) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM t8 EXCEPT ALL SELECT id FROM f8) AS d)
           || '|' || substr(((SELECT count(*) FROM f8) = (SELECT count(*) FROM t8)
                        AND (SELECT count(*) FROM t8) > 0)::text, 1, 1)
           || '|' || (SELECT count(*) FROM (SELECT id FROM f9 EXCEPT ALL SELECT id FROM t9) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM t9 EXCEPT ALL SELECT id FROM f9) AS d)
           || '|' || substr(((SELECT count(*) FROM f9) = (SELECT count(*) FROM t9)
                        AND (SELECT count(*) FROM t9) > 0)::text, 1, 1);
      """

  Scenario: One row, one heap page and one complete range are the smallest transferable geometry
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.one (id bigint, pad integer);
      INSERT INTO public.one VALUES (1, 7);
      CREATE TABLE public.page (id bigint, pad integer);
      INSERT INTO public.page SELECT i, i % 97 FROM generate_series(1, 100) AS i;
      CREATE TABLE public.range1 (id bigint, pad integer) WITH (fillfactor = 10);
      DO $do$
      DECLARE n bigint := 0;
      BEGIN
        WHILE (SELECT pg_relation_size('public.range1')) < 1 * 8192 LOOP
          INSERT INTO public.range1 VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
      END
      $do$;
      CREATE INDEX one_brin ON public.one USING brin (id) WITH (pages_per_range = 1);
      CREATE INDEX page_brin ON public.page USING brin (id) WITH (pages_per_range = 1);
      CREATE INDEX range1_brin ON public.range1 USING brin (id) WITH (pages_per_range = 1);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.one', 'public.one', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.page', 'public.page', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.range1', 'public.range1', true
      );
      """
    Then the following SQL on "target" returns "1|3|1|3|1|3|t|t|t":
      """
      SELECT pg_relation_size('public.one') / 8192,
             pg_relation_size('public.one_brin'::regclass) / 8192,
             pg_relation_size('public.page') / 8192,
             pg_relation_size('public.page_brin'::regclass) / 8192,
             pg_relation_size('public.range1') / 8192,
             pg_relation_size('public.range1_brin'::regclass) / 8192,
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.one_brin'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.page_brin'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.range1_brin'::regclass);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on page_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.page WHERE id = 42;
      ROLLBACK;
      """

  Scenario: A measured multi-revmap-page extent transfers completely
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.big (id bigint, pad integer) WITH (fillfactor = 10);
      DO $do$
      DECLARE n bigint := 0;
      BEGIN
        WHILE (SELECT pg_relation_size('public.big')) < 1390 * 8192 LOOP
          INSERT INTO public.big SELECT n + i, (n + i) % 97 FROM generate_series(1, 20) AS i;
          n := n + 20;
        END LOOP;
        WHILE (SELECT pg_relation_size('public.big')) < 1400 * 8192 LOOP
          INSERT INTO public.big VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
      END
      $do$;
      CREATE INDEX big_brin ON public.big USING brin (id) WITH (pages_per_range = 1);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "1400|t":
      """
      SELECT pg_relation_size('public.big') / 8192,
             pg_relation_size('public.big') / 8192 > 1358
      """
    Then the following SQL on "source" returns "8|t":
      """
      SELECT pg_relation_size('public.big_brin'::regclass) / 8192,
             pg_relation_size('public.big_brin'::regclass) / 8192 <= 24;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.big', 'public.big', true
      );
      """
    Then the following SQL on "target" returns "1400|8|t|t":
      """
      SELECT pg_relation_size('public.big') / 8192,
             pg_relation_size('public.big_brin'::regclass) / 8192,
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.big_brin'::regclass;
      """
    When target relation "public.big_brin" block 2 is recorded as a brin "revmap" page
    And target relation "public.big_brin" block 7 is recorded as a brin "summary" page
    Then the following SQL on "target" contains "Bitmap Index Scan on big_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.big
      WHERE id >= (SELECT max(id) FROM public.big) - 40;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.big
      WHERE id >= (SELECT max(id) FROM public.big) - 40;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.big
      WHERE id >= (SELECT max(id) FROM public.big) - 40;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || substr(((SELECT count(*) FROM pc_indexed)
                        = (SELECT count(*) FROM pc_sequential)
                        AND (SELECT count(*) FROM pc_sequential) > 0)::text, 1, 1);
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.big WHERE id < 3;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.big WHERE id < 3;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """

  Scenario: Enough ranges to allocate several summary pages transfer completely
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.sum (id bigint, pad integer) WITH (fillfactor = 10);
      DO $do$
      DECLARE n bigint := 0;
      BEGIN
        WHILE (SELECT pg_relation_size('public.sum')) < 599 * 8192 LOOP
          INSERT INTO public.sum SELECT n + i, (n + i) % 97 FROM generate_series(1, 20) AS i;
          n := n + 20;
        END LOOP;
        WHILE (SELECT pg_relation_size('public.sum')) < 600 * 8192 LOOP
          INSERT INTO public.sum VALUES (n, n % 97);
          n := n + 1;
        END LOOP;
      END
      $do$;
      CREATE INDEX sum_brin ON public.sum USING brin (id) WITH (pages_per_range = 1);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "600|5":
      """
      SELECT pg_relation_size('public.sum') / 8192,
             pg_relation_size('public.sum_brin'::regclass) / 8192;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.sum', 'public.sum', true
      );
      """
    Then the following SQL on "target" returns "600|5|t|t":
      """
      SELECT pg_relation_size('public.sum') / 8192,
             pg_relation_size('public.sum_brin'::regclass) / 8192,
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.sum_brin'::regclass;
      """
    When target relation "public.sum_brin" block 4 is recorded as a brin "summary" page
    Then the following SQL on "target" contains "Bitmap Index Scan on sum_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.sum
      WHERE id >= (SELECT max(id) FROM public.sum) - 40;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.sum
      WHERE id >= (SELECT max(id) FROM public.sum) - 40;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.sum
      WHERE id >= (SELECT max(id) FROM public.sum) - 40;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || substr(((SELECT count(*) FROM pc_indexed)
                        = (SELECT count(*) FROM pc_sequential)
                        AND (SELECT count(*) FROM pc_sequential) > 0)::text, 1, 1);
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.sum WHERE id < 3;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.sum WHERE id < 3;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
