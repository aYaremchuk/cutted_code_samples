module Bigcommerce
  class ImportService
    class << self
      def connect!(omniauth_response, user, external_application)
        external_id = omniauth_response[:extra][:raw_info][:context].split('/')[1]
        begin
        @http_transport = Bigcommerce::HttpTransport.new do |config|
          config.client_id = BC_CLIENT_ID
          config.store_hash = external_id
          config.access_token = omniauth_response[:credentials][:token].token
        end
          bigcommerce_store = Bigcommerce::StoreInfo.instance(@http_transport).info
        rescue
          nil
        else
          external_shop = ExternalShop.where(external_application_id: external_application.id, external_id: external_id).first
          if external_shop.present?
            external_shop.update_attributes(store_attributes(bigcommerce_store, user, omniauth_response.credentials.token.token))
          else
            attrs = store_attributes(bigcommerce_store, user, omniauth_response.credentials.token.token).merge(external_application_id: external_application.id)
            external_shop = ExternalShop.new(attrs)
            external_shop.page_not_required = true
            external_shop.save
            Rails.logger.info "Connected Shop: #{external_application.name.titleize} Account: #{external_shop.name} for #{external_shop.user.email}"
          end

          external_shop
        end
      end

      def store_attributes(store_object, user, access_token)
        {
            external_id: store_object.id.to_s,
            name: store_object.name,
            customer_email: store_object.admin_email,
            address1: store_object.address,
            phone: store_object.phone,
            user_id: user.id,
            access_token: access_token,
            url: store_object.domain,
            valid_access_token: true,
            uninstalled: false
        }
      end

      def paying_customers_monthly_report
        return false unless Time.zone.now.mday == 1
        total_plan_amount = 0.0
        Page.in_good_standing.find_each do |page|
          next if !page.bigcommerce_account.present? || page.needs_to_upgrade? || page.free? || page.in_trial_period?
          total_plan_amount += page.fan_plan.price
        end
        owed_to_bigcommerce = total_plan_amount > 0.0 ? total_plan_amount * 0.2 : total_plan_amount
        AdminMailer.generic('Money owed to Bigcommerce', "Send #{owed_to_bigcommerce} to partnerpayments@bigcommerce.com").deliver
      end
    end

    private_class_method :store_attributes

    def initialize(shop)
      @shop = shop
    end

    def initial_import(first_time_import = true)
      import_products
      import_customers
      if first_time_import
        import_orders
        create_webhooks
        @shop.update_attributes(initial_import_finished: true, initial_import_finished_at: Time.zone.now)
      end
    end

    def webhook_product(request)
      product_id = request['data']['id']
      product = Bigcommerce::Product.instance(configuration_http_transport).find(product_id)
      import_product(product)
    end

    def webhook_customer(request)
      customer_id = request['data']['id']
      customer = Bigcommerce::Customer.instance(configuration_http_transport).find(customer_id)
      import_customer(customer)
    end

    def webhook_order(request)
      order_id = request['data']['id']
      order = Bigcommerce::Order.instance(configuration_http_transport).find(order_id)
      webhook_import(order)
    end

    private

    def webhook_import(order)
      delay(priority: 1, queue: 'utility').import_order(order)
    end

    def create_webhooks
      webhooks = Bigcommerce::Webhook.instance(configuration_http_transport).all
      if webhooks.empty?
        destination = Rails.env.production? ? 'https://www.kitcrm.com/bigcommerce/handle' : 'https://kit8f5sjd0ekss90.ngrok.io/bigcommerce/handle'
        Bigcommerce::Webhook.instance(configuration_http_transport).create(scope: 'store/order/*', destination: destination)
        Bigcommerce::Webhook.instance(configuration_http_transport).create(scope: 'store/product/*', destination: destination)
        Bigcommerce::Webhook.instance(configuration_http_transport).create(scope: 'store/customer/*', destination: destination)
      end
    end

    def import_customers(per_request_limit = 100)
      page = 1
      loop do
        customers = Bigcommerce::Customer.instance(configuration_http_transport).all(page: page, limit: per_request_limit)
        break if customers.blank?
        customers.each { |customer| import_customer(customer) }
        break if customers.count < per_request_limit
        page += 1
      end
    end

    def import_customer(customer)
        external_id = "#{customer.email}/#{customer.id}"
        external_lead = ExternalLead.find_by_external_id_and_external_application_id(external_id, @shop.external_application_id)
        begin
        if external_lead.nil?
          external_lead = ExternalLead.create(lead_attributes(customer))
          ExternalShopStat.create(external_shop_id: @shop.id, external_lead_id: external_lead.id)
        else
          external_lead.update_attributes(lead_attributes(customer))
          ExternalShopStat.create(external_shop_id: @shop.id, external_lead_id: external_lead.id)
        end
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end

    def configuration_http_transport
        Bigcommerce::HttpTransport.new do |config|
        config.client_id = BC_CLIENT_ID
        config.store_hash = @shop.external_id
        config.access_token = @shop.access_token
        end
    end

    def import_products(per_request_limit = 100)
      page = 1
      loop do
        products = Bigcommerce::Product.instance(configuration_http_transport).all(page: page, limit: per_request_limit)
        break if products.blank?

        products.each { |product| import_product(product) }

        break if products.count < per_request_limit
        page += 1
      end
    end

    def import_product(product)
      external_id = @shop.external_id + product.id.to_s
      list_of_categories = Bigcommerce::Category.instance(configuration_http_transport).all

      external_item = ExternalItem.find_by_external_id_and_external_application_id(external_id, @shop.external_application_id)

      if external_item.present?
        external_item.update_attributes(item_attributes(product, list_of_categories))
      else
        external_item = ExternalItem.create(item_attributes(product, list_of_categories))
      end

      import_product_images(product, external_item)
    end

    def set_categories(product, list_of_categories)
      product_categories = []
      product.categories.each do |product_category|
        list_of_categories.each do |category|
          product_categories.push(category) if product_category == category.id
        end
      end
      product_categories.map(&:name)
    end

    def import_orders(per_request_limit = 20)
      page = 1
      loop do
        orders = Bigcommerce::Order.instance(configuration_http_transport).all(page: page, limit: per_request_limit)
        break if orders.blank?
        orders.each { |order| import_order(order) }
        break if orders.count < per_request_limit
        page += 1
      end
    end

    def import_order(order)
      external_lead = import_customer_from_order(order)
      unless external_lead.nil?
        import_products_from_order(order, external_lead)
      end
    end

    def get_customer_by_id(id)
      customer = Bigcommerce::Customer.instance(configuration_http_transport).find(id)

      customer
    end

    def import_customer_from_order(order)
      external_lead_id = "#{order.billing_address[:email]}/#{order.customer_id}"
      external_lead = ExternalLead.find_by_external_id_and_external_application_id(external_lead_id, @shop.external_application_id)
      customer_information = get_customer_by_id(order.customer_id)
      if customer_information.class == Bigcommerce::Customer
        if external_lead.nil?
          external_lead = ExternalLead.create(lead_attributes(customer_information))
          ExternalShopStat.create(external_shop_id: @shop.id, external_lead_id: external_lead.id)
        else
          external_lead.update_attributes(lead_attributes(customer_information))
          ExternalShopStat.create(external_shop_id: @shop.id, external_lead_id: external_lead.id)
        end
      end
      external_lead
    end

    def import_products_from_order(order, external_lead)
      list_of_categories = Bigcommerce::Category.instance(configuration_http_transport).all
      order_products = Bigcommerce::OrderProduct.instance(configuration_http_transport).all(order.id)
      order_products.each do |order_product|
        begin
          product = Bigcommerce::Product.instance(configuration_http_transport).find(order_product.product_id)

          product_external_id = @shop.external_id + order_product.product_id.to_s

          external_item = ExternalItem.find_by_external_id_and_external_application_id(product_external_id, @shop.external_application_id)

          if external_item.present?
            external_item.update_attributes(item_attributes(product, list_of_categories, order[:items_total]))
          else
            external_item = ExternalItem.create(item_attributes(product, list_of_categories, order[:items_total]))
          end

          import_product_images(product, external_item)
          order_id = "#{@shop.external_id}/#{order.id}"
          item_id = external_item.id
          lead_id = external_lead.id
          ext_item_ext_lead = ExternalItemExternalLead.find_by_external_order_id_and_external_item_id_and_external_lead_id(order_id, item_id, lead_id)
          if ext_item_ext_lead.present?
            ext_item_ext_lead.update_attribute(:external_shop_id, @shop.id)
          else
            ExternalItemExternalLead.create(order_attributes(external_item, external_lead, order, order_product))
          end
        rescue ActiveRecord::RecordNotUnique
          next
        end
      end
    end

    def import_product_images(product, external_item)
      product_images = configuration_http_transport.get("products/#{product.id}/images")
      product_images.each do |image|
        begin
          image_external_id = @shop.external_id + image[:id].to_s
          external_image = ExternalImage.find_by_external_id_and_external_application_id(image_external_id, @shop.external_application_id)
          if external_image.present?
            external_image.update_attributes(image_attributes(external_item, image, image_external_id))
          else
            ExternalImage.create(image_attributes(external_item, image, image_external_id))
          end
        rescue ActiveRecord::RecordNotUnique
          next
        end
      end
    end

    def item_attributes(product, list_of_categories, purchased_quantity = 0)
      {
        external_shop_id: @shop.id,
        external_application_id: @shop.external_application_id,
        external_variation_id: @shop.external_id + product.id.to_s,
        external_id: @shop.external_id + product.id.to_s,
        tags: set_categories(product, list_of_categories),
        inventory_quantity: product.inventory_level,
        created_on_shop_at: Time.zone.parse("#{product.date_created} UTC"),
        price: product.price,
        product_title: product.name.titleize,
        url: "http://#{@shop.url}#{product.custom_url.gsub(/\/$/, '')}",
        image_url: (product.primary_image[:thumbnail_url] if product.primary_image.present?)
      }
    end

    def lead_attributes(customer)
      {
        external_id: "#{customer.email}/#{customer.id}",
        external_application_id: @shop.external_application_id,
        email: customer.email,
        name: "#{customer.first_name} #{customer.last_name}",
        first_name: customer.first_name,
        last_name: customer.last_name
      }
    end

    def image_attributes(external_item, image, image_external_id)
      {
        external_id: image_external_id,
        external_item_id: external_item.id,
        external_application_id: @shop.external_application_id,
        url_small: image[:tiny_url],
        url_medium: image[:standard_url],
        url_large: image[:thumbnail_url],
        url_xlarge: image[:zoom_url]
      }
    end

    def order_attributes(external_item, external_lead, order, order_product)
      {
        external_item_id: external_item.id,
        external_lead_id: external_lead.id,
        external_shop_id: @shop.id,
        external_order_id: "#{@shop.external_id}/#{order.id}",
        purchase_amount: external_item.price,
        purchase_quantity: order_product.quantity,
        purchased_at: order.date_created,
        email: external_lead.email,
        address1: order.billing_address[:street_1],
        address2: order.billing_address[:street_2],
        city: order.billing_address[:city],
        country: order.billing_address[:country],
        country_id: order.billing_address[:country_iso2],
        province: order.billing_address[:state],
        zip: order.billing_address[:zip],
        name: external_lead.name,
        first_name: external_lead.first_name,
        last_name: external_lead.last_name,
        company: order.billing_address[:company],
        phone: order.billing_address[:phone]
      }
    end
  end
end
