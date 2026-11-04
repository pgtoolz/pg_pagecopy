@cross-major @brin
Feature: Every upward pair transfers every approved opclass populated

  One scenario outline per approved opclass pair; the pair filter runs each
  job's own six examples. Each scenario proves the source physical
  classification, target validity and populated size, a named BRIN Bitmap
  Index Scan, duplicate-preserving indexed-versus-sequential equality,
  exact boundary counts on both clusters, and post-upgrade maintenance.

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers a populated smallint index
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k smallint);
      CREATE INDEX t_brin ON public.t USING brin (k int2_minmax_ops) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, (i % 7 - 3)::smallint FROM generate_series(1, 2800) AS i;
      INSERT INTO public.t SELECT i, (5800 + i)::smallint FROM generate_series(2801, 3000) AS i;
      INSERT INTO public.t VALUES (3001, -32768), (3002, 32767), (3003, NULL), (3004, NULL), (3005, 0);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical":
      """
      SELECT method FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT indisvalid, indisready,
             pg_relation_size('public.t_brin'::regclass) >= 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k > 8000;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|201":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k > 8000;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k > 8000;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    Then the following SQL on "source" returns "1|1201|2":
      """
      SELECT (SELECT count(*) FROM public.t WHERE k = 32767),
             (SELECT count(*) FROM public.t WHERE k BETWEEN -2 AND 0),
             (SELECT count(*) FROM public.t WHERE k IS NULL);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k = 32767;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k BETWEEN -2 AND 0;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k IS NULL;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|0|0|0|0|1|1201|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE eq_i AS SELECT id FROM public.t WHERE k = 32767;
      CREATE TEMP TABLE rg_i AS SELECT id FROM public.t WHERE k BETWEEN -2 AND 0;
      CREATE TEMP TABLE nl_i AS SELECT id FROM public.t WHERE k IS NULL;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE eq_s AS SELECT id FROM public.t WHERE k = 32767;
      CREATE TEMP TABLE rg_s AS SELECT id FROM public.t WHERE k BETWEEN -2 AND 0;
      CREATE TEMP TABLE nl_s AS SELECT id FROM public.t WHERE k IS NULL;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM eq_i EXCEPT ALL SELECT id FROM eq_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM eq_s EXCEPT ALL SELECT id FROM eq_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_i EXCEPT ALL SELECT id FROM rg_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_s EXCEPT ALL SELECT id FROM rg_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_i EXCEPT ALL SELECT id FROM nl_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_s EXCEPT ALL SELECT id FROM nl_i) AS d)
            || '|' || (SELECT count(*) FROM eq_i)
            || '|' || (SELECT count(*) FROM rg_i)
            || '|' || (SELECT count(*) FROM nl_i);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 10000 + i, (9000 + i)::smallint FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.t;
      """
    Then the following SQL on "target" returns "t|701|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             (SELECT count(*) FROM public.t WHERE k > 8000),
             brin_summarize_new_values('public.t_brin'::regclass) <= 1;
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13 | 14 |
      | 13 | 15 |
      | 13 | 16 |
      | 13 | 17 |
      | 13 | 18 |
      | 14 | 15 |
      | 14 | 16 |
      | 14 | 17 |
      | 14 | 18 |
      | 15 | 16 |
      | 15 | 17 |
      | 15 | 18 |
      | 16 | 17 |
      | 16 | 18 |
      | 17 | 18 |

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers a populated integer index
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 128);
      INSERT INTO public.t SELECT i, (i % 7 - 3)::integer FROM generate_series(1, 2800) AS i;
      INSERT INTO public.t SELECT i, (5800 + i)::integer FROM generate_series(2801, 3000) AS i;
      INSERT INTO public.t VALUES (3001, (-2147483648)::integer), (3002, 2147483647), (3003, NULL), (3004, NULL), (3005, 0);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical":
      """
      SELECT method FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT indisvalid, indisready,
             pg_relation_size('public.t_brin'::regclass) >= 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k > 8000;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|201":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k > 8000;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k > 8000;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k = 2147483647;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k BETWEEN -2 AND 0;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k IS NULL;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|0|0|0|0|1|1201|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE eq_i AS SELECT id FROM public.t WHERE k = 2147483647;
      CREATE TEMP TABLE rg_i AS SELECT id FROM public.t WHERE k BETWEEN -2 AND 0;
      CREATE TEMP TABLE nl_i AS SELECT id FROM public.t WHERE k IS NULL;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE eq_s AS SELECT id FROM public.t WHERE k = 2147483647;
      CREATE TEMP TABLE rg_s AS SELECT id FROM public.t WHERE k BETWEEN -2 AND 0;
      CREATE TEMP TABLE nl_s AS SELECT id FROM public.t WHERE k IS NULL;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM eq_i EXCEPT ALL SELECT id FROM eq_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM eq_s EXCEPT ALL SELECT id FROM eq_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_i EXCEPT ALL SELECT id FROM rg_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_s EXCEPT ALL SELECT id FROM rg_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_i EXCEPT ALL SELECT id FROM nl_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_s EXCEPT ALL SELECT id FROM nl_i) AS d)
            || '|' || (SELECT count(*) FROM eq_i)
            || '|' || (SELECT count(*) FROM rg_i)
            || '|' || (SELECT count(*) FROM nl_i);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 10000 + i, 9000 + i FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.t;
      """
    Then the following SQL on "target" returns "t|701|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             (SELECT count(*) FROM public.t WHERE k > 8000),
             brin_summarize_new_values('public.t_brin'::regclass) <= 1;
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13 | 14 |
      | 13 | 15 |
      | 13 | 16 |
      | 13 | 17 |
      | 13 | 18 |
      | 14 | 15 |
      | 14 | 16 |
      | 14 | 17 |
      | 14 | 18 |
      | 15 | 16 |
      | 15 | 17 |
      | 15 | 18 |
      | 16 | 17 |
      | 16 | 18 |
      | 17 | 18 |

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers a populated bigint index
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k int8_minmax_ops) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, (i % 7 - 3)::bigint FROM generate_series(1, 2800) AS i;
      INSERT INTO public.t SELECT i, (5800 + i)::bigint FROM generate_series(2801, 3000) AS i;
      INSERT INTO public.t VALUES (3001, (-9223372036854775808)::bigint), (3002, 9223372036854775807), (3003, NULL), (3004, NULL), (3005, 0);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical":
      """
      SELECT method FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT indisvalid, indisready,
             pg_relation_size('public.t_brin'::regclass) >= 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k > 8000;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|201":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k > 8000;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k > 8000;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    Then the following SQL on "source" returns "1|1201|2":
      """
      SELECT (SELECT count(*) FROM public.t WHERE k = 9223372036854775807),
             (SELECT count(*) FROM public.t WHERE k BETWEEN -2 AND 0),
             (SELECT count(*) FROM public.t WHERE k IS NULL);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k = 9223372036854775807;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k BETWEEN -2 AND 0;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k IS NULL;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|0|0|0|0|1|1201|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE eq_i AS SELECT id FROM public.t WHERE k = 9223372036854775807;
      CREATE TEMP TABLE rg_i AS SELECT id FROM public.t WHERE k BETWEEN -2 AND 0;
      CREATE TEMP TABLE nl_i AS SELECT id FROM public.t WHERE k IS NULL;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE eq_s AS SELECT id FROM public.t WHERE k = 9223372036854775807;
      CREATE TEMP TABLE rg_s AS SELECT id FROM public.t WHERE k BETWEEN -2 AND 0;
      CREATE TEMP TABLE nl_s AS SELECT id FROM public.t WHERE k IS NULL;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM eq_i EXCEPT ALL SELECT id FROM eq_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM eq_s EXCEPT ALL SELECT id FROM eq_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_i EXCEPT ALL SELECT id FROM rg_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_s EXCEPT ALL SELECT id FROM rg_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_i EXCEPT ALL SELECT id FROM nl_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_s EXCEPT ALL SELECT id FROM nl_i) AS d)
            || '|' || (SELECT count(*) FROM eq_i)
            || '|' || (SELECT count(*) FROM rg_i)
            || '|' || (SELECT count(*) FROM nl_i);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 10000 + i, 9000 + i FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.t;
      """
    Then the following SQL on "target" returns "t|701|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             (SELECT count(*) FROM public.t WHERE k > 8000),
             brin_summarize_new_values('public.t_brin'::regclass) <= 1;
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13 | 14 |
      | 13 | 15 |
      | 13 | 16 |
      | 13 | 17 |
      | 13 | 18 |
      | 14 | 15 |
      | 14 | 16 |
      | 14 | 17 |
      | 14 | 18 |
      | 15 | 16 |
      | 15 | 17 |
      | 15 | 18 |
      | 16 | 17 |
      | 16 | 18 |
      | 17 | 18 |

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers a populated date index
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k date);
      CREATE INDEX t_brin ON public.t USING brin (k date_minmax_ops) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, date '2000-01-01' + (i % 7 - 3) FROM generate_series(1, 2800) AS i;
      INSERT INTO public.t SELECT i, date '2030-01-01' + (i - 2801) FROM generate_series(2801, 3000) AS i;
      INSERT INTO public.t VALUES (3001, date '0001-01-01 BC'), (3002, date 'infinity'), (3003, date '-infinity'), (3004, NULL), (3005, NULL), (3006, date '2000-01-01');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical":
      """
      SELECT method FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT indisvalid, indisready,
             pg_relation_size('public.t_brin'::regclass) >= 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k >= date '2030-01-01';
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|201":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k >= date '2030-01-01';
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k >= date '2030-01-01';
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k = date '0001-01-01 BC';
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k BETWEEN date '1999-12-30' AND date '2000-01-01';
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k IS NULL;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|0|0|0|0|1|1201|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE eq_i AS SELECT id FROM public.t WHERE k = date '0001-01-01 BC';
      CREATE TEMP TABLE rg_i AS SELECT id FROM public.t WHERE k BETWEEN date '1999-12-30' AND date '2000-01-01';
      CREATE TEMP TABLE nl_i AS SELECT id FROM public.t WHERE k IS NULL;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE eq_s AS SELECT id FROM public.t WHERE k = date '0001-01-01 BC';
      CREATE TEMP TABLE rg_s AS SELECT id FROM public.t WHERE k BETWEEN date '1999-12-30' AND date '2000-01-01';
      CREATE TEMP TABLE nl_s AS SELECT id FROM public.t WHERE k IS NULL;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM eq_i EXCEPT ALL SELECT id FROM eq_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM eq_s EXCEPT ALL SELECT id FROM eq_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_i EXCEPT ALL SELECT id FROM rg_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_s EXCEPT ALL SELECT id FROM rg_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_i EXCEPT ALL SELECT id FROM nl_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_s EXCEPT ALL SELECT id FROM nl_i) AS d)
            || '|' || (SELECT count(*) FROM eq_i)
            || '|' || (SELECT count(*) FROM rg_i)
            || '|' || (SELECT count(*) FROM nl_i);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 10000 + i, date '2040-01-01' + i FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.t;
      """
    Then the following SQL on "target" returns "t|701|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             (SELECT count(*) FROM public.t WHERE k >= date '2030-01-01'),
             brin_summarize_new_values('public.t_brin'::regclass) <= 1;
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13 | 14 |
      | 13 | 15 |
      | 13 | 16 |
      | 13 | 17 |
      | 13 | 18 |
      | 14 | 15 |
      | 14 | 16 |
      | 14 | 17 |
      | 14 | 18 |
      | 15 | 16 |
      | 15 | 17 |
      | 15 | 18 |
      | 16 | 17 |
      | 16 | 18 |
      | 17 | 18 |

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers a populated timestamp index
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k timestamp);
      CREATE INDEX t_brin ON public.t USING brin (k timestamp_minmax_ops) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, timestamp '2000-01-01' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i;
      INSERT INTO public.t SELECT i, timestamp '2030-01-01' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i;
      INSERT INTO public.t VALUES (3001, timestamp '0001-01-01 00:00:00 BC'), (3002, timestamp 'infinity'), (3003, timestamp '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamp '2000-01-01 00:00:00.000001');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical":
      """
      SELECT method FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT indisvalid, indisready,
             pg_relation_size('public.t_brin'::regclass) >= 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k >= timestamp '2030-01-01';
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|201":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k >= timestamp '2030-01-01';
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k >= timestamp '2030-01-01';
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k = timestamp '2000-01-01 00:00:00.000001';
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k BETWEEN timestamp '2000-01-01' AND timestamp '2000-01-02';
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k IS NULL;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|0|0|0|0|1|801|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE eq_i AS SELECT id FROM public.t WHERE k = timestamp '2000-01-01 00:00:00.000001';
      CREATE TEMP TABLE rg_i AS SELECT id FROM public.t WHERE k BETWEEN timestamp '2000-01-01' AND timestamp '2000-01-02';
      CREATE TEMP TABLE nl_i AS SELECT id FROM public.t WHERE k IS NULL;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE eq_s AS SELECT id FROM public.t WHERE k = timestamp '2000-01-01 00:00:00.000001';
      CREATE TEMP TABLE rg_s AS SELECT id FROM public.t WHERE k BETWEEN timestamp '2000-01-01' AND timestamp '2000-01-02';
      CREATE TEMP TABLE nl_s AS SELECT id FROM public.t WHERE k IS NULL;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM eq_i EXCEPT ALL SELECT id FROM eq_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM eq_s EXCEPT ALL SELECT id FROM eq_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_i EXCEPT ALL SELECT id FROM rg_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_s EXCEPT ALL SELECT id FROM rg_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_i EXCEPT ALL SELECT id FROM nl_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_s EXCEPT ALL SELECT id FROM nl_i) AS d)
            || '|' || (SELECT count(*) FROM eq_i)
            || '|' || (SELECT count(*) FROM rg_i)
            || '|' || (SELECT count(*) FROM nl_i);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 10000 + i, timestamp '2040-01-01' + make_interval(secs => i * 30) FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.t;
      """
    Then the following SQL on "target" returns "t|701|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             (SELECT count(*) FROM public.t WHERE k >= timestamp '2030-01-01'),
             brin_summarize_new_values('public.t_brin'::regclass) <= 1;
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13 | 14 |
      | 13 | 15 |
      | 13 | 16 |
      | 13 | 17 |
      | 13 | 18 |
      | 14 | 15 |
      | 14 | 16 |
      | 14 | 17 |
      | 14 | 18 |
      | 15 | 16 |
      | 15 | 17 |
      | 15 | 18 |
      | 16 | 17 |
      | 16 | 18 |
      | 17 | 18 |

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers a populated timestamptz index
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k timestamptz);
      CREATE INDEX t_brin ON public.t USING brin (k timestamptz_minmax_ops) WITH (pages_per_range = 128);
      INSERT INTO public.t SELECT i, timestamptz '2000-01-01 00:00:00+00' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i;
      INSERT INTO public.t SELECT i, timestamptz '2030-01-01 00:00:00+00' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i;
      INSERT INTO public.t VALUES (3001, timestamptz '0001-01-01 00:00:00+00 BC'), (3002, timestamptz 'infinity'), (3003, timestamptz '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamptz '2024-06-01 00:00:00+00'), (3007, timestamptz '2024-06-01 02:00:00+02'), (3008, timestamptz '2024-05-31 19:00:00-05'), (3009, timestamptz '2024-06-01 00:00:00+00');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical":
      """
      SELECT method FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT indisvalid, indisready,
             pg_relation_size('public.t_brin'::regclass) >= 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k >= timestamptz '2030-01-01 00:00:00+00';
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|201":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k >= timestamptz '2030-01-01 00:00:00+00';
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k >= timestamptz '2030-01-01 00:00:00+00';
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k = timestamptz '2024-06-01 00:00:00+00';
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k BETWEEN timestamptz '2000-01-01 00:00:00+00' AND timestamptz '2000-01-02 00:00:00+00';
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k IS NULL;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|0|0|0|0|4|800|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE eq_i AS SELECT id FROM public.t WHERE k = timestamptz '2024-06-01 00:00:00+00';
      CREATE TEMP TABLE rg_i AS SELECT id FROM public.t WHERE k BETWEEN timestamptz '2000-01-01 00:00:00+00' AND timestamptz '2000-01-02 00:00:00+00';
      CREATE TEMP TABLE nl_i AS SELECT id FROM public.t WHERE k IS NULL;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE eq_s AS SELECT id FROM public.t WHERE k = timestamptz '2024-06-01 00:00:00+00';
      CREATE TEMP TABLE rg_s AS SELECT id FROM public.t WHERE k BETWEEN timestamptz '2000-01-01 00:00:00+00' AND timestamptz '2000-01-02 00:00:00+00';
      CREATE TEMP TABLE nl_s AS SELECT id FROM public.t WHERE k IS NULL;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM eq_i EXCEPT ALL SELECT id FROM eq_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM eq_s EXCEPT ALL SELECT id FROM eq_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_i EXCEPT ALL SELECT id FROM rg_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM rg_s EXCEPT ALL SELECT id FROM rg_i) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_i EXCEPT ALL SELECT id FROM nl_s) AS d)
            || '|' || (SELECT count(*) FROM (SELECT id FROM nl_s EXCEPT ALL SELECT id FROM nl_i) AS d)
            || '|' || (SELECT count(*) FROM eq_i)
            || '|' || (SELECT count(*) FROM rg_i)
            || '|' || (SELECT count(*) FROM nl_i);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 10000 + i, timestamptz '2040-01-01 00:00:00+00' + make_interval(secs => i * 30) FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.t;
      """
    Then the following SQL on "target" returns "t|701|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             (SELECT count(*) FROM public.t WHERE k >= timestamptz '2030-01-01 00:00:00+00'),
             brin_summarize_new_values('public.t_brin'::regclass) <= 1;
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13 | 14 |
      | 13 | 15 |
      | 13 | 16 |
      | 13 | 17 |
      | 13 | 18 |
      | 14 | 15 |
      | 14 | 16 |
      | 14 | 17 |
      | 14 | 18 |
      | 15 | 16 |
      | 15 | 17 |
      | 15 | 18 |
      | 16 | 17 |
      | 16 | 18 |
      | 17 | 18 |
