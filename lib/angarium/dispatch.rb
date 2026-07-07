module Angarium
  module Dispatch
    module_function

    def call(event_name, payload, owner:)
      notify_payload = {event: event_name, event_id: nil, deliveries: 0}
      ActiveSupport::Notifications.instrument("dispatch.angarium", notify_payload) do
        # Load only the columns subscription matching needs. Endpoints carry
        # large encrypted blobs (signing_secret, previous_signing_secret,
        # custom_headers); pulling them for every candidate — most of which may
        # not even match — is wasted I/O. The matched endpoints' secrets are
        # loaded later, at delivery time, from the delivery's own association.
        candidates = Endpoint.enabled.where(owner: owner).select(:id, :subscribed_events)
        endpoints = candidates.to_a.select { |endpoint| endpoint.subscribed_to?(event_name) }
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
