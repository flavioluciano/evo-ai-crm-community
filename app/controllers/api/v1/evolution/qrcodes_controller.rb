class Api::V1::Evolution::QrcodesController < Api::V1::BaseController
  include EvolutionWhatsappCredentials

  def show
    Rails.logger.info "Evolution API get QR code called for instance: #{params[:id]}"

    begin
      instance_name = params[:id]
      channel = find_whatsapp_channel_by_instance_name(instance_name)

      if channel
        api_url = evolution_api_url_for_channel(channel)
        api_hash = evolution_api_key_for_channel(channel)

        result = get_qrcode(api_url, api_hash, instance_name)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API get QR code error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def create
    Rails.logger.info "Evolution API QR code refresh called with params: #{params.inspect}"

    begin
      # Extract parameters
      auth_params = params[:qrcode] || params
      api_url = auth_params[:api_url]
      api_hash = auth_params[:api_hash]
      instance_name = auth_params[:instance_name]

      Rails.logger.info "Evolution API: Refreshing QR code for instance #{instance_name}"

      # Get updated QR code
      qrcode_data = get_qrcode(api_url, api_hash, instance_name)

      render json: {
        success: true,
        qrcode: qrcode_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution API QR code refresh error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def find_whatsapp_channel_by_instance_name(instance_name)
    Channel::Whatsapp.joins(:inbox)
                     .where(provider: 'evolution')
                     .find do |ch|
      config = ch.provider_config || {}
      candidates = [
        config['instance_name'],
        config['instanceName'],
        config['instance'],
        ch.inbox&.name
      ].compact.uniq
      candidates.include?(instance_name)
    end
  end

  def evolution_http_error_message(response)
    body = response.body.to_s
    parsed = JSON.parse(body)
    raw = parsed['response'] && parsed['response']['message']
    msg =
      case raw
      when Array
        raw.flatten.map(&:to_s).reject(&:blank?).join('; ')
      when String
        raw
      else
        parsed['message'].presence
      end
    msg ||= body.truncate(400)
    "Evolution API HTTP #{response.code}: #{msg}"
  rescue JSON::ParserError
    "Evolution API HTTP #{response.code}: #{body.truncate(400)}"
  end

  # Normalizes GET /instance/connect/:name payloads (Evolution v2 returns QR at top level or under qrcode).
  def normalize_evolution_connect_response(parsed)
    if parsed['error'] == true
      msg = parsed['message'].to_s.presence || 'Evolution API returned an error'
      raise msg
    end

    if parsed['instance'].is_a?(Hash) && parsed['instance']['state'] == 'open'
      return {
        connected: true,
        state: 'open',
        instance_name: parsed['instance']['instanceName']
      }
    end

    nested = parsed['qrcode'] || parsed['qrCode']
    base64 = parsed['base64']
    base64 = nested['base64'] if base64.blank? && nested.is_a?(Hash)
    pairing = parsed['pairingCode']
    pairing = nested['pairingCode'] if pairing.blank? && nested.is_a?(Hash)

    {
      base64: base64,
      pairingCode: pairing,
      connected: false
    }
  end

  def get_qrcode(api_url, api_hash, instance_name)
    raise ArgumentError, 'Evolution api_url is missing for this channel.' if api_url.blank?
    raise ArgumentError, 'Evolution API key is missing (set admin_token or api_hash on the channel).' if api_hash.blank?

    qrcode_url = "#{api_url.chomp('/')}/instance/connect/#{instance_name}"
    Rails.logger.info "Evolution API: Getting QR code from #{qrcode_url}"

    uri = URI.parse(qrcode_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution API: QR code response code: #{response.code}"
    Rails.logger.info "Evolution API: QR code response body: #{response.body}"

    raise evolution_http_error_message(response) unless response.is_a?(Net::HTTPSuccess)

    parsed_response = JSON.parse(response.body)
    normalize_evolution_connect_response(parsed_response)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: QR code JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API connect endpoint'
  end
end
