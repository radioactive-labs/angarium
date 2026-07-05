require "httpx"

module Angarium
  # Thin wrapper over HTTPX. Returns a plain result struct so callers/tests
  # never touch HTTPX response objects directly. Note: HTTPX does NOT follow
  # redirects unless the :follow_redirects plugin is enabled, so we intentionally
  # leave it disabled so a 3xx to an internal URL can't bypass SSRF checks.
  class Client
    Result = Struct.new(:success, :code, :body, :error, :duration, :headers) do
      def success? = success
    end

    def post(url, body:, headers:, addresses: nil)
      conn = self.class.connection
      conn = conn.with(addresses: addresses) if addresses && !addresses.empty?

      started = monotonic
      response = conn.post(url, body: body, headers: headers)
      duration = monotonic - started

      if response.is_a?(HTTPX::ErrorResponse)
        return Result.new(success: false,
          error: "#{response.error.class}: #{response.error.message}",
          duration: duration,
          headers: {})
      end

      max = Angarium.config.max_response_body_bytes
      body = response.body.to_s
      body = body.byteslice(0, max) if max

      Result.new(
        success: (200..299).cover?(response.status),
        code: response.status,
        body: body,
        duration: duration,
        headers: response.headers.to_h.transform_keys(&:downcase)
      )
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def self.connection
      HTTPX.with(
        headers: {"user-agent" => Angarium.config.user_agent, "content-type" => "application/json"},
        timeout: {
          connect_timeout: Angarium.config.open_timeout,
          read_timeout: Angarium.config.http_timeout
        }
      )
    end
  end
end
