@cross-major @hash
Feature: Approved HASH indexes transfer physically across major versions

  The core int2_ops/int4_ops/int8_ops hash procedures are identical on
  PostgreSQL 13-18, so their indexes cross majors as page images; the
  sparse reserved blocks and allocation geometry survive too.

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers int hash indexes physically
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (
        s smallint,
        i integer,
        b bigint
      );
      CREATE INDEX t_s ON public.t USING hash (s);
      CREATE INDEX t_i ON public.t USING hash (i);
      CREATE INDEX t_b ON public.t USING hash (b);
      INSERT INTO public.t
      SELECT i % 32768, i * 7919 - 100000, i * 104729
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
      """
    Then the following SQL on "target" returns "3|3|2000":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.t)
      FROM pg_index WHERE indrelid = 'public.t'::regclass;
      """
    And the following SQL on "target" contains "Index Scan using t_i on t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE i = 7919 - 100000;
      ROLLBACK;
      """
    And the following SQL on "target" returns "2000|1|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*),
             count(*) FILTER (WHERE i = 7919 - 100000),
             count(*) FILTER (WHERE b = 104729),
             count(*) FILTER (WHERE i = 7919 - 100000 + 1)
      FROM public.t;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t VALUES (7, 7919 - 100000, 104729);
      """
    Then the following SQL on "target" returns "2|2|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.t WHERE i = 7919 - 100000),
             (SELECT count(*) FROM public.t WHERE b = 104729),
             (SELECT count(*) FROM public.t WHERE s = 7)
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
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k) WITH (fillfactor = 10);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 3000) AS i;
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
             (SELECT pg_relation_size('public.t_k'::regclass) >= 111 * 8192),
             (SELECT count(*) FROM public.t)
      FROM pg_index WHERE indexrelid = 'public.t_k'::regclass;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t SELECT 9000 + i, i * 3 FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "5000|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*), count(*) FILTER (WHERE k = 3000)
      FROM public.t;
      ROLLBACK;
      """

    Examples:
      | wal  | checksums |
      | true | enabled   |
      | true | disabled  |
      | false | enabled  |
      | false | disabled |
