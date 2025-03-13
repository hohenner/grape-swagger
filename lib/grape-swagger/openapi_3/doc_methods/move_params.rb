# frozen_string_literal: true

require 'active_support/core_ext/hash/deep_merge'

module GrapeSwagger
  module DocMethods
    class OpenAPIMoveParams
      class << self
        attr_accessor :definitions

        def can_be_moved?(params, http_verb)
          return false unless move_methods.include?(http_verb)

          # Check if any parameter should be in the body
          params.any? do |param|
            # Original body param check
            param[:in] == 'body' ||
              # Also check for hash and array types that should be in body
              param[:type] == 'Hash' ||
              param[:type] == 'Array' ||
              (param[:schema] && %w[object array].include?(param[:schema][:type])) ||
              # Check documentation type as well
              (param[:documentation] &&
               (%w[Hash Array].include?(param[:documentation][:type]) ||
                param[:documentation][:in] == 'body' ||
                param[:documentation][:param_type] == 'body'))
          end
        end

        def to_definition(path, params, route, definitions)
          @definitions = definitions
          unify!(params)

          params_to_move = movable_params(params)

          return (params + correct_array_param(params_to_move)) if should_correct_array?(params_to_move)

          params << parent_definition_of_params(params_to_move, path, route)

          params
        end

        private

        def should_correct_array?(param)
          param.length == 1 && param.first[:in] == 'body' && param.first[:type] == 'array'
        end

        def correct_array_param(param)
          param.first[:schema] = { type: param.first.delete(:type), items: param.first.delete(:items) }

          param
        end

        def parent_definition_of_params(params, path, route)
          definition_name = OperationId.manipulate(parse_model(path))
          referenced_definition = build_definition(definition_name, params, route.request_method.downcase)
          definition = @definitions[referenced_definition]

          move_params_to_new(definition, params)

          definition[:description] = route.description if route.try(:description)

          build_body_parameter(referenced_definition, definition_name, route.options)
        end

        def move_params_to_new(definition, params)
          params, nested_params = params.partition { |x| !x[:name].to_s.include?('[') }

          unless params.blank?
            properties, required = build_properties(params)
            add_properties_to_definition(definition, properties, required)
          end

          nested_properties = build_nested_properties(nested_params) unless nested_params.blank?
          add_properties_to_definition(definition, nested_properties, []) unless nested_params.blank?
        end

        def build_properties(params)
          properties = {}
          required = []

          prepare_nested_types(params) if should_expose_as_array?(params)

          params.each do |param|
            name = param[:name].to_sym

            properties[name] = if should_expose_as_array?([param])
                                 document_as_array(param)
                               else
                                 document_as_property(param)
                               end

            required << name if deletable?(param) && param[:required]
          end

          [properties, required]
        end

        def document_as_array(param)
          {}.tap do |property|
            property[:type] = 'array'
            property[:description] = param.delete(:description) unless param[:description].nil?
            property[:items] = document_as_property(param)[:items]
          end
        end

        def document_as_property(param)
          property_keys.each_with_object({}) do |x, memo|
            value = param[x]
            value = param[:schema][x] if value.blank? && param[:schema] && param[:schema][x]
            next if value.blank?

            if x == :type
              if value == 'Hash'
                memo[x] = 'object'
              elsif value == 'Array'
                memo[x] = 'array'
                # Add default items if none specified
                memo[:items] = { type: 'string' } unless param[:items] || (param[:schema] && param[:schema][:items])
              elsif value == 'array'
                memo[x] = value
                # Add default items if none specified
                memo[:items] = { type: 'string' } unless param[:items] || (param[:schema] && param[:schema][:items])
              elsif @definitions[value].present?
                # Handle reference type
                if param[:description].present? || (param[:schema] && param[:schema][:description].present?)
                  description = param[:description] || param[:schema][:description]
                  memo['allOf'] = [{ '$ref' => "#/components/schemas/#{value}" }]
                  memo['description'] = description
                else
                  memo['$ref'] = "#/components/schemas/#{value}"
                end
              else
                # Normal type handling
                memo[x] = value
              end
            else
              memo[x] = value
            end
          end
        end

        def build_nested_properties(params, properties = {})
          property = params.bsearch { |x| x[:name].include?('[') }[:name].split('[').first

          nested_params, params = params.partition { |x| x[:name].start_with?("#{property}[") }
          prepare_nested_names(property, nested_params)

          recursive_call(properties, property, nested_params) unless nested_params.empty?
          build_nested_properties(params, properties) unless params.empty?

          properties
        end

        def recursive_call(properties, property, nested_params)
          if should_expose_as_array?(nested_params)
            properties[property.to_sym] = array_type
            move_params_to_new(properties[property.to_sym][:items], nested_params)
          else
            properties[property.to_sym] = object_type
            move_params_to_new(properties[property.to_sym], nested_params)
          end
        end

        def movable_params(params)
          to_delete = params.each_with_object([]) { |x, memo| memo << x if deletable?(x) }
          delete_from(params, to_delete)

          to_delete
        end

        def delete_from(params, to_delete)
          to_delete.each { |x| params.delete(x) }
        end

        def add_properties_to_definition(definition, properties, required)
          if definition.key?(:items)
            definition[:items][:properties] ||= {}
            definition[:items][:properties].deep_merge!(properties)
            add_to_required(definition[:items], required)
          else
            definition[:properties] ||= {}
            definition[:properties].deep_merge!(properties)
            add_to_required(definition, required)
          end
        end

        def add_to_required(definition, value)
          return if value.blank?

          definition[:required] ||= []
          definition[:required].push(*value)
        end

        def build_body_parameter(reference, name, options)
          {
            name: options[:body_name] || name,
            in: 'body',
            required: true,
            schema: { '$ref' => "#/components/schemas/#{reference}" }
          }
        end

        def build_definition(name, params, verb = nil)
          name = "#{verb}#{name}" if verb

          # Special handling for hash and array parameters - always create a schema definition
          has_hash_or_array = params.any? do |param|
            (param[:schema] && param[:schema][:type] == 'array') ||
              (param[:schema] && param[:schema][:type] == 'object') ||
              (param[:type] == 'Hash') ||
              (param[:type] == 'Array') ||
              # Check for 'array' and 'hash' as strings in type
              (param[:documentation] &&
                %w[array hash].include?(param[:documentation][:type].to_s))
          end

          # Create the definition regardless of array status if we have hash or array params
          @definitions[name] = if has_hash_or_array
                                 object_type
                               else
                                 should_expose_as_array?(params) ? array_type : object_type
                               end

          name
        end

        def array_type
          { type: 'array', items: { type: 'object', properties: {} } }
        end

        def object_type
          { type: 'object', properties: {} }
        end

        def prepare_nested_types(params)
          params.each do |param|
            next unless param[:items]

            param[:schema] ||= {}
            param[:schema][:type] = if param[:items][:type] == 'array'
                                      'string'
                                    elsif param[:items].key?('$ref')
                                      'object'
                                    else
                                      param[:items][:type]
                                    end
            param[:schema][:format] = param[:items][:format] if param[:items][:format]
            param.delete(:items) if param[:schema][:type] != 'object'
          end
        end

        def prepare_nested_names(property, params)
          params.each { |x| x[:name] = x[:name].sub(property, '').sub('[', '').sub(']', '') }
        end

        def unify!(params)
          params.each { |x| x[:in] = x.delete(:param_type) if x[:param_type] }
          params.each { |x| x[:in] = 'body' if x[:in] == 'formData' } if includes_body_param?(params)
        end

        def parse_model(ref)
          parts = ref.split('/')
          parts.last.include?('{') ? parts[0..-2].join('/') : parts[0..-1].join('/')
        end

        def property_keys
          %i[type format description minimum maximum items enum default]
        end

        def deletable?(param)
          param[:in] == 'body' ||
            param[:type] == 'Hash' ||
            param[:type] == 'Array' ||
            (param[:schema] && %w[object array].include?(param[:schema][:type])) ||
            (param[:documentation] &&
             (%w[Hash Array].include?(param[:documentation][:type]) ||
              param[:documentation][:in] == 'body' ||
              param[:documentation][:param_type] == 'body'))
        end

        def move_methods
          [:post, :put, :patch, 'POST', 'PUT', 'PATCH']
        end

        def includes_body_param?(params)
          params.map { |x| return true if x[:in] == 'body' || x[:param_type] == 'body' }
          false
        end

        def should_expose_as_array?(params)
          return false if params.empty?

          params.map do |x|
            schema = x[:schema] || {}
            return false if schema[:type] && schema[:type] != 'array'
          end

          true
        end

        def should_exposed_as(params)
          params.map { |x| return 'object' if x[:schema] && x[:schema][:type] && x[:schema][:type] != 'array' }
          'array'
        end
      end
    end
  end
end
