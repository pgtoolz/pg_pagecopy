@brin
Feature: BRIN index states and target matching combinations

  Indexes created before or after population, summarized, unsummarized and
  desummarized ranges, autosummarize, invalid/not-ready flags on either
  side, duplicate definitions in every creation order, and permuted target
  indexes. The network pull runs VACUUM (FREEZE) during preparation, which
  summarizes unsummarized and desummarized ranges before export; every
  scenario verifies the state at the transfer boundary instead of assuming
  it was preserved.

  Scenario Outline: An index created <when> inserts transfers with no pending ranges after the freeze
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.t (id integer, k bigint);
      <index_at>
      INSERT INTO public.t
      SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      <index_after>
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "<srcpending>":
      """
      WITH revmap AS (SELECT get_raw_page('t_brin', 1) AS p),
           ranges AS (
             SELECT g
             FROM revmap,
                  LATERAL generate_series(0,
                        (((pg_relation_size('public.t') + 8191) / 8192 + 3) / 4 - 1)::int) AS g
           )
      SELECT count(*) FILTER (
                WHERE get_byte(p, 24 + 6*g) = 0 AND get_byte(p, 25 + 6*g) = 0
                   AND get_byte(p, 26 + 6*g) = 0 AND get_byte(p, 27 + 6*g) = 0
                   AND get_byte(p, 28 + 6*g) = 0 AND get_byte(p, 29 + 6*g) = 0) > 1
      FROM revmap, ranges;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t|1":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             brin_summarize_new_values('public.t_brin'::regclass) <= 1,
             count(*) FILTER (WHERE k = 37 * 100)
      FROM public.t;
      """

    Examples:
      | when  | index_at                                                          | index_after | srcpending |
      | after |                                                                   | CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4); | f |
      | before | CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4); | | t |

  Scenario: Autosummarize on and off leave pending ranges that the preparation freeze summarizes
    Bulk INSERT..SELECT never triggers autosummarize's range-completion
    callback on either setting, so both indexes keep unsummarized completed
    ranges on the source; the pull's VACUUM (FREEZE) summarizes them before
    export, and both targets arrive with at most the final partial range
    pending and identical results.
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.auto_off (id integer, k bigint) WITH (fillfactor = 10);
      CREATE INDEX auto_off_brin ON public.auto_off
        USING brin (k) WITH (pages_per_range = 4, autosummarize = off);
      INSERT INTO public.auto_off
      SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      CREATE TABLE public.auto_on (id integer, k bigint) WITH (fillfactor = 10);
      CREATE INDEX auto_on_brin ON public.auto_on
        USING brin (k) WITH (pages_per_range = 4, autosummarize = on);
      INSERT INTO public.auto_on
      SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "t|t":
      """
      WITH off_probe AS (
        SELECT count(*) FILTER (
                  WHERE get_byte(p, 24 + 6*g) = 0 AND get_byte(p, 25 + 6*g) = 0
                     AND get_byte(p, 26 + 6*g) = 0 AND get_byte(p, 27 + 6*g) = 0
                     AND get_byte(p, 28 + 6*g) = 0 AND get_byte(p, 29 + 6*g) = 0) > 1 AS pending
        FROM (SELECT get_raw_page('auto_off_brin', 1) AS p) s,
             LATERAL generate_series(0,
                   (((pg_relation_size('public.auto_off') + 8191) / 8192 + 3) / 4 - 1)::int) AS g
      ), on_probe AS (
        SELECT count(*) FILTER (
                  WHERE get_byte(p, 24 + 6*g) = 0 AND get_byte(p, 25 + 6*g) = 0
                     AND get_byte(p, 26 + 6*g) = 0 AND get_byte(p, 27 + 6*g) = 0
                     AND get_byte(p, 28 + 6*g) = 0 AND get_byte(p, 29 + 6*g) = 0) > 1 AS pending
        FROM (SELECT get_raw_page('auto_on_brin', 1) AS p) s,
             LATERAL generate_series(0,
                   (((pg_relation_size('public.auto_on') + 8191) / 8192 + 3) / 4 - 1)::int) AS g
      )
      SELECT (SELECT pending FROM off_probe),
             (SELECT pending FROM on_probe);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.auto_off', 'public.auto_off', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.auto_on', 'public.auto_on', true
      );
      """
    Then the following SQL on "target" returns "t|t|t|t":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.auto_off_brin'::regclass),
             (SELECT brin_summarize_new_values('public.auto_off_brin'::regclass) <= 1),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.auto_on_brin'::regclass),
             (SELECT brin_summarize_new_values('public.auto_on_brin'::regclass) <= 1);
      """
    And the following SQL on "target" returns "1|1":
      """
      SELECT (SELECT count(*) FROM public.auto_off WHERE k = 3700),
             (SELECT count(*) FROM public.auto_on WHERE k = 3700);
      """

  Scenario: A desummarized range is re-summarized by the preparation freeze and transfers correctly
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      SELECT brin_desummarize_range('public.t_brin'::regclass, 0);
      SELECT brin_desummarize_range('public.t_brin'::regclass, 3);
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
    Then the following SQL on "target" returns "t|0":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             brin_summarize_new_values('public.t_brin'::regclass);
      """
    And the following SQL on "target" returns "1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.t WHERE k = 3700;
      ROLLBACK;
      """

  Scenario: Post-transfer inserts, summarize, desummarize and re-summarize keep target results exact
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION pageinspect;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      INSERT INTO public.t
      SELECT 10000 + i, 1000000 + i * 41 FROM generate_series(1, 4000) AS i;
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL on "target" returns "t":
      """
      SELECT brin_summarize_new_values('public.t_brin'::regclass) > 0;
      """
    When the following SQL is executed on "target":
      """
      SELECT brin_desummarize_range('public.t_brin'::regclass, 0);
      """
    Then the following SQL on "target" returns "1|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k = 3700;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k = 3700;
      COMMIT;
      SELECT (SELECT count(*) FROM pc_indexed)
           || '|' || (SELECT count(*) FROM pc_sequential);
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t WHERE k < 300;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t WHERE k < 300;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
    Then the following SQL on "target" returns "1":
      """
      SELECT brin_summarize_new_values('public.t_brin'::regclass);
      """
    And the following SQL on "target" returns "t|0|1":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             (SELECT count(*) FILTER (
                       WHERE get_byte(p, 24 + 6*g) = 0 AND get_byte(p, 25 + 6*g) = 0
                          AND get_byte(p, 26 + 6*g) = 0 AND get_byte(p, 27 + 6*g) = 0
                          AND get_byte(p, 28 + 6*g) = 0 AND get_byte(p, 29 + 6*g) = 0)
              FROM (SELECT get_raw_page('t_brin', 1) AS p) s,
                   LATERAL generate_series(0,
                         (((pg_relation_size('public.t') + 8191) / 8192 + 3) / 4 - 1)::int) AS g),
             (SELECT count(*) FROM public.t WHERE k = 3700);
      """
    And the following SQL on "target" returns "1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.t WHERE k = 3700;
      ROLLBACK;
      """

  Scenario Outline: A source index that is invalid or not ready degrades to a rebuildable definition
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 2000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      UPDATE pg_index SET indisvalid = <valid>, indisready = <ready>
      WHERE indexrelid = 'public.t_brin'::regclass;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "definition":
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
    Then the following SQL on "target" returns "f|2000|1":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_brin'::regclass),
             count(*),
             count(*) FILTER (WHERE k = 37 * 100)
      FROM public.t;
      """
    When the following SQL is executed on "target":
      """
      REINDEX INDEX public.t_brin;
      """
    Then the following SQL on "target" returns "t|t|1":
      """
      SELECT indisvalid, indisready,
             (SELECT count(*) FROM public.t WHERE k = 3700)
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """

    Examples:
      | valid | ready |
      | false | true  |
      | true  | false |
      | false | false |

  Scenario Outline: An invalid or not-ready target index cannot receive a physical transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 2000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999);
      UPDATE pg_index SET indisvalid = <valid>, indisready = <ready>
      WHERE indexrelid = 'public.t_brin'::regclass;
      """
    Then the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|999999|<v>|<r>":
      """
      SELECT (SELECT count(*) FROM public.t)
          || '|' || (SELECT max(k) FROM public.t)
          || '|' || substr(indisvalid::text, 1, 1) || '|' || substr(indisready::text, 1, 1)
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    Then the following SQL on "source" returns "0":
      """
      SELECT count(*) FROM pg_locks
      WHERE relation = 'public.t'::regclass AND NOT granted;
      """

    Examples:
      | valid | ready | v | r |
      | false | true  | f | t |
      | true  | false | t | f |
      | false | false | f | f |

  Scenario Outline: Duplicate definitions match in every creation order (<layout>)
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.duplicates (id integer);
      <src_create>
      INSERT INTO public.duplicates SELECT * FROM generate_series(1, 1000);
      <src_flags>
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.duplicates (id integer);
      <tgt_create>
      <tgt_flags>
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.duplicates', 'public.duplicates', true
      );
      """
    Then the following SQL on "target" returns "1000|500500|<expected>":
      """
      SELECT (SELECT count(*) FROM public.duplicates),
             (SELECT sum(id) FROM public.duplicates),
             string_agg(c.relname || ':' || substr(i.indisvalid::text, 1, 1)
                        || substr(i.indisready::text, 1, 1), ';' ORDER BY c.relname)
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE i.indrelid = 'public.duplicates'::regclass;
      """

    Examples:
      | layout | src_create | src_flags | tgt_create | tgt_flags | expected |
      | source a invalid, target a invalid | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.a_first'::regclass; | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.a_first'::regclass; | a_first:ff;b_second:tt |
      | source a invalid, target b invalid | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.a_first'::regclass; | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.b_second'::regclass; | a_first:tt;b_second:ff |
      | source b invalid, target a invalid | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.b_second'::regclass; | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.a_first'::regclass; | a_first:ff;b_second:tt |
      | source b invalid, target b invalid | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.b_second'::regclass; | CREATE INDEX a_first ON public.duplicates USING brin (id); CREATE INDEX b_second ON public.duplicates USING brin (id); | UPDATE pg_index SET indisvalid = false, indisready = false WHERE indexrelid = 'public.b_second'::regclass; | a_first:tt;b_second:ff |

  Scenario: Physical BRIN, physical btree, degraded BRIN and TOAST route to the right targets
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.routed (
        id bigint,
        ts timestamptz,
        note text,
        body text
      );
      CREATE INDEX routed_brin ON public.routed USING brin (id) WITH (pages_per_range = 4);
      CREATE INDEX routed_note ON public.routed USING btree (note);
      CREATE INDEX routed_degraded ON public.routed USING brin (note);
      INSERT INTO public.routed
      SELECT i,
             timestamptz '2024-01-01' + make_interval(secs => i * 30),
             'note' || i % 10,
             (SELECT string_agg(md5(i::text || g::text), '') FROM generate_series(1, 64) AS g)
      FROM generate_series(1, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "physical|physical|definition":
      """
      SELECT (SELECT method FROM pagecopy.check('public.routed')
              WHERE name = 'routed_brin' AND type = 'index'),
             (SELECT method FROM pagecopy.check('public.routed')
              WHERE name = 'routed_note' AND type = 'index'),
             (SELECT method FROM pagecopy.check('public.routed')
              WHERE name = 'routed_degraded' AND type = 'index');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.routed', 'public.routed', true
      );
      """
    Then the following SQL on "target" returns "3|2|1|200|200|t":
      """
      SELECT count(*),
             count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.routed WHERE id > 1800),
             (SELECT count(*) FROM public.routed WHERE note = 'note3'),
             pg_relation_size(
               (SELECT reltoastrelid FROM pg_class
                WHERE oid = 'public.routed'::regclass)) > 0
      FROM pg_index WHERE indrelid = 'public.routed'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on routed_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.routed WHERE id > 1800;
      ROLLBACK;
      """
    And the following SQL on "target" contains "routed_note":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.routed WHERE note = 'note3';
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.routed WHERE id > 1800;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.routed WHERE id > 1800;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
    When the following SQL is executed on "target":
      """
      REINDEX INDEX public.routed_degraded;
      """
    Then the following SQL on "target" returns "3|3":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready)
      FROM pg_index WHERE indrelid = 'public.routed'::regclass;
      """

  Scenario: Reordered target index creation still matches by definition
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id bigint, ts timestamptz);
      CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4);
      CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8);
      INSERT INTO public.t
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i * 30)
      FROM generate_series(1, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id bigint, ts timestamptz);
      CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8);
      CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_id'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_ts'::regclass);
      """

  Scenario Outline: <case> target indexes fail the transfer without touching the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id bigint, ts timestamptz);
      <src_indexes>
      INSERT INTO public.t
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i * 30)
      FROM generate_series(1, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id bigint, ts timestamptz);
      <target_indexes>
      INSERT INTO public.t VALUES (9999, timestamptz '2030-01-01');
      """
    Then the following SQL on "target" fails with "<error>":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|9999|<idxcount>":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(id) FROM public.t),
             count(*)
      FROM pg_index WHERE indrelid = 'public.t'::regclass;
      """
    Then the following SQL on "source" returns "0":
      """
      SELECT count(*) FROM pg_locks
      WHERE relation = 'public.t'::regclass AND NOT granted;
      """

    Examples:
      | case | src_indexes | target_indexes | error | idxcount |
      | missing | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8); | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); | source and target index counts differ | 1 |
      | extra | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8); | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8); CREATE INDEX t_extra ON public.t USING brin (id, ts) WITH (pages_per_range = 8); | source and target index counts differ | 3 |
      | different key order | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8); CREATE INDEX t_pair ON public.t USING brin (id, ts) WITH (pages_per_range = 8); | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8); CREATE INDEX t_pair ON public.t USING brin (ts, id) WITH (pages_per_range = 8); | target lacks source index | 3 |
      | different pages_per_range | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 8); | CREATE INDEX t_id ON public.t USING brin (id) WITH (pages_per_range = 4); CREATE INDEX t_ts ON public.t USING brin (ts) WITH (pages_per_range = 32); | target lacks source index | 2 |
