@cross-major @core
Feature: Upward physical transfer across PostgreSQL majors

  Scenario Outline: PostgreSQL <source_major> to <target_major> preserves heap, TOAST, NULL, dropped columns and btree with checksums <checksums> and WAL <wal>
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text, note text);
      ALTER TABLE public.events ALTER COLUMN payload SET STORAGE EXTERNAL;
      ALTER TABLE public.events ADD COLUMN obsolete text;
      ALTER TABLE public.events DROP COLUMN obsolete;
      INSERT INTO public.events
      SELECT i, repeat('payload-' || i, 1000), CASE WHEN i % 2 = 0 THEN 'even' END
      FROM generate_series(1, 40) AS i;
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
        'public.events', 'public.imported_events', <wal>
      );
      """
    Then the following SQL on "target" returns "40|391000|20":
      """
      SELECT count(*), sum(length(payload)), count(*) FILTER (WHERE note IS NULL)
      FROM public.imported_events;
      """
    And the following SQL on "target" returns "20|10000|even":
      """
      SET enable_seqscan = off;
      SELECT id, length(payload), note FROM public.imported_events WHERE id = 20;
      """
    And the following SQL on "target" contains "Index Only Scan":
      """
      SET enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT id FROM public.imported_events WHERE id = 20;
      """
    And the following SQL on "target" returns "0|1":
      """
      SELECT (SELECT count(*) FROM verify_heapam('public.imported_events')),
             (SELECT count(*) FROM (
                SELECT bt_index_check('public.imported_events_pkey', true) AS result
              ) AS checked);
      """

    Examples:
      | source_major | target_major | checksums | wal   |
      | 13           | 14           | enabled   | true |
      | 13           | 14           | enabled   | false |
      | 13           | 14           | disabled   | true |
      | 13           | 14           | disabled   | false |
      | 13           | 15           | enabled   | true |
      | 13           | 15           | enabled   | false |
      | 13           | 15           | disabled   | true |
      | 13           | 15           | disabled   | false |
      | 13           | 16           | enabled   | true |
      | 13           | 16           | enabled   | false |
      | 13           | 16           | disabled   | true |
      | 13           | 16           | disabled   | false |
      | 13           | 17           | enabled   | true |
      | 13           | 17           | enabled   | false |
      | 13           | 17           | disabled   | true |
      | 13           | 17           | disabled   | false |
      | 13           | 18           | enabled   | true |
      | 13           | 18           | enabled   | false |
      | 13           | 18           | disabled   | true |
      | 13           | 18           | disabled   | false |
      | 14           | 15           | enabled   | true |
      | 14           | 15           | enabled   | false |
      | 14           | 15           | disabled   | true |
      | 14           | 15           | disabled   | false |
      | 14           | 16           | enabled   | true |
      | 14           | 16           | enabled   | false |
      | 14           | 16           | disabled   | true |
      | 14           | 16           | disabled   | false |
      | 14           | 17           | enabled   | true |
      | 14           | 17           | enabled   | false |
      | 14           | 17           | disabled   | true |
      | 14           | 17           | disabled   | false |
      | 14           | 18           | enabled   | true |
      | 14           | 18           | enabled   | false |
      | 14           | 18           | disabled   | true |
      | 14           | 18           | disabled   | false |
      | 15           | 16           | enabled   | true |
      | 15           | 16           | enabled   | false |
      | 15           | 16           | disabled   | true |
      | 15           | 16           | disabled   | false |
      | 15           | 17           | enabled   | true |
      | 15           | 17           | enabled   | false |
      | 15           | 17           | disabled   | true |
      | 15           | 17           | disabled   | false |
      | 15           | 18           | enabled   | true |
      | 15           | 18           | enabled   | false |
      | 15           | 18           | disabled   | true |
      | 15           | 18           | disabled   | false |
      | 16           | 17           | enabled   | true |
      | 16           | 17           | enabled   | false |
      | 16           | 17           | disabled   | true |
      | 16           | 17           | disabled   | false |
      | 16           | 18           | enabled   | true |
      | 16           | 18           | enabled   | false |
      | 16           | 18           | disabled   | true |
      | 16           | 18           | disabled   | false |
      | 17           | 18           | enabled   | true |
      | 17           | 18           | enabled   | false |
      | 17           | 18           | disabled   | true |
      | 17           | 18           | disabled   | false |

  Scenario Outline: Built-in <type> values survive a <source_major> to <target_major> transfer
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload <type>);
      INSERT INTO public.events VALUES (1, <value>);
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
    Then the following SQL on "target" returns "1|<expected>":
      """
      SELECT id, payload::text FROM public.imported_events;
      """

    Examples:
      | source_major | target_major | type         | value                              | expected                    |
      | 13           | 14           | numeric(10,3)| 12.340                             | 12.340                      |
      | 13           | 14           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 13           | 14           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 13           | 14           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 13           | 14           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 13           | 14           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 13           | 14           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 13           | 14           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 13           | 14           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 13           | 14           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 13           | 14           | varbit       | B'1010'                            | 1010                        |
      | 13           | 15           | numeric(10,3)| 12.340                             | 12.340                      |
      | 13           | 15           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 13           | 15           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 13           | 15           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 13           | 15           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 13           | 15           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 13           | 15           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 13           | 15           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 13           | 15           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 13           | 15           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 13           | 15           | varbit       | B'1010'                            | 1010                        |
      | 13           | 16           | numeric(10,3)| 12.340                             | 12.340                      |
      | 13           | 16           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 13           | 16           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 13           | 16           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 13           | 16           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 13           | 16           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 13           | 16           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 13           | 16           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 13           | 16           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 13           | 16           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 13           | 16           | varbit       | B'1010'                            | 1010                        |
      | 13           | 17           | numeric(10,3)| 12.340                             | 12.340                      |
      | 13           | 17           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 13           | 17           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 13           | 17           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 13           | 17           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 13           | 17           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 13           | 17           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 13           | 17           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 13           | 17           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 13           | 17           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 13           | 17           | varbit       | B'1010'                            | 1010                        |
      | 13           | 18           | numeric(10,3)| 12.340                             | 12.340                      |
      | 13           | 18           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 13           | 18           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 13           | 18           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 13           | 18           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 13           | 18           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 13           | 18           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 13           | 18           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 13           | 18           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 13           | 18           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 13           | 18           | varbit       | B'1010'                            | 1010                        |
      | 14           | 15           | numeric(10,3)| 12.340                             | 12.340                      |
      | 14           | 15           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 14           | 15           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 14           | 15           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 14           | 15           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 14           | 15           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 14           | 15           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 14           | 15           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 14           | 15           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 14           | 15           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 14           | 15           | varbit       | B'1010'                            | 1010                        |
      | 14           | 16           | numeric(10,3)| 12.340                             | 12.340                      |
      | 14           | 16           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 14           | 16           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 14           | 16           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 14           | 16           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 14           | 16           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 14           | 16           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 14           | 16           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 14           | 16           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 14           | 16           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 14           | 16           | varbit       | B'1010'                            | 1010                        |
      | 14           | 17           | numeric(10,3)| 12.340                             | 12.340                      |
      | 14           | 17           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 14           | 17           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 14           | 17           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 14           | 17           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 14           | 17           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 14           | 17           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 14           | 17           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 14           | 17           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 14           | 17           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 14           | 17           | varbit       | B'1010'                            | 1010                        |
      | 14           | 18           | numeric(10,3)| 12.340                             | 12.340                      |
      | 14           | 18           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 14           | 18           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 14           | 18           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 14           | 18           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 14           | 18           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 14           | 18           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 14           | 18           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 14           | 18           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 14           | 18           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 14           | 18           | varbit       | B'1010'                            | 1010                        |
      | 15           | 16           | numeric(10,3)| 12.340                             | 12.340                      |
      | 15           | 16           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 15           | 16           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 15           | 16           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 15           | 16           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 15           | 16           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 15           | 16           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 15           | 16           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 15           | 16           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 15           | 16           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 15           | 16           | varbit       | B'1010'                            | 1010                        |
      | 15           | 17           | numeric(10,3)| 12.340                             | 12.340                      |
      | 15           | 17           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 15           | 17           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 15           | 17           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 15           | 17           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 15           | 17           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 15           | 17           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 15           | 17           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 15           | 17           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 15           | 17           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 15           | 17           | varbit       | B'1010'                            | 1010                        |
      | 15           | 18           | numeric(10,3)| 12.340                             | 12.340                      |
      | 15           | 18           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 15           | 18           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 15           | 18           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 15           | 18           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 15           | 18           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 15           | 18           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 15           | 18           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 15           | 18           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 15           | 18           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 15           | 18           | varbit       | B'1010'                            | 1010                        |
      | 16           | 17           | numeric(10,3)| 12.340                             | 12.340                      |
      | 16           | 17           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 16           | 17           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 16           | 17           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 16           | 17           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 16           | 17           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 16           | 17           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 16           | 17           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 16           | 17           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 16           | 17           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 16           | 17           | varbit       | B'1010'                            | 1010                        |
      | 16           | 18           | numeric(10,3)| 12.340                             | 12.340                      |
      | 16           | 18           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 16           | 18           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 16           | 18           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 16           | 18           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 16           | 18           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 16           | 18           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 16           | 18           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 16           | 18           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 16           | 18           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 16           | 18           | varbit       | B'1010'                            | 1010                        |
      | 17           | 18           | numeric(10,3)| 12.340                             | 12.340                      |
      | 17           | 18           | uuid         | '11111111-2222-3333-4444-555555555555' | 11111111-2222-3333-4444-555555555555 |
      | 17           | 18           | jsonb        | '[1,2]'::jsonb                    | [1, 2]                      |
      | 17           | 18           | timestamptz  | '2024-01-02 03:04:05+00'           | 2024-01-02 03:04:05+00      |
      | 17           | 18           | bytea        | decode('0102', 'hex')              | \x0102                      |
      | 17           | 18           | inet         | '192.168.1.1/24'                   | 192.168.1.1/24              |
      | 17           | 18           | integer[]    | ARRAY[1, 2]                        | {1,2}                       |
      | 17           | 18           | text[]       | ARRAY['a', 'b']                    | {a,b}                       |
      | 17           | 18           | tsvector     | 'b:2 a:1'::tsvector                | 'a':1 'b':2                 |
      | 17           | 18           | pg_lsn       | '0/16B6C50'::pg_lsn                | 0/16B6C50                   |
      | 17           | 18           | varbit       | B'1010'                            | 1010                        |
