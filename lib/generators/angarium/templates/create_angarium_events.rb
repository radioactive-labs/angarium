class CreateAngariumEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_events, id: Angarium.primary_key_type do |t|
      t.string :name, null: false
      # No DB-level default: MySQL forbids defaults on JSON/TEXT/BLOB columns. The
      # default is set on the model (Event#payload) so null: false holds everywhere.
      t.json :payload, null: false
      t.timestamps
    end
  end
end
