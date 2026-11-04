@cross-major @btree_dedup
Feature: Older btree duplicate pages remain valid on dedup-aware PostgreSQL

  Scenario Outline: PostgreSQL <source_major> to <target_major> preserves duplicate-key btree semantics
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, note text);
      CREATE INDEX events_note_idx ON public.events USING btree (note);
      INSERT INTO public.events SELECT i, 'same-note' FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION amcheck;
      CREATE TABLE public.events(id integer PRIMARY KEY, note text);
      CREATE INDEX events_note_idx ON public.events USING btree (note);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1000|1|1000":
      """
      SELECT count(*), count(DISTINCT note),
             (SELECT count(*) FROM public.events WHERE note = 'same-note')
      FROM public.events;
      """
    And the following SQL on "target" returns "1|1":
      """
      SELECT (SELECT count(*) FROM (
                SELECT bt_index_check('public.events_note_idx', true) AS result
              ) AS checked),
             (SELECT count(*) FROM (
                SELECT bt_index_check('public.events_pkey', true) AS result
              ) AS checked);
      """

    Examples:
      | source_major | target_major |
      | 13           | 15           |
      | 13           | 16           |
      | 13           | 17           |
      | 13           | 18           |
      | 14           | 15           |
      | 14           | 16           |
      | 14           | 17           |
      | 14           | 18           |
