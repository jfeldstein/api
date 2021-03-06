require 'grape-entity'


module API
  module Entities
    class User < Grape::Entity
      expose :_id, as: :id
      expose :profile
      expose :email
      expose :apiKey
      expose :algoliaApiKey
      expose :allowedOrigins
    end
  end
end
