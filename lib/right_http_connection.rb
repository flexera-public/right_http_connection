#
# Copyright (c) 2007 RightScale Inc
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

require "net/https"
require "uri"
require "time"

#-----------------------------------------------------------------
# HttpConnection - Maintain a persistent HTTP connection to a remote
# server. The tricky part is that HttpConnection tries to be smart
# about errors. It will retry a request a few times and then "refuse"
# to talk to the server for a while until it does one retry. The intent
# is that we don't want to stall for many seconds on every request if the
# remote server went down.
# In addition, the error retry algorithm is global, as opposed to
# per-thread, this means that if one thread discovers that there is a
# problem then other threads get an error immediately until the lock-out period
# is over.
#-----------------------------------------------------------------


class Ec2Error < RuntimeError;
  attr_accessor :errors
  attr_accessor :errors_str
  attr_accessor :requestID
  attr_accessor :http_code
  def initialize(msg='', http_code=0, errors=[], requestID='')
    @errors     = errors
    @requestID  = requestID
    @http_code  = http_code
    @errors_str = errors.map{|code, msg| "#{code}: #{msg}"}.join("; ")
    super(msg)
  end
  def include?(pattern)
    @errors.each{ |code, msg| return true if code =~ pattern }
    return false
  end
end

#-----------------------------------------------------------------

