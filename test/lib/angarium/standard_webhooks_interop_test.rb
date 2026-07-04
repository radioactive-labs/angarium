require "test_helper"
require "standardwebhooks"

# Real bidirectional interop against the official `standardwebhooks` library —
# proves our signatures aren't just spec-shaped but actually accepted by (and
# accept) the gem receivers will use. Complements the canonical-vector test in
# signature_test.rb (which guards the byte-exact algorithm with no dependency).
class Angarium::StandardWebhooksInteropTest < ActiveSupport::TestCase
  setup do
    @secret  = "whsec_#{[SecureRandom.bytes(32)].pack("m0")}"
    @id      = "msg_interop_1"
    @ts      = Time.now.to_i # fresh: the gem enforces a 5-minute tolerance
    @payload = %q({"event":"invoice.paid","data":{"id":42}})
    @wh      = StandardWebhooks::Webhook.new(@secret)
  end

  test "an Angarium signature verifies with the official standardwebhooks gem" do
    signature = Angarium::Signature.sign(payload: @payload, id: @id, timestamp: @ts, secret: @secret)
    headers = { "webhook-id" => @id, "webhook-timestamp" => @ts.to_s, "webhook-signature" => signature }
    assert_nothing_raised { @wh.verify(@payload, headers) }
  end

  test "Angarium verifies a signature produced by the standardwebhooks gem" do
    signature = @wh.sign(@id, @ts, @payload)
    assert Angarium::Signature.verify(payload: @payload, id: @id, timestamp: @ts, signature: signature, secret: @secret)
  end

  test "Angarium rejects a gem signature over a tampered body" do
    signature = @wh.sign(@id, @ts, @payload)
    refute Angarium::Signature.verify(payload: "#{@payload} ", id: @id, timestamp: @ts, signature: signature, secret: @secret)
  end
end
