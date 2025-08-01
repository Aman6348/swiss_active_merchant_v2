module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class FlexchargeGateway < Gateway
      include Empty

      self.test_url = 'https://api-sandbox.flexfactor.io'
      self.live_url = 'https://api.flexfactor.io'
      self.supported_countries = %w[US CA]
      self.supported_cardtypes = %i[visa master american_express discover]
      self.default_currency = 'USD'
      self.money_format = :cents
      self.display_name = 'Flexcharge'

      def initialize(options = {})
        requires!(options, :api_key, :api_secret, :merchant_id, :token)
        super
        @api_key = options[:api_key]
        @api_secret = options[:api_secret]
        @mid = options[:merchant_id]
        @tokenization_key = options[:token]
        @site_id = options[:site_id]
        @response_http_code = nil
      end

      def purchase(amount, payment_source, options = {})
        token_response = get_access_token
        return token_response unless token_response.success?

        tokenize_response = tokenize_card(payment_source, options)
        return tokenize_response unless tokenize_response.success?

        post = {}
        add_invoice(post, amount, options)
        add_payment_method(post, tokenize_response.params['paymentMethod'])
        add_customer_data(post, options)
        add_billing_address(post, payment_source)
        add_merchant_data(post, options)
        add_idempotency_key(post, options)

        evaluate_response = commit('evaluate', post, token_response.authorization, options)
        handle_evaluate_response(evaluate_response, amount, options)
      end

      def capture(amount, authorization, options = {})
        token_response = get_access_token
        return token_response unless token_response.success?

        post = {}
        add_capture_data(post, amount, authorization, options)
        add_idempotency_key(post, options)

        commit('capture', post, token_response.authorization, options)
      end

      def refund(amount, authorization, options = {})
        token_response = get_access_token
        return token_response unless token_response.success?

        post = {}
        add_refund_data(post, amount)

        commit('refund', post, token_response.authorization, options.merge(order_id: authorization))
      end

      def verify_credentials
        response = get_access_token
        response.success?
      end

      private

      def tokenize_card(payment_source, options)
        uri = build_tokenization_uri
        payload = build_tokenization_payload(payment_source, options)

        begin
          raw_response = ssl_post(uri, payload.to_json, tokenization_headers)
          parsed = parse(raw_response)
          process_tokenization_response(parsed, payment_source)
        rescue ResponseError => e
          handle_response_error(e)
        end
      end

      def build_tokenization_uri
        base_url = test? ? test_url : live_url
        "#{base_url}/v1/tokenize?mid=#{@mid}&environment=#{@tokenization_key}"
      end

      def build_tokenization_payload(payment_source, options)
        {
          payment_method: {
            email: options[:email],
            credit_card: {
              first_name: payment_source.first_name,
              last_name: payment_source.last_name,
              number: '4000002760003184',
              verification_value: payment_source.verification_value,
              month: payment_source.month.to_s,
              year: payment_source.year.to_s
            }
          }
        }
      end

      def process_tokenization_response(parsed, payment_source)
        token = parsed.dig("transaction", "payment_method", "token")
        success = token.present?
        payment_method = build_payment_method_data(payment_source, token)

        Response.new(
          success,
          success ? 'Tokenization successful' : 'Tokenization failed',
          parsed.merge('paymentMethod' => payment_method),
          test: test?,
          authorization: token
        )
      end

      def build_payment_method_data(payment_source, token)
        {
          holderName: "#{payment_source.first_name} #{payment_source.last_name}",
          cardType: "CREDIT",
          expirationMonth: payment_source.month.to_i,
          expirationYear: payment_source.year.to_i,
          cardBinNumber: payment_source.bin_card,
          cardLast4Digits: payment_source.last_digits,
          cardNumber: token,
          token: true
        }
      end

      def handle_evaluate_response(evaluate_response, amount, options)
        return evaluate_response unless evaluate_response.success?

        status = evaluate_response.params['status']

        case status
        when 'CAPTUREREQUIRED', 'CHALLENGE'
          process_capture_required(evaluate_response, amount, options)
        else
          evaluate_response
        end
      end

      def process_capture_required(evaluate_response, amount, options)
        capture_response = capture(amount, evaluate_response.authorization, options)
        merged_params = evaluate_response.params.merge('capture' => capture_response.params)

        Response.new(
          capture_response.success?,
          capture_response.message,
          merged_params,
          test: test?,
          authorization: capture_response.authorization
        )
      end

      def add_invoice(post, amount, options)
        transaction_id = options[:order_id] || SecureRandom.hex(6)

        post[:transaction] = {
          amount: amount,
          currency: options[:currency] || default_currency,
          id: transaction_id,
          dynamicDescriptor: options[:descriptor] || 'YourBusiness',
          avsResultCode: 'Y',
          cvvResultCode: 'M',
          cavvResultCode: '2',
          responseCodeSource: 'G',
          responseCode: '05',
          responseStatus: 'DECLINED',
          transactionType: 'CAPTURE'
        }
      end

      def add_payment_method(post, payment_method)
        post[:paymentMethod] = payment_method
      end

      def add_customer_data(post, options)
        post[:payer] = {
          email: options[:email] || 'test@example.com'
        }
      end

      def add_billing_address(post, payment_source)
        post[:billingInformation] = {
          firstName: payment_source.first_name,
          lastName: payment_source.last_name,
          country: 'United States',
          countryCode: 'US',
          addressLine1: 'sdsd',
          city: 'sdfghj',
          state: 'asdfghj',
          zipcode: "asdfghj"
        }.compact
      end

      def add_merchant_data(post, options)
        post[:orderId] = options[:order_id] || SecureRandom.uuid
        post[:mid] = @mid
        post[:isDeclined] = true
        post[:siteId] = @site_id
      end

      def add_capture_data(post, amount, authorization, options)
        post[:orderId] = authorization
        post[:amount] = amount
        post[:currency] = options[:currency] || default_currency
      end

      def add_refund_data(post, amount)
        post[:amountToRefund] = amount.to_f / 100
      end

      def add_idempotency_key(post, options)
        post[:idempotencyKey] = options[:idempotency_key] || SecureRandom.uuid
      end

      def commit(action, params, access_token, options = {})
        request_url = build_request_url(action, options)
        raw_response = ssl_post(request_url, params.to_json, headers(access_token))
        response = parse(raw_response).merge('is_flexcharge' => 'true')
        succeeded = success_from(action, response)

        Response.new(
          succeeded,
          message_from(action, response),
          response,
          authorization: authorization_from(response),
          test: test?,
          request_method: :post,
          request_endpoint: request_url,
          request_body: params,
          response_type: response_type(response['status']),
          response_http_code: @response_http_code
        )
      rescue ResponseError => e
        handle_response_error(e)
      end

      def build_request_url(action, options)
        case action
        when 'evaluate'
          "#{url}/v1/evaluate"
        when 'capture'
          "#{url}/v1/capture"
        when 'refund'
          "#{url}/v1/orders/#{options[:order_id]}/refund"
        end
      end

      def headers(access_token)
        {
          'Authorization' => "Bearer #{access_token}",
          'accept' => 'application/json',
          'content-type' => 'application/*+json'
        }
      end

      def tokenization_headers
        {
          'Accept' => 'application/json',
          'Content-Type' => 'application/json'
        }
      end

      def get_access_token
        payload = build_token_payload
        raw_response = ssl_post("#{url}/v1/oauth2/token", payload.to_json, tokenization_headers)
        process_token_response(raw_response)
      rescue ResponseError => e
        handle_response_error(e)
      end

      def build_token_payload
        {
          AppKey: @api_key,
          AppSecret: @api_secret
        }
      end

      def process_token_response(raw_response)
        parsed = parse(raw_response)
        token = parsed['accessToken']
        success = token.present?

        Response.new(
          success,
          success ? 'Token Retrieved' : 'Token Request Failed',
          parsed,
          authorization: token,
          test: test?
        )
      end

      def url
        test? ? test_url : live_url
      end

      def parse(body)
        JSON.parse(body)
      end

      def success_from(action, response)
        case action
        when 'evaluate'
          status = response['status']
          status = 'Succeeded' if status == 'APPROVED'
          status == 'Succeeded'
        when 'capture'
          response['captureStatus'] == 'SUCCESS'
        when 'refund'
          response['status'] == 'SUCCESS'
        end
      end

      def message_from(action, response)
        case action
        when 'evaluate'
          status = response['status']
          status == 'APPROVED' ? 'Succeeded' : status
        when 'capture'
          response['captureStatus']
        when 'refund'
          if response['status'] == 'SUCCESS'
            response['status']
          else
            response['responseMessage']
          end
        end
      end

      def authorization_from(response)
        response['orderId']
      end

      def handle_response_error(error)
        @response_http_code = error.response&.code&.to_i
        body = error.response.body
        parsed = parse(body) rescue { 'error' => body }
        Response.new(
          false,
          parsed['error'] || 'Unspecified Error',
          parsed,
          test: test?,
          response_http_code: @response_http_code
        )
      end

      def handle_response(response)
        @response_http_code = response.code.to_i
        response.body
      end

      def response_type(status)
        case status
        when 'APPROVED'             then 0
        when 'DECLINED', 'FAILED'   then 2
        when 'CAPTUREREQUIRED', 'CHALLENGE' then 1
        else 1
        end
      end
    end
  end
end
