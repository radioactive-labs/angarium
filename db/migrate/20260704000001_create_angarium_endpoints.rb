class CreateAngariumEndpoints < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_endpoints do |t|
      t.references :owner, polymorphic: true, null: false
      t.string :name, null: false
      t.string :url, null: false
      t.boolean :active, null: false, default: true
      t.text :signing_secret, null: false
      t.json :subscribed_events, null: false, default: []
      t.boolean :allow_private_network, null: false, default: false
      t.json :allowed_networks, null: false, default: []
      t.timestamps
    end
  end
end
