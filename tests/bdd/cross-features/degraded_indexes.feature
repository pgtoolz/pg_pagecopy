@cross-major @degraded
Feature: Non-btree indexes degrade and rebuild across major versions

  Scenario Outline: PostgreSQL <source_major> to <target_major> degrades non-btree indexes and REINDEX rebuilds them
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id integer PRIMARY KEY, tags integer[], loc point, payload text
      );
      CREATE INDEX events_hash ON public.events USING hash (id);
      CREATE INDEX events_gin ON public.events USING gin (tags);
      CREATE INDEX events_gist ON public.events USING gist (loc);
      CREATE INDEX events_brin ON public.events USING brin (payload);
      INSERT INTO public.events
      SELECT i, ARRAY[i, i + 1], point(i, i), 'row-' || i
      FROM generate_series(1, 20) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.imported_events', true
      );
      """
    Then the following SQL on "target" returns "20|4":
      """
      SELECT count(*),
             (SELECT count(*) FROM pg_index
              WHERE indrelid = 'public.imported_events'::regclass AND NOT indisvalid)
      FROM public.imported_events;
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.imported_events;
      """
    Then the following SQL on "target" returns "0":
      """
      SELECT count(*) FROM pg_index
      WHERE indrelid = 'public.imported_events'::regclass AND NOT indisvalid;
      """

    Examples:
      | source_major | target_major |
      | 16 | 17 |
      | 16 | 18 |
      | 17 | 18 |
