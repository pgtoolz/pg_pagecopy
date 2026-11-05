@gist @degraded
Feature: Unapproved GIST indexes degrade while custom opclasses fail

  Physical GIST covers only the core point_ops opclass on a plain
  single-column point key. Every other core GIST opclass degrades to a
  definition-only transfer with a precise reason, expressions and partials
  degrade, invalid or not-ready indexes degrade, and custom opclasses —
  contrib extensions like btree_gist included — stay a hard error.

  Scenario: Unapproved core opclasses, expressions and partials degrade with precise reasons
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.states (
        id integer PRIMARY KEY,
        loc point,
        loc2 point,
        area box,
        spot circle,
        ground polygon,
        span int4range,
        host inet,
        body tsvector,
        query tsquery
      );
      CREATE INDEX states_loc ON public.states USING gist (loc);
      CREATE INDEX states_area ON public.states USING gist (area);
      CREATE INDEX states_spot ON public.states USING gist (spot);
      CREATE INDEX states_ground ON public.states USING gist (ground);
      CREATE INDEX states_span ON public.states USING gist (span);
      CREATE INDEX states_host ON public.states USING gist (host inet_ops);
      CREATE INDEX states_body ON public.states USING gist (body);
      CREATE INDEX states_query ON public.states USING gist (query);
      CREATE INDEX states_expr ON public.states USING gist ((box(loc, loc)));
      CREATE INDEX states_partial ON public.states USING gist (loc) WHERE id > 500;
      CREATE INDEX states_multi ON public.states USING gist (loc, loc2);
      CREATE INDEX states_include ON public.states USING gist (loc) INCLUDE (id);
      INSERT INTO public.states
      SELECT i,
             point(i, i),
             point(i + 1, i + 1),
             box(point(i, i), point(i + 1, i + 1)),
             circle(point(i, i), 1),
             polygon(box(point(i, i), point(i + 10, i + 10))),
             int4range(i, i + 10),
             ('10.0.0.' || (i % 250))::inet,
             to_tsvector('english', 'row ' || i),
             to_tsquery('english', 'row | ' || i)
      FROM generate_series(1, 1000) AS i;
      """
    Then the following SQL on "source" returns "definition|definition|definition|definition|definition|definition|definition|definition|definition|definition|definition|physical":
      """
      SELECT (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_area%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_spot%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_ground%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_span%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_host%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_body%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_query%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_expr%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_partial%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_multi%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_include%'),
             (SELECT method FROM pagecopy.check('public.states')
              WHERE name = 'states_loc' AND type = 'index' AND detail = '')
      """
    And the following SQL on "source" returns "gist opclass pg_catalog.box_ops on box is not the core point_ops on point|gist opclass pg_catalog.circle_ops on circle is not the core point_ops on point|gist opclass pg_catalog.poly_ops on polygon is not the core point_ops on point|gist opclass pg_catalog.range_ops on int4range is not the core point_ops on point|gist opclass pg_catalog.inet_ops on inet is not the core point_ops on point|gist opclass pg_catalog.tsvector_ops on tsvector is not the core point_ops on point|gist opclass pg_catalog.tsquery_ops on tsquery is not the core point_ops on point|gist expression or partial indexes are not transferred|gist expression or partial indexes are not transferred|gist physical transfer requires a single key column|gist physical transfer requires one key column and no INCLUDE columns":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_area%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_spot%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_ground%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_span%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_host%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_body%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_query%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_expr%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_partial%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_multi%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_include%')
      """
    Given the following SQL is executed on "source":
      """
      CREATE TABLE public.pull_t (
        id integer PRIMARY KEY,
        loc point,
        area box,
        spot circle,
        ground polygon,
        note text
      );
      CREATE INDEX pull_loc ON public.pull_t USING gist (loc);
      CREATE INDEX pull_area ON public.pull_t USING gist (area);
      CREATE INDEX pull_spot ON public.pull_t USING gist (spot);
      CREATE INDEX pull_ground ON public.pull_t USING gist (ground);
      INSERT INTO public.pull_t
      SELECT i, point(i, i), box(point(i, i), point(i + 1, i + 1)),
             circle(point(i, i), 1), polygon(box(point(i, i), point(i + 10, i + 10))),
             'row ' || i
      FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.pull_t', 'public.pull_t', true
      );
      """
    Then the following SQL on "target" returns "2|3|1000":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.pull_t)
      FROM pg_index WHERE indrelid = 'public.pull_t'::regclass;
      """
    And the following SQL on "target" returns "500|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.pull_t WHERE loc <@ box(point(0, 0), point(500, 500))),
             (SELECT count(*) FROM public.pull_t WHERE loc ~= point(500, 500));
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.pull_t;
      """
    Then the following SQL on "target" returns "5":
      """
      SELECT count(*) FROM pg_index
      WHERE indrelid = 'public.pull_t'::regclass AND indisvalid AND indisready;
      """

  Scenario: Invalid and not-ready source GIST indexes degrade to definitions
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      CREATE INDEX t_p2 ON public.t USING gist (p);
      INSERT INTO public.t SELECT i, point(i, i) FROM generate_series(1, 100) AS i;
      SELECT pc_test_empty_index_state('public.t_p', false, false);
      SELECT pc_test_empty_index_state('public.t_p2', true, false);
      """
    Then the following SQL on "source" returns "invalid on source|not ready on source":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.t') WHERE name = 't_p'),
             (SELECT detail FROM pagecopy.check('public.t') WHERE name LIKE 't_p2%')
      """
    Given the following SQL is executed on "target":
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
    Then the following SQL on "target" returns "2|2|100":
      """
      SELECT count(*),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.t)
      FROM pg_index WHERE indrelid = 'public.t'::regclass;
      """

  Scenario: A custom GIST opclass is a hard error even when it looks core
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.custom (id integer, p point);
      CREATE OPERATOR CLASS public.custom_point_ops FOR TYPE point USING gist AS
        OPERATOR 1 <<(point, point),
        OPERATOR 15 ~= (point, point),
        FUNCTION 1 gist_point_consistent(internal, point, smallint, oid, internal),
        FUNCTION 2 gist_box_union(internal, internal),
        FUNCTION 3 gist_point_compress(internal),
        FUNCTION 5 gist_box_penalty(internal, internal, internal),
        FUNCTION 6 gist_box_picksplit(internal, internal),
        FUNCTION 7 gist_box_same(box, box, internal);
      CREATE INDEX custom_p ON public.custom USING gist (p public.custom_point_ops);
      INSERT INTO public.custom VALUES (1, point(1, 1)), (2, point(2, 2));
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT method, detail FROM pagecopy.check('public.custom')
      WHERE name LIKE 'custom_p%';
      """
    Then the following SQL on "target" fails with "custom opclasses are not supported":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.custom', 'public.custom', true
      );
      """
    And the following SQL on "target" returns "0":
      """
      SELECT count(*) FROM pg_tables WHERE tablename = 'custom';
      """

  Scenario: The contrib btree_gist extension opclasses stay a hard error
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION btree_gist;
      CREATE TABLE public.nums (id integer PRIMARY KEY, k integer);
      CREATE INDEX nums_k ON public.nums USING gist (k gist_int4_ops);
      INSERT INTO public.nums SELECT i, i FROM generate_series(1, 200) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT method, detail FROM pagecopy.check('public.nums')
      WHERE name LIKE 'nums_k%';
      """
    Then the following SQL on "target" fails with "custom opclasses are not supported":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.nums', 'public.nums', true
      );
      """
    And the following SQL on "target" returns "0":
      """
      SELECT count(*) FROM pg_tables WHERE tablename = 'nums';
      """


  Scenario: Deleted-page horizons are normalized during GiST preparation
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t SELECT i, point(i, i)
      FROM generate_series(1, 2000) AS i;
      DELETE FROM public.t WHERE id <= 1500;
      """
    And the following SQL is executed on "source":
      """
      VACUUM public.t;
      """
    And the following SQL is executed on "source":
      """
      CREATE FUNCTION pc_test_gist_deleted_horizon(regclass)
        RETURNS bigint AS 'pc_bdd_fixtures', 'pc_test_gist_deleted_horizon'
        LANGUAGE C STRICT;
      """
    Then the following SQL on "source" returns "t|0|nonnegative":
      """
      SELECT true,
             CASE WHEN pc_test_gist_deleted_horizon('public.t_p') = -1
                  THEN -1 ELSE 0 END,
             CASE WHEN pc_test_gist_deleted_horizon('public.t_p') >= 0
                  THEN 'nonnegative' ELSE 'negative' END
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t VALUES (9999, point(9999, 9999));
      CREATE FUNCTION pc_test_gist_deleted_horizon(regclass)
        RETURNS bigint AS 'pc_bdd_fixtures', 'pc_test_gist_deleted_horizon'
        LANGUAGE C STRICT;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "3":
      """
      SELECT CASE WHEN pc_test_gist_deleted_horizon('public.t_p') = -1
                  THEN -1
                  ELSE pc_test_gist_deleted_horizon('public.t_p') END;
      """
