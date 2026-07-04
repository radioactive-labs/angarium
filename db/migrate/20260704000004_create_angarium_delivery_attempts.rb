class CreateAngariumDeliveryAttempts < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_delivery_attempts do |t|
      t.references :delivery, null: false, foreign_key: { to_table: :angarium_deliveries }
      t.integer :response_code
      t.text :response_body
      t.string :error
      t.float :duration
      t.timestamps
    end
  end
end
