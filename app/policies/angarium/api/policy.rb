module Angarium
  module Api
    # The single place for API authorization:
    #   #scope(relation)  narrows a base relation to what this user may see
    #   #owner            who a newly-created endpoint belongs to
    #   #<action>?        whether each action is allowed
    #
    # Angarium instantiates config.policy_class per request with the controller
    # and (for member actions) the target record, and runs it in the controller's
    # context, so `current_user`, `params`, and `controller` are available.
    #
    # Defaults are permissive and single-owner: you see and create your own
    # endpoints and may do anything to them. Subclass and override to change the
    # scope, support multi-tenancy or admin-on-behalf-of, or restrict actions.
    class Policy
      attr_reader :controller, :record

      def initialize(controller, record = nil)
        @controller = controller
        @record = record
      end

      def current_user = controller.angarium_current_user
      def params = controller.params

      # Narrow the given base relation to the endpoints this user may see and act
      # on (reads and finds go through this; deliveries and attempts scope through
      # their endpoint). Receives a relation so you can compose on top of it.
      def scope(relation)
        relation.where(owner: current_user)
      end

      # Owner assigned to a newly-created endpoint. Override to let an admin
      # create on behalf of another owner (e.g. read a param), then gate who may
      # do so in #create? via `record.owner`.
      def owner
        current_user
      end

      # May the API set the SSRF-sensitive network controls (allow_private_network,
      # allowed_networks)? Default: no. They let an endpoint target private and
      # loopback addresses, so expose them only to trusted operators, never end
      # users. When false, create/update silently ignore those attributes.
      def permit_network_controls?
        false
      end

      def index? = true
      def show? = true
      def create? = true
      def update? = true
      def destroy? = true

      def rotate_secret? = update?
      def pause? = update?
      def enable? = update?
      def ping? = update?
      def redeliver? = update?
    end
  end
end
