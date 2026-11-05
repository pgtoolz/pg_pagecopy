@gin @degraded
Feature: Unapproved GIN indexes degrade while custom opclasses fail

  Physical GIN covers only core array_ops on a plain int[] key and
  jsonb_ops on a plain jsonb key. Every other core GIN opclass degrades to
  a definition-only transfer with a precise reason, expressions, partials
  and multicolumn indexes degrade, invalid or not-ready indexes degrade,
  and custom opclasses stay a hard error.

  Scenario: Unapproved core opclasses, expressions, partials and multicolumn indexes degrade with precise reasons
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.states (
        id integer PRIMARY KEY,
        body text,
        tsv tsvector,
        doc jsonb,
        words text[],
        tags integer[],
        other integer[]
      );
      CREATE INDEX states_tsv ON public.states USING gin (tsv);
      CREATE INDEX states_doc ON public.states USING gin (doc jsonb_path_ops);
      CREATE INDEX states_words ON public.states USING gin (words);
      CREATE INDEX states_expr ON public.states USING gin (to_tsvector('simple', body));
      CREATE INDEX states_partial ON public.states USING gin (tags) WHERE id > 500;
      CREATE INDEX states_multi ON public.states USING gin (tags, other);
      INSERT INTO public.states
      SELECT i, 'body' || i, to_tsvector('simple', 'body' || i),
             jsonb_build_object('k', i), ARRAY['a', 'b'], ARRAY[i], ARRAY[i + 1]
      FROM generate_series(1, 1000) AS i;
      """
    Then the following SQL on "source" returns "definition|definition|definition|definition|definition|definition":
      """
      SELECT (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_tsv%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_doc%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_words%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_expr%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_partial%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_multi%')
      """
    And the following SQL on "source" returns "gin opclass pg_catalog.tsvector_ops on tsvector is not one of the core array_ops/jsonb_ops pairs|gin opclass pg_catalog.jsonb_path_ops on jsonb is not one of the core array_ops/jsonb_ops pairs|gin opclass pg_catalog.array_ops on _text is not one of the core array_ops/jsonb_ops pairs|gin expression or partial indexes are not transferred|gin expression or partial indexes are not transferred|gin multicolumn indexes are not transferred":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_tsv%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_doc%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_words%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_expr%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_partial%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_multi%')
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
             (SELECT count(*) FROM public.states WHERE tsv @@ to_tsquery('simple', 'body42'))
      FROM pg_index WHERE indrelid = 'public.states'::regclass;
      """

  Scenario: Invalid and not-ready source gin indexes degrade to definitions
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer, tags integer[], other integer[]);
      CREATE INDEX t_tags ON public.t USING gin (tags);
      CREATE INDEX t_tags2 ON public.t USING gin (other);
      INSERT INTO public.t SELECT i, ARRAY[i, i + 1], ARRAY[i + 2] FROM generate_series(1, 100) AS i;
      SELECT pc_test_empty_index_state('public.t_tags', false, false);
      SELECT pc_test_empty_index_state('public.t_tags2', true, false);
      """
    Then the following SQL on "source" returns "invalid on source|not ready on source":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.t') WHERE name = 't_tags'),
             (SELECT detail FROM pagecopy.check('public.t') WHERE name LIKE 't_tags2%')
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

  Scenario: A custom gin opclass is a hard error even when it looks core
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.custom (id integer, tags integer[]);
      CREATE OPERATOR CLASS public.custom_gin_ops FOR TYPE integer[] USING gin AS
        OPERATOR 1 && (anyarray, anyarray),
        OPERATOR 2 @> (anyarray, anyarray),
        OPERATOR 3 <@ (anyarray, anyarray),
        OPERATOR 4 = (anyarray, anyarray),
        FUNCTION 1 btint4cmp(integer, integer),
        FUNCTION 2 ginarrayextract(anyarray, internal, internal),
        FUNCTION 3 ginqueryarrayextract(anyarray, internal, int2, internal, internal, internal, internal),
        FUNCTION 4 ginarrayconsistent(internal, int2, anyarray, int4, internal, internal, internal, internal);
      CREATE INDEX custom_tags ON public.custom USING gin (tags public.custom_gin_ops);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT method, detail FROM pagecopy.check('public.custom')
      WHERE name LIKE 'custom_tags%';
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
