# This migration comes from angarium (originally 20260704000003)
class CreateAngariumDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_deliveries, id: Angarium.primary_key_type do |t|
      t.references :event, null: false, type: Angarium.primary_key_type, foreign_key: {to_table: :angarium_events}
      # index: false — the endpoint-scoped delivery list orders by created_at, so
      # the composite index below covers both the FK lookup and the list order.
      t.references :endpoint, index: false, null: false, type: Angarium.primary_key_type, foreign_key: {to_table: :angarium_endpoints}
      t.string :state, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      # A manual ping!/redeliver! delivery whose next attempt bypasses the
      # endpoint status guard. Persisted (not just a job arg) so the reaper can
      # honor it when re-running an attempt that was stranded before completing;
      # cleared once a recorded failure schedules a retry.
      t.boolean :forced, null: false, default: false
      t.datetime :last_attempt_at
      t.datetime :next_attempt_at
      t.timestamps
      # Endpoint-scoped list endpoint (WHERE endpoint_id ORDER BY created_at DESC).
      t.index [:endpoint_id, :created_at], name: "idx_angarium_deliveries_on_endpoint_created_at"
      # Stalled-delivery reaper: WHERE state = 'delivering' AND last_attempt_at < ?.
      t.index [:state, :last_attempt_at], name: "idx_angarium_deliveries_on_state_last_attempt"
    end
  end
end
