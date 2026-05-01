module EvolutionGoConcern
  extend ActiveSupport::Concern

  private

  # Preenche api_url/admin_token a partir da InstallationConfig quando o canal usa "config global"
  # (frontend não grava api_url/admin_token no provider_config).
  #
  # only_fill_blanks: true — só completa @api_url / tokens já definidos no pedido (ex.: AuthorizationsController).
  def hydrate_evolution_go_credentials_from_channel!(whatsapp_channel, only_fill_blanks: false)
    cfg = (whatsapp_channel.provider_config || {}).with_indifferent_access

    merged = {
      api_url: cfg[:api_url].presence || GlobalConfigService.load('EVOLUTION_GO_API_URL', '').to_s.strip,
      admin_token: cfg[:admin_token].presence || GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '').to_s.strip,
      instance_token: cfg[:instance_token].presence,
      instance_uuid: cfg[:instance_uuid].presence || cfg[:instance_name].presence,
      instance_name: cfg[:instance_name].presence
    }

    if only_fill_blanks
      @api_url = @api_url.presence || merged[:api_url]
      @admin_token = @admin_token.presence || merged[:admin_token]
      @instance_token = @instance_token.presence || merged[:instance_token]
      @instance_uuid = @instance_uuid.presence || merged[:instance_uuid]
      @instance_name = @instance_name.presence || merged[:instance_name]
    else
      @api_url = merged[:api_url]
      @admin_token = merged[:admin_token]
      @instance_token = merged[:instance_token]
      @instance_uuid = merged[:instance_uuid].presence || @instance_uuid
      @instance_name = merged[:instance_name].presence || @instance_name
    end
  end

  def connect_instance(api_url, instance_token, _instance_name = nil)
    connect_url = "#{api_url.chomp('/')}/instance/connect"
    Rails.logger.info "Evolution Go API: Connecting instance at #{connect_url}"

    webhook_url_value = webhook_url

    request_body = {
      subscribe: [
        'MESSAGE',
        'READ_RECEIPT',
        'CONNECTION'
      ],
      webhookUrl: webhook_url_value
    }

    uri = URI.parse(connect_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.info "Evolution Go API: Connect instance request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Connect instance response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Connect instance response body: #{response.body}"

    raise "Failed to connect instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Connect instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API connect instance endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Connect instance connection error: #{e.class} - #{e.message}"
    raise "Failed to connect instance: #{e.message}"
  end

  def webhook_url
    api_url = ENV.fetch('BACKEND_URL', 'https://api.evoai.app')
    "#{api_url.chomp('/')}/webhooks/whatsapp/evolution_go"
  end
end
