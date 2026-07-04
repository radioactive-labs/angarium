require "resolv"

module Angarium
  class EndpointUrlValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      uri = begin
        URI.parse(value.to_s)
      rescue URI::InvalidURIError
        nil
      end

      unless uri.is_a?(URI::HTTPS) && uri.host.present?
        record.errors.add(attribute, "must be a valid https URL")
        return
      end

      if Angarium.config.block_private_ips && private_host?(uri.host)
        record.errors.add(attribute, "must not point to a private or loopback address")
      end
    end

    private

    def private_host?(host)
      addresses(host).any? do |ip|
        ip.loopback? || ip.private? || ip.link_local? ||
          (ip.respond_to?(:unique_local?) && ip.unique_local?)
      end
    end

    def addresses(host)
      ([host] + resolve(host)).filter_map do |candidate|
        IPAddr.new(candidate)
      rescue IPAddr::InvalidAddressError
        nil
      end
    end

    def resolve(host)
      Resolv.getaddresses(host)
    rescue StandardError
      []
    end
  end
end
