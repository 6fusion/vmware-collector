require 'fileutils'
require 'securerandom'

module PasswordHelper

  HOST_ETC = '/host/etc'

  # Grab the core user's entry from /etc/shadow,
  #  pull out the hash's salt, crypt the password that
  #  was passed in with it, and see if it matches
  def valid?(password)
    shadow_line = File.readlines("#{HOST_ETC}/shadow")
                  .find{|l| l.start_with?('core:') }
                  .split(':')[1]
    if ( shadow_line.match(/\$6\$/) )
      salt = shadow_line.split('$')[2]
      check = password.crypt('$6$' + salt)
      shadow_line.eql?(check)
    else
      false
    end
  end

  def unset?
    shadow_line = File.readlines("#{HOST_ETC}/shadow")
                  .find{|l| l.start_with?('core:') }
                  .split(':')[1]
    shadow_line.eql?('*')
  end

  def defaulted?
    valid?('6fusion') or unset?
  end

  # Encrypts a new password for the core user and updates /etc/shadow
  #  The update is done first in a copy and then mv'd to ensure, in the
  #  case that the file system is full, that we fail rather than create a
  #  partial/corrupted shadow file
  def set_password(new_password)
    salt = SecureRandom.hex(8)
    new_hashed = new_password.crypt('$6$' + salt)

    new_shadow_file = File.open("#{HOST_ETC}/.shadow", 'w', 0600)

    File.readlines("#{HOST_ETC}/shadow").each do |line|
      if ( line.start_with?('core:') )
        fields = line.split(':')
        new_shadow_file.puts([fields[0],new_hashed,fields[2..-1]].flatten.join(':'))
      else
        new_shadow_file.write line
      end
    end

    new_shadow_file.close
    FileUtils.mv("#{HOST_ETC}/.shadow", "#{HOST_ETC}/shadow")
  end


  module_function :set_password, :valid?, :defaulted?, :unset?

end
