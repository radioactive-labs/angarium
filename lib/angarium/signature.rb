require "openssl"

module Angarium
  module Signature
    module_function

    def sign(payload:, secret:, timestamp: Time.now.to_i)
      digests = Array(secret).map { |s| "v1=#{hexdigest(s, timestamp, payload)}" }
      "t=#{timestamp},#{digests.join(",")}"
    end

    def verify(payload:, header:, secret:, tolerance: 300, now: Time.now.to_i)
      parsed = parse(header)
      return false unless parsed

      timestamp, signatures = parsed
      return false if (now - timestamp).abs > tolerance

      expected = hexdigest(secret, timestamp, payload)
      signatures.any? { |signature| secure_compare(expected, signature) }
    end

    def hexdigest(secret, timestamp, payload)
      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{payload}")
    end

    def parse(header)
      pairs = header.to_s.split(",").filter_map { |kv|
        k, v = kv.split("=", 2)
        [k, v] if k && v
      }
      t = pairs.find { |k, _| k == "t" }&.last
      v1s = pairs.select { |k, _| k == "v1" }.map(&:last).select { |v| v.match?(/\A[0-9a-f]{64}\z/) }
      return nil unless t&.match?(/\A\d+\z/) && v1s.any?

      [t.to_i, v1s]
    end

    def secure_compare(a, b)
      ActiveSupport::SecurityUtils.secure_compare(a, b)
    rescue ArgumentError
      false
    end
  end
end
