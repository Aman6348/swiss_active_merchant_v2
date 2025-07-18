module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class MollieGateway < Gateway
      include Empty

      SOFT_DECLINE_REASONS = %w[
        insufficient_funds
        card_expired
        card_declined
        temporary_failure
        verification_required
      ].freeze

      AUTHORIZATION_PREFIX = 'Bearer '.freeze
      CONTENT_TYPE         = 'application/json'.freeze

      self.test_url = 'https://api.mollie.com/v2'
      self.live_url = 'https://api.mollie.com/v2'
      self.supported_countries = %w[NL BE DE FR CH US GB]
      self.default_currency = 'EUR'
      self.supported_cardtypes = %i[visa master american_express]
      self.money_format = :cents
      self.homepage_url = 'https://www.mollie.com'
      self.display_name = 'Mollie'

      def initialize(options = {})
        requires!(options, :api_key)
        super
        @api_key = options[:api_key]
      end

      def purchase(amount, payment_method, options = {})
        return recurring(amount, payment_method, options) if recurring_payment?(payment_method, options)

        result = add_customer_to_payment(payment_method, options)
        return result if result.is_a?(Response) && !result.success?

        post = {}
        add_purchase_data(post, amount, payment_method, options)
        add_customer_data(post, result, options)
        add_payment_token(post, payment_method, options)
        add_addresses(post, options)

        commit('payments', post, options)
      end

      def recurring(amount, payment_method, options = {})
        post = {}
        add_recurring_data(post, amount, payment_method, options)

        commit('payments', post, options)
      end

      def refund(amount, authorization, options = {})
        post = {}
        add_refund_data(post, amount, authorization, options)

        commit("payments/#{authorization}/refunds", post, options)
      end

      def void(authorization, options = {})
        commit("payments/#{authorization}", {}, options.merge(method: :delete))
      end

      private

      def recurring_payment?(payment_method, options)
        options[:mollie_customer_id].present? && payment_method.mollie_mandate_id.present?
      end

      def add_customer_to_payment(payment_method, options)
        return options[:mollie_customer_id] if existing_customer?(options)

        customer_response = create_customer(options)
        return customer_response unless customer_response.success?

        customer_response.params['id']
      end

      def existing_customer?(options)
        options[:mollie_customer_id].present?
      end

      def create_customer(options)
        post = {}
        add_customer_creation_data(post, options)

        commit('customers', post, options)
      end

      def add_customer_creation_data(post, options)
        billing = options[:billing_address] || {}

        post[:name]   = billing[:name]
        post[:email]  = options[:email]
        post[:locale] = options[:locale]
      end

      def add_purchase_data(post, amount, payment_method, options)
        post[:amount]       = format_amount(amount, options[:currency])
        post[:description]  = "Order ##{options[:order_id]}"
        post[:method]       = payment_method.mollie_payment_method
        post[:sequenceType] = 'first'
        post[:locale]       = options[:locale]

        add_urls(post, options)
      end

      def add_recurring_data(post, amount, payment_method, options)
        post[:amount]       = format_amount(amount, options[:currency])
        post[:description]  = "Order ##{options[:order_id]}"
        post[:sequenceType] = 'recurring'
        post[:customerId]   = options[:mollie_customer_id]
        post[:mandateId]    = payment_method.mollie_mandate_id

        add_urls(post, options)
      end

      def add_refund_data(post, amount, authorization, options)
        post[:amount] = format_amount(amount, options[:currency])
        post[:description] = "Order ##{options[:order_id]} Refund at #{Time.current.to_i}"

        post[:metadata] = {
          refund_reference: "refund-#{options[:order_id]}-#{SecureRandom.hex(4)}"
        }
      end

      def add_customer_data(post, customer_result, options)
        customer_id = customer_result.is_a?(String) ? customer_result : customer_result.params['id']
        post[:customerId] = customer_id
      end

      def add_urls(post, options)
        post[:redirectUrl] = options.dig(:redirect_links, :success_url)
        post[:webhookUrl]  = options[:mollie_webhook_url]
        post[:cancelUrl]   = options.dig(:redirect_links, :failure_url)
      end

      def add_payment_token(post, payment_method, options)
        method = post[:method].to_s.downcase

        return unless %w[creditcard applepay googlepay].include?(method)

        token = payment_method.mollie_payment_token
        return unless token

        case method
        when 'creditcard'
          post[:cardToken] = token
        when 'applepay'
          post[:applePayPaymentToken] = token
        when 'googlepay'
          post[:googlePayPaymentToken] = token
        end
      end

      def add_addresses(post, options)
        post[:billingAddress]  = build_address(options[:billing_address])
        post[:shippingAddress] = build_address(options[:shipping_address])
      end

      def build_address(data)
        return if data.blank?

        first_name, last_name = split_names(data[:name])

        {
          title: data[:title],
          givenName: first_name,
          familyName: last_name,
          organizationName: data[:company],
          streetAndNumber: data[:address1],
          streetAdditional: data[:address2],
          postalCode: data[:zip],
          city: data[:city],
          region: data[:state],
          country: data[:country],
          phone: data[:phone]
        }.compact
      end

      def split_names(name)
        return [nil, nil] if name.blank?

        parts = name.split
        [parts.first, parts[1..].join(' ')].compact
      end

      def format_amount(amount, currency = nil)
        {
          currency: currency || default_currency,
          value: sprintf('%.2f', amount.to_f / 100)
        }
      end

      def commit(endpoint, post = {}, options = {})
        request_url = build_request_url(endpoint)
        payload = build_payload(post)
        method = options[:method]

        begin
          raw_response = perform_request(method, request_url, payload)
          response = parse(raw_response)
          succeeded = success_from(response)

          Response.new(
            succeeded,
            message_from(succeeded, response),
            response,
            authorization: authorization_from(response),
            test: test_from(response),
            error_code: error_code_from(succeeded, response),
            response_type: response_type_from(response),
            response_http_code: @response_http_code,
            request_endpoint: request_url,
            request_method: method,
            request_body: payload
          )
        rescue ResponseError => e
          handle_error_response(e)
        end
      end

      def build_request_url(endpoint)
        "#{url}/#{endpoint}"
      end

      def build_payload(post)
        post.compact
      end

      def perform_request(method, url, payload)
        case method
        when :post
          ssl_post(url, payload.to_json, headers)
        when :get
          ssl_get(url, headers)
        when :delete
          ssl_delete(url, headers)
        else
          raise ArgumentError, "Unsupported HTTP method: #{method}"
        end
      end

      def url
        test? ? test_url : live_url
      end

      def headers
        {
          'Authorization' => "#{AUTHORIZATION_PREFIX}#{@api_key}",
          'Content-Type' => CONTENT_TYPE
        }
      end

      def parse(response)
        @response_http_code = response.respond_to?(:code) ? response.code.to_i : nil
        JSON.parse(response)
      end

      def success_from(response)
        resource_type = response['resource']
        status = response['status']

        resource_type == 'customer' || %w[paid authorized].include?(status)
      end

      def message_from(succeeded, response)
        resource_type = response['resource']
        status = response['status']

        return 'Customer created' if resource_type == 'customer'
        return 'Pending' if status == 'open' || (resource_type == 'refund' && status == 'pending')
        return 'Success' if %w[paid authorized].include?(status)

        status || 'failed'
      end

      def error_code_from(succeeded, response)
        return nil if succeeded

        response['status'] || response['type']
      end

      def authorization_from(response)
        response['id']
      end

      def test_from(response)
        response['mode'] == 'test'
      end

      def response_type_from(response)
        return 'success' if response['sequenceType'] == 'recurring' && response['status'] == 'paid'

        nil
      end

      def handle_error_response(error)
        parsed     = JSON.parse(error.response.body) rescue {}
        error_code = error.response.code
        detail     = parsed['detail']
        field      = parsed['field']
        message    = parsed['title'] || parsed['message'] || error.message

        full_message = build_error_message(error_code, message, detail, field)

        Response.new(
          false,
          full_message,
          parsed,
          error_code: error_code
        )
      end

      def build_error_message(error_code, message, detail, field)
        components = ["Failed with #{error_code}", message, detail]
        components << "(field: #{field})" if field
        components.compact.join(': ')
      end
    end
  end
end
