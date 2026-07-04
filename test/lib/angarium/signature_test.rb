require "test_helper"
require "base64"

class Angarium::SignatureTest < ActiveSupport::TestCase
  # Standard Webhooks conformance vector (https://www.standardwebhooks.com).
  # This exact input/output MUST match byte-for-byte so receivers can verify
  # with any off-the-shelf standardwebhooks/Svix library.
  test "matches the Standard Webhooks canonical test vector" do
    signature = Angarium::Signature.sign(
      payload: '{"test": 2432232314}',
      id: "msg_p5jXN8AQM9LWM0D4loKWxJek",
      timestamp: 1614265330,
      secret: "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
    )
    assert_equal "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=", signature
  end

  def secret
    "whsec_#{Base64.strict_encode64("0" * 32)}"
  end

  test "sign then verify round-trips" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: secret)
    assert_match(%r{\Av1,[A-Za-z0-9+/=]+\z}, sig)
    assert Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: secret, now: 1_100
    )
  end

  test "rejects tampered payload" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: secret)
    refute Angarium::Signature.verify(
      payload: "TAMPERED", id: "1", timestamp: 1_000, signature: sig, secret: secret, now: 1_100
    )
  end

  test "rejects wrong secret" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: secret)
    other = "whsec_#{Base64.strict_encode64("1" * 32)}"
    refute Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: other, now: 1_100
    )
  end

  test "rejects stale timestamp beyond tolerance" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: secret)
    refute Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: secret, now: 9_999, tolerance: 300
    )
  end

  test "rejects future timestamp beyond tolerance" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 10_000, secret: secret)
    refute Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 10_000, signature: sig, secret: secret, now: 1_000, tolerance: 300
    )
  end

  test "accepts timestamp within tolerance on either side" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: secret)
    assert Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: secret, now: 1_200, tolerance: 300
    )
    assert Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: secret, now: 800, tolerance: 300
    )
  end

  test "rejects a non-numeric timestamp" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: secret)
    refute Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: "abc", signature: sig, secret: secret, now: 1_000
    )
  end

  test "rejects a malformed signature header" do
    refute Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 1_000, signature: "garbage", secret: secret, now: 1_000
    )
  end

  test "single-secret sign produces one v1 token and verifies" do
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: secret)
    assert_equal 1, sig.split(" ").size
    assert Angarium::Signature.verify(
      payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: secret, now: 1_100
    )
  end

  test "signing with an array of secrets yields two space-delimited v1 tokens" do
    a = "whsec_#{Base64.strict_encode64("a" * 32)}"
    b = "whsec_#{Base64.strict_encode64("b" * 32)}"
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: [a, b])
    tokens = sig.split(" ")
    assert_equal 2, tokens.size
    assert tokens.all? { |t| t.start_with?("v1,") }
    assert_equal tokens, tokens.uniq
  end

  test "verify succeeds for a receiver holding either rotated secret" do
    a = "whsec_#{Base64.strict_encode64("a" * 32)}"
    b = "whsec_#{Base64.strict_encode64("b" * 32)}"
    c = "whsec_#{Base64.strict_encode64("c" * 32)}"
    sig = Angarium::Signature.sign(payload: "body", id: "1", timestamp: 1_000, secret: [a, b])
    assert Angarium::Signature.verify(payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: a, now: 1_100)
    assert Angarium::Signature.verify(payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: b, now: 1_100)
    refute Angarium::Signature.verify(payload: "body", id: "1", timestamp: 1_000, signature: sig, secret: c, now: 1_100)
  end

  test "parse keeps the base64 payload of each v1 token and drops others" do
    assert_equal ["abc", "def"], Angarium::Signature.parse("v1,abc v1,def")
    assert_equal ["abc"], Angarium::Signature.parse("v1,abc v2,def")
    assert_equal [], Angarium::Signature.parse("garbage")
  end
end
