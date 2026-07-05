module Angarium
  module Api
    # Base authorization policy for the JSON API.
    #
    # Angarium instantiates `config.policy_class` per request with the controller
    # and the record the action targets (an Endpoint, a Delivery, or nil for
    # collection actions), then calls `<action_name>?`. It runs in the
    # controller's context, so `current_user`, `params`, and `controller` are
    # available.
    #
    # Every action defaults to allowed; the endpoint scope already isolates
    # records to the current user, so subclass and override to *restrict* (e.g. a
    # read-only role, or admin-only deletes). Return truthy to permit, falsey to
    # get a 403.
    class Policy
      attr_reader :controller, :record

      def initialize(controller, record)
        @controller = controller
        @record = record
      end

      def current_user = controller.angarium_current_user
      def params = controller.params

      def index? = true
      def show? = true
      def create? = true
      def update? = true
      def destroy? = true

      # Endpoint member actions default to the same capability as update?.
      def rotate_secret? = update?
      def pause? = update?
      def enable? = update?
      def ping? = update?

      # Delivery actions.
      def redeliver? = update?
    end
  end
end