class RightAWSParser
  attr_accessor :result
  attr_reader   :xmlpath
  def initialize
    @xmlpath = ''
    @result  = false
    @text    = ''
    reset
  end
  def tag_start(name, attributes)
    @text = ''
    tagstart(name, attributes)
    @xmlpath += @xmlpath.empty? ? name : "/#{name}"
  end
  def tag_end(name)
    @xmlpath[/^(.*?)\/?#{name}$/]
    @xmlpath = $1
    tagend(name)
  end
  def text(text)
    @text = text
    tagtext(text)
  end
    # Parser must have a lots of methods 
    # (see /usr/lib/ruby/1.8/rexml/parsers/streamparser.rb)
    # We dont need most of them in QEc2Parser and method_missing helps us
    # to skip their definition
  def method_missing(method, *params)
      # if the method is one of known - just skip it ...
    return if [:comment, :attlistdecl, :notationdecl, :elementdecl, 
               :entitydecl, :cdata, :xmldecl, :attlistdecl, :instruction, 
               :doctype].include?(method)
      # ... else - call super to raise an exception
    super(method, params)
  end
    # the functions to be overriden by children (if nessesery)
  def reset                     ; end
  def tagstart(name, attributes); end
  def tagend(name)              ; end
  def tagtext(text)             ; end
end

#-----------------------------------------------------------------
#      PARSERS: Errors
#-----------------------------------------------------------------

class RightErrorResponseParser < RightAWSParser
  attr_accessor :errors  # array of hashes: error/message
  attr_accessor :requestID
  def tagend(name)
    case name
      when 'RequestID' ; @requestID = @text
      when 'Code'      ; @code      = @text
      when 'Message'   ; @message   = @text
      when 'Error'     ; @errors   << [ @code, @message ]
    end
  end
  def reset
    @errors = []
  end
end


#-----------------------------------------------------------------


class RightHttpConnection
    # Timeouts
  HTTP_CONNECTION_RETRY_COUNT   = 3   # Number of retries to perform on the first error encountered
  HTTP_CONNECTION_OPEN_TIMEOUT  = 5   # Wait a short time when opening a connection
  HTTP_CONNECTION_READ_TIMEOUT  = 30  # Wait a little longer for a response, the serv may have to "think", after all
  HTTP_CONNECTION_RETRY_DELAY   = 15  # All requests during this period are disabled
  #--------------------
  # class methods
  #--------------------
    # Params hash
    # :user_agent => 'www.HostName.com'    # User agent
    # :ca_file    => 'path_to_file'        # A path of a CA certification file in PEM format. The file can contrain several CA certificats.
    # :logger     => Logger object         # If omitted then logs to STDOUT
  @@params = {}
  
  def self.params
    @@params
  end
  
  def self.params=(params)
    @@params = params
  end

  #------------------
  # instance methods
  #------------------
  attr_accessor :http
  attr_accessor :server
  attr_accessor :params      # see @@params
  attr_accessor :logger

  def initialize(params={})
    @params = params     
    @http   = nil
    @server = nil
    @logger = get_param(:logger) || 
              (RAILS_DEFAULT_LOGGER if defined?(RAILS_DEFAULT_LOGGER)) ||
              Logger.new(STDOUT)
  end

  def get_param(name)
    @params[name] || @@params[name]
  end

private
  #--------------
  # Retry state - Keep track of errors on a per-server basis
  #--------------
  @@state = {}  # retry state indexed by server: consecutive error count, error time, and error

  # number of consecutive errors seen for server, 0 all is ok
  def error_count
    @@state[@server] ? @@state[@server][:count] : 0
  end
  
  # time of last error for server, nil if all is ok
  def error_time
    @@state[@server] && @@state[@server][:time]
  end
  
  # message for last error for server, "" if all is ok
  def error_message
    @@state[@server] ? @@state[@server][:message] : ""
  end
  
  # add an error for a server
  def error_add(message)
    @@state[@server] = { :count => error_count+1, :time => Time.now, :message => message }
  end
  
  # reset the error state for a server (i.e. a request succeeded)
  def error_reset
    @@state.delete(@server)
  end
  
  # Error message stuff...
  def banana_message
    return "#{@server} temporarily unavailable: (#{error_message})"
  end

  def err_header
    return "#{self.class.name} : "
  end
  
  #---------------------------------------------------------------------
  # Start a fresh connection. Close any existing one first.
  #---------------------------------------------------------------------
  def start(request_params)
    # close the previous if exists
    @http.finish if @http && @http.started?
    # create new connection
    @server = request_params[:server]
    @port   = request_params[:port]
    @logger.info("Opening new HTTP connection to #{@server}")
    @http = Net::HTTP.new(@server, @port)
    @http.open_timeout = HTTP_CONNECTION_OPEN_TIMEOUT
    @http.read_timeout = HTTP_CONNECTION_READ_TIMEOUT
    if @port == 443
      verifyCallbackProc = Proc.new{ |ok, x509_store_ctx|
        code = x509_store_ctx.error
        msg = x509_store_ctx.error_string
          #debugger
        @logger.warn("##### #{@server} certificate verify failed: #{msg}") unless code == 0
        true
      }
      @http.use_ssl = true
      ca_file = get_param(:ca_file)
      if ca_file
        @http.verify_mode     = OpenSSL::SSL::VERIFY_PEER
        @http.verify_callback = verifyCallbackProc
        @http.ca_file         = ca_file 
      end
    end
    # open connection
    @http.start
  end

public
  
  #-----------------------------
  # Send HTTP request to server
  #-----------------------------
    
  def request(request_params)
    loop do
      # if we are inside a delay between retries: no requests this time!
      if error_count > HTTP_CONNECTION_RETRY_COUNT \
      && error_time + HTTP_CONNECTION_RETRY_DELAY > Time.now
        @logger.warn(err_header + " re-raising same error: #{banana_message} " +
                    "-- error count: #{error_count}, error age: #{Time.now - error_time}")  
        # TODO: figure out how to remove dependency on Ec2Error from this class...
        raise Ec2Error.new(banana_message)
      end
    
      # try to connect server(if connection does not exist) and get response data
      begin
        # (re)open connection to server if none exists
        start(request_params) unless @http
        
        # get response and return it
        request  = request_params[:request]
        request['User-Agent'] = get_param(:user_agent) || 'www.RightScale.com'
        # if we reuse request due to connection problem it may have @body set already
        # this case - 'data' must be set to nil
        # (Also: see net/http.rb's set_body_internal)
        data     = (request.request_body_permitted? && request.body.nil?) ? request_params[:data] : nil
        response = @http.request(request, data)
        
        error_reset
        return response
      
      # EOFError means the server closed the connection on us, that's not a problem, we
      # just start a new one (without logging any error)
      rescue EOFError => e
        @logger.debug(err_header + " server #{@server} closed connection")
        @http = nil
        
      rescue Exception => e  # See comment at bottom for the list of errors seen...
        # if ctrl+c is pressed - we have to reraise exception to terminate proggy 
        if e.is_a?(Interrupt) && !( e.is_a?(Errno::ETIMEDOUT) || e.is_a?(Timeout::Error))
          @logger.debug(err_header + " request to server #{@server} interrupted by ctrl-c")
          @http = nil
          raise
        end
        # oops - we got a banana: log it
        error_add(e.message)
        @logger.warn(err_header + " request failure count: #{error_count}, exception: #{e.inspect}")
        @http = nil
      end
    end
  end

# Errors received during testing:
#
#  #<Timeout::Error: execution expired>
#  #<Errno::ETIMEDOUT: Connection timed out - connect(2)>
#  #<SocketError: getaddrinfo: Name or service not known>
#  #<SocketError: getaddrinfo: Temporary failure in name resolution>
#  #<EOFError: end of file reached>
#  #<Errno::ECONNRESET: Connection reset by peer>
#  #<OpenSSL::SSL::SSLError: SSL_write:: bad write retry>
end

  # Synonym for RightHttpConnection for old code compartibility
class HttpConnection < RightHttpConnection; end