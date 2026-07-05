require "openssl"
require "base64"

module Angarium
  module Signature
    module_function

    # secret may be a String or Array of secrets (dual-secret rotation grace);
    # produces one `v1,<base64>` token per secret, space-delimited.
    def sign(payload:, id:, timestamp:, secret:)
      Array(secret).map { |s| "v1,#{signature_for(s, id, timestamp, payload)}" }.join(" ")
    end

    # Verify a Standard Webhooks signature. Pass the fields explicitly, or pass a
    # Rails `request:` and Angarium pulls the raw body and webhook-* headers for
    # you, so a receiver is a one-liner:
    #
    #   Angarium::Signature.verify(request:, secret: endpoint.signing_secret)
    #
    def verify(secret:, request: nil, payload: nil, id: nil, timestamp: nil, signature: nil,
      tolerance: 300, now: Time.now.to_i)
      if request
        payload ||= request.raw_post
        id ||= request.headers["webhook-id"]
        timestamp ||= request.headers["webhook-timestamp"]
        signature ||= request.headers["webhook-signature"]
      end

      return false unless timestamp.to_s.match?(/\A\d+\z/)
      return false if (now - timestamp.to_i).abs > tolerance

      expected = signature_for(secret, id, timestamp.to_i, payload)
      parse(signature).any? { |sig| secure_compare(expected, sig) }
    end

    def signature_for(secret, id, timestamp, payload)
      key = Base64.decode64(secret.to_s.delete_prefix("whsec_"))
      digest = OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{payload}")
      Base64.strict_encode64(digest)
    end

    # webhook-signature is space-delimited `v1,<base64>` tokens; keep the base64
    # payload of each v1 token.
    def parse(header)
      header.to_s.split(" ").filter_map { |token|
        version, sig = token.split(",", 2)
        sig if version == "v1" && sig && !sig.empty?
      }
    end

    def secure_compare(a, b)
      ActiveSupport::SecurityUtils.secure_compare(a, b)
    rescue ArgumentError
      false
    end
  end
end
