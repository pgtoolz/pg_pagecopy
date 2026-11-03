Feature: Production build excludes test-only corruption hooks
  Scenario: The corruption GUC is unavailable without test-hooks
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_corrupt_page;
      """
