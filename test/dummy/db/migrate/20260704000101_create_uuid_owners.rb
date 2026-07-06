class CreateUuidOwners < ActiveRecord::Migration[7.1]
  def change
    create_table :uuid_owners, id: :string do |t|
      t.string :name
      t.timestamps
    end
  end
end
