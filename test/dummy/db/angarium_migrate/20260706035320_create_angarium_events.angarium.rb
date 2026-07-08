# This migration comes from angarium (originally 20260704000002)
class CreateAngariumEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_events, id: Angarium.primary_key_type do |t|
      t.string :name, null: false
      t.json :payload, null: false
      t.timestamps
    end
  end
end
