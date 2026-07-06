class CreateAngariumEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_events, id: Angarium.primary_key_type do |t|
      t.string :name, null: false
      t.json :payload, null: false, default: {}
      t.timestamps
    end
  end
end
