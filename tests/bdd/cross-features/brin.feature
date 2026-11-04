@cross-major @brin
Feature: Approved BRIN indexes transfer across major upgrades

  The core ordinary minmax opclasses on the approved fixed-width types have
  a stable metapage, revmap and summary envelope across PostgreSQL 13-18,
  so they cross every upward pair as page images.

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers an approved multi-range BRIN index with checksums <checksums> and WAL <wal>
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id bigint,
        ts timestamptz,
        note text
      );
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      CREATE INDEX events_id ON public.events USING brin (id);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i * 30),
             repeat('payload-' || i, 20)
      FROM generate_series(1, 5000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', <wal>
      );
      """
    Then the following SQL on "target" returns "2|2|0":
      """
      SELECT count(*),
             count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid OR NOT indisready)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """
    And the following SQL on "target" returns "t|t":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_id'::regclass);
      """
    And the following SQL on "target" returns "49|2501|5000":
      """
      SELECT count(*) FILTER (WHERE ts < timestamptz '2024-01-01 00:25:00'),
             count(*) FILTER (WHERE id BETWEEN 1000 AND 3500),
             count(*)
      FROM public.events;
      """
    And the following SQL on "target" returns "50":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.events
      WHERE ts BETWEEN timestamptz '2024-01-01' AND timestamptz '2024-01-01 00:25:00';
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-02' + make_interval(secs => i), 'new'
      FROM generate_series(5001, 5500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.events;
      """
    Then the following SQL on "target" returns "2621":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.events
      WHERE ts >= timestamptz '2024-01-02' AND ts < timestamptz '2024-01-03';
      ROLLBACK;
      """

    Examples:
      | source_major | target_major | checksums | wal   |
      | 13           | 14           | enabled   | true  |
      | 13           | 15           | enabled   | true  |
      | 13           | 16           | enabled   | true  |
      | 13           | 17           | enabled   | true  |
      | 13           | 18           | enabled   | true  |
      | 13           | 18           | disabled  | true  |
      | 13           | 18           | disabled  | false |
      | 14           | 15           | enabled   | true  |
      | 14           | 16           | enabled   | true  |
      | 14           | 17           | enabled   | true  |
      | 14           | 18           | enabled   | true  |
      | 15           | 16           | enabled   | true  |
      | 15           | 17           | enabled   | true  |
      | 15           | 18           | enabled   | true  |
      | 16           | 17           | enabled   | true  |
      | 16           | 18           | enabled   | true  |
      | 17           | 18           | enabled   | true  |

  Scenario: PG14+ bloom and minmax-multi BRIN opclasses degrade instead of transferring
    Given a fresh PostgreSQL 18 to 18 pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.modern (id bigint, ts timestamptz);
      CREATE INDEX modern_multi ON public.modern USING brin (id int8_minmax_multi_ops);
      CREATE INDEX modern_ts ON public.modern USING brin (ts timestamptz_bloom_ops);
      INSERT INTO public.modern
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i)
      FROM generate_series(1, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.modern', 'public.modern', true
      );
      """
    Then the following SQL on "target" returns "2|2":
      """
      SELECT count(*), count(*) FILTER (WHERE NOT indisvalid AND NOT indisready)
      FROM pg_index WHERE indrelid = 'public.modern'::regclass;
      """
    And the following SQL on "source" contains "brin opclass":
      """
      SELECT detail FROM pagecopy.check('public.modern')
      WHERE name LIKE 'modern_multi%' AND type = 'index';
      """
    And the following SQL on "source" contains "brin opclass":
      """
      SELECT detail FROM pagecopy.check('public.modern')
      WHERE name LIKE 'modern_ts%' AND type = 'index';
      """
