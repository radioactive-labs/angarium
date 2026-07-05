require "test_helper"
require "ipaddr"
require "base64"

class Angarium::EndpointTest < ActiveSupport::TestCase
  setup { @owner = Owner.create!(name: "Acme") }

  def build(attrs = {})
    Angarium::Endpoint.new({
      owner: @owner, name: "prod", url: "https://example.test/hook",
      subscribed_events: ["*"]
    }.merge(attrs))
  end

  test "generates a signing_secret on create when blank" do
    endpoint = build
    assert_nil endpoint.signing_secret
    endpoint.save!
    assert endpoint.signing_secret.present?
    assert_operator endpoint.signing_secret.length, :>=, 32
  end

  test "keeps a provided signing_secret" do
    explicit = "whsec_#{Base64.strict_encode64("0" * 32)}"
    endpoint = build(signing_secret: explicit)
    endpoint.save!
    assert_equal explicit, endpoint.signing_secret
  end

  test "generated signing_secret uses the Standard Webhooks whsec_ format" do
    endpoint = build.tap(&:save!)
    assert_match(/\Awhsec_/, endpoint.signing_secret)
  end

  test "signing_secret is encrypted at rest and transparently decrypted" do
    endpoint = build.tap(&:save!)
    plaintext = endpoint.signing_secret
    assert plaintext.present?

    raw = ActiveRecord::Base.connection_pool.with_connection do |c|
      c.select_value("SELECT signing_secret FROM angarium_endpoints WHERE id = #{endpoint.id}")
    end
    refute_equal plaintext, raw, "stored value must not be the plaintext secret"
    assert_includes raw, "\"p\":", "expected Active Record Encryption envelope in the DB"

    assert_equal plaintext, endpoint.reload.signing_secret, "must decrypt transparently on read"
  end

  test "custom_headers is encrypted at rest (may carry a bearer token) and decrypts transparently" do
    endpoint = build(custom_headers: { "Authorization" => "Bearer s3kret" }).tap(&:save!)

    raw = ActiveRecord::Base.connection_pool.with_connection do |c|
      c.select_value("SELECT custom_headers FROM angarium_endpoints WHERE id = #{endpoint.id}")
    end
    refute_includes raw.to_s, "Bearer s3kret", "the bearer token must not be stored in plaintext"
    assert_includes raw.to_s, "\"p\":", "expected Active Record Encryption envelope in the DB"

    assert_equal({ "Authorization" => "Bearer s3kret" }, endpoint.reload.custom_headers,
      "must decrypt transparently on read")
  end

  test "requires https" do
    endpoint = build(url: "http://example.test/hook")
    refute endpoint.valid?
    assert_includes endpoint.errors[:url].join, "https"
  end

  test "rejects private/loopback hosts when block_private_ips is on" do
    endpoint = build(url: "https://127.0.0.1/hook")
    refute endpoint.valid?
  end

  test "allows private hosts when block_private_ips is off" do
    Angarium.config.stub(:block_private_ips, false) do
      endpoint = build(url: "https://127.0.0.1/hook")
      assert endpoint.valid?
    end
  end

  test "subscribed_to? honors patterns" do
    endpoint = build(subscribed_events: ["invoice.*", "user.created"])
    assert endpoint.subscribed_to?("invoice.paid")
    assert endpoint.subscribed_to?("user.created")
    refute endpoint.subscribed_to?("user.deleted")
  end

  test "updating an unrelated attribute does not re-run the address check" do
    endpoint = build(url: "https://93.184.216.34/hook").tap(&:save!)
    # Even if the host would now resolve to a disallowed address, an unrelated
    # update (url/allowlist/allow_private unchanged) must not re-validate it.
    Angarium::AddressPolicy.stub(:resolve, [IPAddr.new("10.0.0.1")]) do
      assert endpoint.update(status: :paused), endpoint.errors.full_messages.to_sentence
    end
  end

  test "changing the url re-runs the address check" do
    endpoint = build(url: "https://93.184.216.34/hook").tap(&:save!)
    endpoint.url = "https://10.0.0.1/hook"
    refute endpoint.valid?
    assert_includes endpoint.errors[:url].join, "disallowed"
  end

  test "turning off allow_private_network re-validates the url" do
    endpoint = build(url: "https://10.1.2.5/hook", allow_private_network: true).tap(&:save!)
    endpoint.allow_private_network = false
    refute endpoint.valid?
    assert_includes endpoint.errors[:url].join, "disallowed"
  end

  test "tightening allowed_networks re-validates the url" do
    endpoint = build(url: "https://93.184.216.34/hook").tap(&:save!)
    endpoint.allowed_networks = ["10.0.0.0/8"] # public IP no longer within the allowlist
    refute endpoint.valid?
    assert_includes endpoint.errors[:url].join, "disallowed"
  end

  test "rotate_signing_secret! rotates and persists a new secret" do
    endpoint = build.tap(&:save!)
    old = endpoint.signing_secret
    returned = endpoint.rotate_signing_secret!

    refute_equal old, endpoint.signing_secret
    assert_equal endpoint.signing_secret, returned
    assert_equal returned, endpoint.reload.signing_secret
    assert_operator returned.length, :>=, 32
  end

  test "a private URL needs allow_private_network even if allowlisted" do
    only_allowlist = build(url: "https://10.1.2.5/hook", allowed_networks: ["10.1.2.0/24"])
    refute only_allowlist.valid?

    with_flag = build(url: "https://10.1.2.5/hook", allow_private_network: true, allowed_networks: ["10.1.2.0/24"])
    assert with_flag.valid?, with_flag.errors.full_messages.to_sentence
  end

  test "allows a private URL when allow_private_network is set" do
    endpoint = build(url: "https://10.1.2.5/hook", allow_private_network: true)
    assert endpoint.valid?, endpoint.errors.full_messages.to_sentence
  end

  test "rejects invalid CIDR entries in allowed_networks" do
    endpoint = build(allowed_networks: ["not-a-cidr"])
    refute endpoint.valid?
    assert_includes endpoint.errors[:allowed_networks].join, "invalid CIDR"
  end

  test "accepts a string=>string custom_headers hash and an empty default" do
    assert build(custom_headers: { "Authorization" => "Bearer x" }).valid?
    assert build.valid?
  end

  test "rejects custom_headers with non-string keys or values" do
    endpoint = build(custom_headers: { "X-Count" => 3 })
    refute endpoint.valid?
    assert_includes endpoint.errors[:custom_headers].join, "hash of string keys and values"
  end

  test "rejects custom_headers that override a transport header" do
    endpoint = build(custom_headers: { "Content-Type" => "text/plain" })
    refute endpoint.valid?
    assert_includes endpoint.errors[:custom_headers].join, "reserved or transport headers"
  end

  test "rejects custom_headers that override a signature header" do
    endpoint = build(custom_headers: { "webhook-signature" => "x" })
    refute endpoint.valid?
    assert_includes endpoint.errors[:custom_headers].join, "reserved or transport headers"
  end

  test "reserved custom_headers denylist is case-insensitive" do
    endpoint = build(custom_headers: { "HOST" => "evil" })
    refute endpoint.valid?
    assert_includes endpoint.errors[:custom_headers].join, "reserved or transport headers"
  end

  test "allows a normal custom_headers entry alongside the denylist" do
    assert build(custom_headers: { "Authorization" => "Bearer x" }).valid?
  end

  test "rotate_signing_secret! records the previous secret and rotation time" do
    endpoint = build.tap(&:save!)
    old = endpoint.signing_secret
    endpoint.rotate_signing_secret!

    assert_equal old, endpoint.previous_signing_secret
    assert endpoint.secret_rotated_at.present?
  end

  test "active_signing_secrets includes the previous secret only within grace" do
    endpoint = build.tap(&:save!)
    old = endpoint.signing_secret
    new = endpoint.rotate_signing_secret!

    assert_equal [new, old], endpoint.active_signing_secrets

    endpoint.update!(secret_rotated_at: 2.days.ago)
    assert_equal [new], endpoint.active_signing_secrets
  end

  test "record_delivery_failure! disables the endpoint at the configured threshold" do
    endpoint = build.tap(&:save!)
    Angarium.config.stub(:auto_disable_endpoint_after, 1) do
      endpoint.record_delivery_failure!
    end
    assert endpoint.disabled?
    assert endpoint.status_changed_at.present?
    assert_equal 1, endpoint.consecutive_failures
  end

  test "a new endpoint is enabled by default" do
    assert build.tap(&:save!).enabled?
  end

  test "pause! stops deliveries and enable! resumes them" do
    endpoint = build.tap(&:save!)

    endpoint.pause!
    assert endpoint.paused?
    assert endpoint.status_changed_at.present?
    assert_empty Angarium::Endpoint.enabled

    endpoint.enable!
    assert endpoint.enabled?
    assert_equal [endpoint], Angarium::Endpoint.enabled.to_a
  end

  test "enable! revives a disabled endpoint and clears the failure counter" do
    endpoint = build.tap(&:save!)
    Angarium.config.stub(:auto_disable_endpoint_after, 1) do
      endpoint.record_delivery_failure!
    end
    assert endpoint.disabled?

    endpoint.enable!
    assert endpoint.enabled?
    assert_equal 0, endpoint.consecutive_failures
  end

  test "record_delivery_success! clears consecutive_failures" do
    endpoint = build.tap(&:save!)
    endpoint.update!(consecutive_failures: 3)
    endpoint.record_delivery_success!
    assert_equal 0, endpoint.consecutive_failures
  end
end
