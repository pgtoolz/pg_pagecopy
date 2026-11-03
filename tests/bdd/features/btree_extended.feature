@btree_extended
Feature: Partial and expression btree indexes transfer as ready pages

  Scenario: Partial and expression btree transfer physically valid
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text,
        note text
      );
      CREATE INDEX events_note_partial ON public.events USING btree (note) WHERE note IS NOT NULL;
      CREATE INDEX events_note_expr ON public.events USING btree (lower(note));
      INSERT INTO public.events VALUES
        (1, repeat('x', 10000), 'Alpha'),
        (2, 'two', 'Beta'),
        (3, 'three', NULL);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION amcheck;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "3|0|1":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT count(*) FROM pg_index
              WHERE indrelid = 'public.events'::regclass
                AND (NOT indisvalid OR NOT indisready)),
             (SELECT count(*) FROM public.events WHERE lower(note) = 'alpha');
      """
    When the following SQL is executed on "target":
      """
      SELECT bt_index_check('public.events_note_partial'::regclass, true),
             bt_index_check('public.events_note_expr'::regclass, true);
      """

  Scenario: Unique partial and unique expression btree transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        note text
      );
      CREATE UNIQUE INDEX events_note_uniq_partial ON public.events USING btree (lower(note)) WHERE note IS NOT NULL;
      INSERT INTO public.events VALUES (1, 'Alpha'), (2, NULL);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION amcheck;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.events_note_uniq_partial'::regclass;
      """
    When the following SQL is executed on "target":
      """
      SELECT bt_index_check('public.events_note_uniq_partial'::regclass, true);
      """
    Then the following SQL on "target" fails with "duplicate key value violates unique constraint":
      """
      INSERT INTO public.events VALUES (3, 'ALPHA');
      """

  Scenario: A clustered expression index transfers physically and keeps the flag
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_expression ON public.events USING btree (lower(note));
      INSERT INTO public.events VALUES (1, 'Alpha'), (2, 'beta');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_expression ON public.events USING btree (lower(note));
      INSERT INTO public.events VALUES (99, 'target');
      CLUSTER public.events USING events_expression;
      SET search_path = public, pg_catalog;
      """
    Then the following SQL on "target" returns "public, pg_catalog":
      """
      SET search_path = public, pg_catalog;
      SELECT current_setting('search_path') FROM (
        SELECT pagecopy.pull(
          'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
          'public.events', 'events', false
        )
      ) AS moved;
      """
    And the following SQL on "target" returns "t|t|t|2":
      """
      SELECT indisvalid, indisready, indisclustered,
             (SELECT count(*) FROM public.events)
      FROM pg_index WHERE indexrelid = 'events_expression'::regclass;
      """

  Scenario: A pre-created mismatched expression index fails the transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_expression ON public.events USING btree (lower(note));
      INSERT INTO public.events VALUES (1, 'Alpha');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_expression ON public.events USING btree (upper(note));
      """
    Then the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """

  Scenario: Multicolumn DESC/NULLS and INCLUDE btree keep ordering and serve index-only scans
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text, score integer);
      CREATE INDEX events_order ON public.events USING btree (score DESC NULLS LAST, note ASC);
      CREATE INDEX events_cover ON public.events USING btree (score) INCLUDE (note);
      INSERT INTO public.events VALUES
        (1, 'Alpha', NULL), (2, 'beta', 3), (3, NULL, 1),
        (4, 'Gamma', NULL), (5, 'delta', 2);
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
    Then the following SQL on "target" returns "2:5:3:1:4|0":
      """
      SET enable_seqscan = off;
      SELECT string_agg(id::text, ':' ORDER BY score DESC NULLS LAST, note),
             (SELECT count(*) FROM pg_index
              WHERE indrelid = 'public.events'::regclass AND NOT indisvalid)
      FROM public.events;
      """
    And the following SQL on "target" contains "Index Only Scan":
      """
      SET enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT score FROM public.events WHERE score = 3;
      """
