
orgId = 62
   
describe 'GET: One Organizations response data' do
  it 'should be' do
    get "/organizations/#{orgId}.json?access_token=#{Setup::Token}"
    expect_status(200)

    result = expect_json( {
       :name => "6fusion Test Org 0",
       :status => "Active",
       :uuid => "6b68b561-7a41-0132-ad49-005056b269cf",
       :phone => "800-555-1111",
       :facsimile => "800-555-2222"
    } )
    puts result
  end
end
