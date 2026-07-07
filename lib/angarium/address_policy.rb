require "ipaddr"
require "resolv"

module Angarium
  # Central SSRF policy. Decides whether a destination IP is permitted for a
  # given endpoint, composing three controls:
  #   1. endpoint.allowed_networks (CIDR list) -> if present, ONLY those are allowed
  #   2. endpoint.allow_private_network        -> bypass the private-IP denylist
  #   3. Angarium.config.block_private_ips      -> default denylist of private ranges
  module AddressPolicy
    module_function

    # Is a single IP (String or IPAddr) permitted for this endpoint?
    #
    # Two independent gates, both must pass:
    #   Gate A (private denylist): private/loopback/link-local addresses are
    #     blocked unless endpoint.allow_private_network is set. An allowlist entry
    #     does NOT by itself unlock a private address.
    #   Gate B (allowlist): when endpoint.allowed_networks is non-empty, the
    #     address must fall within one of those CIDRs.
    def ip_allowed?(ip, endpoint)
      ip = to_ipaddr(ip)
      return false unless ip

      if private?(ip) && Angarium.config.block_private_ips
        return false unless endpoint.allow_private_network
      end

      allowlist = Array(endpoint.allowed_networks).reject(&:blank?)
      unless allowlist.empty?
        return false unless allowlist.any? { |cidr| cidr_include?(cidr, ip) }
      end

      true
    end

    # Resolve host and return true only if EVERY resolved address is allowed.
    # Unresolvable hosts return [] and this returns true (can't prove disallowed);
    # callers that need strictness at connect time check each resolved IP instead.
    def host_permitted_for_validation?(host, endpoint)
      resolve(host).all? { |ip| ip_allowed?(ip, endpoint) }
    end

    def resolve(host)
      literal = to_ipaddr(host)
      return [literal] if literal

      # Bound DNS with config.dns_timeout via an explicit Resolv::DNS — an
      # unbounded lookup lets a host with a deliberately slow authoritative
      # nameserver tie up a delivery worker well past our HTTP timeouts. With the
      # hosts file enabled (default), wrap it in a Resolv that consults
      # /etc/hosts first (so an internally-pinned endpoint resolves, and a hosts
      # hit short-circuits DNS); otherwise resolve DNS-only.
      dns = Resolv::DNS.new
      dns.timeouts = Angarium.config.dns_timeout if Angarium.config.dns_timeout
      resolvers = Angarium.config.resolve_dns_with_hosts_file ? [Resolv::Hosts.new, dns] : [dns]
      Resolv.new(resolvers).getaddresses(host).filter_map { |a| to_ipaddr(a.to_s) }
    rescue
      []
    ensure
      dns&.close
    end

    # IANA special-use ranges that are unsafe webhook destinations but that
    # Ruby's IPAddr predicates (loopback?/private?/link_local?/unique_local?) do
    # NOT flag. Without these, e.g. `https://0.0.0.1/` (routes to localhost on
    # Linux) or `https://[64:ff9b::a9fe:a9fe]/` (NAT64 of the cloud metadata IP)
    # would pass validation and be delivered to. Documentation ranges
    # (192.0.2.0/24, 2001:db8::/32, etc.) are intentionally omitted: they aren't
    # an SSRF vector and blocking them would reject the TEST-NET fixtures.
    SPECIAL_USE_RANGES = [
      "0.0.0.0/8",      # "this host" — routes to localhost on Linux
      "100.64.0.0/10",  # CGNAT (RFC 6598)
      "192.0.0.0/24",   # IETF protocol assignments (RFC 6890)
      "198.18.0.0/15",  # benchmarking (RFC 2544)
      "240.0.0.0/4",    # reserved / future use, incl. 255.255.255.255 broadcast
      "64:ff9b::/96",   # NAT64 well-known prefix (RFC 6052)
      "64:ff9b:1::/48"  # NAT64 local-use prefix (RFC 8215)
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    def private?(ip)
      ip = normalize(ip)
      return true if ip.to_i.zero? # 0.0.0.0 / :: (unspecified -> localhost on Linux)

      ip.loopback? || ip.private? || ip.link_local? ||
        (ip.respond_to?(:unique_local?) && ip.unique_local?) ||
        special_use?(ip)
    end

    def special_use?(ip)
      SPECIAL_USE_RANGES.any? { |range| range.family == ip.family && range.include?(ip) }
    end

    # Collapse IPv4-mapped IPv6 (::ffff:x.x.x.x) to native IPv4 so the predicates
    # above see the real address; leave other addresses untouched.
    def normalize(ip)
      ip.respond_to?(:native) ? ip.native : ip
    rescue
      ip
    end

    def cidr_include?(cidr, ip)
      IPAddr.new(cidr.to_s).include?(ip)
    rescue IPAddr::InvalidAddressError
      false
    end

    def to_ipaddr(value)
      ip = value.is_a?(IPAddr) ? value : IPAddr.new(value.to_s)
      normalize(ip)
    rescue IPAddr::InvalidAddressError
      nil
    end
  end
end
