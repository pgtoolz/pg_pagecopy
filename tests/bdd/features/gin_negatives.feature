@gin @negatives
Feature: GIN target matching, corruption and cancellation fail closed

  A target GIN index matches only an identical approved definition; every
  mismatch, corrupted metapage or page, dropped stream page and mid-import
  cancellation rolls the whole transfer back without touching the old
  target contents. A corrupted source metapage - including the pending
  list pointers - fails the transfer outright.

  Scenario Outline: A mismatching target gin index fails the transfer without touching the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[], doc jsonb);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 10], jsonb_build_object('k', i)
      FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[], doc jsonb);
      <target_index>
      INSERT INTO public.t VALUES (9999, ARRAY[1], '{}');
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
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_tags'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_tags'::regclass)
      """

    Examples:
      | target_index                                                       |
      | CREATE INDEX t_tags ON public.t USING btree (tags);                |
      | CREATE INDEX t_tags ON public.t USING gin (doc);                   |
      | CREATE INDEX t_tags ON public.t USING gin (tags) WHERE id > 10;    |
      | CREATE INDEX t_tags ON public.t USING gin (array_append(tags, 1)); |

  Scenario Outline: A missing or extra target gin index fails the transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, tags integer[], doc jsonb);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i], jsonb_build_object('k', i)
      FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, tags integer[], doc jsonb);
      <target_index_a>
      <target_index_b>
      INSERT INTO public.t VALUES (9999, ARRAY[1], '{}');
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
      | target_index_a                                      | target_index_b                                     | failure                   |
      | CREATE INDEX t_extra ON public.t USING gin (doc);    |                                                    | target lacks source index |
      | CREATE INDEX t_tags ON public.t USING gin (tags);    | CREATE INDEX t_extra ON public.t USING gin (doc);  | source and target index counts differ |

  Scenario: An invalid physical target gin index is not used for a physical source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i] FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t VALUES (9999, ARRAY[1]);
      SELECT pc_test_empty_index_state('public.t_tags', false, false);
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
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_tags'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_tags'::regclass)
      """

  Scenario Outline: Duplicate valid and invalid gin definitions in opposite creation orders
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_good ON public.t USING gin (tags);
      CREATE INDEX t_bad ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i % 5] FROM generate_series(1, 200) AS i;
      SELECT pc_test_empty_index_state('public.t_bad', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      <target_first>
      <target_second>
      INSERT INTO public.t VALUES (9999, ARRAY[42]);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "2|1|0|200":
      """
      SELECT (SELECT count(*) FILTER (WHERE indisvalid AND indisready)
              FROM pg_index WHERE indrelid = 'public.t'::regclass),
             (SELECT count(*) FILTER (WHERE NOT indisvalid AND NOT indisready)
              FROM pg_index WHERE indrelid = 'public.t'::regclass),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[42]),
             (SELECT count(*) FROM public.t)
      """

    Examples:
      | target_first                                   | target_second                                  |
      | CREATE INDEX t_good ON public.t USING gin (tags); | CREATE INDEX t_bad ON public.t USING gin (tags); |
      | CREATE INDEX t_bad ON public.t USING gin (tags);  | CREATE INDEX t_good ON public.t USING gin (tags); |

  Scenario: An invalid first source entry routes around the only valid target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_bad ON public.t USING gin (tags);
      CREATE INDEX t_good ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i % 5] FROM generate_series(1, 200) AS i;
      SELECT pc_test_empty_index_state('public.t_bad', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_bad ON public.t USING gin (tags);
      CREATE INDEX t_good ON public.t USING gin (tags);
      INSERT INTO public.t VALUES (9999, ARRAY[42]);
      SELECT pc_test_empty_index_state('public.t_bad', false, false);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|f|f|200|0":
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
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[42])
      """

  Scenario Outline: A corrupted source gin metapage is rejected with "<detail>"
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i % 7, i % 3] FROM generate_series(1, 500) AS i;
      CREATE FUNCTION pc_test_corrupt_index_byte(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_byte'
        LANGUAGE C STRICT;
      SELECT pc_test_corrupt_index_byte('public.t_tags', 0, <offset>);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t VALUES (9999, ARRAY[999999]);
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
              WHERE indexrelid = 'public.t_tags'::regclass),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[999999]),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[1]);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_tags":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE tags @> ARRAY[999999];
      ROLLBACK;
      """

    Examples:
      | offset | detail                        |
      | 8190   | gin metapage is not a metapage |
      | 72     | gin metapage version mismatch |

  Scenario Outline: A corrupted source gin pending-list pointer is rejected with "<detail>"
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i % 7, i % 3] FROM generate_series(1, 500) AS i;
      CREATE FUNCTION pc_test_corrupt_index_byte(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_byte'
        LANGUAGE C STRICT;
      SELECT pc_test_corrupt_index_byte('public.t_tags', 0, <offset>);
      """
    Then the following SQL on "target" fails with "<detail>":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    And the following SQL on "target" returns "0|500|t":
      """
      SELECT (SELECT count(*) FROM pg_tables WHERE tablename = 't_copy'),
             (SELECT count(*) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_tags'::regclass)
      """

    Examples:
      | offset | detail                                        |
      | 24     | gin pending list head is out of range         |
      | 28     | gin pending list tail is out of range         |
      | 49     | gin metapage statistics exceed the index size |

  Scenario Outline: A corrupted incoming gin metapage fails verification on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i % 7, i % 3] FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t VALUES (9999, ARRAY[999999]);
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = <offset>;
      SET pagecopy.debug_corrupt_index_ordinal = 2;
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
              WHERE indexrelid = 'public.t_tags'::regclass),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[999999]),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[1]);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_tags":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE tags @> ARRAY[999999];
      ROLLBACK;
      """

    Examples:
      | offset |
      | 8190   |
      | 72     |
      | 24     |
      | 28     |
      | 49     |

  Scenario: A later corrupted gin metapage rolls back earlier installed relations
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[], note text, tags2 integer[]);
      CREATE INDEX t_a ON public.t USING gin (tags);
      CREATE INDEX t_b ON public.t USING gin (tags2);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 7], repeat('x', 200) || i, ARRAY[i % 5]
      FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[], note text, tags2 integer[]);
      CREATE INDEX t_a ON public.t USING gin (tags);
      CREATE INDEX t_b ON public.t USING gin (tags2);
      INSERT INTO public.t VALUES (9999, ARRAY[999999], 'sentinel');
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 24;
      SET pagecopy.debug_corrupt_index_ordinal = 3;
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
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[999999]),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[1]);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_a":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE tags @> ARRAY[999999];
      ROLLBACK;
      """

  Scenario Outline: A corrupted incoming gin page header fails page verification
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i % 7, i % 3] FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size('public.t_tags'::regclass) >= 6 * 8192;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t VALUES (9999, ARRAY[999999]);
      """
    Then the following SQL on "target" fails with "page verification failed":
      """
      SET pagecopy.debug_corrupt_page_relation = 5;
      SET pagecopy.debug_corrupt_page = <block>;
      SET pagecopy.debug_corrupt_offset = 13;
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
              WHERE indexrelid = 'public.t_tags'::regclass),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[999999]),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[1]);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_tags":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE tags @> ARRAY[999999];
      ROLLBACK;
      """

    Examples:
      | block |
      | 3     |
      | 5     |

  Scenario: A dropped interior incoming gin page ends the stream with an out-of-order error
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t SELECT i, ARRAY[i % 7, i % 3] FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, tags integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      INSERT INTO public.t VALUES (9999, ARRAY[999999]);
      """
    Then the following SQL on "target" fails with "out-of-order block":
      """
      SET pagecopy.debug_drop_index_page_relation = 5;
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
              WHERE indexrelid = 'public.t_tags'::regclass),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[999999]),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[1]);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_tags":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE tags @> ARRAY[999999];
      ROLLBACK;
      """

  Scenario: Deterministic cancellation after a gin page rolls back and the source unlocks
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[], payload text, tags2 integer[]);
      CREATE INDEX t_a ON public.t USING gin (tags);
      CREATE INDEX t_b ON public.t USING gin (tags2);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 97], repeat('body-', 200) || i, ARRAY[i % 89]
      FROM generate_series(1, 30000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, tags integer[], payload text, tags2 integer[]);
      CREATE INDEX t_a ON public.t USING gin (tags);
      CREATE INDEX t_b ON public.t USING gin (tags2);
      INSERT INTO public.t VALUES (9999, ARRAY[999999], 'sentinel');
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
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[999999]),
             (SELECT count(*) FROM public.t WHERE tags @> ARRAY[1]);
      ROLLBACK;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_a":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT * FROM public.t WHERE tags @> ARRAY[999999];
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
