Feature: Local table clone inside a single database
  The same-page pipeline as the cross-instance import, but inside one
  postmaster: pagecopy.clone keeps original xids valid in the shared xid
  space, so it never runs VACUUM (FREEZE) and instead inherits the source
  freeze horizons on the target.

  Background:
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """

  @local
  Scenario: Local clone transfers TOAST and btree pages
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text NOT NULL,
        note text
      );
      INSERT INTO public.events
        SELECT i, repeat(md5(i::text), 700), CASE WHEN i % 2 = 0 THEN 'even' ELSE 'odd' END
        FROM generate_series(1, 500) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.events', 'public.events_copy', true);
      """
    Then the following SQL on "target" returns "500|500|700|even":
      """
      SELECT (SELECT count(*) FROM public.events_copy)
          || '|' || (SELECT count(*) FROM public.events_copy WHERE id BETWEEN 1 AND 500)
          || '|' || (SELECT length(payload) / 32 FROM public.events_copy WHERE id = 42)
          || '|' || (SELECT note FROM public.events_copy WHERE id = 42);
      """

  @local
  Scenario: Local clone transfers unfrozen tuples without VACUUM FREEZE
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.warm (id integer PRIMARY KEY, value text NOT NULL);
      INSERT INTO public.warm VALUES (1, 'one');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.warm', 'public.warm_copy', false);
      """
    Then the following SQL on "target" returns "1|one|t|true":
      """
      SELECT (SELECT count(*) FROM public.warm_copy)
          || '|' || (SELECT value FROM public.warm_copy WHERE id = 1)
          || '|' || (SELECT bool_and(xmin::text::bigint > 2) FROM public.warm_copy)
          || '|' || (SELECT count(*) = 0 FROM pg_stat_activity
                      WHERE query LIKE '%VACUUM (FREEZE)%' AND state = 'active'
                        AND pid <> pg_backend_pid());
      """

  @local
  Scenario: Local clone inherits freeze horizons and keeps every xid
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.unfrozen (id integer PRIMARY KEY, value text NOT NULL);
      INSERT INTO public.unfrozen
      SELECT i, 'v' || i FROM generate_series(1, 50) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.unfrozen', 'public.unfrozen_copy', true);
      """
    Then the following SQL on "target" returns "t|t|t|t|50":
      """
      SELECT (SELECT relfrozenxid = (SELECT relfrozenxid FROM pg_class
                                     WHERE oid = 'public.unfrozen'::regclass)
              FROM pg_class WHERE oid = 'public.unfrozen_copy'::regclass)
          || '|' || (SELECT relminmxid = (SELECT relminmxid FROM pg_class
                                          WHERE oid = 'public.unfrozen'::regclass)
                     FROM pg_class WHERE oid = 'public.unfrozen_copy'::regclass)
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT id, xmin FROM public.unfrozen
                 EXCEPT SELECT id, xmin FROM public.unfrozen_copy)
                UNION ALL
                (SELECT id, xmin FROM public.unfrozen_copy
                 EXCEPT SELECT id, xmin FROM public.unfrozen)) delta)
          || '|' || (SELECT bool_and(xmin::text::bigint > 2) FROM public.unfrozen_copy)
          || '|' || (SELECT count(*) FROM public.unfrozen_copy);
      """
    And the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.unfrozen_copy;
      """
    Then the following SQL on "target" returns "50":
      """
      SELECT count(*) FROM public.unfrozen_copy;
      """

  @local
  Scenario: Local clone without WAL keeps rows readable
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.small (id integer PRIMARY KEY, value text NOT NULL);
      INSERT INTO public.small VALUES (1, 'one'), (2, 'two');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.small', 'public.small_copy', false);
      """
    Then the following SQL on "target" returns "2|two":
      """
      SELECT (SELECT count(*) FROM public.small_copy)
          || '|' || (SELECT value FROM public.small_copy WHERE id = 2);
      """

  @local
  Scenario: Local clone rejects the source table as its own target
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.self (id integer PRIMARY KEY);
      INSERT INTO public.self VALUES (1);
      """
    Then the following SQL on "target" fails with "must differ from the source table":
      """
      SELECT pagecopy.clone('public.self', 'public.self', true);
      """
