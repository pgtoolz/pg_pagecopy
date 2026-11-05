@spgist @degraded
Feature: Unapproved SP-GiST indexes degrade while custom opclasses fail

  Physical SP-GiST covers only core quad_point_ops/kd_point_ops on plain
  single-column point keys. Every other core SP-GiST opclass degrades to a
  definition-only transfer with a precise reason, expressions and partials
  degrade, invalid or not-ready indexes degrade, and custom opclasses stay
  a hard error.

  Scenario: Unapproved core opclasses, expressions and partials degrade with precise reasons
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.states (
        id integer PRIMARY KEY,
        body text,
        addr inet,
        shape polygon,
        frame box,
        spot point
      );
      CREATE INDEX states_body ON public.states USING spgist (body);
      CREATE INDEX states_addr ON public.states USING spgist (addr);
      CREATE INDEX states_shape ON public.states USING spgist (shape);
      CREATE INDEX states_frame ON public.states USING spgist (frame);
      CREATE INDEX states_expr ON public.states USING spgist ((point(id % 5, id % 5)));
      CREATE INDEX states_partial ON public.states USING spgist (spot) WHERE id > 500;
      INSERT INTO public.states
      SELECT i,
             'body' || i,
             ('10.0.0.' || (i % 250))::inet,
             polygon(box(point(i % 50, i % 50), point(i % 50 + 10, i % 50 + 10))),
             box(point(i % 50, i % 50), point(i % 60, i % 60)),
             point(i % 100, i % 100)
      FROM generate_series(1, 1000) AS i;
      """
    Then the following SQL on "source" returns "definition|definition|definition|definition|definition|definition":
      """
      SELECT (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_body%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_addr%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_shape%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_frame%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_expr%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_partial%')
      """
    And the following SQL on "source" returns "spgist opclass pg_catalog.text_ops on text is not one of the core point pairs|spgist opclass pg_catalog.inet_ops on inet is not one of the core point pairs|spgist opclass pg_catalog.poly_ops on polygon is not one of the core point pairs|spgist opclass pg_catalog.box_ops on box is not one of the core point pairs|spgist expression or partial indexes are not transferred|spgist expression or partial indexes are not transferred":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_body%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_addr%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_shape%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_frame%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_expr%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_partial%')
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.states', 'public.states', true
      );
      """
    Then the following SQL on "target" returns "7|6|1|1000":
      """
      SELECT count(*),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.states)
      FROM pg_index WHERE indrelid = 'public.states'::regclass;
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.states;
      """
    Then the following SQL on "target" returns "7|1":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.states
               WHERE addr = '10.0.0.10' AND id <= 250)
      FROM pg_index WHERE indrelid = 'public.states'::regclass;
      """

  Scenario: Invalid and not-ready source spgist indexes degrade to definitions
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      CREATE INDEX t_q2 ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i, i) FROM generate_series(1, 100) AS i;
      SELECT pc_test_empty_index_state('public.t_q', false, false);
      SELECT pc_test_empty_index_state('public.t_q2', true, false);
      """
    Then the following SQL on "source" returns "invalid on source|not ready on source":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.t') WHERE name = 't_q'),
             (SELECT detail FROM pagecopy.check('public.t') WHERE name LIKE 't_q2%')
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

  Scenario: A custom spgist opclass is a hard error even when it looks core
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.custom (id integer, p point);
      CREATE OPERATOR CLASS public.custom_point_ops FOR TYPE point USING spgist AS
        FUNCTION 1 spg_quad_config(internal, internal),
        FUNCTION 2 spg_quad_choose(internal, internal),
        FUNCTION 3 spg_quad_picksplit(internal, internal),
        FUNCTION 4 spg_quad_inner_consistent(internal, internal),
        FUNCTION 5 spg_quad_leaf_consistent(internal, internal);
      CREATE INDEX custom_q ON public.custom USING spgist (p public.custom_point_ops);
      INSERT INTO public.custom VALUES (1, point(1, 1)), (2, point(2, 2));
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT method, detail FROM pagecopy.check('public.custom')
      WHERE name LIKE 'custom_q%';
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
