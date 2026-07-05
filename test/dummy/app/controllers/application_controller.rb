class ApplicationController < ActionController::Base
  # Dummy auth for the API request tests: resolve the "current user" (an Owner)
  # from a header so a test can act as a given owner. Real host apps use their
  # own authentication (Devise/Rodauth/etc.).
  def current_user
    @current_user ||= Owner.find_by(id: request.headers["X-Owner-Id"])
  end
end
