@brin
Feature: Dataset shapes transfer with identical BRIN results

  Ascending, descending, shuffled, duplicate-heavy, all-equal, outlier,
  all-NULL and mixed-NULL keys all transfer as page images and answer the
  same predicates on source and target, with duplicate-preserving
  indexed-versus-sequential equality on the target.

  Scenario Outline: A <shape> key distribution transfers and answers identically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.d (id integer, k bigint, payload text);
      INSERT INTO public.d
      SELECT i, <keygen>, 'p' || i
      FROM generate_series(1, 6000) AS i;
      CREATE INDEX d_brin ON public.d USING brin (k) WITH (pages_per_range = 4);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical|<eqn>|<nulln>|6000":
      """
      SELECT (SELECT method FROM pagecopy.check('public.d')
              WHERE name = 'd_brin' AND type = 'index'),
             count(*) FILTER (WHERE <eq>),
             count(*) FILTER (WHERE k IS NULL),
             count(*)
      FROM public.d;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.d', 'public.d', true
      );
      """
    Then the following SQL on "target" returns "t|<eqn>|<nulln>|6000":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = 'public.d_brin'::regclass),
             count(*) FILTER (WHERE <eq>),
             count(*) FILTER (WHERE k IS NULL),
             count(*)
FROM public.d;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on d_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.d WHERE <eq>;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.d WHERE <eq>;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.d WHERE <eq>;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """

    Examples:
      | shape          | keygen                                                               | eq    | eqn | nulln |
      | ascending      | i                                                                    | k = 5000 | 1   | 0     |
      | descending     | 6001 - i                                                             | k = 1    | 1   | 0     |
      | shuffled       | (i * 7919) % 6000                                                    | k = 5000 | 1   | 0     |
      | duplicates     | i % 10                                                               | k = 3    | 600 | 0     |
      | all equal      | 42                                                                   | k = 42   | 6000 | 0    |
      | sparse outliers | CASE WHEN i % 3000 = 0 THEN 1000000 + i ELSE 7 END                  | k > 500000 | 2 | 0     |
      | all null       | NULL                                                                 | k = 5    | 0   | 6000  |
      | mixed null     | CASE WHEN i % 3 = 0 THEN NULL ELSE i % 100 END                       | k = 5    | 40  | 2000  |

  Scenario: Verified out-of-line TOAST alongside a BRIN index transfers completely
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.wide (id bigint, k bigint, payload text);
      CREATE INDEX wide_brin ON public.wide USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.wide
      SELECT i, i % 100, (SELECT string_agg(md5(i::text || g::text), '') FROM generate_series(1, 64) AS g)
      FROM generate_series(1, 800) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "t|800":
      """
      SELECT pg_relation_size(
               (SELECT reltoastrelid FROM pg_class
                WHERE oid = 'public.wide'::regclass)) > 0,
             (SELECT count(*) FROM public.wide);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.wide', 'public.wide', true
      );
      """
    Then the following SQL on "target" returns "t|t|8|800|2048":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = 'public.wide_brin'::regclass),
             pg_relation_size(
               (SELECT reltoastrelid FROM pg_class
                WHERE oid = 'public.wide'::regclass)) > 0,
             count(*) FILTER (WHERE k = 5),
             count(*),
             (SELECT length(payload) FROM public.wide WHERE id = 42)
FROM public.wide;
      """
    And the following SQL on "target" returns "0|0|8":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.wide WHERE k = 5;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.wide WHERE k = 5;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """

  Scenario: Updates beyond the extrema, deletes and reinserts stay consistent after VACUUM
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.m (id integer, k bigint);
      INSERT INTO public.m SELECT i, i FROM generate_series(1, 3000) AS i;
      CREATE INDEX m_brin ON public.m USING brin (k) WITH (pages_per_range = 4);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.m', 'public.m', true
      );
      UPDATE public.m SET k = -k * 1000 WHERE id <= 300;
      DELETE FROM public.m WHERE id BETWEEN 500 AND 600;
      INSERT INTO public.m
      SELECT i, -5000000 - i FROM generate_series(500, 600) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.m;
      """
    Then the following SQL on "target" returns "t|401|101|1":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = 'public.m_brin'::regclass),
             count(*) FILTER (WHERE k < 0),
             count(*) FILTER (WHERE k <= -5000000),
             count(*) FILTER (WHERE k = -100000)
FROM public.m;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on m_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.m WHERE k < 0;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.m WHERE k < 0;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.m WHERE k < 0;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
