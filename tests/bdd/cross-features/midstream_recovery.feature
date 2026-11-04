@cross-major @midstream_recovery
Feature: A late remote page error leaves both PostgreSQL clusters usable

  Scenario Outline: PostgreSQL <source_major> to <target_major> rolls back target storage and releases the source after a late rejection
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION pageinspect;
      CREATE EXTENSION pg_visibility;
      CREATE TABLE public.events(id integer PRIMARY KEY) WITH (autovacuum_enabled = false);
      INSERT INTO public.events SELECT generate_series(1, 10000);
      """
    And the following SQL is executed on "source":
      """
      VACUUM (FREEZE) public.events;
      """
    And the following SQL is executed on "source":
      """
      CREATE FUNCTION legacy_xmin(regclass) RETURNS void
        AS '$libdir/pc_bdd_fixtures', 'pc_test_legacy_xmin' LANGUAGE C STRICT;
      SELECT legacy_xmin('public.events');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY);
      INSERT INTO public.events VALUES (99);
      CREATE TABLE public.saved_storage AS
      SELECT oid, relfilenode FROM pg_class
      WHERE oid = 'public.events'::regclass
         OR oid IN (SELECT indexrelid FROM pg_index WHERE indrelid = 'public.events'::regclass);
      """
    Then the following SQL on "source" returns "t|t":
      """
      SELECT pg_relation_size('public.events') > 8192,
             (SELECT t_xmin = '2'::xid FROM heap_page_items(get_raw_page('public.events',
               (pg_relation_size('public.events') / 8192 - 1)::integer)) WHERE lp = 1);
      """
    Then the following SQL on "target" fails with "is not frozen":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|99|t":
      """
      SELECT count(*), min(id),
             (SELECT bool_and(c.relfilenode = s.relfilenode)
              FROM public.saved_storage s JOIN pg_class c USING (oid))
      FROM public.events;
      """
    And the following SQL on "source" returns "10000":
      """
      BEGIN;
      LOCK TABLE public.events IN ACCESS EXCLUSIVE MODE NOWAIT;
      SELECT count(*) FROM public.events;
      ROLLBACK;
      """
    And source PostgreSQL did not crash

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
