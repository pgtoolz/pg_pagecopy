@gist @negatives
Feature: GIST target matching, corruption and cancellation fail closed

  A target GIST index matches only an identical approved definition; every
  mismatch, corrupted root page or page header, dropped stream page and
  mid-import cancellation rolls the whole transfer back without touching
  the old target contents.

  Scenario Outline: A mismatching target GIST index fails the transfer without touching the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, note text, b box);
      CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 50);
      INSERT INTO public.t SELECT i, point(i, i), 'note' || i
      FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, note text, b box);
      <target_index>
      INSERT INTO public.t VALUES (9999, point(9999, 9999), 'sentinel', NULL);
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
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_p'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_p'::regclass)
      """

    Examples:
      | target_index                                                       |
      | CREATE INDEX t_p ON public.t USING hash (note);                     |
      | CREATE INDEX t_p ON public.t USING brin (id);                       |
      | CREATE INDEX t_p ON public.t USING gist (b);                        |
      | CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 75); |
      | CREATE INDEX t_p ON public.t USING gist (p) WHERE note IS NOT NULL; |

  Scenario Outline: A missing or extra target GIST index fails the transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t SELECT i, point(i, i) FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      <target_index_a>
      <target_index_b>
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
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
      | target_index_a                                   | target_index_b                                   | failure                               |
      | CREATE INDEX t_extra ON public.t USING btree (id); |                                                  | target lacks source index             |
      | CREATE INDEX t_p ON public.t USING gist (p);      | CREATE INDEX t_extra ON public.t USING btree (id); | source and target index counts differ |

  Scenario: An invalid physical target GIST index is not used for a physical source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t SELECT i, point(i, i) FROM generate_series(1, 300) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
      UPDATE pg_index SET indisvalid = false, indisready = false
      WHERE indexrelid = 'public.t_p'::regclass;
      """
    Then the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t)
      """

  Scenario: A source gist root advertising a larger page size fails bounded validation
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t SELECT i, point(i % 41, (i * 7) % 43)
      FROM generate_series(1, 500) AS i;
      CREATE FUNCTION pc_test_set_index_byte(regclass, integer, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_set_index_byte'
        LANGUAGE C STRICT;
      SELECT pc_test_set_index_byte('public.t_p', 0, 17, 63);
      SELECT pc_test_set_index_byte('public.t_p', 0, 19, 64);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
      """
    Then the following SQL on "target" fails with "gist page has an unexpected special area":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_p'::regclass)
      """

  Scenario Outline: A corrupted incoming GIST root fails verification on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t SELECT i, point(i % 41, (i * 7) % 43)
      FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
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
              WHERE indexrelid = 'public.t_p'::regclass),
             (SELECT count(*) FROM public.t WHERE p ~= point(9999, 9999)),
             (SELECT count(*) FROM public.t WHERE p ~= point(1, 7));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using t_p":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE p ~= point(9999, 9999);
      ROLLBACK;
      """

    Examples:
      | offset |
      | 8190   |
      | 8188   |
      | 8184   |
      | 8176   |

  Scenario: A later corrupted GIST root rolls back earlier installed relations
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, q point);
      CREATE INDEX t_a ON public.t USING gist (p);
      CREATE INDEX t_b ON public.t USING gist (q);
      INSERT INTO public.t SELECT i, point(i, i), point(i, -i)
      FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point, q point);
      CREATE INDEX t_a ON public.t USING gist (p);
      CREATE INDEX t_b ON public.t USING gist (q);
      INSERT INTO public.t VALUES (9999, point(9999, 9999), point(-9999, 9999));
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 8184;
      SET pagecopy.debug_corrupt_index_ordinal = 2;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|t|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_b'::regclass),
             (SELECT count(*) FROM public.t WHERE p ~= point(9999, 9999)),
             (SELECT count(*) FROM public.t WHERE p ~= point(1, 1));
      ROLLBACK;
      """

  Scenario Outline: A corrupted incoming GIST page header fails page verification
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 10);
      INSERT INTO public.t SELECT i, point(i % 89, (i * 7) % 97)
      FROM generate_series(1, 3000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size('public.t_p'::regclass) >= 6 * 8192;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 10);
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
      """
    Then the following SQL on "target" fails with "page verification failed":
      """
      SET pagecopy.debug_corrupt_page_relation = 3;
      SET pagecopy.debug_corrupt_page = <block>;
      SET pagecopy.debug_corrupt_offset = 13;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_p'::regclass),
             (SELECT count(*) FROM public.t WHERE p ~= point(9999, 9999));
      ROLLBACK;
      """

    Examples:
      | block |
      | 2     |
      | 4     |

  Scenario: A dropped interior incoming GIST page ends the stream with an out-of-order error
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 10);
      INSERT INTO public.t
      SELECT i, point(i % 89, (i * 7) % 97) FROM generate_series(1, 3000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size('public.t_p'::regclass) >= 4 * 8192;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 10);
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
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
    And the following SQL on "target" returns "1|9999|t|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_p'::regclass),
             (SELECT count(*) FROM public.t WHERE p ~= point(9999, 9999));
      ROLLBACK;
      """

  Scenario: Deterministic cancellation after a GIST page rolls back and the source unlocks
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 10);
      INSERT INTO public.t SELECT i, point(i % 89, (i * 7) % 97)
      FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p) WITH (fillfactor = 10);
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
      """
    When the following SQL on "target" is cancelled after the index page milestone:
      """
      SET pagecopy.debug_hold_index_page_block = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "1|9999|t|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_p'::regclass),
             (SELECT count(*) FROM public.t WHERE p ~= point(9999, 9999));
      ROLLBACK;
      """
    And the following SQL on "source" returns "0|3000":
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
    Then the following SQL on "target" returns "3000|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.t
                WHERE p <@ box(point(0, 0), point(88, 96))),
             (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.t_p'::regclass);
      ROLLBACK;
      """
