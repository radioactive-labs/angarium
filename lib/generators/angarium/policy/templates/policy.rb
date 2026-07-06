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

  # SSRF controls, gated independently (default off). allow_private_network
  # relaxes the private-IP block (dangerous, operators only); allowed_networks
  # only restricts delivery to a CIDR allowlist (safe to expose more widely).
  # def permit_allow_private_network? = current_user.admin?
  # def permit_allowed_networks? = true

  # Per-action permissions. rotate_secret?/pause?/enable?/ping?/redeliver? all
  # default to update?.
  # def index?   = true
  # def show?    = true
  # def create?  = true
  # def update?  = true
  # def destroy? = true
end
