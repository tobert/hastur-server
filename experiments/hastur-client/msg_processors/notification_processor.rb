#
# The HasturNotificationProcessor will send a notification/alert to Hastur.
#

require_relative "message_processor"
require_relative "../lib/client_config"
require_relative "../models/hastur_notification"

class HasturNotificationProcessor < HasturMessageProcessor
  
  def initialize
    super( HasturClientConfig::NOTIFY_ROUTE )
  end

  #
  # Checks if the message is a NOTIFICATION type and processes if true
  #
  def process_message(msg)
    if msg["method"] == @method
      # queue notification in case something happens
      name = msg['params']['name']
      subsystem = msg['params']['subsystem']
      uuid = msg['params']['uuid']
      id = msg['params']['id']
      notification = Hastur::Notification.new(name, subsystem, uuid, nil, id)
      HasturNotificationQueue.add( notification )
      # tell Hastur about this horrible incident
      flush_to_hastur(HasturClientConfig::NOTIFY_ROUTE, notification.to_json)
      return true
    end
    return false
  end
end