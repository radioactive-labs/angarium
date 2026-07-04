require "test_helper"

class Angarium::EventMatcherTest < ActiveSupport::TestCase
  test "exact match" do
    assert Angarium::EventMatcher.match?("invoice.paid", "invoice.paid")
    refute Angarium::EventMatcher.match?("invoice.paid", "invoice.void")
  end

  test "catch-all" do
    assert Angarium::EventMatcher.match?("*", "anything.happened")
  end

  test "prefix wildcard" do
    assert Angarium::EventMatcher.match?("invoice.*", "invoice.paid")
    refute Angarium::EventMatcher.match?("invoice.*", "user.created")
  end
end
