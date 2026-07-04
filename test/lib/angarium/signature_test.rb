require "test_helper"

class Angarium::SignatureTest < ActiveSupport::TestCase
  test "sign then verify round-trips" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    assert_match(/\At=1000,v1=[0-9a-f]{64}\z/, header)
    assert Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 1_100)
  end

  test "rejects tampered payload" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    refute Angarium::Signature.verify(payload: "TAMPERED", header: header, secret: "shh", now: 1_100)
  end

  test "rejects wrong secret" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    refute Angarium::Signature.verify(payload: "body", header: header, secret: "nope", now: 1_100)
  end

  test "rejects stale timestamp beyond tolerance" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    refute Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 9_999, tolerance: 300)
  end

  test "rejects future timestamp beyond tolerance" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 10_000)
    refute Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 1_000, tolerance: 300)
  end

  test "accepts timestamp within tolerance on either side" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    assert Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 1_200, tolerance: 300)
    assert Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 800, tolerance: 300)
  end

  test "rejects malformed header" do
    refute Angarium::Signature.verify(payload: "body", header: "garbage", secret: "shh", now: 1_000)
  end

  test "single-secret sign still produces one v1 and verifies" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    assert_equal 1, header.scan("v1=").size
    assert Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 1_100)
  end

  test "signing with an array of secrets yields two distinct v1 values" do
    header = Angarium::Signature.sign(payload: "body", secret: %w[old new], timestamp: 1_000)
    _ts, v1s = Angarium::Signature.parse(header)
    assert_equal 2, v1s.size
    assert_equal v1s, v1s.uniq
    assert_match(/\At=1000,v1=[0-9a-f]{64},v1=[0-9a-f]{64}\z/, header)
  end

  test "verify succeeds for a receiver holding either rotated secret" do
    header = Angarium::Signature.sign(payload: "body", secret: %w[old new], timestamp: 1_000)
    assert Angarium::Signature.verify(payload: "body", header: header, secret: "old", now: 1_100)
    assert Angarium::Signature.verify(payload: "body", header: header, secret: "new", now: 1_100)
    refute Angarium::Signature.verify(payload: "body", header: header, secret: "other", now: 1_100)
  end

  test "parse collects all valid v1 values and returns an array" do
    ts, v1s = Angarium::Signature.parse("t=1000,v1=#{"a" * 64},v1=#{"b" * 64}")
    assert_equal 1000, ts
    assert_equal ["a" * 64, "b" * 64], v1s
  end

  test "parse drops malformed v1 values but keeps valid ones" do
    _ts, v1s = Angarium::Signature.parse("t=1000,v1=nope,v1=#{"c" * 64}")
    assert_equal ["c" * 64], v1s
  end

  test "parse returns nil when no valid v1 remains" do
    assert_nil Angarium::Signature.parse("t=1000,v1=nope")
    assert_nil Angarium::Signature.parse("t=abc,v1=#{"a" * 64}")
  end
end
