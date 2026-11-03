Feature: Local clone durability and interruption

  @local @wal @slow
  Scenario: WAL local clone recovers unfrozen tuples after a target crash
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.crash_source (id integer PRIMARY KEY, payload text)
      WITH (autovacuum_enabled = false);
      INSERT INTO public.crash_source
      SELECT i, repeat(md5(i::text), 200) FROM generate_series(1, 2000) i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.crash_source', 'public.crash_copy', true);
      """
    When target postmaster is crashed and restarted
    Then the following SQL on "target" returns "2000|2000|true":
      """
      SELECT count(*)
          || '|' || count(*) FILTER (WHERE length(payload) = 6400)
          || '|' || bool_and(xmin::text::bigint > 2)
      FROM public.crash_copy;
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.crash_copy;
      """
    Then the following SQL on "target" returns "2000":
      """
      SELECT count(*) FROM public.crash_copy;
      """

  @local @slow
  Scenario: No-WAL local clone is durable after a checkpoint and crash
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.nowal_source (id integer PRIMARY KEY, payload text);
      INSERT INTO public.nowal_source
      SELECT i, repeat(md5(i::text), 100) FROM generate_series(1, 1000) i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.nowal_source', 'public.nowal_copy', false);
      CHECKPOINT;
      """
    When target postmaster is crashed and restarted
    Then the following SQL on "target" returns "1000|1000|true":
      """
      SELECT count(*)
          || '|' || count(*) FILTER (WHERE length(payload) = 3200)
          || '|' || bool_and(xmin::text::bigint > 2)
      FROM public.nowal_copy;
      """

  @local @slow
  Scenario: Cancelling a local clone keeps the old target and releases the source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION pgcrypto;
      CREATE TABLE public.cancel_source (id integer PRIMARY KEY, payload text);
      INSERT INTO public.cancel_source
      SELECT i, encode(gen_random_bytes(1000), 'hex') FROM generate_series(1, 20000) i;
      CREATE TABLE public.cancel_target (id integer PRIMARY KEY, payload text);
      INSERT INTO public.cancel_target VALUES (0, 'kept');
      """
    When the following SQL on "target" is cancelled:
      """
      SELECT pagecopy.clone('public.cancel_source', 'public.cancel_target', true);
      """
    Then the following SQL on "target" returns "1|kept":
      """
      SELECT count(*) || '|' || min(payload) FROM public.cancel_target;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      SET LOCAL lock_timeout = '5s';
      LOCK TABLE public.cancel_source IN ACCESS EXCLUSIVE MODE;
      COMMIT;
      """

  @local @slow
  Scenario: Statement timeout rolls back a local clone
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.timeout_source (id integer PRIMARY KEY, payload text);
      INSERT INTO public.timeout_source
      SELECT i, repeat(md5(i::text), 1000) FROM generate_series(1, 10000) i;
      CREATE TABLE public.timeout_target (id integer PRIMARY KEY, payload text);
      INSERT INTO public.timeout_target VALUES (0, 'kept');
      ALTER FUNCTION pagecopy_internal.pagecopy_lock_source(text)
        RENAME TO real_lock_source;
      CREATE FUNCTION pagecopy_internal.pagecopy_lock_source(source_table text)
        RETURNS void LANGUAGE plpgsql AS $function$
      BEGIN
        PERFORM pagecopy_internal.real_lock_source(source_table);
        PERFORM pg_sleep(60);
      END
      $function$;
      """
    Then the following SQL on "target" fails with "canceling statement due to statement timeout":
      """
      SET statement_timeout = '50ms';
      SELECT pagecopy.clone('public.timeout_source', 'public.timeout_target', true);
      """
    Then the following SQL on "target" returns "1|kept":
      """
      SELECT count(*) || '|' || min(payload) FROM public.timeout_target;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      SET LOCAL lock_timeout = '5s';
      LOCK TABLE public.timeout_source IN ACCESS EXCLUSIVE MODE;
      COMMIT;
      """

  @local @checksum
  Scenario: Local clone writes valid checksums while preserving original xids
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.checksum_source (id integer PRIMARY KEY, payload text);
      INSERT INTO public.checksum_source VALUES (1, repeat('checksum', 1000));
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.checksum_source', 'public.checksum_copy', true);
      """
    Then the following SQL on "target" returns "on|1|true|true":
      """
      SELECT current_setting('data_checksums')
          || '|' || (SELECT count(*) FROM public.checksum_copy)
          || '|' || (SELECT bool_and(s.xmin = t.xmin AND t.xmin::text::bigint > 2)
                     FROM public.checksum_source s JOIN public.checksum_copy t USING (id))
          || '|' || ((page_header(get_raw_page('public.checksum_copy', 0))).checksum <> 0);
      """
