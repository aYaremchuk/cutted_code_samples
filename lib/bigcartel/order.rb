module Bigcartel
  class Order
    include Bigcartel::HTTPHandler

    BIGCARTEL_ORDER_ATTRIBUTES =  [:shipping_address_1, :shipping_address_2, :shipping_city, :shipping_state, :completed_at, :created_at, :shipping_zip]

    attr_accessor :id, :client, :customer, :items, :shipping_country_id, :country, *BIGCARTEL_ORDER_ATTRIBUTES

    def initialize(client = nil)
      @client = client
      @items = []
    end

    def all(params = {})
      response = handle_response { client.make_request(resource_path, params) }
      return Bigcartel::ErrorData.new(response) unless [200, 201].include?(response[:status]) && response[:body].try(:[], :data).present?
      build_bigcartel_orders(response[:body])
    end

    def resource_path
      '/orders'
    end

    def build_bigcartel_order(raw_order, included_data)
      order = BIGCARTEL_ORDER_ATTRIBUTES.each_with_object(Bigcartel::Order.new) do |attr, order_obj|
        order_obj.send("#{attr}=", raw_order['attributes'][attr])
      end
      unless raw_order['relationships']['shipping_country'].try(:[], 'data').blank?
        order.shipping_country_id = raw_order['relationships']['shipping_country']['data'].try(:[], 'id')
      end
      included_data.select { |key| order.country = key[:attributes][:name] if key[:id] == order.shipping_country_id }
      order.id = raw_order[:id]
      order.customer = Customer.new_from_order(raw_order, included_data)
      raw_items = raw_order['relationships']['items']['data'].inject([]) do |array, hash|
        array << hash['id'] if hash['type'] == 'order_line_items'
        array
      end

      included_items = included_data.select { |r| r['type'] == 'order_line_items' && raw_items.include?(r['id']) }
      included_items.each do |included_item|
        product = included_item['relationships']['product']['data']
        product_option = included_item['relationships']['product_option']['data']
        unless product.try(:[], 'id').blank? && product_option.try(:[],'id').blank?
          item_data = { products_id: product['id'], product_options_id: product_option['id'], quantity: included_item['attributes']['quantity'] }
          order.items.push item_data
        end
      end
      order
    end

    private

    def build_bigcartel_orders(response_body)
      orders = response_body[:data]
      orders.map do |raw_order|
        build_bigcartel_order(raw_order, response_body[:included])
      end
    end
  end
end
