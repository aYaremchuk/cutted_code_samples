module Bigcartel
  class Image
    BIGCARTEL_IMAGE_ATTRIBUTES = [:url]

    attr_accessor :id, *BIGCARTEL_IMAGE_ATTRIBUTES

    def parse_from_data(included_data, raw_product)
      images_ids = raw_product['relationships']['images']['data'].map { |r| r['id'] if r['type'] == 'product_images' }
      images_ids.map { |id| build_image(included_data, id) }
    end

    def build_image(included_data, id)
      image_data = included_data.select { |key| key if key[:id] == id }
      image = BIGCARTEL_IMAGE_ATTRIBUTES.each_with_object(Bigcartel::Image.new) do |attr, external_image|
        external_image.send("#{attr}=", image_data.first['attributes'][attr])
      end
      image.id = image_data.first['id']
      image
    end
  end
end
