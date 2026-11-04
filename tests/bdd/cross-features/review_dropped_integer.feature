@cross-major @review-dropped-integer
Feature: Dropped fixed-width placeholders preserve physical layout

  Scenario Outline: PostgreSQL <source_major> to <target_major> preserves a dropped integer attribute
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text, obsolete integer);
      ALTER TABLE public.events ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.events VALUES (1, repeat('x', 12000), 99);
      ALTER TABLE public.events DROP COLUMN obsolete;
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
    Then the following SQL on "target" returns "1|12000|4|t":
      """
      SELECT count(*), sum(length(payload)),
             (SELECT attlen FROM pg_attribute
              WHERE attrelid = 'public.imported_events'::regclass AND attnum = 3),
             (SELECT attbyval FROM pg_attribute
              WHERE attrelid = 'public.imported_events'::regclass AND attnum = 3)
      FROM public.imported_events;
      """
    And the following SQL on "target" returns "0|1":
      """
      SELECT (SELECT count(*) FROM verify_heapam('public.imported_events')),
             (SELECT count(*) FROM (
                SELECT bt_index_check('public.imported_events_pkey', true) AS result
              ) AS checked);
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
