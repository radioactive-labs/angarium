module Angarium
  module Dispatch
    module_function

    def call(event_name, payload, owner:)
      endpoints = Endpoint.enabled.where(owner: owner).select do |endpoint|
        endpoint.subscribed_to?(event_name)
      end
      return nil if endpoints.empty?

      Event.transaction do
        event = Event.create!(name: event_name, payload: payload)
        endpoints.each { |endpoint| event.deliveries.create!(endpoint: endpoint) }
        event
      end
    end
  end
end
