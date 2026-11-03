@cross-major @modern_type_rejection
Feature: Types absent on an older major cannot be silently reinterpreted

  Scenario: PostgreSQL 14 to 13 is rejected before multirange values can be reinterpreted
    Given a fresh PostgreSQL 14 to 13 pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload int4multirange);
      INSERT INTO public.events VALUES (1, '{[1,3),[5,7)}'::int4multirange);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text);
      INSERT INTO public.events VALUES (99, 'kept');
      """
    Then the following SQL on "target" fails with "unsupported PostgreSQL major pair 14 -> 13":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|99|kept":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """
    And source PostgreSQL did not crash
