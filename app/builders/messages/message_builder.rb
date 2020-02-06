require 'open-uri'

# This class creates both outgoing messages from chatwoot and echo outgoing messages based on the flag `outgoing_echo`
# Assumptions
# 1. Incase of an outgoing message which is echo, source_id will NOT be nil,
#    based on this we are showing "not sent from chatwoot" message in frontend
#    Hence there is no need to set user_id in message for outgoing echo messages.

class Messages::MessageBuilder
  attr_reader :response

  def initialize(response, inbox, outgoing_echo = false)
    @response = response
    @inbox = inbox
    @sender_id = (outgoing_echo ? @response.recipient_id : @response.sender_id)
    @message_type = (outgoing_echo ? :outgoing : :incoming)
  end

  def perform
    ActiveRecord::Base.transaction do
      build_contact
      build_message
    end
  rescue StandardError => e
    Raven.capture_exception(e)
    true
  end

  private

  def contact
    @contact ||= @inbox.contact_inboxes.find_by(source_id: @sender_id)&.contact
  end

  def build_contact
    return if contact.present?

    @contact = Contact.create!(contact_params.except(:remote_avatar_url))
    avatar_resource = LocalResource.new(contact_params[:remote_avatar_url])
    @contact.avatar.attach(io: avatar_resource.file, filename: avatar_resource.tmp_filename, content_type: avatar_resource.encoding)

    @contact_inbox = ContactInbox.create(contact: contact, inbox: @inbox, source_id: @sender_id)
  end

  def build_message
    @message = conversation.messages.create!(message_params)
    (response.attachments || []).each do |attachment|
      attachment_obj = @message.build_attachment(attachment_params(attachment).except(:remote_file_url))
      attachment_obj.save!
      attach_file(attachment_obj, attachment_params(attachment)[:remote_file_url]) if attachment_params(attachment)[:remote_file_url]
    end
  end

  def attach_file(attachment, file_url)
    file_resource = LocalResource.new(file_url)
    attachment.file.attach(io: file_resource.file, filename: file_resource.tmp_filename, content_type: file_resource.encoding)
  end

  def conversation
    @conversation ||= Conversation.find_by(conversation_params) || build_conversation
  end

  def build_conversation
    @contact_inbox ||= contact.contact_inboxes.find_by!(source_id: @sender_id)
    Conversation.create!(conversation_params.merge(
                           contact_inbox_id: @contact_inbox.id
                         ))
  end

  def attachment_params(attachment)
    file_type = attachment['type'].to_sym
    params = { file_type: file_type, account_id: @message.account_id }

    if [:image, :file, :audio, :video].include? file_type
      params.merge!(file_type_params(attachment))
    elsif file_type == :location
      params.merge!(location_params(attachment))
    elsif file_type == :fallback
      params.merge!(fallback_params(attachment))
    end

    params
  end

  def file_type_params(attachment)
    {
      external_url: attachment['payload']['url'],
      remote_file_url: attachment['payload']['url']
    }
  end

  def location_params(attachment)
    lat = attachment['payload']['coordinates']['lat']
    long = attachment['payload']['coordinates']['long']
    {
      external_url: attachment['url'],
      coordinates_lat: lat,
      coordinates_long: long,
      fallback_title: attachment['title']
    }
  end

  def fallback_params(attachment)
    {
      fallback_title: attachment['title'],
      external_url: attachment['url']
    }
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: contact.id
    }
  end

  def message_params
    {
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: @message_type,
      content: response.content,
      source_id: response.identifier
    }
  end

  def contact_params
    begin
      k = Koala::Facebook::API.new(@inbox.channel.page_access_token) if @inbox.facebook?
      result = k.get_object(@sender_id) || {}
    rescue Exception => e
      result = {}
      Raven.capture_exception(e)
    end
    {
      name: "#{result['first_name'] || 'John'} #{result['last_name'] || 'Doe'}",
      account_id: @inbox.account_id,
      remote_avatar_url: result['profile_pic'] || ''
    }
  end
end
