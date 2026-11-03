@validation @safety-source-checksum
Feature: Source page checksums are verified before rewriting

  Scenario: Export rejects a corrupted source page instead of recomputing its checksum
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION dblink;
      CREATE TABLE public.events(id integer PRIMARY KEY) WITH (autovacuum_enabled = false);
      INSERT INTO public.events VALUES (1);
      """
    And the following SQL is executed on "source":
      """
      VACUUM (FREEZE) public.events;
      """
    And the following SQL is executed on "source":
      """
      CHECKPOINT;
      """
    And the following SQL is executed on "source":
      """
      CREATE FUNCTION pc_test_corrupt_page(regclass, integer, integer)
      RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_page'
      LANGUAGE C STRICT;
      SELECT pc_test_corrupt_page('public.events', 0, 100);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY);
      INSERT INTO public.events VALUES (42);
      """
    Then the following SQL on "source" fails with "checksum":
      """
      BEGIN;
      SELECT pagecopy_internal.pagecopy_lock_source('public.events');
      SELECT dblink_exec('host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres', 'CHECKPOINT');
      SELECT pagecopy_internal.pagecopy_export_stream('public.events', 'public.events', 0::oid, true, true);
      COMMIT;
      """
    And the following SQL on "source" returns "1":
      """
      SELECT count(*) FROM public.events;
      """
    And the following SQL on "target" returns "1|42":
      """
      SELECT count(*), min(id) FROM public.events;
      """
