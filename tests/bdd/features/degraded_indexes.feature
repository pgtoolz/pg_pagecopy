@degraded_indexes
Feature: Unsupported secondary indexes survive as rebuildable definitions

  Scenario: Mixed indexes transfer with heap data and rebuild on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      CREATE INDEX events_note_btree ON public.events USING btree (note);
      CREATE INDEX events_id_hash ON public.events USING hash (id);
      CREATE INDEX events_note_partial ON public.events (note) WHERE note IS NOT NULL;
      CREATE INDEX events_note_expr ON public.events (lower(note));
      INSERT INTO public.events VALUES
        (1, repeat('x', 10000), 'Alpha'),
        (2, 'two', 'Beta'),
        (3, 'three', NULL);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|4":
      """
      SELECT count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             count(*) FILTER (WHERE indisvalid AND indisready)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """
    And the following SQL on "source" returns "0":
      """
      SELECT count(*) FROM pg_index
      WHERE indrelid = 'public.events'::regclass AND (NOT indisvalid OR NOT indisready);
      """
    And the following SQL on "target" returns "3|6|10000|2":
      """
      SELECT count(*), sum(id), max(length(payload)), count(note) FROM public.events;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.events VALUES (4, 'four', 'Gamma');
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" returns "0|4|1|1|1":
      """
      SELECT (SELECT count(*) FROM pg_index
              WHERE indrelid = 'public.events'::regclass
                AND (NOT indisvalid OR NOT indisready)),
             (SELECT count(*) FROM public.events),
             (SELECT count(*) FROM public.events WHERE lower(note) = 'alpha'),
             (SELECT count(*) FROM public.events WHERE id = 2),
             (SELECT count(*) FROM public.events WHERE note = 'Gamma');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|3|6":
      """
      SELECT (SELECT count(*) FROM pg_index
              WHERE indrelid = 'public.events'::regclass
                AND NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.events),
             (SELECT sum(id) FROM public.events);
      """

  Scenario: Source-only index tablespaces are not required on the target
    Given a fresh PostgreSQL pair
    And a non-default tablespace is available on "source"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_note_btree ON public.events USING btree (note) TABLESPACE attach_space;
      CREATE INDEX events_id_hash ON public.events USING hash (id) TABLESPACE attach_space;
      INSERT INTO public.events VALUES (1, 'one'), (2, 'two');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "2|1|1":
      """
      SELECT count(*) FILTER (WHERE c.reltablespace = 0),
             count(*) FILTER (WHERE NOT i.indisvalid AND NOT i.indisready),
             count(*) FILTER (WHERE i.indisvalid AND i.indisready)
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE i.indrelid = 'public.events'::regclass;
      """

  Scenario: Quoted index names containing USING do not corrupt definitions
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX "hash USING suffix" ON public.events USING hash (id);
      CREATE INDEX "btree USING suffix" ON public.events USING btree (note);
      INSERT INTO public.events VALUES (1, 'one');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|1":
      """
      SELECT count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             count(*) FILTER (WHERE indisvalid AND indisready)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT i.indisvalid, i.indisready
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam
      WHERE i.indrelid = 'public.events'::regclass AND am.amname = 'hash';
      """

  Scenario Outline: Supported <name> remains a physical Btree transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_supported ON public.events USING btree <definition>;
      INSERT INTO public.events VALUES (1, 'Alpha'), (2, 'beta'), (3, NULL);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "0|1|3":
      """
      SELECT count(*) FILTER (WHERE NOT indisvalid OR NOT indisready),
             count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.events)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """

    Examples:
      | name                        | definition |
      | pg_catalog nondefault opclass | (note text_pattern_ops) |
      | explicit collation            | (note COLLATE "C") |
      | multicolumn desc/nulls        | (id DESC NULLS LAST, note ASC) |
      | include column                | (id) INCLUDE (note) |

  Scenario Outline: Existing target with <name> foreign key is rejected before replacement
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      INSERT INTO public.events VALUES (1, 'source');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      INSERT INTO public.events VALUES (99, 'target');
      <setup>
      """
    Then the following SQL on "target" fails with "target table participates in foreign key constraints":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', false
      );
      """
    And the following SQL on "target" returns "99|target":
      """
      SELECT id, note FROM public.events;
      """

    Examples:
      | name     | setup |
      | outgoing | CREATE TABLE public.parent (id integer PRIMARY KEY); INSERT INTO public.parent VALUES (99); ALTER TABLE public.events ADD CONSTRAINT events_parent_fk FOREIGN KEY (id) REFERENCES public.parent(id); |
      | incoming | ALTER TABLE public.events ADD CONSTRAINT events_id_key UNIQUE (id); CREATE TABLE public.child (event_id integer REFERENCES public.events(id)); |

  Scenario: Degraded expression cannot bind through the target search_path
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE SCHEMA source_ops;
      CREATE FUNCTION source_ops.lower(text) RETURNS text LANGUAGE sql IMMUTABLE
        AS 'SELECT pg_catalog.upper($1)';
      CREATE TABLE public.events (id integer, note text);
      INSERT INTO public.events VALUES (1, 'Alpha');
      CREATE INDEX events_expression ON public.events USING btree (source_ops.lower(note));
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE SCHEMA attacker;
      CREATE FUNCTION attacker.lower(text) RETURNS text LANGUAGE sql IMMUTABLE
        AS 'SELECT pg_catalog.upper($1)';
      """
    Then the following SQL on "target" fails with "source_ops":
      """
      SET search_path = attacker, pg_catalog;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('public.events');
      """

  Scenario: An unqualified target retains its visible existing namespace
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer);
      CREATE INDEX events_expression ON public.events (lower(id::text));
      INSERT INTO public.events VALUES (1);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE SCHEMA app;
      CREATE TABLE public.events (id integer);
      CREATE INDEX events_expression ON public.events (lower(id::text));
      INSERT INTO public.events VALUES (99);
      """
    Then the following SQL on "target" returns "app, public, pg_catalog":
      """
      SET search_path = app, public, pg_catalog;
      SELECT current_setting('search_path') FROM (
        SELECT pagecopy.pull(
          'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
          'public.events', 'events', false
        )
      ) AS moved;
      """
    And the following SQL on "target" returns "1|NULL":
      """
      SELECT (SELECT count(*) FROM public.events), to_regclass('app.events');
      """

  Scenario: An unqualified target rejects a visible existing view
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer);
      INSERT INTO public.events VALUES (1);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE SCHEMA app;
      CREATE VIEW public.events AS SELECT 42 AS id;
      """
    Then the following SQL on "target" fails with "target must be a plain logged table":
      """
      SET search_path = app, public, pg_catalog;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'events', false
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('app.events');
      """


  Scenario: Expression replay preserves backslash string semantics
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer);
      INSERT INTO public.events VALUES (1), (2);
      CREATE INDEX events_expression ON public.events ((id + length(E'\\\\')));
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "target" returns "off|SQL, DMY|3":
      """
      SET standard_conforming_strings = off;
      SET DateStyle = 'SQL, DMY';
      SET extra_float_digits = 3;
      SELECT current_setting('standard_conforming_strings'),
             current_setting('DateStyle'), current_setting('extra_float_digits')
      FROM (
        SELECT pagecopy.pull(
          'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
          'public.events', 'events', false
        )
      ) AS moved;
      """
    And the following SQL on "target" returns "(id + length('\\'::text))":
      """
      SELECT pg_get_expr(i.indexprs, i.indrelid)
      FROM pg_index i WHERE i.indexrelid = 'events_expression'::regclass;
      """
    And the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid, indisready FROM pg_index
      WHERE indexrelid = 'events_expression'::regclass;
      """
