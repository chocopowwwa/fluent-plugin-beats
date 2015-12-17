#
# Fluent
#
# Copyright (C) 2015 Masahiro Nakagawa
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module Fluent
  class BeatsInput < Input
    Plugin.register_input('beats', self)

    def initialize
      super

      require "lumberjack/beats"
      require "lumberjack/beats/server"
      require 'concurrent/executor/cached_thread_pool'
    end

    config_param :port, :integer, :default => 5044
    config_param :bind, :string, :default => '0.0.0.0'
    config_param :tag, :string, :default => nil
    config_param :metadata_as_tag, :bool, :default => nil
    config_param :format, :string, :default => nil
    config_param :max_connections, :integer, :default => nil # CachedThreadPool can't limit the number of threads
    config_param :use_ssl, :string, :default => false
    config_param :ssl_certificate, :string, :default => nil
    config_param :ssl_key, :string, :default => nil
    config_param :ssl_key_passphrase, :string, :default => nil

    def configure(conf)
      super

      if !@tag && !@metadata_as_tag
        raise ConfigError,  "'tag' or 'metadata_as_tag' parameter is required on beats input"
      end

      @time_parser = TextParser::TimeParser.new('%Y-%m-%dT%H:%M:%S.%N%z')
      if @format
        @parser = Plugin.new_parser(@format)
        @parser.configure(conf)
      end
      @connections = []
    end

    def start
      @lumberjack = Lumberjack::Beats::Server.new(
        :address => @bind, :port => @port, :ssl => @use_ssl, :ssl_certificate => @ssl_certificate,
        :ssl_key => @ssl_key, :ssl_key_passphrase => @ssl_key_passphrase)
      # Lumberjack::Beats::Server depends on normal accept so we need to launch thread for each connection.
      # TODO: Re-implement Beats Server with Cool.io for resource control
      @thread_pool = Concurrent::CachedThreadPool.new(:idletime => 15) # idletime setting is based on logstash beats input
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @lumberjack.close rescue nil
      @thread_pool.shutdown
      @thread.join
    end

    FILEBEAT_MESSAGE = 'message'

    def run
      until @lumberjack.closed?
        conn = @lumberjack.accept
        next if conn.nil?

        if @max_connections
          @connections.reject! { |c| c.closed? }
          if @connections.size >= @max_connections
            conn.close # close for retry on beats side
            sleep 1
            next
          end          
          @connections << conn
        end

        @thread_pool.post {
          begin
            conn.run { |map|
              tag = @metadata_as_tag ? map['@metadata']['beat'] : @tag

              if map.has_key?('message') &&  @format
                message = map.delete('message')
                @parser.parse(message) { |time, record|
                  record['@timestamp'] = map['@timestamp']
                  map.each { |k, v|
                    record[k] = v
                  }
                  router.emit(tag, time, record)
                }
                next
              end

              router.emit(tag, @time_parser.parse(map['@timestamp']), map)
            }
          rescue => e
            log.error "unexpected error", :error => e.to_s
            log.error_backtrace
          end
        }
      end
    end
  end
end