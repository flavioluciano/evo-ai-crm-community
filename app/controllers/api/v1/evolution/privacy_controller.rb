class Api::V1::Evolution::PrivacyController < Api::V1::BaseController
  include EvolutionWhatsappCredentials

  before_action :set_channel, only: [:show, :update]

  # GET /api/v1/evolution/privacy/:id
  def show
    Rails.logger.info "Evolution API: Getting privacy settings for instance #{params[:id]}"

    begin
      result = fetch_privacy_settings(@api_url, @api_hash, @instance_name)

      render json: {
        success: true,
        data: result
      }
    rescue StandardError => e
      Rails.logger.error "Evolution API: Get privacy error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # PUT /api/v1/evolution/privacy/:id
  def update
    Rails.logger.info "Evolution API: Updating privacy settings for instance #{params[:id]}"

    begin
      privacy = params[:privacy]
      result = update_privacy_settings(@api_url, @api_hash, @instance_name, privacy)

      render json: {
        success: true,
        message: 'Privacy settings updated successfully',
        data: result
      }
    rescue StandardError => e
      Rails.logger.error "Evolution API: Update privacy error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def set_channel
    instance_name = params[:id]
    channel = find_whatsapp_channel_by_instance_name(instance_name)

    if channel
      @instance_name = instance_name
      @api_url = evolution_api_url_for_channel(channel)
      @api_hash = evolution_api_key_for_channel(channel)
    else
      render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
    end
  end

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

  def fetch_privacy_settings(api_url, api_hash, instance_name)
    url = "#{api_url.chomp('/')}/chat/fetchPrivacySettings/#{instance_name}"
    Rails.logger.info "Evolution API: Fetching privacy from #{url}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution API: Get privacy response #{response.code}: #{response.body}"

    raise "Failed to get privacy settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError
    raise 'Invalid response from Evolution API privacy endpoint'
  rescue StandardError => e
    raise "Failed to get privacy settings: #{e.message}"
  end

  def update_privacy_settings(api_url, api_hash, instance_name, privacy)
    url = "#{api_url.chomp('/')}/chat/updatePrivacySettings/#{instance_name}"
    Rails.logger.info "Evolution API: Updating privacy at #{url}"

    request_body = {
      readreceipts: privacy[:readreceipts] || privacy[:readReceipts],
      profile: privacy[:profile],
      status: privacy[:status],
      online: privacy[:online],
      last: privacy[:last] || privacy[:lastSeen],
      groupadd: privacy[:groupadd] || privacy[:groupAdd]
    }.compact

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.info "Evolution API: Update privacy body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution API: Update privacy response #{response.code}: #{response.body}"

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.error "Evolution API: Update privacy FAILED — Status: #{response.code}, Body: #{response.body}, Sent body: #{request_body.to_json}"
      raise "Failed to update privacy settings. Status: #{response.code}, Body: #{response.body}"
    end

    JSON.parse(response.body)
  rescue JSON::ParserError
    raise 'Invalid response from Evolution API update privacy endpoint'
  rescue StandardError => e
    raise "Failed to update privacy settings: #{e.message}"
  end
end
