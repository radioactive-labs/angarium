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

      unless AddressPolicy.host_permitted_for_validation?(uri.host, record)
        record.errors.add(attribute, "resolves to a disallowed address")
      end
    end
  end
end
