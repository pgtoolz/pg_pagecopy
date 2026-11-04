@brin
Feature: Every approved opclass pair transfers physically with exact results

  Each of the six approved opclass/type pairs (int2, int4, int8, date,
  timestamp, timestamptz ordinary minmax) transfers as page images in both
  the explicit-opclass and the default-opclass form. Every scenario proves
  the source physical classification, target validity and populated size, a
  named BRIN Bitmap Index Scan, and duplicate-preserving indexed-versus-
  sequential equality for a selective predicate, plus exact counts for
  boundary, NULL and timezone-equivalent predicates on both clusters.

  Scenario Outline: <label> with <form> opclass form transfers populated summaries exactly
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k <coldef>);
      CREATE INDEX t_brin ON public.t USING brin (k <opc>) WITH (pages_per_range = 4);
      <datagen>
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical|t":
      """
      SELECT method, supported FROM pagecopy.check('public.t')
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
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE <sel>;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Heap Scan":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE <sel>;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|<seln>":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE <sel>;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE <sel>;
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
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE <eq>;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE <rng>;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE k IS NULL;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|<eqn>|0|0|<rngn>|0|0|<nuln>":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE eq_i AS SELECT id FROM public.t WHERE <eq>;
      CREATE TEMP TABLE rg_i AS SELECT id FROM public.t WHERE <rng>;
      CREATE TEMP TABLE nl_i AS SELECT id FROM public.t WHERE k IS NULL;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE eq_s AS SELECT id FROM public.t WHERE <eq>;
      CREATE TEMP TABLE rg_s AS SELECT id FROM public.t WHERE <rng>;
      CREATE TEMP TABLE nl_s AS SELECT id FROM public.t WHERE k IS NULL;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM eq_i EXCEPT ALL SELECT id FROM eq_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM eq_s EXCEPT ALL SELECT id FROM eq_i) AS d)
           || '|' || (SELECT count(*) FROM eq_i)
           || '|' || (SELECT count(*) FROM (SELECT id FROM rg_i EXCEPT ALL SELECT id FROM rg_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM rg_s EXCEPT ALL SELECT id FROM rg_i) AS d)
           || '|' || (SELECT count(*) FROM rg_i)
           || '|' || (SELECT count(*) FROM (SELECT id FROM nl_i EXCEPT ALL SELECT id FROM nl_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM nl_s EXCEPT ALL SELECT id FROM nl_i) AS d)
           || '|' || (SELECT count(*) FROM nl_i);
      """
    Then the following SQL on "source" returns "<eqn>|<rngn>|<nuln>":
      """
      SELECT (SELECT count(*) FROM public.t WHERE <eq>),
             (SELECT count(*) FROM public.t WHERE <rng>),
             (SELECT count(*) FROM public.t WHERE k IS NULL);
      """

    Examples:
      | label       | form     | coldef       | opc                   | datagen                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | sel                                        | seln | eq                                        | eqn | rng                                                                                                   | rngn | nuln |
      | smallint    | explicit | smallint     | int2_minmax_ops       | INSERT INTO public.t SELECT i, (i % 7 - 3)::smallint FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::smallint FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, -32768), (3002, 32767), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                                                          | k > 8000                                   | 201  | k = 32767                                 | 1   | k BETWEEN -2 AND 0                                                                                    | 1201 | 2    |
      | smallint    | default  | smallint     |                       | INSERT INTO public.t SELECT i, (i % 7 - 3)::smallint FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::smallint FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, -32768), (3002, 32767), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                                                          | k > 8000                                   | 201  | k = 32767                                 | 1   | k BETWEEN -2 AND 0                                                                                    | 1201 | 2    |
      | integer     | explicit | integer      | int4_minmax_ops       | INSERT INTO public.t SELECT i, (i % 7 - 3)::integer FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::integer FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, (-2147483648)::integer), (3002, 2147483647), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                                        | k > 8000                                   | 201  | k = 2147483647                            | 1   | k BETWEEN -2 AND 0                                                                                    | 1201 | 2    |
      | integer     | default  | integer      |                       | INSERT INTO public.t SELECT i, (i % 7 - 3)::integer FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::integer FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, (-2147483648)::integer), (3002, 2147483647), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                                        | k > 8000                                   | 201  | k = 2147483647                            | 1   | k BETWEEN -2 AND 0                                                                                    | 1201 | 2    |
      | bigint      | explicit | bigint       | int8_minmax_ops       | INSERT INTO public.t SELECT i, (i % 7 - 3)::bigint FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::bigint FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, (-9223372036854775808)::bigint), (3002, 9223372036854775807), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                     | k > 8000                                   | 201  | k = 9223372036854775807                   | 1   | k BETWEEN -2 AND 0                                                                                    | 1201 | 2    |
      | bigint      | default  | bigint       |                       | INSERT INTO public.t SELECT i, (i % 7 - 3)::bigint FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::bigint FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, (-9223372036854775808)::bigint), (3002, 9223372036854775807), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                     | k > 8000                                   | 201  | k = 9223372036854775807                   | 1   | k BETWEEN -2 AND 0                                                                                    | 1201 | 2    |
      | date        | explicit | date         | date_minmax_ops       | INSERT INTO public.t SELECT i, date '2000-01-01' + (i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, date '2030-01-01' + (i - 2801) FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, date '0001-01-01 BC'), (3002, date 'infinity'), (3003, date '-infinity'), (3004, NULL), (3005, NULL), (3006, date '2000-01-01');                                                                                                                                  | k >= date '2030-01-01'                     | 201  | k = date '0001-01-01 BC'                  | 1   | k BETWEEN date '1999-12-30' AND date '2000-01-01'                                                     | 1201 | 2    |
      | date        | default  | date         |                       | INSERT INTO public.t SELECT i, date '2000-01-01' + (i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, date '2030-01-01' + (i - 2801) FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, date '0001-01-01 BC'), (3002, date 'infinity'), (3003, date '-infinity'), (3004, NULL), (3005, NULL), (3006, date '2000-01-01');                                                                                                                                  | k >= date '2030-01-01'                     | 201  | k = date '0001-01-01 BC'                  | 1   | k BETWEEN date '1999-12-30' AND date '2000-01-01'                                                     | 1201 | 2    |
      | timestamp   | explicit | timestamp    | timestamp_minmax_ops  | INSERT INTO public.t SELECT i, timestamp '2000-01-01' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, timestamp '2030-01-01' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, timestamp '0001-01-01 00:00:00 BC'), (3002, timestamp 'infinity'), (3003, timestamp '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamp '2000-01-01 00:00:00.000001');                                                                        | k >= timestamp '2030-01-01'                | 201  | k = timestamp '2000-01-01 00:00:00.000001' | 1   | k BETWEEN timestamp '2000-01-01' AND timestamp '2000-01-02'                                           | 801  | 2    |
      | timestamp   | default  | timestamp    |                       | INSERT INTO public.t SELECT i, timestamp '2000-01-01' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, timestamp '2030-01-01' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, timestamp '0001-01-01 00:00:00 BC'), (3002, timestamp 'infinity'), (3003, timestamp '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamp '2000-01-01 00:00:00.000001');                                                                        | k >= timestamp '2030-01-01'                | 201  | k = timestamp '2000-01-01 00:00:00.000001' | 1   | k BETWEEN timestamp '2000-01-01' AND timestamp '2000-01-02'                                           | 801  | 2    |
      | timestamptz | explicit | timestamptz  | timestamptz_minmax_ops | INSERT INTO public.t SELECT i, timestamptz '2000-01-01 00:00:00+00' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, timestamptz '2030-01-01 00:00:00+00' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, timestamptz '0001-01-01 00:00:00+00 BC'), (3002, timestamptz 'infinity'), (3003, timestamptz '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamptz '2024-06-01 00:00:00+00'), (3007, timestamptz '2024-06-01 02:00:00+02'), (3008, timestamptz '2024-05-31 19:00:00-05'), (3009, timestamptz '2024-06-01 00:00:00+00'); | k >= timestamptz '2030-01-01 00:00:00+00' | 201  | k = timestamptz '2024-06-01 00:00:00+00'  | 4   | k BETWEEN timestamptz '2000-01-01 00:00:00+00' AND timestamptz '2000-01-02 00:00:00+00'              | 800  | 2    |
      | timestamptz | default  | timestamptz  |                       | INSERT INTO public.t SELECT i, timestamptz '2000-01-01 00:00:00+00' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, timestamptz '2030-01-01 00:00:00+00' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, timestamptz '0001-01-01 00:00:00+00 BC'), (3002, timestamptz 'infinity'), (3003, timestamptz '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamptz '2024-06-01 00:00:00+00'), (3007, timestamptz '2024-06-01 02:00:00+02'), (3008, timestamptz '2024-05-31 19:00:00-05'), (3009, timestamptz '2024-06-01 00:00:00+00'); | k >= timestamptz '2030-01-01 00:00:00+00' | 201  | k = timestamptz '2024-06-01 00:00:00+00'  | 4   | k BETWEEN timestamptz '2000-01-01 00:00:00+00' AND timestamptz '2000-01-02 00:00:00+00'              | 800  | 2    |

  Scenario: A multi-column approved index answers per-key and combined predicates identically to a sequential scan
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mc (id integer, a bigint, b timestamp, c date);
      CREATE INDEX mc_brin ON public.mc
        USING brin (a int8_minmax_ops, b timestamp_minmax_ops, c date_minmax_ops)
        WITH (pages_per_range = 4);
      INSERT INTO public.mc
      SELECT i, (i % 5 - 2)::bigint,
             timestamp '2000-01-01' + make_interval(days => i % 7 - 3),
             date '2000-01-01' + (i % 3 - 1)
      FROM generate_series(1, 2400) AS i;
      INSERT INTO public.mc VALUES
        (2401, 9223372036854775807, timestamp 'infinity', date 'infinity'),
        (2402, NULL, NULL, NULL);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical":
      """
      SELECT method FROM pagecopy.check('public.mc')
      WHERE name = 'mc_brin' AND type = 'index';
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.mc', 'public.mc', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT indisvalid, indisready,
             pg_relation_size('public.mc_brin'::regclass) >= 3 * 8192
      FROM pg_index WHERE indexrelid = 'public.mc_brin'::regclass;
      """
    And the following SQL on "target" contains "mc_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mc
      WHERE a = 1 AND b = timestamp '2000-01-01' AND c = date '2000-01-01';
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on mc_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mc WHERE a = 1;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mc WHERE b = timestamp '2000-01-01';
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mc WHERE c = date '2000-01-01';
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mc WHERE a = 9223372036854775807;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mc WHERE c = date 'infinity';
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|480|0|0|343|0|0|800|0|0|1|0|0|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE p1_i AS SELECT id FROM public.mc WHERE a = 1;
      CREATE TEMP TABLE p2_i AS SELECT id FROM public.mc WHERE b = timestamp '2000-01-01';
      CREATE TEMP TABLE p3_i AS SELECT id FROM public.mc WHERE c = date '2000-01-01';
      CREATE TEMP TABLE p4_i AS SELECT id FROM public.mc WHERE a = 9223372036854775807;
      CREATE TEMP TABLE p5_i AS SELECT id FROM public.mc WHERE c = date 'infinity';
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE p1_s AS SELECT id FROM public.mc WHERE a = 1;
      CREATE TEMP TABLE p2_s AS SELECT id FROM public.mc WHERE b = timestamp '2000-01-01';
      CREATE TEMP TABLE p3_s AS SELECT id FROM public.mc WHERE c = date '2000-01-01';
      CREATE TEMP TABLE p4_s AS SELECT id FROM public.mc WHERE a = 9223372036854775807;
      CREATE TEMP TABLE p5_s AS SELECT id FROM public.mc WHERE c = date 'infinity';
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM p1_i EXCEPT ALL SELECT id FROM p1_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p1_s EXCEPT ALL SELECT id FROM p1_i) AS d)
           || '|' || (SELECT count(*) FROM p1_i)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p2_i EXCEPT ALL SELECT id FROM p2_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p2_s EXCEPT ALL SELECT id FROM p2_i) AS d)
           || '|' || (SELECT count(*) FROM p2_i)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p3_i EXCEPT ALL SELECT id FROM p3_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p3_s EXCEPT ALL SELECT id FROM p3_i) AS d)
           || '|' || (SELECT count(*) FROM p3_i)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p4_i EXCEPT ALL SELECT id FROM p4_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p4_s EXCEPT ALL SELECT id FROM p4_i) AS d)
           || '|' || (SELECT count(*) FROM p4_i)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p5_i EXCEPT ALL SELECT id FROM p5_s) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM p5_s EXCEPT ALL SELECT id FROM p5_i) AS d)
           || '|' || (SELECT count(*) FROM p5_i);
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS
      SELECT id FROM public.mc
      WHERE a = 1 AND b = timestamp '2000-01-01' AND c = date '2000-01-01';
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS
      SELECT id FROM public.mc
      WHERE a = 1 AND b = timestamp '2000-01-01' AND c = date '2000-01-01';
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
    Then the following SQL on "source" returns "480|343|800|1|1":
      """
      SELECT (SELECT count(*) FROM public.mc WHERE a = 1),
             (SELECT count(*) FROM public.mc WHERE b = timestamp '2000-01-01'),
             (SELECT count(*) FROM public.mc WHERE c = date '2000-01-01'),
             (SELECT count(*) FROM public.mc WHERE a = 9223372036854775807),
             (SELECT count(*) FROM public.mc WHERE c = date 'infinity');
      """
