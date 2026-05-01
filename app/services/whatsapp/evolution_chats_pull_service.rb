# frozen_string_literal: true

# Pulls chat list from Evolution POST /chat/findChats/:instanceName and ensures CRM conversations exist.
class Whatsapp::EvolutionChatsPullService
  pattr_initialize [:channel!]

  # @param force [Boolean] Manual sync from Chat UI skips throttle.
  def perform(force: false)
    unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'evolution'
      Rails.logger.warn '[EVOLUTION] Chats pull skipped: channel is not Evolution WhatsApp'
      return
    end

    instance_name = channel.provider_config['instance_name'].presence ||
                    channel.provider_config['instanceName'].presence
    if instance_name.blank?
      Rails.logger.warn '[EVOLUTION] Chats pull skipped: missing instance_name'
      return
    end

    cache_key = "evolution_chats_pull:#{channel.id}"
    unless force
      if Rails.cache.exist?(cache_key)
        Rails.logger.info '[EVOLUTION] Chats pull skipped (recent run)'
        return
      end
    end

    api_url = evolution_api_url
    api_key = evolution_api_key
    if api_url.blank? || api_key.blank?
      Rails.logger.warn '[EVOLUTION] Chats pull skipped: missing api_url or api key'
      return
    end

    url = "#{api_url.chomp('/')}/chat/findChats/#{instance_name}"
    Rails.logger.info "[EVOLUTION] Pulling chats from #{url}"

    response = HTTParty.post(
      url,
      headers: {
        'Content-Type' => 'application/json',
        'apikey' => api_key
      },
      body: {}.to_json,
      timeout: 180
    )

    unless response.success?
      Rails.logger.error "[EVOLUTION] findChats failed: #{response.code} — #{response.body.to_s.truncate(500)}"
      return
    end

    list = normalize_chat_list(response.parsed_response)
    Rails.logger.info "[EVOLUTION] findChats returned #{list.size} rows"

    Rails.cache.write(cache_key, true, expires_in: 30.minutes) unless force

    list.each do |row|
      Whatsapp::EvolutionChatRowSyncService.new(channel: channel, chat_payload: row).perform
    end
  rescue StandardError => e
    Rails.logger.error "[EVOLUTION] Chats pull error: #{e.message}"
    Rails.logger.debug { e.backtrace.join("\n") }
  end

  private

  def normalize_chat_list(parsed)
    return [] if parsed.blank?

    list =
      if parsed.is_a?(Array)
        parsed
      elsif parsed.is_a?(Hash)
        parsed['chats'] || parsed[:chats] || parsed['data'] || parsed[:data] || []
      else
        []
      end

    list.is_a?(Array) ? list : []
  end

  def evolution_api_url
    channel.provider_config['api_url'].to_s.strip.presence ||
      GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
  end

  def evolution_api_key
    cfg = channel.provider_config || {}
    (
      cfg['admin_token'].presence ||
      cfg['api_hash'].presence ||
      cfg['hash'].presence ||
      cfg['instance_token'].presence
    ).to_s.strip.presence || GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
  end
end
