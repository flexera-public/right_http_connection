Feature: RightHTTPConnection can connect to a secure web server through a proxy
  In order to access HTTP resources through web proxies in a secure robust fashion
  RightHTTPConnection users should be able to connect to a web server proxy
  And make connections to HTTPS servers from there

  Scenario: normal operation
    Given an HTTPS URL
    And a proxy
    When I request that URL using RightHTTPConnection
    Then I should get the contents of the URL
    And the proxy should have been tunneled through

  Scenario: normal operation with a CA certification file
    Given an HTTPS URL
    And a proxy
    And a CA certification file containing that server
    When I request that URL using RightHTTPConnection
    Then I should get the contents of the URL
    And the proxy should have been tunneled through
    And there should not be a warning about certificate verification failing

  Scenario: man in the middle
    Given an HTTPS URL
    And a proxy
    And a CA certification file not containing that server
    When I request that URL using RightHTTPConnection
    Then I should get the contents of the URL
    And there should be a warning about certificate verification failing
    And the proxy should have been tunneled through

  Scenario: strict man in the middle
    Given an HTTPS URL
    And a proxy
    And a CA certification file not containing that server
    And the strict failure option turned on
    When I request that URL using RightHTTPConnection
    Then I should get an exception
    And the proxy should have been tunneled through
