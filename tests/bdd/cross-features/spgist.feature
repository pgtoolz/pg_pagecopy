@cross-major @spgist @cross
Feature: Approved SP-GiST indexes transfer physically across major versions

  The core quad_point_ops and kd_point_ops support functions are identical
  on PostgreSQL 13-18 (their pinned core OIDs never moved), so point
  indexes cross majors as page images, nulls tree and split geometry
  included.

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers spgist point indexes physically
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (p point);
      CREATE INDEX t_p ON public.t USING spgist (p);
      CREATE TABLE public.k (q point);
      CREATE INDEX k_q ON public.k USING spgist (q kd_point_ops);
      INSERT INTO public.t
      SELECT point(i % 97, i % 89)
      FROM generate_series(1, 2000) AS i;
      INSERT INTO public.k
      SELECT point((i * 7919) % 211 - 105, (i * 104729) % 199 - 99)
      FROM generate_series(1, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.k', 'public.k', true
      );
      """
    Then the following SQL on "target" returns "2|2|2000":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.t)
      FROM pg_index
      WHERE indrelid IN ('public.t'::regclass, 'public.k'::regclass);
      """
    And the following SQL on "target" contains "using t_p on t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t
        WHERE p <@ box(point(0, 0), point(4, 4));
      ROLLBACK;
      """
    And the following SQL on "target" contains "using k_q on k":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.k
        WHERE q <@ box(point(-1, -1), point(1, 1));
      ROLLBACK;
      """
    And the following SQL on "target" returns "2000|8|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*),
             count(*) FILTER (WHERE p <@ box(point(0, 0), point(4, 4))),
             (SELECT count(*) FROM public.k WHERE q <@ box(point(-1, -1), point(1, 1)))
      FROM public.t;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t VALUES (point(0, 0));
      INSERT INTO public.k VALUES (point(-105, -99));
      """
    Then the following SQL on "target" returns "1|1|9":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(0, 0))),
             (SELECT count(*) FROM public.k WHERE q <@ box(point(-106, -100), point(-104, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(4, 4)));
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13           | 14           |
      | 13           | 18           |
      | 17           | 18           |

  Scenario Outline: PostgreSQL 13 to 18 with WAL <wal> and checksums <checksums>
    Given a fresh PostgreSQL 13 to 18 pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t
      SELECT i, CASE WHEN i % 13 = 0 THEN NULL
                     ELSE point(i % 97, i % 89) END
      FROM generate_series(1, 3000) AS i;
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
    Then the following SQL on "target" returns "t|t|3000":
      """
      SELECT indisvalid AND indisready,
             (SELECT pg_relation_size('public.t_q'::regclass) > 3 * 8192),
             (SELECT count(*) FROM public.t)
      FROM pg_index WHERE indexrelid = 'public.t_q'::regclass;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 9000 + i, point(i % 83, i % 79) FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "5000|230":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*), count(*) FILTER (WHERE p IS NULL)
      FROM public.t;
      ROLLBACK;
      """

    Examples:
      | wal   | checksums |
      | true  | enabled   |
      | true  | disabled  |
      | false | enabled   |
      | false | disabled  |
