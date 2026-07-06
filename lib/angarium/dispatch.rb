module Angarium
  module Dispatch
    module_function

    def call(event_name, payload, owner:)
      notify_payload = {event: event_name, event_id: nil, deliveries: 0}
      ActiveSupport::Notifications.instrument("dispatch.angarium", notify_payload) do
        endpoints = Endpoint.enabled.where(owner: owner).select do |endpoint|
          endpoint.subscribed_to?(event_name)
        end
        next nil if endpoints.empty?

        Event.transaction do
          event = Event.create!(name: event_name, payload: payload)
          endpoints.each { |endpoint| event.deliveries.create!(endpoint: endpoint) }
          notify_payload[:event_id] = event.id
          notify_payload[:deliveries] = endpoints.size
          event
        end
      end
    end
  end
end
