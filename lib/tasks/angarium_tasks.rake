namespace :angarium do
  desc "Prune delivery attempts older than Angarium.config.delivery_attempt_retention"
  task prune: :environment do
    retention = Angarium.config.delivery_attempt_retention
    abort "Set Angarium.config.delivery_attempt_retention (e.g. 90.days) before pruning." unless retention
    count = Angarium::DeliveryAttempt.prune(older_than: retention)
    puts "Angarium: pruned #{count} delivery attempt(s) older than #{retention.inspect}."
  end
end
