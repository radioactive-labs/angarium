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

      Resolv.getaddresses(host).filter_map { |a| to_ipaddr(a) }
    rescue StandardError
      []
    end

    def private?(ip)
      ip.loopback? || ip.private? || ip.link_local? ||
        (ip.respond_to?(:unique_local?) && ip.unique_local?)
    end

    def cidr_include?(cidr, ip)
      IPAddr.new(cidr.to_s).include?(ip)
    rescue IPAddr::InvalidAddressError
      false
    end

    def to_ipaddr(value)
      return value if value.is_a?(IPAddr)
      IPAddr.new(value.to_s)
    rescue IPAddr::InvalidAddressError
      nil
    end
  end
end
