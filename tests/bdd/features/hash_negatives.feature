@hash @negatives
Feature: HASH target matching, corruption and cancellation fail closed

  A target HASH index matches only an identical approved definition; every
  mismatch, corrupted metapage or page, dropped stream page and mid-import
  cancellation rolls the whole transfer back without touching the old
  target contents.

  Scenario Outline: A mismatching target hash index fails the transfer without touching the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer, note text);
      CREATE INDEX t_k ON public.t USING hash (k) WITH (fillfactor = 50);
      INSERT INTO public.t SELECT i, i * 3, 'note' || i FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer, note text);
      <target_index>
      INSERT INTO public.t VALUES (9999, 1, 'sentinel');
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
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_k'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_k'::regclass)
      """

    Examples:
      | target_index                                                                                   |
      | CREATE INDEX t_k ON public.t USING btree (k);                                                   |
      | CREATE INDEX t_k ON public.t USING hash (note);                                                 |
      | CREATE INDEX t_k ON public.t USING hash (id);                                                   |
      | CREATE INDEX t_k ON public.t USING hash (note text_pattern_ops);                              |
      | CREATE INDEX t_k ON public.t USING hash (k) WITH (fillfactor = 75);                             |
      | CREATE INDEX t_k ON public.t USING hash (k) WHERE k > 10;                                       |
      | CREATE INDEX t_k ON public.t USING hash ((k + 1));                                             |

  Scenario: A missing or extra target hash index fails the transfer
    Given a fresh PostgreSQL pair
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
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_extra ON public.t USING hash (id);
      INSERT INTO public.t VALUES (9999, 1);
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
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_extra'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_extra'::regclass)
      """

  Scenario: An invalid physical target hash index is not used for a physical source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t VALUES (9999, 1);
      SELECT pc_test_empty_index_state('public.t_k', false, false);
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
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.t_k'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'public.t_k'::regclass)
      """

  Scenario Outline: Duplicate valid and invalid hash definitions in opposite creation orders
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_good ON public.t USING hash (k);
      CREATE INDEX t_bad ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i FROM generate_series(1, 200) AS i;
      SELECT pc_test_empty_index_state('public.t_bad', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      <target_first>
      <target_second>
      INSERT INTO public.t VALUES (9999, 42);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "2|1|1|200":
      """
      SELECT (SELECT count(*) FILTER (WHERE indisvalid AND indisready)
              FROM pg_index WHERE indrelid = 'public.t'::regclass),
             (SELECT count(*) FILTER (WHERE NOT indisvalid AND NOT indisready)
              FROM pg_index WHERE indrelid = 'public.t'::regclass),
             (SELECT count(*) FROM public.t WHERE k = 42),
             (SELECT count(*) FROM public.t)
      """

    Examples:
      | target_first                                     | target_second                                    |
      | CREATE INDEX t_good ON public.t USING hash (k);  | CREATE INDEX t_bad ON public.t USING hash (k);   |
      | CREATE INDEX t_bad ON public.t USING hash (k);   | CREATE INDEX t_good ON public.t USING hash (k);  |

  Scenario Outline: A corrupted source hash metapage is rejected with "<detail>"
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 500) AS i;
      CREATE FUNCTION pc_test_corrupt_index_byte(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_byte'
        LANGUAGE C STRICT;
      SELECT pc_test_corrupt_index_byte('public.t_k', 0, <offset>);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "<detail>":
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
              WHERE indexrelid = 'public.t_k'::regclass)
      """

    Examples:
      | offset | detail                                        |
      | 8190   | hash metapage has an unexpected page id       |
      | 8188   | hash metapage is not a metapage               |
      | 24     | hash metapage magic mismatch                  |
      | 28     | hash metapage version mismatch                |
      | 42     | hash metapage bsize mismatch                  |
      | 68     | hash metapage bitmap address out of range      |
      | 72     | hash metapage support function mismatch       |

  Scenario Outline: A corrupted incoming hash metapage fails verification on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = <offset>;
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
              WHERE indexrelid = 'public.t_k'::regclass)
      """

    Examples:
      | offset |
      | 8190   |
      | 8188   |
      | 24     |
      | 28     |
      | 42     |
      | 68     |
      | 72     |

  Scenario: A later corrupted hash metapage rolls back earlier installed relations
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer, note text);
      CREATE INDEX t_a ON public.t USING hash (k);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t
      SELECT i, i * 7, repeat('x', 200) || i FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer, note text);
      CREATE INDEX t_a ON public.t USING hash (k);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t VALUES (9999, 999999, 'sentinel');
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
    And the following SQL on "target" returns "1|9999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_b'::regclass)
      """

  Scenario Outline: A corrupted incoming hash bucket or bitmap page fails page verification
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t VALUES (9999, 999999);
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
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_k'::regclass)
      """

    Examples:
      | block | offset |
      | 3     | 13     |
      | 5     | 13     |

  Scenario: A dropped interior incoming hash page ends the stream with an out-of-order error
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t VALUES (9999, 999999);
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
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_k'::regclass)
      """

  Scenario: A dropped final incoming hash page ends the stream early
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 100) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "stream ended early":
      """
      SET pagecopy.debug_drop_index_page_relation = 3;
      SET pagecopy.debug_drop_index_page_block = 9;
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
              WHERE indexrelid = 'public.t_k'::regclass)
      """

  Scenario: Deterministic cancellation after a hash page rolls back and the source unlocks
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer, payload text);
      CREATE INDEX t_a ON public.t USING hash (k);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t
      SELECT i, i * 37, repeat('body-', 200) || i
      FROM generate_series(1, 30000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer, payload text);
      CREATE INDEX t_a ON public.t USING hash (k);
      CREATE INDEX t_b ON public.t USING hash (id);
      INSERT INTO public.t VALUES (9999, 999999, 'sentinel');
      """
    When the following SQL on "target" is cancelled after the index page milestone:
      """
      SET pagecopy.debug_hold_index_page_block = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "1|9999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_a'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_b'::regclass)
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
