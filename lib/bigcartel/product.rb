module Bigcartel
  class Product
    include Bigcartel::HTTPHandler

    BIGCARTEL_PRODUCT_ATTRIBUTES = [:id, :name, :permalink, :created_at, :updated_at]

    attr_accessor :client, :items, :categories, :images, *BIGCARTEL_PRODUCT_ATTRIBUTES

    def initialize(client = nil)
      @client = client
      @categories = []
    end

    def all(params = {})
      response = handle_response { client.make_request(resource_path, params) }

      return Bigcartel::ErrorData.new(response) unless [200, 201].include?(response[:status])

      build_bigcartel_products(response[:body])
    end

    def one(product_id)
      response = handle_response { client.make_request("#{resource_path}/#{product_id}") }
      return Bigcartel::ErrorData.new(response) unless [200, 201].include?(response[:status])

      build_bigcartel_product(response[:body][:data], response[:body][:included])
    end

    def resource_path
      '/products'
    end

    def build_bigcartel_product(raw_product, included_data)
      product = BIGCARTEL_PRODUCT_ATTRIBUTES.each_with_object(Bigcartel::Product.new) do |attr, product|
        product.send("#{attr}=", raw_product['attributes'][attr])
      end
      item_ids = raw_product['relationships']['options']['data'].map { |item| item['id'] }
      product.id = raw_product[:id]
      product.items = Bigcartel::Item.parse_items_from_included_data included_data, item_ids
      unless raw_product['relationships']['categories'].try(:[], 'data').blank?
        categories_ids = raw_product['relationships']['categories']['data'].map { |r| r['id'] if r['type'] == 'categories' }
        included_data.select { |key| product.categories.push key[:attributes][:name] if categories_ids.include?(key[:id]) }
      end
      if raw_product['relationships']['images'].present?
        product.images = Bigcartel::Image.new.parse_from_data(included_data, raw_product)
      end

      product
    end

    private

    def build_bigcartel_products(response_body)
      products = response_body[:data]
      products.map do |raw_product|
        build_bigcartel_product(raw_product, response_body[:included])
      end
    end
  end
end
