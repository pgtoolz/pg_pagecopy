Feature: Production build excludes test-only debug hooks
  Scenario: Every debug GUC is unavailable without test-hooks
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_corrupt_page;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_corrupt_offset;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_corrupt_page_relation;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_corrupt_index_metapage_offset;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_corrupt_index_ordinal;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_drop_index_page_relation;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_drop_index_page_block;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_hold_brin_page_block;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      SHOW pagecopy.debug_disable_lz4;
      """
