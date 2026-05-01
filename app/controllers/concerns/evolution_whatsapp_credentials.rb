# frozen_string_literal: true

# Evolution API accepts either the global key (AUTHENTICATION_API_KEY), stored as admin_token,
# or the per-instance token returned by POST /instance/create (often persisted as api_hash or hash).
# Falls back to InstallationConfig / ENV via GlobalConfigService when the channel omits credentials
# (same behaviour as Whatsapp::Providers::EvolutionService).
module EvolutionWhatsappCredentials
  extend ActiveSupport::Concern

  private

  def evolution_api_url_for_channel(channel)
    config = channel.provider_config || {}
    config['api_url'].to_s.strip.presence || GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
  end

  def evolution_api_key_for_channel(channel)
    config = channel.provider_config || {}
    (
      config['admin_token'].presence ||
      config['api_hash'].presence ||
      config['hash'].presence ||
      config['instance_token'].presence
    ).to_s.strip.presence || GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
  end
end
