class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :null_session

  before_filter :authorize

  def authorize
    unless session[:logged_in] or PasswordHelper::defaulted?
      session[:original_url] = request.original_url # Keep track of this, so we can bounce user back to their original destination on succesful login
      redirect_to '/login'
    end
  end

end
