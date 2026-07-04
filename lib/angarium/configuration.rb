module Angarium
  class Configuration
    attr_accessor :job_queue, :http_timeout, :user_agent,
                  :retry_schedule, :signature_header, :block_private_ips

    def initialize
      @job_queue        = :default
      @http_timeout     = 10
      @user_agent       = "Angarium/#{Angarium::VERSION}"
      @retry_schedule   = [1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]
      @signature_header = "X-Angarium-Signature"
      @block_private_ips = true
    end
  end
end
