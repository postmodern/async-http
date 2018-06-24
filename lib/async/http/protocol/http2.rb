# Copyright, 2018, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative '../request'
require_relative '../response'
require_relative '../headers'
require_relative '../body/writable'

require_relative 'http11'

require 'async/notification'

require 'http/2'

module Async
	module HTTP
		module Protocol
			# A server that supports both HTTP1.0 and HTTP1.1 semantics by detecting the version of the request.
			class HTTP2
				def self.client(stream)
					self.new(::HTTP2::Client.new, stream)
				end
				
				def self.server(stream)
					self.new(::HTTP2::Server.new, stream)
				end
				
				HTTPS = 'https'.freeze
				SCHEME = ':scheme'.freeze
				METHOD = ':method'.freeze
				PATH = ':path'.freeze
				AUTHORITY = ':authority'.freeze
				REASON = ':reason'.freeze
				STATUS = ':status'.freeze
				VERSION = 'HTTP/2.0'.freeze
				
				def initialize(controller, stream)
					@controller = controller
					@stream = stream
					
					@controller.on(:frame) do |data|
						@stream.write(data)
						@stream.flush
					end
					
					@controller.on(:frame_sent) do |frame|
						Async.logger.debug(self) {"Sent frame: #{frame.inspect}"}
					end
					
					@controller.on(:frame_received) do |frame|
						Async.logger.debug(self) {"Received frame: #{frame.inspect}"}
					end
					
					@goaway = false
					
					@controller.on(:goaway) do |payload|
						Async.logger.error(self) {"goaway: #{payload.inspect}"}
						
						@goaway = true
					end
					
					@count = 0
				end
				
				attr :count
				
				# Multiple requests can be processed at the same time.
				def multiplex
					@controller.remote_settings[:settings_max_concurrent_streams]
				end
				
				# Can we use this connection to make requests?
				def good?
					@stream.connected?
				end
				
				def reusable?
					!@goaway || !@stream.closed?
				end
				
				def version
					VERSION
				end
				
				def start_connection
					@reader ||= read_in_background
				end
				
				def read_in_background(task: Task.current)
					task.async do |nested_task|
						nested_task.annotate("#{version} reading data")
						
						while buffer = @stream.read_partial
							@controller << buffer
						end
						
						Async.logger.debug(self) {"Connection reset by peer!"}
					end
				end
				
				def close
					Async.logger.debug(self) {"Closing connection"}
					
					@reader.stop if @reader
					@stream.close
				end
				
				class Request < HTTP::Request
					def initialize(stream)
						super(nil, nil, nil, VERSION, Headers.new, Body::Writable.new)
						
						@stream = stream
					end
					
					attr :stream
					
					def assign_headers(headers)
						headers.each do |key, value|
							if key == METHOD
								raise BadRequest, "Request method already specified" if @method
								
								@method = value
							elsif key == PATH
								raise BadRequest, "Request path already specified" if @path
								
								@path = value
							elsif key == AUTHORITY
								raise BadRequest, "Request authority already specified" if @authority
								
								@authority = value
							else
								@headers[key] = value
							end
						end
					end
				end
				
				def receive_requests(task: Task.current, &block)
					# emits new streams opened by the client
					@controller.on(:stream) do |stream|
						request = Request.new(stream)
						body = request.body
						
						stream.on(:headers) do |headers|
							begin
								request.assign_headers(headers)
							rescue
								Async.logger.error(self) {$!}
								
								stream.headers({
									STATUS => "400"
								}, end_stream: true)
							else
								task.async do
									generate_response(request, stream, &block)
								end
							end
						end
						
						stream.on(:data) do |chunk|
							body.write(chunk.to_s) unless chunk.empty?
						end
						
						stream.on(:half_close) do
							# We are no longer receiving any more data frames:
							body.finish
						end
						
						stream.on(:close) do |error|
							body.stop(EOFError.new(error)) if error
						end
					end
					
					start_connection
					@reader.wait
				end
				
				# Generate a response to the request. If this fails, the stream is terminated and the error is reported.
				private def generate_response(request, stream, &block)
					# We need to close the stream if the user code blows up while generating a response:
					response = begin
						yield(request, stream)
					rescue
						stream.close(:internal_error)
						
						raise
					end
					
					if response
						headers = Headers::Merged.new({
							STATUS => response.status,
						}, response.headers)
						
						if response.body.nil? or response.body.empty?
							stream.headers(headers, end_stream: true)
							response.body.read if response.body
						else
							stream.headers(headers, end_stream: false)
							
							response.body.each do |chunk|
								stream.data(chunk, end_stream: false)
							end
							
							stream.data("", end_stream: true)
						end
					else
						stream.close(:internal_error) unless stream.state == :closed
					end
				rescue
					Async.logger.error(request) {$!}
				end
				
				def call(request)
					request.version ||= self.version
					
					stream = @controller.new_stream
					@count += 1
					
					headers = Headers::Merged.new({
						SCHEME => HTTPS,
						METHOD => request.method,
						PATH => request.path,
						AUTHORITY => request.authority,
					}, request.headers)
					
					finished = Async::Notification.new
					
					exception = nil
					response = Response.new
					response.version = self.version
					response.headers = Headers.new
					body = Body::Writable.new
					response.body = body
					
					stream.on(:headers) do |headers|
						headers.each do |key, value|
							if key == STATUS
								response.status = value.to_i
							elsif key == REASON
								response.reason = value
							else
								response.headers[key] = value
							end
						end
						
						# At this point, we are now expecting two events: data and close.
						stream.on(:close) do |error|
							# If we receive close after this point, it's not a request error, but a failure we need to signal to the body.
							if error
								body.stop(EOFError.new(error))
							else
								body.finish
							end
						end
						
						finished.signal
					end
					
					stream.on(:data) do |chunk|
						body.write(chunk.to_s) unless chunk.empty?
					end
					
					stream.on(:close) do |error|
						# The remote server has closed the connection while we were sending the request.
						if error
							exception = EOFError.new(error)
							finished.signal
						end
					end
					
					if request.body.nil? or request.body.empty?
						stream.headers(headers, end_stream: true)
						request.body.read if request.body
					else
						begin
							stream.headers(headers)
						rescue
							raise RequestFailed.new
						end
						
						request.body.each do |chunk|
							stream.data(chunk, end_stream: false)
						end
							
						stream.data("")
					end
					
					start_connection
					@stream.flush
					
					Async.logger.debug(self) {"Stream flushed, waiting for signal."}
					finished.wait
					
					if exception
						raise exception
					end
					
					Async.logger.debug(self) {"Stream finished: #{response.inspect}"}
					return response
				end
			end
		end
	end
end
