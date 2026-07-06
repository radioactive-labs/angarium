class Owner < ActiveRecord::Base
  has_many :webhook_endpoints, as: :owner, class_name: "Angarium::Endpoint"
end
