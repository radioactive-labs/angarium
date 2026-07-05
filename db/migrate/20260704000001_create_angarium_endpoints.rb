class CreateAngariumEndpoints < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_endpoints, id: Angarium.primary_key_type do |t|
      t.references :owner, polymorphic: true, null: false, type: :string
      t.string :name, null: false
      t.string :url, null: false
      t.string :status, null: false, default: "enabled"
      t.text :signing_secret, null: false
      t.json :subscribed_events, null: false, default: []
      t.boolean :allow_private_network, null: false, default: false
      t.json :allowed_networks, null: false, default: []
      t.json :custom_headers, null: false, default: {}
      t.integer :consecutive_failures, null: false, default: 0
      t.text :previous_signing_secret
      t.datetime :secret_rotated_at
      t.datetime :status_changed_at
      t.timestamps
    end
  end
end
