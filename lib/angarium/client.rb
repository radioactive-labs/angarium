require "httpx"

module Angarium
  # Thin wrapper over HTTPX. Returns a plain result struct so callers/tests
  # never touch HTTPX response objects directly. Note: HTTPX does NOT follow
  # redirects unless the :follow_redirects plugin is enabled — we intentionally
  # leave it disabled so a 3xx to an internal URL can't bypass SSRF checks.
  class Client
    Result = Struct.new(:success, :code, :body, :error, :duration, keyword_init: true) do
      def success? = success
    end

    def post(url, body:, headers:)
      started = monotonic
      response = self.class.connection.post(url, body: body, headers: headers)
      duration = monotonic - started

      if response.is_a?(HTTPX::ErrorResponse)
        return Result.new(success: false,
                          error: "#{response.error.class}: #{response.error.message}",
                          duration: duration)
      end

      Result.new(
        success: (200..299).cover?(response.status),
        code: response.status,
        body: response.body.to_s[0..1500],
        duration: duration
      )
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def self.connection
      HTTPX.with(
        headers: { "user-agent" => Angarium.config.user_agent, "content-type" => "application/json" },
        timeout: {
          connect_timeout: Angarium.config.open_timeout,
          read_timeout: Angarium.config.http_timeout
        }
      )
    end
  end
end
