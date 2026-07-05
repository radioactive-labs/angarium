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

      # May the API set allow_private_network? Default: no. This *relaxes* SSRF
      # protection (delivery to private/loopback addresses), so an end user who
      # can set it can point a webhook at your internal network. Trusted operators
      # only.
      def permit_allow_private_network?
        false
      end

      # May the API set allowed_networks (a per-endpoint CIDR allowlist)? Default:
      # no. Unlike allow_private_network this only *restricts* where an endpoint
      # may deliver, so it's safe to expose more widely, but it's gated
      # independently so you can allow it without allowing the private-network
      # relaxation.
      def permit_allowed_networks?
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
