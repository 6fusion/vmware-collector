
module RestClient::Response
  def remote_id
    link_self = json["_links"]["self"]["href"]
    match_data = link_self.match(/\/(\d+)$/)
    match_data.nil? ? nil : match_data[1].to_i
  end

  def json
    #!! need a rescue around this
    j = JSON::parse(body)
    # Insert remote IDs
    #!! rescues, ifs etc needed
    j['_links']['self']['remote_id'] = j["_links"]["self"]["href"]
    if j['embedded'] and !j['embedded']['remote_id']
      j['embedded'].values.flatten.each do |thing|
        md = thing['_links']['self']['href'].match(/\/(\d+)$/)
        thing['remote_id'] = md[1].to_i
      end
    end
    j
  end

end
