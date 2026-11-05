@spgist @negatives
Feature: SP-GiST target matching, corruption and cancellation fail closed

  A target SP-GiST index matches only an identical approved definition;
  every mismatch, corrupted metapage or page, dropped stream page and
  mid-import cancellation rolls the whole transfer back without touching
  the old target contents.

  Scenario Outline: A mismatching target spgist index fails the transfer without touching the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, note text);
      CREATE INDEX t_q ON public.t USING spgist (p) WITH (fillfactor = 50);
      INSERT INTO public.t SELECT i, point(i, i * 3), 'note' || i FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, note text);
      <target_index>
      INSERT INTO public.t VALUES (9999, point(1, 1), 'sentinel');
      """
    Then the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_q'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_q'::regclass)
      """

    Examples:
      | target_index                                                          |
      | CREATE INDEX t_q ON public.t USING btree (note);                      |
      | CREATE INDEX t_q ON public.t USING spgist (p kd_point_ops);           |
      | CREATE INDEX t_q ON public.t USING spgist (note);                     |
      | CREATE INDEX t_q ON public.t USING spgist (p) WHERE id > 0;          |
      | CREATE INDEX t_q ON public.t USING spgist (p) WITH (fillfactor = 75); |
      | CREATE INDEX t_q ON public.t USING spgist (p) WHERE p IS NOT NULL;    |
      | CREATE INDEX t_q ON public.t USING spgist ((p + point(1, 1)));        |

  Scenario Outline: A missing or extra target spgist index fails the transfer
    Given a fresh PostgreSQL pair
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
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      <target_index_a>
      <target_index_b>
      INSERT INTO public.t VALUES (9999, point(1, 1));
      """
    Then the following SQL on "target" fails with "<failure>":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_extra'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_extra'::regclass)
      """

    Examples:
      | target_index_a                                    | target_index_b                                    | failure                   |
      | CREATE INDEX t_extra ON public.t USING spgist (p kd_point_ops); |                                                 | target lacks source index |
      | CREATE INDEX t_q ON public.t USING spgist (p);     | CREATE INDEX t_extra ON public.t USING spgist (p); | source and target index counts differ |

  Scenario: An invalid physical target spgist index is not used for a physical source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i, i) FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t VALUES (9999, point(1, 1));
      SELECT pc_test_empty_index_state('public.t_q', false, false);
      """
    Then the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|f|f":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_q'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_q'::regclass)
      """

  Scenario Outline: Duplicate valid and invalid spgist definitions in opposite creation orders
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_good ON public.t USING spgist (p);
      CREATE INDEX t_bad ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 200) AS i;
      SELECT pc_test_empty_index_state('public.t_bad', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      <target_first>
      <target_second>
      INSERT INTO public.t VALUES (9999, point(42, 42));
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "2|1|3|200":
      """
      SELECT (SELECT count(*) FILTER (WHERE indisvalid AND indisready)
              FROM pg_index WHERE indrelid = 'public.t'::regclass),
             (SELECT count(*) FILTER (WHERE NOT indisvalid AND NOT indisready)
              FROM pg_index WHERE indrelid = 'public.t'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(41, 41), point(43, 43))),
             (SELECT count(*) FROM public.t)
      """

    Examples:
      | target_first                                    | target_second                                   |
      | CREATE INDEX t_good ON public.t USING spgist (p); | CREATE INDEX t_bad ON public.t USING spgist (p); |
      | CREATE INDEX t_bad ON public.t USING spgist (p);  | CREATE INDEX t_good ON public.t USING spgist (p); |

  Scenario: An invalid first source entry routes around the only valid target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_bad ON public.t USING spgist (p);
      CREATE INDEX t_good ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 200) AS i;
      SELECT pc_test_empty_index_state('public.t_bad', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_bad ON public.t USING spgist (p);
      CREATE INDEX t_good ON public.t USING spgist (p);
      INSERT INTO public.t VALUES (9999, point(42, 42));
      SELECT pc_test_empty_index_state('public.t_bad', false, false);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|f|f|200|3":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_good'::regclass),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.t_good'::regclass),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.t_bad'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.t_bad'::regclass),
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(41, 41), point(43, 43)));
      """
    And the following SQL on "target" contains "Index Scan using t_good":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(41, 41), point(43, 43));
      ROLLBACK;
      """

  Scenario Outline: A corrupted source spgist metapage is rejected with "<detail>"
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 2000) AS i;
      CREATE FUNCTION pc_test_corrupt_index_byte(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_byte'
        LANGUAGE C STRICT;
      SELECT pc_test_corrupt_index_byte('public.t_q', 0, <offset>);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t VALUES (9999, point(-99, -99));
      """
    Then the following SQL on "target" fails with "<detail>":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_q'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(1, 1)));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_q":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98));
      ROLLBACK;
      """

    Examples:
      | offset | detail                                              |
      | 8190   | spgist metapage has an unexpected page id           |
      | 8184   | spgist metapage is not a metapage                   |
      | 28     | spgist metapage cached page address out of range    |

  Scenario Outline: A corrupted incoming spgist metapage fails verification on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t VALUES (9999, point(-99, -99));
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = <offset>;
      SET pagecopy.debug_corrupt_index_ordinal = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_q'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(1, 1)));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_q":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98));
      ROLLBACK;
      """

    Examples:
      | offset |
      | 8190   |
      | 8184   |
      | 24     |
      | 28     |

  Scenario: A later corrupted spgist metapage rolls back earlier installed relations
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, note text);
      CREATE INDEX t_a ON public.t USING spgist (p);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t
      SELECT i, point(i % 199, i % 197), repeat('x', 200) || i FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, note text);
      CREATE INDEX t_a ON public.t USING spgist (p);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t VALUES (9999, point(-99, -99), 'sentinel');
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 24;
      SET pagecopy.debug_corrupt_index_ordinal = 2;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|sentinel|t|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT note FROM public.t WHERE id = 9999),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_b'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(1, 1)));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_a":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98));
      ROLLBACK;
      """

  Scenario Outline: A corrupted incoming spgist page header fails page verification
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size('public.t_q'::regclass) >= 6 * 8192;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t VALUES (9999, point(-99, -99));
      """
    Then the following SQL on "target" fails with "page verification failed":
      """
      SET pagecopy.debug_corrupt_page_relation = 3;
      SET pagecopy.debug_corrupt_page = <block>;
      SET pagecopy.debug_corrupt_offset = <offset>;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_q'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(1, 1)));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_q":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98));
      ROLLBACK;
      """

    Examples:
      | block | offset |
      | 3     | 13     |
      | 5     | 13     |

  Scenario: A dropped interior incoming spgist page ends the stream with an out-of-order error
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t VALUES (9999, point(-99, -99));
      """
    Then the following SQL on "target" fails with "out-of-order block":
      """
      SET pagecopy.debug_drop_index_page_relation = 3;
      SET pagecopy.debug_drop_index_page_block = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_q'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(1, 1)));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_q":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98));
      ROLLBACK;
      """

  Scenario: A dropped final incoming spgist page ends the stream early
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 3000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size('public.t_q'::regclass) = 21 * 8192;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t VALUES (9999, point(-99, -99));
      """
    Then the following SQL on "target" fails with "stream ended early":
      """
      SET pagecopy.debug_drop_index_page_relation = 3;
      SET pagecopy.debug_drop_index_page_block = 20;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_q'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(1, 1)));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_q":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98));
      ROLLBACK;
      """

  Scenario: Deterministic cancellation after a spgist page rolls back and the source unlocks
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, payload text);
      CREATE INDEX t_a ON public.t USING spgist (p);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t
      SELECT i, point(i % 199, i % 197), repeat('body-', 200) || i
      FROM generate_series(1, 30000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, payload text);
      CREATE INDEX t_a ON public.t USING spgist (p);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t VALUES (9999, point(-99, -99), 'sentinel');
      """
    When the following SQL on "target" is cancelled after the index page milestone:
      """
      SET pagecopy.debug_hold_index_page_block = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "1|9999|sentinel|t|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT payload FROM public.t WHERE id = 9999),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_b'::regclass),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98))),
             (SELECT count(*) FROM public.t WHERE p <@ box(point(0, 0), point(1, 1)));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_a":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p <@ box(point(-100, -100), point(-98, -98));
      ROLLBACK;
      """
    And the following SQL on "source" returns "0|30000":
      """
      SELECT (SELECT count(*) FROM pg_stat_activity
               WHERE query LIKE 'COPY (SELECT pagecopy_internal.pagecopy_export_stream(%'
                 AND state = 'active'),
             (SELECT count(*) FROM public.t)
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "30000|3|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT count(*) FILTER (WHERE indisvalid AND indisready)
              FROM pg_index WHERE indrelid = 'public.t'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass)
      """
