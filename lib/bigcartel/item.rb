module Bigcartel
  class Item
    BIGCARTEL_ITEM_ATTRIBUTES = [:name, :quantity, :price, :sold]

    attr_accessor :id, *BIGCARTEL_ITEM_ATTRIBUTES

    def self.parse_items_from_included_data(included_data, ids)
      raw_items = included_data.select { |h| h['type'] == 'product_options' && ids.include?(h['id']) }

      raw_items.map do |raw_item|
        item = Bigcartel::Item.new
        item.id = raw_item['id']
        BIGCARTEL_ITEM_ATTRIBUTES.each do |attr|
          item.send("#{attr}=", raw_item['attributes'][attr])
        end

        item
      end
    end
  end
end
