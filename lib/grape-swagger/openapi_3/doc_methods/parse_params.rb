# frozen_string_literal: true

require 'grape-swagger/doc_methods/parse_params'
require 'grape-swagger/endpoint/info_object_builder'

module GrapeSwagger
  module DocMethods
    class OpenAPIParseParams < GrapeSwagger::DocMethods::ParseParams
      class << self
        def call(param, values, _path, _route, definitions, _consumes = nil)
          @parsed_param = { name: param }
          data_type = values.is_a?(Hash) ? values[:type] : nil

          # Initialize schema
          @parsed_param[:schema] = {}

          if values.is_a?(Hash)
            # Properly initialize the schema
            document_hidden_params(values)
            data_type = parse_data_type_value(values)
            document_attributes(values)
            document_type(data_type, definitions)
            add_array_validator(values, data_type, definitions)

            # Handle header parameters explicitly
            if values[:documentation] && values[:documentation][:header]
              @parsed_param[:in] = 'header'
            # Handle body parameters
            elsif values[:documentation] && (values[:documentation][:in] == 'body' || values[:documentation][:param_type] == 'body')
              @parsed_param[:in] = 'body'
            # Set param type based on param_type or default to query
            else
              @parsed_param[:in] = values[:param_type] || values[:in] || 'query'
            end

            # Properly handle required flag
            @parsed_param[:required] = values[:required] || false
          end

          # Ensure array parameters are properly constructed
          ensure_array_param(data_type) if data_type.to_s.include?('Array')

          # Remove any unnecessary schema if it's empty
          @parsed_param.delete(:schema) if @parsed_param[:schema].empty?

          # Description should be outside schema
          if @parsed_param[:schema] && @parsed_param[:schema][:description]
            @parsed_param[:description] = @parsed_param[:schema].delete(:description)
          end

          @parsed_param
        end

        private

        # Checks if the parameter is marked as hidden and should be excluded from documentation
        # @param values [Hash] parameter values
        def document_hidden_params(values)
          return unless values.is_a?(Hash)

          documentation = values[:documentation] || {}
          hidden = documentation[:hidden]

          # Skip hidden parameters (when hidden is true or when it's a Proc that evaluates to true)
          if hidden.is_a?(Proc)
            @parsed_param[:type] = 'skip' if hidden.call
          elsif hidden
            @parsed_param[:type] = 'skip'
          end
        end

        # Extract data type from values
        # @param values [Hash] parameter values
        # @return [Symbol, String, nil] The data type
        def parse_data_type_value(values)
          return unless values.is_a?(Hash)

          # First try to get type from documentation
          if values[:documentation].present? && values[:documentation][:type].present?
            return values[:documentation][:type]
          end

          # Otherwise use the type directly from values
          values[:type]
        end

        # Add additional attributes to the parsed_param
        # @param values [Hash] parameter values
        def document_attributes(values)
          return unless values.is_a?(Hash)

          @parsed_param[:schema] ||= {}
          documentation = values[:documentation] || {}

          # Copy description
          description = documentation[:desc] || values[:desc]
          @parsed_param[:schema][:description] = description if description.present?

          # Copy example
          example = documentation[:example] || values[:example]
          @parsed_param[:schema][:example] = example if example.present?

          # Copy default value
          default_value = documentation[:default] || values[:default]
          @parsed_param[:schema][:default] = default_value if default_value.present?

          # Handle values/enum
          enum_values = documentation[:values] || values[:values]
          enum_or_range_values = parse_enum_or_range_values(enum_values)
          @parsed_param[:schema].merge!(enum_or_range_values) if enum_or_range_values.present?
        end

        def ensure_array_param(data_type)
          return unless data_type.to_s.include?('Array')

          @parsed_param[:schema] ||= {}
          @parsed_param[:schema][:type] = 'array'
          @parsed_param[:schema][:items] ||= { type: 'string' }
        end

        def document_type(data_type, definitions)
          return if data_type.nil?

          @parsed_param[:schema] ||= {}

          if data_type.to_s.include?('Array') && data_type.is_a?(String)
            document_array_param(data_type.sub('Array', '').sub(/^\[|\]$/, ''), definitions)
          elsif data_type.to_s.include?('Array') && data_type.is_a?(Class)
            document_array_param(data_type.to_s.sub('Array', '').sub(/^\[|\]$/, ''), definitions)
          elsif data_type.to_s.include?('Array[') # Array[Type] syntax
            inner_type = data_type.to_s.sub('Array[', '').sub(']', '')
            document_array_param({ data_type: inner_type }, definitions)
          elsif data_type.is_a?(Hash) # Nested parameters
            data_type[:documentation] ||= {}
            parameter_type = data_type[:documentation][:param_type] || data_type[:param_type]
            nested_type = data_type[:documentation][:type] || data_type[:type]

            document_nested_type(nested_type, parameter_type, definitions)
          else
            document_type_and_format(data_type.is_a?(Class) ? { type: data_type } : data_type, data_type)
          end
        end

        def document_type_and_format(settings, data_type)
          @parsed_param[:schema] ||= {}
          if DataType.primitive?(data_type)
            data = DataType.mapping(data_type)

            # Replace the parallel assignment with explicit assignments to avoid type issues
            if data.is_a?(Array)
              @parsed_param[:schema][:type] = data[0]
              @parsed_param[:schema][:format] = data[1] if data.length > 1
            else
              @parsed_param[:schema][:type] = data
            end
          else
            @parsed_param[:schema][:type] = data_type
          end

          # Make sure settings[:format] is only used when present and schema is properly initialized
          return unless settings.is_a?(Hash) && settings[:format].present?

          @parsed_param[:schema][:format] = settings[:format]
        end

        def document_array_param(value_type, definitions)
          if value_type.is_a?(Hash) && value_type[:documentation].present?
            param_type = value_type[:documentation][:param_type]
            doc_type = value_type[:documentation][:type]
            type = DataType.mapping(doc_type) if doc_type && !DataType.request_primitive?(doc_type)
            collection_format = value_type[:documentation][:collectionFormat]
          end

          param_type ||= value_type[:param_type] if value_type.is_a?(Hash)

          # Ensure we have a schema
          @parsed_param[:schema] ||= {}
          @parsed_param[:schema][:type] = 'array'

          array_items = {}
          if value_type.is_a?(Hash) && definitions[value_type[:data_type]]
            array_items['$ref'] = "#/components/schemas/#{value_type[:data_type]}"
          elsif value_type.is_a?(String) && definitions[value_type]
            array_items['$ref'] = "#/components/schemas/#{value_type}"
          else
            array_items[:type] = if value_type.is_a?(Hash) && type
                                   type
                                 elsif value_type.is_a?(String)
                                   value_type
                                 else
                                   'string'
                                 end
          end
          array_items[:format] = @parsed_param[:schema].delete(:format) if @parsed_param[:schema][:format]

          if value_type.is_a?(Hash)
            values = value_type[:values] || nil
            enum_or_range_values = parse_enum_or_range_values(values)
            array_items.merge!(enum_or_range_values) if enum_or_range_values

            array_items[:default] = value_type[:default] if value_type[:default].present?
          end

          @parsed_param[:in] = param_type || 'query' if param_type
          @parsed_param[:schema][:items] = array_items
          return unless collection_format && DataType.collections.include?(collection_format)

          @parsed_param[:collectionFormat] =
            collection_format
        end

        def parse_enum_or_range_values(values)
          case values
          when Proc
            if values.parameters.empty?
              proc_value = values.call
              case proc_value
              when Range
                parse_range_values(proc_value)
              when Array
                { enum: proc_value }
              else
                { enum: [proc_value] }
              end
            end
          when Range
            if values.first.is_a?(Numeric)
              parse_range_values(values)
            else
              { enum: values.to_a }
            end
          else
            if values
              if values.respond_to? :each
                { enum: values }
              else
                { enum: [values] }
              end
            end
          end
        end

        def parse_range_values(values)
          if values.first.is_a?(Integer) || values.first.is_a?(Numeric)
            { minimum: values.first, maximum: values.last }
          else
            { enum: values.to_a }
          end
        end

        def add_array_validator(values, data_type, definitions)
          return unless values.is_a?(Hash) && data_type.to_s.include?('Array')

          # If we have a special validator for this array, use it
          return unless values[:documentation].present? && values[:documentation][:is_array]

          document_array_param(values, definitions)
        end
      end
    end
  end
end
