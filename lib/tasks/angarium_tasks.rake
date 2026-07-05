namespace :angarium do
  desc "Prune delivery attempts older than Angarium.config.delivery_attempt_retention"
  task prune: :environment do
    retention = Angarium.config.delivery_attempt_retention
    abort "Set Angarium.config.delivery_attempt_retention (e.g. 90.days) before pruning." unless retention
    count = Angarium::DeliveryAttempt.prune(older_than: retention)
    puts "Angarium: pruned #{count} delivery attempt(s) older than #{retention.inspect}."
  end

  desc "Requeue deliveries stuck in the delivering state past Angarium.config.delivering_timeout"
  task reap: :environment do
    count = Angarium::Delivery.reap_stalled
    puts "Angarium: requeued #{count} stalled deliver(y/ies)."
  end
end
