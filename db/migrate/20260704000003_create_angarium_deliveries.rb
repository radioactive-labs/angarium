class CreateAngariumDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_deliveries, id: Angarium.primary_key_type do |t|
      t.references :event, null: false, type: Angarium.primary_key_type, foreign_key: { to_table: :angarium_events }
      t.references :endpoint, null: false, type: Angarium.primary_key_type, foreign_key: { to_table: :angarium_endpoints }
      t.string :state, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.datetime :last_attempt_at
      t.datetime :next_attempt_at
      t.timestamps
    end
  end
end
