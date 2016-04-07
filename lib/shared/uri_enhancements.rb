require 'uri'

module URI
  def url
    scheme + '://' + host + ':' + port.to_s + path
  end

  def parameters
    query.nil? ? {} : Hash[ *(URI::decode_www_form(query).map{|a| [a[0].to_sym, a[1] ]}).flatten ]
  end
end
