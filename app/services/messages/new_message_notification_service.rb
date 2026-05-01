class Messages::NewMessageNotificationService
  pattr_initialize [:message!]

  def perform
    return unless message.notifiable?

    notify_conversation_assignee
    notify_participating_users
    notify_evolution_go_inbox_team_when_unassigned
  end

  private

  delegate :conversation, :sender, :account, :inbox, to: :message

  # Evolution Go: unassigned conversations had no bell notification (only ActionCable).
  # Inbox members receive participating_conversation_new_message like implicit participants.
  def notify_evolution_go_inbox_team_when_unassigned
    return unless message.incoming?

    channel = inbox&.channel
    return unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'evolution_go'
    return if conversation.assignee.present?

    inbox.members.each do |agent|
      next if sender.is_a?(User) && sender.id == agent.id
      next if already_notified?(agent)

      NotificationBuilder.new(
        notification_type: 'participating_conversation_new_message',
        user: agent,
        account: account,
        primary_actor: conversation,
        secondary_actor: message
      ).perform
    end
  end

  def notify_conversation_assignee
    return if conversation.assignee.blank?
    return if already_notified?(conversation.assignee)
    return if conversation.assignee == sender

    NotificationBuilder.new(
      notification_type: 'assigned_conversation_new_message',
      user: conversation.assignee,
      account: account,
      primary_actor: message.conversation,
      secondary_actor: message
    ).perform
  end

  def notify_participating_users
    participating_users = conversation.conversation_participants.map(&:user)
    participating_users -= [sender] if sender.is_a?(User)

    participating_users.uniq.each do |participant|
      next if already_notified?(participant)

      NotificationBuilder.new(
        notification_type: 'participating_conversation_new_message',
        user: participant,
        account: account,
        primary_actor: message.conversation,
        secondary_actor: message
      ).perform
    end
  end

  # The user could already have been notified via a mention or via assignment
  # So we don't need to notify them again
  def already_notified?(user)
    conversation.notifications.exists?(user: user, secondary_actor: message)
  end
end
