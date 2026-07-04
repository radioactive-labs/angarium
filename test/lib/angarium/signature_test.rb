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

  test "rejects malformed header" do
    refute Angarium::Signature.verify(payload: "body", header: "garbage", secret: "shh", now: 1_000)
  end
end
