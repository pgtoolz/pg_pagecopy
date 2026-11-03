Feature: Extension privileges and production build safety
  Background:
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """

  Scenario: Debug GUCs are not public extension configuration
    Then the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW debug_corrupt_page;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW debug_disable_lz4;
      """

  Scenario: Non-superusers cannot probe or stream source relations
    Given the following SQL is executed on "source":
      """
      CREATE TABLE events (id integer);
      CREATE ROLE loader LOGIN;
      GRANT USAGE ON SCHEMA pagecopy_internal TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy_internal.pagecopy_lock_source(text) TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy_internal.pagecopy_export_schema(text) TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy_internal.pagecopy_export_stream(text, text, oid, boolean, boolean, boolean) TO loader;
      """
    Then the following SQL on "source" fails with "physical source export requires superuser":
      """
      SET ROLE loader;
      SELECT pagecopy_internal.pagecopy_lock_source('public.events');
      """
    And the following SQL on "source" fails with "physical source export requires superuser":
      """
      SET ROLE loader;
      SELECT pagecopy_internal.pagecopy_export_schema('public.events');
      """
    And the following SQL on "source" fails with "physical source export requires superuser":
      """
      SET ROLE loader;
      SELECT pagecopy_internal.pagecopy_export_stream('public.events', 'public.events', 0, false, false, false);
      """

  Scenario: An import operator cannot replace another owner's target
    Given the following SQL is executed on "source":
      """
      CREATE TABLE events (id integer);
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE events (id integer);
      CREATE ROLE loader LOGIN;
      GRANT EXECUTE ON FUNCTION pagecopy.pull(text, text, text, boolean) TO loader;
      """
    Then the following SQL on "target" fails with "target table must be owned by the current user":
      """
      SET ROLE loader;
      SELECT pagecopy.pull('host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres', 'public.events', 'public.events', false);
      """

  Scenario: A trusted target owner can import through a source superuser
    Given the following SQL is executed on "source":
      """
      CREATE TABLE events (id integer);
      INSERT INTO events VALUES (1);
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE events (id integer);
      CREATE ROLE loader LOGIN;
      ALTER TABLE events OWNER TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy.pull(text, text, text, boolean) TO loader;
      """
    When the following SQL is executed on "target":
      """
      SET ROLE loader;
      SELECT pagecopy.pull('host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres', 'public.events', 'public.events', false);
      """
    Then the following SQL on "target" returns "1":
      """
      SELECT id FROM public.events;
      """

  Scenario: Frozen clone grants cannot bypass source authorization
    Given the following SQL is executed on "source":
      """
      CREATE TABLE events (id integer);
      CREATE ROLE loader LOGIN;
      GRANT USAGE ON SCHEMA pagecopy_internal TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy_internal.pagecopy_export_stream(text, text, oid, boolean, boolean, boolean) TO loader;
      SELECT pagecopy_internal.pagecopy_lock_source('public.events');
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE events (id integer);
      CREATE ROLE loader LOGIN;
      ALTER TABLE events OWNER TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy.pull(text, text, text, boolean) TO loader;
      """
    Then the following SQL on "target" fails with "permission denied for function":
      """
      SET ROLE loader;
      SELECT pagecopy.pull('host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=loader', 'public.events', 'public.events', false);
      """

  Scenario: Ownership change while waiting for target lock is rechecked
    Given the following SQL is executed on "source":
      """
      CREATE TABLE events (id integer, payload text);
      INSERT INTO events VALUES (1, 'payload');
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE events (id integer, payload text);
      CREATE ROLE loader LOGIN;
      ALTER TABLE events OWNER TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy.pull(text, text, text, boolean) TO loader;
      """
    When target ownership changes during the following SQL on "target":
      """
      SELECT pg_sleep(1);
      SELECT pagecopy.pull('host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres', 'public.events', 'public.events', false);
      """
    Then the following SQL on "target" returns "postgres":
      """
      SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.events'::regclass;
      """

  Scenario: Source connection establishment honors connect_timeout
    Given the following SQL is executed on "target":
      """
      CREATE TABLE events (id integer);
      """
    When an import to a blackholed source times out on "target"

