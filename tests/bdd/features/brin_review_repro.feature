@brin @review-repro
Feature: BRIN review regression coverage

  Regressions for the two confirmed review findings: a custom opclass that
  spoofs a core pg_catalog name is rejected by opclass OID, and duplicate
  BRIN definitions match independently of OID and validity order.

  Scenario: A custom pg_catalog opclass spoofing a core name is rejected as a custom opclass
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      ALTER OPERATOR CLASS pg_catalog.int4_minmax_ops USING brin
        RENAME TO int4_minmax_original;
      CREATE OPERATOR CLASS pg_catalog.int4_minmax_ops FOR TYPE integer USING brin AS
        OPERATOR 1 <(integer,integer),
        OPERATOR 2 <=(integer,integer),
        OPERATOR 3 =(integer,integer),
        OPERATOR 4 >=(integer,integer),
        OPERATOR 5 >(integer,integer),
        FUNCTION 1 brin_minmax_opcinfo(internal),
        FUNCTION 2 brin_minmax_add_value(internal,internal,internal,internal),
        FUNCTION 3 brin_minmax_consistent(internal,internal,internal),
        FUNCTION 4 brin_minmax_union(internal,internal,internal);
      CREATE TABLE public.spoofed (id integer);
      CREATE INDEX spoofed_brin ON public.spoofed
        USING brin (id pg_catalog.int4_minmax_ops);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "t|error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT o.oid >= 16384, c.method, c.detail
      FROM pg_index i
      JOIN pg_opclass o ON o.oid = i.indclass[0]
      CROSS JOIN LATERAL (
        SELECT method, detail FROM pagecopy.check('public.spoofed')
        WHERE name = 'spoofed_brin' AND type = 'index'
      ) AS c
      WHERE i.indexrelid = 'public.spoofed_brin'::regclass;
      """
    And the following SQL on "target" fails with "custom opclasses are not supported":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.spoofed', 'public.spoofed', true
      );
      """

  Scenario: A target-side custom pg_catalog opclass spoof fails the transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.spoofed (id integer);
      CREATE INDEX spoofed_brin ON public.spoofed USING brin (id);
      INSERT INTO public.spoofed SELECT * FROM generate_series(1, 100);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      ALTER OPERATOR CLASS pg_catalog.int4_minmax_ops USING brin
        RENAME TO int4_minmax_original;
      CREATE OPERATOR CLASS pg_catalog.int4_minmax_ops FOR TYPE integer USING brin AS
        OPERATOR 1 <(integer,integer),
        OPERATOR 2 <=(integer,integer),
        OPERATOR 3 =(integer,integer),
        OPERATOR 4 >=(integer,integer),
        OPERATOR 5 >(integer,integer),
        FUNCTION 1 brin_minmax_opcinfo(internal),
        FUNCTION 2 brin_minmax_add_value(internal,internal,internal,internal),
        FUNCTION 3 brin_minmax_consistent(internal,internal,internal),
        FUNCTION 4 brin_minmax_union(internal,internal,internal);
      UPDATE pg_opclass SET opcdefault = (opcname = 'int4_minmax_ops')
      WHERE opcname IN ('int4_minmax_ops', 'int4_minmax_original');
      CREATE TABLE public.spoofed (id integer);
      CREATE INDEX spoofed_brin ON public.spoofed
        USING brin (id pg_catalog.int4_minmax_ops);
      INSERT INTO public.spoofed VALUES (9999);
      """
    Then the following SQL on "target" returns "t|t|error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT pg_get_indexdef('public.spoofed_brin'::regclass) =
               'CREATE INDEX spoofed_brin ON public.spoofed USING brin (id)',
             o.oid >= 16384, c.method, c.detail
      FROM pg_index i
      JOIN pg_opclass o ON o.oid = i.indclass[0]
      CROSS JOIN LATERAL (
        SELECT method, detail FROM pagecopy.check('public.spoofed')
        WHERE name = 'spoofed_brin' AND type = 'index'
      ) AS c
      WHERE i.indexrelid = 'public.spoofed_brin'::regclass;
      """
    And the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.spoofed', 'public.spoofed', true
      );
      """
    And the following SQL on "target" returns "1":
      """
      SELECT count(*) FROM public.spoofed;
      """

  Scenario: Duplicate BRIN definitions match independently of OID and validity order
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.duplicates (id integer);
      CREATE INDEX a_invalid ON public.duplicates USING brin (id);
      CREATE INDEX b_valid ON public.duplicates USING brin (id);
      INSERT INTO public.duplicates SELECT * FROM generate_series(1, 1000);
      UPDATE pg_index SET indisvalid = false, indisready = false
      WHERE indexrelid = 'public.a_invalid'::regclass;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.duplicates (id integer);
      CREATE INDEX a_invalid ON public.duplicates USING brin (id);
      CREATE INDEX b_valid ON public.duplicates USING brin (id);
      UPDATE pg_index SET indisvalid = false, indisready = false
      WHERE indexrelid = 'public.b_valid'::regclass;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.duplicates', 'public.duplicates', true
      );
      """
    Then the following SQL on "target" returns "1000|500500|a_invalid|true|true;b_valid|false|false":
      """
      SELECT (SELECT count(*) FROM public.duplicates),
             (SELECT sum(id) FROM public.duplicates),
             string_agg(c.relname || '|' || i.indisvalid || '|' || i.indisready, ';' ORDER BY c.relname)
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE i.indrelid = 'public.duplicates'::regclass;
      """
