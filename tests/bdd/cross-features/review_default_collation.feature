@cross-major @validation @review-default-collation
Feature: Database-default collation identity must be provable

  Scenario Outline: PostgreSQL <source_major> to <target_major> rejects different default ICU locales
    Given a fresh PostgreSQL <source_major> to <target_major> pair with default ICU locales "de-u-co-phonebk" and "sv"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer, payload text PRIMARY KEY);
      INSERT INTO public.events VALUES (1, 'ä'), (2, 'z');
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT coalesce(row_to_json(pg_database)->>'daticulocale',
                      row_to_json(pg_database)->>'datlocale') = 'de-u-co-phonebk'
         AND NOT EXISTS (
           SELECT 1 FROM pg_collation WHERE collname = 'de-u-co-phonebk'
         )
      FROM pg_database WHERE datname = current_database();
      """
    When the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer, payload text PRIMARY KEY);
      INSERT INTO public.events VALUES (42, 'kept');
      """
    Then the following SQL on "target" returns "t":
      """
      SELECT coalesce(row_to_json(pg_database)->>'daticulocale',
                      row_to_json(pg_database)->>'datlocale') = 'sv'
         AND NOT EXISTS (
           SELECT 1 FROM pg_collation WHERE collname = 'sv'
         )
      FROM pg_database WHERE datname = current_database();
      """
    Then the following SQL on "target" fails with "collation":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|42|kept":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

    Examples:
      | source_major | target_major |
      | 15           | 16           |
      | 15           | 17           |
      | 15           | 18           |
      | 16           | 17           |
      | 16           | 18           |
      | 17           | 18           |
