module Bigcartel
  module HTTPHandler
    def handle_response
      response = yield
      return formatted_response(response) if [200, 201].include?(response.code)

      Rails.logger.info "BIGCARTEL ERROR: #{response.code} - #{response}"
      formatted_response(response)
    end

    private

    def formatted_response(response)
      { body: response.parsed_response, status: response.code }.with_indifferent_access
    end
  end
end
