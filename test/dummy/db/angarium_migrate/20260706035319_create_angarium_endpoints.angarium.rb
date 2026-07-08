# This migration comes from angarium (originally 20260704000001)
class CreateAngariumEndpoints < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_endpoints, id: Angarium.primary_key_type do |t|
      # index: false — the owner scope also orders by created_at, so the
      # composite index below covers both the tenancy filter and the list order.
      t.references :owner, polymorphic: true, null: false, type: :string, index: false
      t.string :name, null: false
      # text, not string: a string column is VARCHAR(255) on MySQL, which would
      # truncate/reject URLs the app validates up to config.max_url_length (2048).
      t.text :url, null: false
      t.string :status, null: false, default: "enabled"
      t.text :signing_secret, null: false
      t.json :subscribed_events, null: false
      t.boolean :allow_private_network, null: false, default: false
      t.json :allowed_networks, null: false
      # Encrypted at rest (may hold a receiver credential), so it's nullable with
      # no DB default — an unencrypted default would fail to decrypt on read.
      t.json :custom_headers
      t.integer :consecutive_failures, null: false, default: 0
      t.text :previous_signing_secret
      t.datetime :secret_rotated_at
      t.datetime :status_changed_at
      t.timestamps
      # Serves the owner-scoped list endpoint (WHERE owner_type/owner_id ORDER BY
      # created_at DESC) in a single index scan.
      t.index [:owner_type, :owner_id, :created_at], name: "idx_angarium_endpoints_on_owner_created_at"
    end
  end
end
