require 'rest_client'
require 'builder'
require 'rexml/document'
require 'base64'
require 'nokogiri'
require 'pry'

class RubyBOSH
  BOSH_XMLNS    = 'http://jabber.org/protocol/httpbind'
  TLS_XMLNS     = 'urn:ietf:params:xml:ns:xmpp-tls'
  SASL_XMLNS    = 'urn:ietf:params:xml:ns:xmpp-sasl'
  BIND_XMLNS    = 'urn:ietf:params:xml:ns:xmpp-bind'
  SESSION_XMLNS = 'urn:ietf:params:xml:ns:xmpp-session'
  CLIENT_XMLNS  = 'jabber:client'
  HEADERS       =  {"Content-Type" => "text/xml; charset=utf-8", "Accept" => "text/xml"}

  class Error < StandardError; end
  class TimeoutError < RubyBOSH::Error; end
  class AuthFailed < RubyBOSH::Error; end
  class ConnFailed < RubyBOSH::Error; end

  attr_accessor :jid, :rid, :sid, :success, :custom_resource

  def initialize(jid:, password:, service_url:, timeout: 10, wait: 5, hold: 1)
    @service_url = service_url
    @password = password
    @success = false
    @timeout = timeout
    @wait    = wait
    @hold    = hold
    parse_jid(jid)
  end

  def success?
    @success == true
  end

  def self.initialize_session(*args)
    new(*args).connect
  end

  def connect
    initialize_bosh_session
    if send_auth_request
      send_restart_request
      request_resource_binding
      @success = send_session_request
    end

    raise RubyBOSH::AuthFailed, "could not authenticate #{@jid}" unless success?
    @rid += 1 #updates the rid for the next call from the browser
    [@jid, @sid, @rid]
  end

  private
  def initialize_bosh_session
    post(construct_body(:wait => @wait, :to => @host,
                                      :hold => @hold,
                                      "xmpp:version" => '1.0'))
  end

  def construct_body(params={}, &block)
    @rid ? @rid+=1 : @rid=rand(100000)

    builder = Builder::XmlMarkup.new
    parameters = {:rid => @rid, :xmlns => BOSH_XMLNS,
                  "xmpp:version" => "1.0",
                  "xmlns:xmpp" => "urn:xmpp:xbosh"}.merge(params)

    if block_given?
      builder.body(parameters) {|body| yield(body)}
    else
      builder.body(parameters)
    end
  end

  def send_auth_request
    request = construct_body(:sid => @sid) do |body|
      auth_string = "#{@jid}\x00#{@jid.split("@").first.strip}\x00#{@password}"
      body.auth(Base64.encode64(auth_string).gsub(/\s/,''),
                    :xmlns => SASL_XMLNS, :mechanism => 'PLAIN')
    end

    response = post(request)
    response.include?("sid")
  end

  def send_restart_request
    request_body = construct_body(:sid => @sid, "xmpp:restart" => true, "xmlns:xmpp" => 'urn:xmpp:xbosh')
    response = post(request_body)
    response.include?("stream:features")
  end

  def request_resource_binding
    request = construct_body(:sid => @sid) do |body|
      body.iq(:id => "bind_#{rand(100000)}", :type => "set",
              :xmlns => "jabber:client") do |iq|
        iq.bind(:xmlns => BIND_XMLNS) do |bind|
          bind.resource(resource_name)
        end
      end
    end
    response = post(request)
    response.include?("<jid>")
  end

  def send_session_request
    request = construct_body(:sid => @sid) do |body|
      body.iq(:xmlns => CLIENT_XMLNS, :type => "set",
              :id => "sess_#{rand(100000)}") do |iq|
        iq.session(:xmlns => SESSION_XMLNS)
      end
    end

    response = post(request)
    response.include?("body")
  end

  def parse(_response)
    puts "RESPONSE!!!!!!!!!!! #{_response}"
    doc = Nokogiri::XML(_response.to_s)
    @sid = doc.at_css("body").attributes["sid"].to_s rescue @sid
    _response
  end

  def post(body)
    # begin
    ::Timeout::timeout(@timeout) do
      log_post(body)
      response = RestClient.post(@service_url, body, HEADERS)
      parsed_response = parse(response)
    end
    # rescue ::Timeout::Error => e
    #   raise RubyBOSH::TimeoutError, e.message
    # rescue Errno::ECONNREFUSED => e
    #   raise RubyBOSH::ConnFailed, "could not connect to #{@host}\n#{e.message}"
    # rescue Exception => e
    #   raise RubyBOSH::Error, e.message
    # end
  end

  def log_post(msg)
    puts("Ruby-BOSH - SEND\n[#{now}]: #{msg}")
  end

  def log_response(msg)
    puts("Ruby-BOSH - RECV\n[#{now}]: #{msg}")
  end

  private
  def now
    Time.now.strftime("%a %b %d %H:%M:%S %Y")
  end

  def parse_jid(jid)
    split_jid = jid.split("/")
    @jid = split_jid.first
    @custom_resource = split_jid.last if split_jid.length > 1
    @host = @jid.split("@").last
  end

  def resource_name
    if @custom_resource.nil?
      "bosh_#{rand(10000)}"
    else
      @custom_resource
    end
  end
end
