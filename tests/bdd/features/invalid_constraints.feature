@invalid_constraints
Feature: Constraint-backed and invalid source indexes transfer as invalid definitions

  Any source index that is not transferred physically (hash/GiST/GIN/BRIN/SP-GiST,
  invalid on source, exclusion, primary key or unique constraint) is recreated on
  the target from its definition with indisvalid=false and indisready=false.
  Uniqueness and exclusion are not enforced until REINDEX. Custom opclasses stay
  a hard error. pagecopy.check() reports the planned transfer mode per index.

  Scenario: Unique index invalid on source transfers as an invalid definition
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer, note text);
      CREATE UNIQUE INDEX events_id_key ON public.events USING btree (id);
      INSERT INTO public.events VALUES (1, 'one'), (2, 'two'), (3, 'three');
      SELECT pc_test_empty_index_state('events_id_key', false, false);
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
    Then the following SQL on "target" returns "3|f|f|0":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.events_id_key'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.events_id_key'::regclass),
             (SELECT count(*) FROM pg_constraint
              WHERE conrelid = 'public.events'::regclass);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.events VALUES (1, 'duplicate while invalid');
      """
    Then the following SQL on "target" returns "2":
      """
      SELECT count(*) FROM public.events WHERE id = 1;
      """
    When the following SQL is executed on "target":
      """
      DELETE FROM public.events WHERE note = 'duplicate while invalid';
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" fails with "duplicate key value violates unique constraint":
      """
      INSERT INTO public.events VALUES (1, 'duplicate after reindex');
      """

  Scenario: Primary key invalid on source keeps the constraint record and rebuilds
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer PRIMARY KEY, note text);
      INSERT INTO public.events VALUES (1, 'one'), (2, 'two');
      SELECT pc_test_empty_index_state('events_pkey', false, false);
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
    Then the following SQL on "target" returns "1|f|f|2":
      """
      SELECT (SELECT count(*) FROM pg_constraint
              WHERE conrelid = 'public.events'::regclass AND contype = 'p'),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.events_pkey'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.events_pkey'::regclass),
             (SELECT count(*) FROM public.events);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.events VALUES (1, 'duplicate while invalid');
      """
    Then the following SQL on "target" returns "2":
      """
      SELECT count(*) FROM public.events WHERE id = 1;
      """
    When the following SQL is executed on "target":
      """
      DELETE FROM public.events WHERE note = 'duplicate while invalid';
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" fails with "duplicate key value violates unique constraint":
      """
      INSERT INTO public.events VALUES (1, 'duplicate after reindex');
      """

  Scenario: Exclusion constraint transfers as an invalid definition instead of failing
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, frame box);
      INSERT INTO public.events VALUES
        (1, box(point(0, 0), point(1, 1))),
        (2, box(point(5, 5), point(6, 6)));
      ALTER TABLE public.events
        ADD CONSTRAINT events_frame_excl EXCLUDE USING gist (frame WITH &&);
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
    Then the following SQL on "target" returns "1|f|f|2":
      """
      SELECT (SELECT count(*) FROM pg_constraint
              WHERE conrelid = 'public.events'::regclass AND contype = 'x'),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.events_frame_excl'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.events_frame_excl'::regclass),
             (SELECT count(*) FROM public.events);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.events VALUES
        (3, box(point(0.5, 0.5), point(1.5, 1.5)));
      """
    Then the following SQL on "target" returns "1":
      """
      SELECT count(*) FROM public.events WHERE id = 3;
      """
    When the following SQL is executed on "target":
      """
      DELETE FROM public.events WHERE id = 3;
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" fails with "conflicting key value violates exclusion constraint":
      """
      INSERT INTO public.events VALUES
        (3, box(point(0.5, 0.5), point(1.5, 1.5)));
      """

  Scenario: pagecopy.check reports the transfer mode of every source index
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_valid ON public.events USING btree (id);
      CREATE INDEX events_hash ON public.events USING hash (note);
      CREATE UNIQUE INDEX events_key ON public.events USING btree (note);
      CREATE OPERATOR CLASS public.custom_text_ops FOR TYPE text USING btree AS
        OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >,
        FUNCTION 1 bttextcmp(text, text);
      CREATE INDEX events_custom ON public.events USING btree (note public.custom_text_ops);
      SELECT pc_test_empty_index_state('events_key', false, false);
      """
    Then the following SQL on "source" returns "events_custom:error,events_hash:definition,events_key:definition,events_valid:physical,public.events:physical":
      """
      SELECT string_agg(name || ':' || method, ',' ORDER BY name)
      FROM pagecopy.check('public.events') WHERE name NOT LIKE 'pg_toast.%';
      """
    And the following SQL on "source" returns "t|physical|":
      """
      SELECT supported, method, detail FROM pagecopy.check('public.events') WHERE name = 'events_valid';
      """
    And the following SQL on "source" returns "t|physical|":
      """
      SELECT supported, method, detail FROM pagecopy.check('public.events') WHERE name = 'public.events';
      """
    And the following SQL on "source" returns "t|definition|hash opclass pg_catalog.text_ops on text is not one of the core int2/int4/int8 pairs":
      """
      SELECT supported, method, detail FROM pagecopy.check('public.events') WHERE name = 'events_hash';
      """
    And the following SQL on "source" returns "t|definition|invalid on source":
      """
      SELECT supported, method, detail FROM pagecopy.check('public.events') WHERE name = 'events_key';
      """
    And the following SQL on "source" returns "f|error|custom opclasses are not supported; only core pg_catalog opclasses are allowed":
      """
      SELECT supported, method, detail FROM pagecopy.check('public.events') WHERE name = 'events_custom';
      """

  Scenario: Degraded matching rejects unique and nonunique definition collisions
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.unique_source (id integer);
      CREATE UNIQUE INDEX unique_source_id_key ON public.unique_source USING btree (id);
      INSERT INTO public.unique_source VALUES (1);
      SELECT pc_test_empty_index_state('unique_source_id_key', false, false);
      CREATE TABLE public.plain_source (id integer);
      CREATE INDEX plain_source_id_key ON public.plain_source USING btree (id);
      INSERT INTO public.plain_source VALUES (2);
      SELECT pc_test_empty_index_state('plain_source_id_key', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.unique_source (id integer);
      CREATE INDEX unique_source_id_key ON public.unique_source USING btree (id);
      INSERT INTO public.unique_source VALUES (7);
      CREATE TABLE public.plain_source (id integer);
      CREATE UNIQUE INDEX plain_source_id_key ON public.plain_source USING btree (id);
      INSERT INTO public.plain_source VALUES (7);
      """
    Then the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.unique_source', 'public.unique_source', true
      );
      """
    And the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.plain_source', 'public.plain_source', true
      );
      """
    And the following SQL on "target" returns "7|f|t|t|7|t|t|t":
      """
      SELECT (SELECT id FROM public.unique_source),
             (SELECT indisunique FROM pg_index
              WHERE indexrelid = 'public.unique_source_id_key'::regclass),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.unique_source_id_key'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.unique_source_id_key'::regclass),
             (SELECT id FROM public.plain_source),
             (SELECT indisunique FROM pg_index
              WHERE indexrelid = 'public.plain_source_id_key'::regclass),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.plain_source_id_key'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.plain_source_id_key'::regclass);
      """

  Scenario: Invalid and physical indexes with equal definitions match their unique peers
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer NOT NULL);
      CREATE INDEX events_plain ON public.events USING btree (id);
      CREATE UNIQUE INDEX events_unique ON public.events USING btree (id);
      INSERT INTO public.events VALUES (1), (2);
      SELECT pc_test_empty_index_state('events_plain', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer NOT NULL);
      CREATE UNIQUE INDEX events_unique ON public.events USING btree (id);
      CREATE INDEX events_plain ON public.events USING btree (id);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "2|f|f|t|t":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.events_plain'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.events_plain'::regclass),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.events_unique'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.events_unique'::regclass);
      """

  Scenario: Degraded target replica identity is reported by catalog state and rebuilds
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.degraded_events (id integer NOT NULL);
      CREATE UNIQUE INDEX degraded_events_id_key ON public.degraded_events USING btree (id);
      INSERT INTO public.degraded_events VALUES (1);
      SELECT pc_test_empty_index_state('degraded_events_id_key', false, false);
      CREATE TABLE public.physical_events (id integer NOT NULL);
      CREATE UNIQUE INDEX physical_events_id_key ON public.physical_events USING btree (id);
      INSERT INTO public.physical_events VALUES (2);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.degraded_events (id integer NOT NULL);
      CREATE UNIQUE INDEX degraded_events_id_key ON public.degraded_events USING btree (id);
      ALTER TABLE public.degraded_events REPLICA IDENTITY USING INDEX degraded_events_id_key;
      CREATE TABLE public.physical_events (id integer NOT NULL);
      CREATE UNIQUE INDEX physical_events_id_key ON public.physical_events USING btree (id);
      ALTER TABLE public.physical_events REPLICA IDENTITY USING INDEX physical_events_id_key;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.degraded_events', 'public.degraded_events', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.physical_events', 'public.physical_events', true
      );
      """
    Then the following SQL on "target" returns "i|t|f|f|i|t|t|t":
      """
      SELECT d.relreplident, di.indisreplident, di.indisvalid, di.indisready,
             p.relreplident, pi.indisreplident, pi.indisvalid, pi.indisready
      FROM pg_class d
      JOIN pg_index di ON di.indexrelid = 'public.degraded_events_id_key'::regclass,
           pg_class p
      JOIN pg_index pi ON pi.indexrelid = 'public.physical_events_id_key'::regclass
      WHERE d.oid = 'public.degraded_events'::regclass
        AND p.oid = 'public.physical_events'::regclass;
      """
    When the following SQL is executed on "target":
      """
      REINDEX INDEX public.degraded_events_id_key;
      """
    Then the following SQL on "target" returns "i|t|t|t":
      """
      SELECT c.relreplident, i.indisreplident, i.indisvalid, i.indisready
      FROM pg_class c JOIN pg_index i ON i.indrelid = c.oid
      WHERE c.oid = 'public.degraded_events'::regclass
        AND i.indexrelid = 'public.degraded_events_id_key'::regclass;
      """

  Scenario: pagecopy.check rejects unsafe heap types in its relation row
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TYPE public.mood AS ENUM ('ok');
      CREATE TABLE public.events (id integer, current_mood public.mood);
      CREATE INDEX events_id ON public.events USING btree (id);
      INSERT INTO public.events VALUES (1, 'ok');
      """
    And the following SQL is executed on "source":
      """
      VACUUM public.events;
      """
    Then the following SQL on "source" returns "f|error|column current_mood has unsafe type public.mood; only built-in types without catalog OIDs in their values are supported":
      """
      SELECT supported, method, detail FROM pagecopy.check('public.events') WHERE name = 'public.events';
      """
    And the following SQL on "source" returns "0":
      """
      SELECT count(*) FROM pagecopy.check('public.events')
      WHERE name = 'public.events' AND type IN ('vm', 'fsm');
      """
    And the following SQL on "source" returns "t|physical":
      """
      SELECT supported, method FROM pagecopy.check('public.events') WHERE name = 'events_id';
      """

  Scenario: pagecopy.check reports non-transferable relations as error rows
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE VIEW public.events_v AS SELECT 1 AS id;
      CREATE UNLOGGED TABLE public.events_u (id integer);
      CREATE TABLE public.events_p (id integer) PARTITION BY RANGE (id);
      """
    Then the following SQL on "source" returns "public.events_v|view|f|error":
      """
      SELECT name, type, supported, method
      FROM pagecopy.check('public.events_v');
      """
    And the following SQL on "source" returns "view: only plain logged tables transfer":
      """
      SELECT detail FROM pagecopy.check('public.events_v');
      """
    And the following SQL on "source" returns "public.events_u|unlogged table|f|error":
      """
      SELECT name, type, supported, method
      FROM pagecopy.check('public.events_u');
      """
    And the following SQL on "source" returns "unlogged table: only plain logged tables transfer":
      """
      SELECT detail FROM pagecopy.check('public.events_u');
      """
    And the following SQL on "source" returns "public.events_p|partitioned table|f|error":
      """
      SELECT name, type, supported, method
      FROM pagecopy.check('public.events_p');
      """
    And the following SQL on "source" returns "partitioned: transfer partitions individually":
      """
      SELECT detail FROM pagecopy.check('public.events_p');
      """

  Scenario: pagecopy.check inventories every relation file with its size
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_id ON public.events USING btree (id);
      INSERT INTO public.events VALUES (1, repeat('x', 10000));
      """
    And the following SQL is executed on "source":
      """
      VACUUM public.events;
      """
    Then the following SQL on "source" returns "table|t|physical|8192":
      """
      SELECT type, supported, method, size
      FROM pagecopy.check('public.events')
      WHERE name = 'public.events' AND type = 'table' AND method = 'physical';
      """
    And the following SQL on "source" returns "vm|t|physical|8192|copied byte-identically with the relation":
      """
      SELECT type, supported, method, size, detail
      FROM pagecopy.check('public.events')
      WHERE name = 'public.events' AND type = 'vm';
      """
    And the following SQL on "source" returns "fsm|t|physical|24576|copied byte-identically with the relation":
      """
      SELECT type, supported, method, size, detail
      FROM pagecopy.check('public.events')
      WHERE name = 'public.events' AND type = 'fsm';
      """
    And the following SQL on "source" returns "toast|t|physical|0":
      """
      SELECT type, supported, method, size
      FROM pagecopy.check('public.events') WHERE type = 'toast';
      """
    And the following SQL on "source" returns "toast index|t|physical|8192":
      """
      SELECT type, supported, method, size
      FROM pagecopy.check('public.events') WHERE type = 'toast index';
      """
    And the following SQL on "source" returns "index|t|physical|16384":
      """
      SELECT type, supported, method, size
      FROM pagecopy.check('public.events')
      WHERE name = 'events_id' AND method = 'physical';
      """
    And the following SQL on "source" returns "1":
      """
      SELECT count(*) FROM pagecopy.check('public.events') WHERE type = 'vm';
      """

  Scenario: pagecopy.check does not wait for an ordinary source writer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_id ON public.events USING btree (id);
      INSERT INTO public.events VALUES (1, 'original');
      """
    When a source writer holds row locks during the following SQL on "source":
      """
      SELECT * FROM pagecopy.check('public.events');
      """
    Then the following SQL on "source" returns "1":
      """
      SELECT count(*) FROM public.events WHERE id = 99 AND note = 'writer';
      """
