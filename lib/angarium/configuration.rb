module Angarium
  class Configuration
    attr_accessor :job_queue, :http_timeout, :open_timeout, :user_agent,
                  :retry_schedule, :block_private_ips,
                  :primary_key_type, :max_response_body_bytes,
                  :auto_disable_endpoint_after, :respect_retry_after,
                  :max_retry_after, :retry_jitter, :signing_secret_grace_period

    def initialize
      @job_queue        = :default
      @http_timeout     = 10
      @open_timeout     = 5
      @user_agent       = "Angarium/#{Angarium::VERSION}"
      @retry_schedule   = [1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]
      @block_private_ips = true
      @primary_key_type = nil
      @max_response_body_bytes     = 65_536
      @auto_disable_endpoint_after = nil
      @respect_retry_after         = true
      @max_retry_after             = 3600
      @retry_jitter                = 0.15
      @signing_secret_grace_period = 24.hours
    end
  end
end
