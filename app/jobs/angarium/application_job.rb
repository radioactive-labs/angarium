module Angarium
  class ApplicationJob < ActiveJob::Base
    queue_as { Angarium.config.job_queue }
  end
end
