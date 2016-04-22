
module RestClient::Response
  def remote_id
    json['id']
  end

  def json
    #!! need a rescue around this
    j = JSON::parse(body)
    # Insert remote IDs
    #!! rescues, ifs etc needed
    if j['embedded'] and !j['embedded']['remote_id']
      j['embedded'].values.flatten.each do |thing|
        md = thing['_links']['self']['href'].match(/\/(\d+)$/)
        thing['remote_id'] = md[1].to_i
      end
    end
    j
  end

end
