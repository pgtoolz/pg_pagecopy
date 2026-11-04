@hash @degraded
Feature: Unapproved HASH indexes degrade while custom opclasses fail

  Physical HASH covers only core int2_ops/int4_ops/int8_ops on plain
  single-column int2/int4/int8 keys. Every other core HASH opclass degrades
  to a definition-only transfer with a precise reason, expressions and
  partials degrade, invalid or not-ready indexes degrade, and custom
  opclasses stay a hard error.

  Scenario: Unapproved core opclasses, arrays, expressions and partials degrade with precise reasons
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.states (
        id integer PRIMARY KEY,
        body text,
        u uuid,
        flag boolean,
        d date,
        tags integer[]
      );
      CREATE INDEX states_body ON public.states USING hash (body);
      CREATE INDEX states_u ON public.states USING hash (u);
      CREATE INDEX states_flag ON public.states USING hash (flag);
      CREATE INDEX states_d ON public.states USING hash (d);
      CREATE INDEX states_tags ON public.states USING hash (tags);
      CREATE INDEX states_expr ON public.states USING hash ((id + 1));
      CREATE INDEX states_partial ON public.states USING hash (id) WHERE id > 500;
      INSERT INTO public.states
      SELECT i, 'body' || i, gen_random_uuid(), i % 2 = 0, date '2024-01-01' + i, ARRAY[i, i + 1]
      FROM generate_series(1, 1000) AS i;
      """
    Then the following SQL on "source" returns "definition|definition|definition|definition|definition|definition|definition":
      """
      SELECT (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_body%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_u%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_flag%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_d%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_tags%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_expr%'),
             (SELECT method FROM pagecopy.check('public.states') WHERE name LIKE 'states_partial%')
      """
    And the following SQL on "source" returns "hash opclass pg_catalog.text_ops on text is not one of the core int2/int4/int8 pairs|hash opclass pg_catalog.uuid_ops on uuid is not one of the core int2/int4/int8 pairs|hash opclass pg_catalog.bool_ops on bool is not one of the core int2/int4/int8 pairs|hash opclass pg_catalog.date_ops on date is not one of the core int2/int4/int8 pairs|hash opclass pg_catalog.array_ops on _int4 is not one of the core int2/int4/int8 pairs|hash expression or partial indexes are not transferred|hash expression or partial indexes are not transferred":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_body%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_u%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_flag%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_d%'),
             (SELECT detail FROM pagecopy.check('public.states') WHERE name LIKE 'states_tags%'),
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
    Then the following SQL on "target" returns "8|7|1|1000":
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
    Then the following SQL on "target" returns "8|4":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.states WHERE flag AND d < date '2024-01-10')
      FROM pg_index WHERE indrelid = 'public.states'::regclass;
      """

  Scenario: Invalid and not-ready source hash indexes degrade to definitions
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.t (id integer, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      CREATE INDEX t_k2 ON public.t USING hash (id);
      INSERT INTO public.t SELECT i, i FROM generate_series(1, 100) AS i;
      SELECT pc_test_empty_index_state('public.t_k', false, false);
      SELECT pc_test_empty_index_state('public.t_k2', true, false);
      """
    Then the following SQL on "source" returns "invalid on source|not ready on source":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.t') WHERE name = 't_k'),
             (SELECT detail FROM pagecopy.check('public.t') WHERE name LIKE 't_k2%')
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
    Then the following SQL on "target" returns "2|0":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready)
      FROM pg_index WHERE indrelid = 'public.t'::regclass;
      """

  Scenario: A custom hash opclass is a hard error even when it looks core
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.custom (id integer, k integer);
      CREATE OPERATOR CLASS public.custom_int4_ops FOR TYPE integer USING hash AS
        OPERATOR 1 =,
        FUNCTION 1 hashint4(integer);
      CREATE INDEX custom_k ON public.custom USING hash (k public.custom_int4_ops);
      INSERT INTO public.custom VALUES (1, 1), (2, 2);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT method, detail FROM pagecopy.check('public.custom')
      WHERE name LIKE 'custom_k%';
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
