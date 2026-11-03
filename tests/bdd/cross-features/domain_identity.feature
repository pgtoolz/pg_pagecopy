@cross-major @domain_identity
Feature: Domain identity cannot be assumed across independent clusters

  Scenario Outline: PostgreSQL <source_major> to <target_major> rejects domain-bearing physical values
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE DOMAIN public.positive_int AS integer CHECK (VALUE > 0);
      CREATE TABLE public.events(id integer PRIMARY KEY, unsafe_value public.positive_int);
      INSERT INTO public.events VALUES (1, 42);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE DOMAIN public.positive_int AS integer CHECK (VALUE > 100);
      """
    Then the following SQL on "target" fails with "unsafe type":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.imported_events', true
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('public.imported_events');
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
