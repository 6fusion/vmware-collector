
class SessionsController < ApplicationController
  include PasswordHelper

  skip_before_filter :authorize


  def create
    if ( PasswordHelper::valid?(params[:password]) )
      session[:logged_in] = true
      url = case
            when session[:original_url].blank? then '/'
            when session[:original_url].match(%r|/login|) then '/'
            else session[:original_url]
            end
      redirect_to url
    else
      redirect_to(login_url)
    end
  end

  def destroy
    session.delete(:original_url)
    session[:logged_in] = false
    respond_to do |format|
      format.html { puts "redirecitng"; redirect_to '/login' }
      format.json { puts "jsoning"; render json: { url: login_url } }
    end
  end


end



