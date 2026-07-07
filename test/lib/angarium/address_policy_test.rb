require "test_helper"
require "ipaddr"

class Angarium::AddressPolicyTest < ActiveSupport::TestCase
  Endpoint = Struct.new(:allow_private_network, :allowed_networks)

  def endpoint(allow_private_network: false, allowed_networks: [])
    Endpoint.new(allow_private_network:, allowed_networks:)
  end

  test "blocks private IPs by default" do
    refute Angarium::AddressPolicy.ip_allowed?("127.0.0.1", endpoint)
    refute Angarium::AddressPolicy.ip_allowed?("10.0.0.5", endpoint)
    refute Angarium::AddressPolicy.ip_allowed?("169.254.169.254", endpoint)
  end

  test "allows public IPs by default" do
    assert Angarium::AddressPolicy.ip_allowed?("93.184.216.34", endpoint)
  end

  test "allow_private_network bypasses the denylist" do
    assert Angarium::AddressPolicy.ip_allowed?("10.0.0.5", endpoint(allow_private_network: true))
    # ...and still allows public
    assert Angarium::AddressPolicy.ip_allowed?("93.184.216.34", endpoint(allow_private_network: true))
  end

  test "allowlist is authoritative: only listed CIDRs allowed" do
    ep = endpoint(allowed_networks: ["203.0.113.0/24"])
    assert Angarium::AddressPolicy.ip_allowed?("203.0.113.10", ep)
    refute Angarium::AddressPolicy.ip_allowed?("93.184.216.34", ep) # public but not listed
  end

  test "allowlist alone does NOT permit a private range" do
    ep = endpoint(allowed_networks: ["10.1.2.0/24"])
    refute Angarium::AddressPolicy.ip_allowed?("10.1.2.5", ep)
  end

  test "whitelisting a private range requires allow_private_network too" do
    ep = endpoint(allow_private_network: true, allowed_networks: ["10.1.2.0/24"])
    assert Angarium::AddressPolicy.ip_allowed?("10.1.2.5", ep)
    # private, allowed by the flag, but outside the allowlist -> still blocked
    refute Angarium::AddressPolicy.ip_allowed?("10.9.9.9", ep)
  end

  test "respects config.block_private_ips = false" do
    Angarium.config.stub(:block_private_ips, false) do
      assert Angarium::AddressPolicy.ip_allowed?("10.0.0.5", endpoint)
    end
  end

  test "blocks IPv4-mapped IPv6 loopback and link-local (SSRF bypass)" do
    refute Angarium::AddressPolicy.ip_allowed?("::ffff:127.0.0.1", endpoint)
    refute Angarium::AddressPolicy.ip_allowed?("::ffff:169.254.169.254", endpoint)
    refute Angarium::AddressPolicy.ip_allowed?("::ffff:10.0.0.1", endpoint)
  end

  test "blocks the unspecified address" do
    refute Angarium::AddressPolicy.ip_allowed?("0.0.0.0", endpoint)
    refute Angarium::AddressPolicy.ip_allowed?("::", endpoint)
  end

  test "blocks IANA special-use ranges that IPAddr predicates miss (SSRF bypass)" do
    {
      "0.0.0.1" => "0.0.0.0/8 routes to localhost on Linux",
      "100.64.0.1" => "CGNAT (RFC 6598)",
      "192.0.0.1" => "IETF protocol assignments",
      "198.18.0.1" => "benchmarking (RFC 2544)",
      "240.0.0.1" => "reserved/future use",
      "255.255.255.255" => "limited broadcast",
      "64:ff9b::a9fe:a9fe" => "NAT64 of 169.254.169.254 (cloud metadata)"
    }.each do |ip, why|
      refute Angarium::AddressPolicy.ip_allowed?(ip, endpoint), "expected #{ip} (#{why}) to be blocked"
    end
  end

  test "special-use ranges do not misfire on legitimate public addresses" do
    ["203.0.113.10", "93.184.216.34", "8.8.8.8", "2606:4700:4700::1111"].each do |ip|
      assert Angarium::AddressPolicy.ip_allowed?(ip, endpoint), "expected #{ip} to be allowed"
    end
  end

  # Fake resolver capturing the timeout so we can assert DNS lookups are bounded
  # (an unbounded lookup lets a hostile slow-resolving host stall a worker).
  # Resolv calls #each_address on its resolvers, so that's what we implement.
  class FakeDNS
    attr_accessor :timeouts
    def each_address(_host)
      yield Resolv::IPv4.create("203.0.113.9")
    end

    def close = nil
  end

  test "resolve bounds DNS lookups with the configured dns_timeout" do
    fake = FakeDNS.new
    Angarium.config.stub(:dns_timeout, [1, 2]) do
      Resolv::DNS.stub(:new, fake) do
        assert_equal ["203.0.113.9"], Angarium::AddressPolicy.resolve("host.example").map(&:to_s)
      end
    end
    assert_equal [1, 2], fake.timeouts, "the configured DNS timeout must be applied"
  end

  test "resolve returns the literal for an IP without a DNS lookup" do
    Resolv::DNS.stub(:new, ->(*) { raise "must not hit DNS for a literal" }) do
      assert_equal ["203.0.113.10"], Angarium::AddressPolicy.resolve("203.0.113.10").map(&:to_s)
    end
  end

  # Internal endpoints are commonly pinned via /etc/hosts (Docker, k8s); a
  # DNS-only resolver would silently fail to resolve them.
  FakeHosts = Struct.new(:addresses) do
    def each_address(_host)
      addresses.each { |a| yield a }
    end
  end

  test "resolve also consults the hosts file by default" do
    Resolv::Hosts.stub(:new, FakeHosts.new(["10.9.9.9"])) do
      Resolv::DNS.stub(:new, FakeDNS.new) do
        result = Angarium::AddressPolicy.resolve("internal.local").map(&:to_s)
        assert_includes result, "10.9.9.9"
      end
    end
  end

  test "resolve skips the hosts file when resolve_dns_with_hosts_file is disabled" do
    Angarium.config.stub(:resolve_dns_with_hosts_file, false) do
      Resolv::Hosts.stub(:new, ->(*) { raise "hosts file must not be consulted" }) do
        Resolv::DNS.stub(:new, FakeDNS.new) do
          assert_equal ["203.0.113.9"], Angarium::AddressPolicy.resolve("host.example").map(&:to_s)
        end
      end
    end
  end

  test "host_permitted_for_validation? blocks a host that resolves to a disallowed IP" do
    # 127.0.0.1 is an IP literal; resolve returns [127.0.0.1] which is loopback
    refute Angarium::AddressPolicy.host_permitted_for_validation?("127.0.0.1", endpoint)
    # unresolvable host -> [] -> all? -> true (lenient at validation; re-checked at delivery)
    assert Angarium::AddressPolicy.host_permitted_for_validation?("does-not-exist.invalid", endpoint)
  end

  test "host_permitted_for_validation? rejects when ANY resolved IP is disallowed" do
    Angarium::AddressPolicy.stub(:resolve, [IPAddr.new("93.184.216.34"), IPAddr.new("10.0.0.1")]) do
      refute Angarium::AddressPolicy.host_permitted_for_validation?("multi.example", endpoint)
    end
  end

  test "host_permitted_for_validation? allows when ALL resolved IPs are allowed" do
    Angarium::AddressPolicy.stub(:resolve, [IPAddr.new("93.184.216.34"), IPAddr.new("8.8.8.8")]) do
      assert Angarium::AddressPolicy.host_permitted_for_validation?("multi.example", endpoint)
    end
  end
end
