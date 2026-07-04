require "openssl"

module Angarium
  module Signature
    module_function

    def sign(payload:, secret:, timestamp: Time.now.to_i)
      digest = hexdigest(secret, timestamp, payload)
      "t=#{timestamp},v1=#{digest}"
    end

    def verify(payload:, header:, secret:, tolerance: 300, now: Time.now.to_i)
      parsed = parse(header)
      return false unless parsed

      timestamp, signature = parsed
      return false if (now - timestamp).abs > tolerance

      expected = hexdigest(secret, timestamp, payload)
      secure_compare(expected, signature)
    end

    def hexdigest(secret, timestamp, payload)
      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{payload}")
    end

    def parse(header)
      parts = header.to_s.split(",").filter_map { |kv|
        k, v = kv.split("=", 2)
        [k, v] if k && v
      }.to_h
      t = parts["t"]
      v1 = parts["v1"]
      return nil unless t&.match?(/\A\d+\z/) && v1&.match?(/\A[0-9a-f]{64}\z/)

      [t.to_i, v1]
    end

    def secure_compare(a, b)
      ActiveSupport::SecurityUtils.secure_compare(a, b)
    rescue ArgumentError
      false
    end
  end
end
