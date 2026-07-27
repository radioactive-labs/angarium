class CreateAngariumDeliveryAttempts < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_delivery_attempts, id: Angarium.primary_key_type do |t|
      # index: false — the delivery-scoped attempt list orders by created_at, so
      # the composite index below covers both the FK lookup and the list order.
      t.references :delivery, index: false, null: false, type: Angarium.primary_key_type, foreign_key: {to_table: :angarium_deliveries}
      t.integer :response_code
      t.text :response_body
      t.string :error
      t.float :duration
      t.timestamps
      # Delivery-scoped attempt list (WHERE delivery_id ORDER BY created_at DESC).
      t.index [:delivery_id, :created_at], name: "idx_angarium_attempts_on_delivery_created_at"
      # Retention prune: DELETE WHERE created_at < cutoff over the largest table.
      t.index :created_at, name: "idx_angarium_attempts_on_created_at"
    end
  end
end
