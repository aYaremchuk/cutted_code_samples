module Bigcartel
  class Account
    include Bigcartel::HTTPHandler

    BIGCARTEL_ACCOUNT_ATTRIBUTES = [:subdomain, :store_name, :url,
                                    :contact_email, :website,
                                    :created_at, :updated_at]

    attr_accessor :id, :client, :country, *BIGCARTEL_ACCOUNT_ATTRIBUTES

    def initialize(client = nil)
      @client = client
    end

    def find
      response = handle_response { client.make_request(resource_path) }
      return Bigcartel::ErrorData.new(response) unless [200, 201].include?(response[:status])
      build_bigcartel_account(response[:body][:data])
    end

    def resource_path
      ''
    end

    def build_bigcartel_account(attributes)
      account = BIGCARTEL_ACCOUNT_ATTRIBUTES.each_with_object(Bigcartel::Account.new) do |attr, store|
        store.send("#{attr}=", attributes[:attributes][attr])
      end
      account.id = attributes[:id]
      account.country = attributes[:relationships][:country][:data][:id]
      account
    end
  end
end
