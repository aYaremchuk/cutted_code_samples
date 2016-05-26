module Bigcartel
  class ImportService
    class << self
      def connect!(omniauth_response, user, external_application)
        bigcartel_store = Bigcartel::Client.new(omniauth_response.credentials.token, omniauth_response.uid).account
        return if bigcartel_store.is_a?(Bigcartel::ErrorData)

        external_shop = ExternalShop.where(user_id: user.id, external_application_id: external_application.id, external_id: omniauth_response.uid.to_s).first
        if external_shop.present? && external_shop.page_id == user.default_page_id
          external_shop.update_attributes(store_attributes(bigcartel_store, user, omniauth_response.credentials.token))
        else
          attrs = store_attributes(bigcartel_store, user, omniauth_response.credentials.token).merge(external_application_id: external_application.id)
          external_shop = ExternalShop.create(attrs)
          Rails.logger.info "Connected Shop: #{external_application.name.titleize} Account: #{external_shop.name} for #{external_shop.user.email}"
        end
        external_shop
      end

      def store_attributes(store_object, user, access_token)
        {
          external_id: store_object.id.to_s,
          name: store_object.store_name,
          customer_email: store_object.contact_email,
          country: store_object.country,
          page_id: user.default_page_id,
          user_id: user.id,
          access_token: access_token,
          url: store_object.url
        }
      end

      def import_new_transactions(external_application)
        ExternalShop.where(external_application_id: external_application.id, initial_import_finished: true).find_each do |bigcartel_shop|
          new(bigcartel_shop).delay(priority: 1, queue: 'external').initial_import(false)
        end
      end
    end

    private_class_method :store_attributes

    def initialize(shop)
      @shop = shop
    end

    def initial_import(first_time_import = true)
      import_products
      if first_time_import
        import_orders
        @shop.update_attributes(initial_import_finished: true, initial_import_finished_at: Time.zone.now)
      end
    end

    def webhook_import(order)
      delay(priority: 1, queue: 'utility').import_order(order)
    end

    def account_updated(body)
      account = Bigcartel::Account.new.build_bigcartel_account body[:payload][:data]
      external_application = ExternalApplication.where(name: 'bigcartel').first!
      external_shop = external_application.external_shops.where(external_id: account.id).first!
      external_shop.update_attributes name: account.store_name,
                                      customer_email: account.contact_email,
                                      country: account.country,
                                      url: account.url
    end

    def order_created(body)
      external_application = ExternalApplication.where(name: 'bigcartel').first!
      external_shop_id = body[:payload][:data][:links][:self].split('/')[5]
      external_shop = external_application.external_shops.where(external_id: external_shop_id).first!
      order = Bigcartel::Order.new.build_bigcartel_order body[:payload][:data], body[:payload][:included]
      if external_shop.external_item_external_leads.where(external_order_id: order.id).blank?
        import = Bigcartel::ImportService.new(external_shop)
        import.webhook_import order
      end
    end

    def import_product_variations(product)
      product.items.map do |item|
        external_item = ExternalItem.find_by_external_id_and_external_variation_id_and_external_application_id(product.id, item.id, @shop.external_application_id)
        if external_item.present?
          external_item.update_attributes(item_attributes(product, item))
        else
          external_item = ExternalItem.create(item_attributes(product, item))
        end
        import_variation_images(product, external_item)
        external_item
      end
    end

    private

    def import_products(per_request_limit = 100)
      client = Bigcartel::Client.new(@shop.access_token, @shop.external_id)
      position = 0
      loop do
        products = client.products("page[limit]=#{per_request_limit}&page[offset]=#{position}")
        break if products.blank? || products.is_a?(Bigcartel::ErrorData)
        products.each { |product| import_product_variations(product) }
        break if products.count < per_request_limit
        position += 1
      end
    end

    def import_orders(per_request_limit = 20)
      client = Bigcartel::Client.new(@shop.access_token, @shop.external_id)
      position = 0
      loop do
        orders = client.orders("page[limit]=#{per_request_limit}&page[offset]=#{position}")
        break if orders.blank? || orders.is_a?(Bigcartel::ErrorData)
        orders.each { |order| import_order(order) }
        break if orders.count < per_request_limit
        position += 1
      end
    end

    def import_order(order)
      external_lead = import_customer_from_order(order)
      import_products_from_order(order, external_lead)
    end

    def import_customer_from_order(order)
      customer = order.customer
      external_lead = ExternalLead.find_by_external_id_and_external_application_id(customer.id, @shop.external_application_id)

      if external_lead.nil?
        external_lead = ExternalLead.create(lead_attributes(customer))
        ExternalShopStat.create(external_shop_id: @shop.id, external_lead_id: external_lead.id)
      else
        external_lead.update_attributes(lead_attributes(customer))
        ExternalShopStat.create(external_shop_id: @shop.id, external_lead_id: external_lead.id)
      end
      external_lead
    end

    def import_products_from_order(order, external_lead)
      order.items.each do |item|
        begin
          external_item = ExternalItem.find_by_external_variation_id_and_external_id(item[:product_options_id], item[:products_id] )
          unless external_item
            client = Bigcartel::Client.new(@shop.access_token, @shop.external_id)
            new_product = client.product(item[:products_id])
            external_item = import_product_variations(new_product).detect { |r| r.external_variation_id == item[:product_options_id] }
          end
          ext_item_ext_lead = ExternalItemExternalLead.find_by_external_order_id_and_external_item_id_and_external_lead_id(order.id, external_item.id, external_lead.id)
          if ext_item_ext_lead.present?
            ext_item_ext_lead.update_attribute(:external_shop_id, @shop.id)
          else
            ExternalItemExternalLead.create(order_attributes(external_item, external_lead, order, item))
          end
        rescue ActiveRecord::RecordNotUnique
          next
        end
      end
    end

    def import_variation_images(product, external_item)
      product.images.each do |image|
        begin
          external_image = ExternalImage.find_by_external_id_and_external_item_id_and_external_application_id(image.id, external_item.id, @shop.external_application_id)
          if external_image.present?
            external_image.update_attributes(image_attributes(external_item, image))
          else
            ExternalImage.create(image_attributes(external_item, image))
          end
        rescue ActiveRecord::RecordNotUnique
          next
        end
      end
    end

    def item_attributes(product, item)
      categories = product.categories.blank? ? nil : product.categories.map { |r| r }
      {
        external_shop_id: @shop.id,
        external_application_id: @shop.external_application_id,
        external_variation_id: item.id,
        external_id: product.id,
        tags: categories,
        inventory_quantity: item.quantity,
        created_on_shop_at: product.created_at,
        price: item.price,
        product_title: product.name.titleize,
        variation_title: item.name.titleize,
        image_url: (product.images.first.url unless product.images.blank?),
        url: "#{@shop.url}/product/#{ product.permalink }"
      }
    end

    def image_attributes(external_item, image)
      {
        external_id: image.id,
        external_item_id: external_item.id,
        external_application_id: @shop.external_application_id,
        url_small: resize_image(image.url, 50),
        url_medium: resize_image(image.url, 300),
        url_large: resize_image(image.url, 1000),
        url_xlarge: resize_image(image.url, 2000)
      }
    end

    def resize_image(image_url, size)
      "#{image_url}?w=#{size}&h=#{size}" unless image_url.blank?
    end

    def lead_attributes(customer)
      addresses = if customer.shipping_address_1.blank? || customer.shipping_address_2.blank?
        "#{customer.shipping_address_1}#{customer.shipping_address_2}"
      else
        "#{customer.shipping_address_1}; #{customer.shipping_address_2}"
      end
      {
        external_id: customer.customer_email,
        external_application_id: @shop.external_application_id,
        email: customer.customer_email,
        name: "#{customer.customer_first_name} #{customer.customer_last_name}",
        first_name: customer.customer_first_name,
        last_name: customer.customer_last_name,
        country_id: customer.country_id,
        zip: customer.shipping_zip,
        city: customer.shipping_city,
        state: customer.shipping_state,
        address: addresses,
        country: customer.country
      }
    end

    def order_attributes(external_item, external_lead, order, item)
      {
        external_item_id: external_item.id,
        external_lead_id: external_lead.id,
        external_shop_id: @shop.id,
        external_order_id: order.id,
        purchase_amount: external_item.price,
        purchase_quantity: item[:quantity],
        purchased_at: order.created_at,
        email: external_lead.email,
        address1: order.shipping_address_1,
        address2: order.shipping_address_2,
        city: order.shipping_city,
        country: order.country,
        country_id: order.shipping_country_id,
        province: order.shipping_state,
        zip: order.shipping_zip,
        name: external_lead.name,
        first_name: external_lead.first_name,
        last_name: external_lead.last_name
      }
    end
  end
end
