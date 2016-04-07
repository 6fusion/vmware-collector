require 'global_configuration'
require 'mongoid-encrypted-fields'

class MeterConfigurationDocument
  include Mongoid::Document
  include Mongoid::Timestamps

  field :vsphere_host, type: String
  field :vsphere_user, type: String
  field :vsphere_password, type: Mongoid::EncryptedString
  field :vsphere_ignore_ssl_errors, type: Boolean
  field :vsphere_debug, type: Boolean

  field :uc6_log_level, type: Integer
  field :uc6_login_email, type: String
  field :uc6_login_password, type: Mongoid::EncryptedString
  field :uc6_organization_id, type: String
  field :uc6_organization_name, type: String
  field :uc6_infrastructure_id, type: String
  field :uc6_meter_id, type: String
  field :uc6_api_host, type: String
  field :uc6_oauth_endpoint, type: String
  field :uc6_oauth_token, type: String
  field :uc6_refresh_token, type: String
  field :uc6_api_endpoint, type: String
  field :uc6_api_scope, type: String
  field :uc6_proxy_host, type: String
  field :uc6_proxy_port, type: String
  field :uc6_proxy_user, type: String
  field :uc6_application_id, type: String
  field :uc6_application_secret, type: String
  field :uc6_proxy_password, type: Mongoid::EncryptedString

  field :readings_batch_size, type: Integer
  field :mongoid_host, type: String
  field :mongoid_port, type: Integer
  field :mongoid_log_level, type: Integer

  field :registration_date, type: Time
  field :container_namespace, type: String, default: '6fusion'
  field :container_repository, type: String, default: 'vmware-collector'

  DOMAIN_REGEXP = %r<(?:[a-z0-9].+)*(?::[0-9]{1,5})?(/.*)?\Z>ixo
  HOST_REGEXP = /\A#{DOMAIN_REGEXP}/
  ADDRESS_REGEXP = %r<\A(?:http|https)://#{DOMAIN_REGEXP}>ixo
  validates_format_of :mongoid_host,   :with => HOST_REGEXP,    allow_blank: true
  validates_format_of :uc6_api_host,   :with => ADDRESS_REGEXP, allow_blank: true
  validates_format_of :uc6_proxy_host, :with => ADDRESS_REGEXP, allow_blank: true
  validates_format_of :vsphere_host,   :with => HOST_REGEXP,    allow_blank: true


  # Validation for this class is tricky: for most of these fields, we don't
  #  care if they're configured except for the registration process in production.
  #  However, the registration process is a wizard with incremental updates to the
  #  configuration...
  #  To support this, I'm going to add some methods that the registration app
  #  can call to implement validation when and as it deems fit
  def uc6_api_configured?
    errors.add(:uc6_api_host, 'cannot be blank') if uc6_api_host.blank?
    validate_user
    errors.empty?
  end
  def vsphere_configured?
    [:vsphere_host, :vsphere_user, :vsphere_password].each {|attribute|
      errors.add(attribute, 'cannot be blank') if ( self[attribute].blank? ) }
    errors.empty?
  end
  def organization_configured?
    !uc6_organization_id.nil
  end

  # helpers for the advanced form in the admin console
  def user_visible_fields
    @user_visible_fields ||= fields.reject{|name,f|
      %w(_id created_at updated_at uc6_login_password vsphere_password uc6_proxy_password).include?(name) }.map(&:first)
  end
  def self.user_editable_fields
    @user_editable_fields ||= fields.reject{|name, f| %w(_id created_at updated_at registration_date).include?(name) }.map(&:first)
  end
  def user_editable_field?(name)
    MeterConfigurationDocument.user_editable_fields.include?(name)
  end


  private
  def validate_user
    self.uc6_refresh_token.blank? ?
      validate_email & validate_password :
      true
  end

  def validate_email
    if ( uc6_login_email and      # this is the email regexp in the activerecord examples
         uc6_login_email.match(/\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\Z/i) )
      true
    else
      errors.add(:uc6_login_email, 'is not a valid email address')
      false
    end
  end
  def validate_password
    if ( uc6_login_password and
         !uc6_login_password.blank? )
      true
    else
      errors.add(:uc6_login_password, 'cannot be blank')
      false
    end
  end

end
