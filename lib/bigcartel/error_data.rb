module Bigcartel
  class ErrorData
    attr_reader :status, :code, :title, :detail

    def initialize(data)
      @status = data[:status]
      unless data[:body].try(:[], :errors).blank?
        @code = data[:body][:errors].first[:code]
        @title = data[:body][:errors].first[:title]
        @detail = data[:body][:errors].first[:detail]
      end
    end
  end
end
