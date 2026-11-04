@cross-major @btree_extended
Feature: Partial and expression btree transfer physically across majors

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers partial and expression btree as ready pages
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer PRIMARY KEY, note text);
      CREATE INDEX events_note_partial ON public.events USING btree (note) WHERE note IS NOT NULL;
      CREATE INDEX events_note_expr ON public.events USING btree (lower(note));
      INSERT INTO public.events
      SELECT i, CASE WHEN i % 2 = 0 THEN 'Note-' || i END
      FROM generate_series(1, 20) AS i;
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
        'public.events', 'public.imported_events', true
      );
      """
    Then the following SQL on "target" returns "20|10|0":
      """
      SELECT (SELECT count(*) FROM public.imported_events),
             (SELECT count(*) FROM public.imported_events WHERE note IS NOT NULL),
             (SELECT count(*) FROM pg_index
              WHERE indrelid = 'public.imported_events'::regclass
                AND (NOT indisvalid OR NOT indisready));
      """
    When the following SQL is executed on "target":
      """
      SELECT bt_index_check('public.events_note_partial'::regclass, true);
      SELECT bt_index_check('public.events_note_expr'::regclass, true);
      """

    Examples:
      | source_major | target_major |
      | 13           | 14           |
      | 13           | 15           |
      | 13           | 16           |
      | 13           | 17           |
      | 13           | 18           |
      | 14           | 15           |
      | 14           | 16           |
      | 14           | 17           |
      | 14           | 18           |
      | 15           | 16           |
      | 15           | 17           |
      | 15           | 18           |
      | 16           | 17           |
      | 16           | 18           |
      | 17           | 18           |
