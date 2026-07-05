# Authorization for Angarium's JSON API. Enable it with
#   config.policy_class = "<%= class_name %>"
# in config/initializers/angarium.rb.
#
# The policy runs in the controller's context, so `current_user`, `params`, and
# `controller` are available. Override only what you need; the inherited defaults
# are permissive and single-owner (a user sees and manages their own endpoints).
class <%= class_name %> < Angarium::Api::Policy
  # Narrow the base relation to the endpoints this user may see and act on.
  # def scope(relation)
  #   relation.where(owner: current_user)
  # end

  # Owner for a newly-created endpoint. Override to create on behalf of another
  # owner (read a param), then gate who may do so in #create?.
  # def owner
  #   current_user
  # end

  # Per-action permissions. rotate_secret?/pause?/enable?/ping?/redeliver? all
  # default to update?.
  # def index?   = true
  # def show?    = true
  # def create?  = true
  # def update?  = true
  # def destroy? = true
end
