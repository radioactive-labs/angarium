require "test_helper"
require "ipaddr"

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
    endpoint = build(signing_secret: "explicit")
    endpoint.save!
    assert_equal "explicit", endpoint.signing_secret
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
      assert endpoint.update(active: false), endpoint.errors.full_messages.to_sentence
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

  test "regenerate_signing_secret! rotates and persists a new secret" do
    endpoint = build.tap(&:save!)
    old = endpoint.signing_secret
    returned = endpoint.regenerate_signing_secret!

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
end
