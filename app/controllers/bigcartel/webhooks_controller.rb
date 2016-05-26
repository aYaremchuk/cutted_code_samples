class Bigcartel::WebhooksController < ApplicationController
  skip_before_filter :verify_authenticity_token
  before_filter :validate_request

  def handle
    case @body[:type]
    when 'order.created'
      external_application = ExternalApplication.where(name: 'bigcartel').first!
      subject = Bigcartel::ImportService.new(external_application)
      subject.order_created @body
    when 'account.updated'
      external_application = ExternalApplication.where(name: 'bigcartel').first!
      subject = Bigcartel::ImportService.new(external_application)
      subject.account_updated @body
    end

    render nothing: true, status: 202
  end

  private

  def validate_request
    raw_body = request.body.read
    @body = JSON.parse(raw_body).with_indifferent_access
    sha256 = OpenSSL::Digest::SHA256.new
    signature = OpenSSL::HMAC.hexdigest(sha256, BIGCARTEL_CLIENT_SECRET, raw_body)

    render text: 'signature is invalid', status: 400 unless signature == request.headers['X-Webhook-Signature']
  end
end
