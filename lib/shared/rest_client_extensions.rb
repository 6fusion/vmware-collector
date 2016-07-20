module RestClient::Response
  def remote_id
    json['id']
  end

  def json
    # IMPORTANT: This will raise an exception if the body is not in JSON format
    JSON.parse(body)
  end
end
