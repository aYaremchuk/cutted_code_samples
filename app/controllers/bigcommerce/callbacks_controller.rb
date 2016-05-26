class Bigcommerce::CallbacksController < ApplicationController
  def handle
    case request.parameters['webhook']['scope'].split('store/')[1]
    when 'product/created', 'product/updated'
      import_service_subject.webhook_product request.parameters
    when 'customer/created', 'customer/updated'
      import_service_subject.webhook_customer request.parameters
    when 'order/created', 'order/updated'
      import_service_subject.webhook_order request.parameters
    end

    render nothing: true, status: 202
  end

  def uninstall
    begin
      payload = verify
      external_id = payload['store_hash']
      external_shop = ExternalShop.where(external_id: external_id).first!
      external_shop.uninstall_shop
      render nothing: true, status: 202
    rescue => e
      Airbrake.notify(e)
      Rails.logger.info e.inspect
      Rails.logger.info e.message
      Rails.logger.info e.backtrace.join("\n")
      redirect_to root_path
    end
  end

  def load
    begin
      payload = verify
      external_id = payload['store_hash']
      user_id = payload['user']['id']
      external_shop = ExternalShop.where(external_id: external_id).first!
      provider = ExternalApplication.find_by_id(external_shop.external_application_id)
      @user = User.where(provider: provider.name, external_oauth_uid: user_id.to_s).first!
      sign_in @user, :event => :authentication
      flash[:notice] = "Welcome to Kit! Thank you for logging in via #{provider.name.capitalize}."
      redirect_to external_shops_authorization_from_application_redirect
    rescue => e
      Airbrake.notify(e)
      Rails.logger.info e.inspect
      Rails.logger.info e.message
      Rails.logger.info e.backtrace.join("\n")
      flash[:error] = 'Something went wrong when connecting. Try again? Or, contact us at hello@kitcrm.com!'
      redirect_to root_path
    end
  end

  private

  def verify(signed_payload = params[:signed_payload], client_secret = BC_CLIENT_SECRET)
    message_parts = signed_payload.split('.')
    encoded_json_payload = message_parts[0]
    encoded_hmac_signature = message_parts[1]
    payload_object = Base64.decode64(encoded_json_payload)
    provided_signature = Base64.decode64(encoded_hmac_signature)
    expected_signature = OpenSSL::HMAC::hexdigest('sha256', client_secret, payload_object)
    return false unless secure_compare(expected_signature, provided_signature)
    JSON.parse(payload_object)
  end

  def secure_compare(a, b)
    return false if a.blank? || b.blank? || a.bytesize != b.bytesize
    l = a.unpack "C#{a.bytesize}"
    res = 0
    b.each_byte { |byte| res |= byte ^ l.shift }
    res == 0
  end

  def import_service_subject
    external_application = ExternalApplication.where(name: 'bigcommerce').first!
    external_shop = external_application.external_shops.where(external_id: request['producer'].split('/')[1]).first!
    subject = Bigcommerce::ImportService.new(external_shop)

    subject
  end
end
