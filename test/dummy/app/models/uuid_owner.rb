class UuidOwner < ActiveRecord::Base
  self.primary_key = "id"
  before_create { self.id ||= SecureRandom.uuid }
  has_many :webhook_endpoints, as: :owner, class_name: "Angarium::Endpoint"
end
