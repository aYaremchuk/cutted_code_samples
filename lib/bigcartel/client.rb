module Bigcartel
  class Client
    attr_accessor :access_token, :base_uri

    include HTTParty
    format :json

    def initialize(access_token, shop_id)
      @access_token = access_token
      @base_uri = "https://api.bigcartel.com/v1/accounts/#{shop_id}"
    end

    def account
      Bigcartel::Account.new(self).find
    end

    def make_request(resource_path, params = {})
      self.class.get(uri(resource_path), query: params, headers: headers)
    end

    def orders(params = {})
      Bigcartel::Order.new(self).all(params)
    end

    def products(params = {})
      Bigcartel::Product.new(self).all(params)
    end

    def product(product_id = nil)
      Bigcartel::Product.new(self).one(product_id)
    end

    private

    def headers
      {
        'Authorization' => "Bearer #{ access_token }",
        'Accept' => 'application/vnd.api+json',
        'User-Agent' => 'mike@kitcrm.com'
      }
    end

    def uri(resource_path)
      base_uri + resource_path
    end
  end
end
