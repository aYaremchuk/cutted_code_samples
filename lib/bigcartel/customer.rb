module Bigcartel
  class Customer
    BIGCARTEL_CUSTOMER_ATTRIBUTES = [:customer_email, :customer_first_name,
                                     :customer_last_name, :shipping_zip,
                                     :shipping_city, :shipping_state,
                                     :shipping_address_1, :shipping_address_2]

    attr_accessor :id, :country_id, :address, :country,
                  *BIGCARTEL_CUSTOMER_ATTRIBUTES

    def self.new_from_order(raw_order, included_data)
      customer = Bigcartel::Customer.new
      BIGCARTEL_CUSTOMER_ATTRIBUTES.each do |attribute|
        customer.send("#{attribute}=", raw_order['attributes'][attribute])
      end
      customer.id = raw_order['attributes']['customer_email']
      unless raw_order['relationships']['shipping_country'].try(:[], 'data').blank?
        customer.country_id = raw_order['relationships']['shipping_country']['data'].try(:[], 'id')
        if customer.country_id.present?
          customer_country = included_data.select { |raw_data| raw_data['type'] == 'countries' }
                             .find { |country| country['id'] == customer.country_id }
          customer.country = customer_country.try(:[], 'attributes').try(:[], 'name')
        else
          customer.country = nil
        end
      end
      customer
    end
  end
end
