require "test_helper"

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

  test "allows a private URL when the endpoint allowlists that range" do
    endpoint = build(url: "https://10.1.2.5/hook", allowed_networks: ["10.1.2.0/24"])
    assert endpoint.valid?, endpoint.errors.full_messages.to_sentence
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
