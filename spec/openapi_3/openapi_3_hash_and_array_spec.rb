# frozen_string_literal: true

require 'spec_helper'

describe 'document hash and array' do
  include_context "#{MODEL_PARSER} swagger example"

  before :all do
    module TheApi
      class TestApi < Grape::API
        format :json

        if ::Entities::DocumentedHashAndArrayModel.respond_to?(:documentation)
          documentation = ::Entities::DocumentedHashAndArrayModel.documentation
        end

        desc 'This returns something'
        namespace :arbitrary do
          params do
            requires :id, type: Integer
          end
          route_param :id do
            desc 'Timeless treasure'
            params do
              requires :body, using: documentation unless documentation.nil?
              requires :raw_hash, type: Hash, documentation: { param_type: 'body' } if documentation.nil?
              requires :raw_array, type: Array, documentation: { param_type: 'body' } if documentation.nil?
            end
            put '/id_and_hash' do
              {}
            end
          end
        end

        add_swagger_documentation openapi_version: '3.0'
      end
    end
  end

  def app
    TheApi::TestApi
  end

  subject do
    get '/swagger_doc'
    JSON.parse(last_response.body)
  end

  describe 'generated request definition' do
    # Helper method to find schema in different possible locations
    def find_schema(doc, schema_name)
      doc.dig('components', 'schemas', schema_name) ||
        doc.dig('paths', '/arbitrary/{id}/id_and_hash', 'put', 'requestBody', 'content', 'application/x-www-form-urlencoded', 'schema')
    end

    let(:schema) { find_schema(subject, 'putArbitraryIdIdAndHash') }

    it 'has hash' do
      expect(schema).not_to be_nil
      expect(schema['properties'].keys).to include('raw_hash')
    end

    it 'has array' do
      expect(schema).not_to be_nil
      expect(schema['properties'].keys).to include('raw_array')
    end

    it 'does not have the path parameter' do
      expect(schema).not_to be_nil
      expect(schema).to_not include('id')
    end
  end
end
